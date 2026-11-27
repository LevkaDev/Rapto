//
//  AccessibilityService.swift
//  Rapto
//
//  Handles accessibility permission checking and window control via AXUIElement.
//

import Foundation
import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "AccessibilityService")

class AccessibilityService {
    
    init(configureSystemTimeout: Bool = true) {
        guard configureSystemTimeout else { return }
        // AX calls run on the main thread; the system default of 6 s per call lets one hung app freeze Rapto.
        // One second still leaves room for apps that are busy for a moment
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Float(AppResponsiveness.messagingTimeout))
    }
    
    // MARK: - AXUIElement Cache
    
    /// Cache of AXUIElement for windows without _AXWindowID (e.g., iTerm2)
    /// This prevents re-matching by position which can cause window confusion
    private var axElementCache: [CGWindowID: AXUIElement] = [:]
    
    /// Clear cache for a specific window (call when window is closed)
    func clearAXCache(for windowID: CGWindowID) {
        axElementCache.removeValue(forKey: windowID)
    }
    
    /// Clear entire AX cache (call on major layout changes)
    func clearAllAXCache() {
        axElementCache.removeAll()
        debugLog("AccessibilityService", "🧹 Cleared all AX element cache")
    }

    // MARK: - Minimum Window Sizes

    /// Sizes windows were seen refusing to shrink below. Such a window counts as placed at that size,
    /// so it isn't asked again and again for a size it won't take
    private var minimumSizes: [CGWindowID: CGSize] = [:]

    /// The frame a window ends up with when asked for `frame`: no smaller than it can get
    func expectedFrame(_ frame: CGRect, windowID: CGWindowID) -> CGRect {
        guard let minimum = minimumSizes[windowID] else { return frame }
        return CGRect(origin: frame.origin, size: CGSize(width: max(frame.width, minimum.width), height: max(frame.height, minimum.height)))
    }
    
    // MARK: - Permission Methods
    
    func checkPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        logger.info("Accessibility permission check: \(trusted)")
        return trusted
    }
    
    /// Request accessibility permissions by prompting the user
    /// This will open System Preferences if permissions are not granted
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Focused Window Detection
    
    /// Position of the app's focused window (AX, top-left origin), or nil if it has none.
    /// Uses the AX focused window, not the first window by z-order
    func getFocusedWindowPosition(for pid: pid_t) -> CGPoint? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        
        var focusedWindowRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(pid) {
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        }
        
        guard result == .success, let focusedWindow = focusedWindowRef else {
            debugLog("AccessibilityService", "⚠️ No focused window for PID \(pid)")
            return nil
        }
        
        var positionRef: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionRef)
        
        guard posResult == .success, let positionValue = positionRef else {
            debugLog("AccessibilityService", "⚠️ Failed to get position of focused window for PID \(pid)")
            return nil
        }
        
        var position = CGPoint.zero
        if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) {
            debugLog("AccessibilityService", "Focused window position for PID \(pid): \(position)")
            return position
        }
        
        return nil
    }
    
    // MARK: - Window Control Methods
    
    /// Check if a window is accessible via AX API (i.e., on the current Space)
    /// Windows on other Spaces return empty window list from AXUIElementCopyAttributeValue
    func isWindowAccessible(_ window: WindowInfo) -> Bool {
        if TourSandboxWindows.contains(window.windowID) { return true }
        guard AppResponsiveness.isResponding(window.ownerPID) else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(window.ownerPID) {
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        }
        
        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            // No windows accessible for this app - it's on another Space
            logger.debug("isWindowAccessible: No AX windows for PID \(window.ownerPID) (\(window.ownerName))")
            return false
        }
        
        if !window.title.isEmpty {
            var axTitles: [String] = []
            
            for axWindow in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    axTitles.append(title)
                    
                    if title == window.title {
                        return true
                    }
                    
                    // Flexible match: AX title contains CGWindow title or vice versa
                    // This handles cases like CGWindow="Inbox" vs AX="Inbox — Mail"
                    if title.contains(window.title) || window.title.contains(title) {
                        logger.debug("isWindowAccessible: Flexible match for '\(window.title)' ~ '\(title)'")
                        return true
                    }
                }
            }
            
            // No title match found - try matching by position/size
            // This handles cases where titles differ significantly
            for axWindow in windows {
                if matchesByFrame(axWindow: axWindow, window: window) {
                    logger.debug("isWindowAccessible: Frame match for '\(window.title)'")
                    return true
                }
            }
            
            logger.debug("isWindowAccessible: No match for '\(window.title)' in AX titles: \(axTitles)")
            return false
        }
        
        // No title to match - assume accessible if app has any windows
        return true
    }
    
    private func matchesByFrame(axWindow: AXUIElement, window: WindowInfo) -> Bool {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        
        guard posResult == .success, sizeResult == .success else {
            return false
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        if let posValue = positionRef {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let sizeValue = sizeRef {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        
        // Allow small tolerance for position (some windows report slightly different positions)
        let tolerance: CGFloat = 5.0
        let positionMatch = abs(position.x - window.frame.origin.x) <= tolerance &&
                           abs(position.y - window.frame.origin.y) <= tolerance
        let sizeMatch = abs(size.width - window.frame.size.width) <= tolerance &&
                       abs(size.height - window.frame.size.height) <= tolerance
        
        return positionMatch && sizeMatch
    }
    
    /// Whether a window can be found by its title: not empty and no other window of the app has it
    nonisolated static func titleIdentifiesWindow(_ title: String, among titles: [String?]) -> Bool {
        !title.isEmpty && titles.filter { $0 == title }.count == 1
    }
    
    func getAXWindow(for window: WindowInfo, overrideFrame: CGRect? = nil, excludeElements: Set<ObjectIdentifier>? = nil) -> AXUIElement? {
        // Never issue synchronous AX IPC to our own process (would deadlock the main thread)
        if TourSandboxWindows.contains(window.windowID) { return nil }
        debugLog("AccessibilityService", "🔎 getAXWindow: windowID=\(window.windowID), title='\(window.title)', CACHE_SIZE=\(axElementCache.count)")
        
        guard AppResponsiveness.isResponding(window.ownerPID) else { return nil }
        
        // Check cache first (for apps without _AXWindowID like iTerm2)
        if let cachedElement = axElementCache[window.windowID],
           excludeElements?.contains(ObjectIdentifier(cachedElement)) != true {
            // Verify cached element is still valid by checking position attribute
            var positionRef: CFTypeRef?
            let cacheCheck = AppResponsiveness.shared.ask(window.ownerPID) {
                AXUIElementCopyAttributeValue(cachedElement, kAXPositionAttribute as CFString, &positionRef)
            }
            if cacheCheck == .success {
                return cachedElement
            } else if !AppResponsiveness.isResponding(window.ownerPID) {
                // The element is not stale, the app just did not answer. It is needed again
                // once the app does: a window without _AXWindowID is hard to match a second time
                return nil
            } else {
                axElementCache.removeValue(forKey: window.windowID)
                debugLog("AccessibilityService", "⚠️ CACHE STALE: Removed windowID=\(window.windowID)")
            }
        }
        
        let app = AXUIElementCreateApplication(window.ownerPID)
        
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(window.ownerPID) {
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        }
        
        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.error("Failed to get windows for PID \(window.ownerPID): \(result.rawValue)")
            return nil
        }
        
        let windowCount = windows.count
        logger.debug("Found \(windowCount) AX windows for PID \(window.ownerPID)")
        
        // PRIORITY 1: Try to match by _AXWindowID (most reliable for same-app windows)
        // This private attribute returns the CGWindowID, allowing precise matching
        var axWindowIDsFound: [CGWindowID] = []
        for axWindow in windows {
            var axWindowIDRef: CFTypeRef?
            let idResult = AXUIElementCopyAttributeValue(axWindow, "_AXWindowID" as CFString, &axWindowIDRef)
            
            if idResult == .success,
               let axWindowIDNumber = axWindowIDRef as? NSNumber {
                let axWindowID = CGWindowID(axWindowIDNumber.uint32Value)
                axWindowIDsFound.append(axWindowID)
                if axWindowID == window.windowID {
                    if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                        logger.debug("⚠️ Matched by _AXWindowID but element already used, skipping")
                        continue
                    }
                    debugLog("AccessibilityService", "✅ Matched by _AXWindowID: \(window.windowID)")
                    axElementCache[window.windowID] = axWindow
                    return axWindow
                }
            }
        }
        
        if !axWindowIDsFound.isEmpty {
            debugLog("AccessibilityService", "⚠️ _AXWindowID available but no match. Looking for: \(window.windowID), found: \(axWindowIDsFound)")
        } else {
            debugLog("AccessibilityService", "⚠️ _AXWindowID not available for PID \(window.ownerPID) (\(window.ownerName))")
        }
        
        // PRIORITY 2: Match by POSITION + SIZE from CGWindowList (most reliable for same-title windows!)
        // Use overrideFrame which contains fresh position AND size from CGWindowList
        if let freshFrame = overrideFrame {
            for axWindow in windows {
                if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                    continue
                }
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
                let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                
                if posResult == .success, let posValue = positionRef {
                    var axPosition = CGPoint.zero
                    var axSize = CGSize.zero
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &axPosition)
                    if sizeResult == .success, let szValue = sizeRef {
                        AXValueGetValue(szValue as! AXValue, .cgSize, &axSize)
                    }
                    
                    // Match if position is within 5 pixels (accounts for rounding)
                    let posMatch = abs(axPosition.x - freshFrame.origin.x) < 5 && abs(axPosition.y - freshFrame.origin.y) < 5
                    // Also check size if available (helps distinguish overlapping windows)
                    let sizeMatch = abs(axSize.width - freshFrame.size.width) < 10 && abs(axSize.height - freshFrame.size.height) < 10
                    
                    if posMatch && sizeMatch {
                        debugLog("AccessibilityService", "✅ Matched by CGPosition+Size: windowID=\(window.windowID)")
                        axElementCache[window.windowID] = axWindow
                        return axWindow
                    }
                }
            }
            for axWindow in windows {
                if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                    continue
                }
                var positionRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                   let posValue = positionRef {
                    var axPosition = CGPoint.zero
                    if AXValueGetValue(posValue as! AXValue, .cgPoint, &axPosition) {
                        let posMatch = abs(axPosition.x - freshFrame.origin.x) < 5 && abs(axPosition.y - freshFrame.origin.y) < 5
                        if posMatch {
                            debugLog("AccessibilityService", "✅ Matched by CGPosition (fallback): windowID=\(window.windowID)")
                            axElementCache[window.windowID] = axWindow
                            return axWindow
                        }
                    }
                }
            }
            debugLog("AccessibilityService", "⚠️ No AXWindow matched CGPosition for windowID=\(window.windowID)")
        }
        
        // PRIORITY 3: Try to match by window title (fallback for single-window apps)
        // Only a title no other window of the app has: two "zsh" terminals would both take the first one
        let titles = windows.map { axWindow -> String? in
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
            return titleRef as? String
        }
        if Self.titleIdentifiesWindow(window.title, among: titles) {
            for axWindow in windows {
                if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                    continue
                }
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   title == window.title {
                    debugLog("AccessibilityService", "✅ Matched by title: '\(title)' for windowID=\(window.windowID)")
                    // Cache it, so later lookups for this windowID don't depend on matching the title again
                    axElementCache[window.windowID] = axWindow
                    return axWindow
                }
            }
        }
        
        // PRIORITY 4: Try to match by position AND size
        // Size matching matters when multiple windows are at the same position
        for axWindow in windows {
            if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                continue
            }
            
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            
            let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
            let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
            
            if posResult == .success,
               let posValue = positionRef {
                var position = CGPoint.zero
                if AXValueGetValue(posValue as! AXValue, .cgPoint, &position) {
                    let targetFrame = overrideFrame ?? window.frame
                    let targetPosition = targetFrame.origin
                    
                    // CGWindowList uses top-left origin, AX uses top-left too
                    let positionMatches = abs(position.x - targetPosition.x) < 50 &&
                                         abs(position.y - targetPosition.y) < 50
                    
                    if positionMatches {
                        // Also check size to distinguish overlapping windows:
                        // new windows have a different size than resized existing windows
                        var sizeMatches = true
                        if sizeResult == .success, let sizeValue = sizeRef {
                            var axSize = CGSize.zero
                            if AXValueGetValue(sizeValue as! AXValue, .cgSize, &axSize) {
                                let targetSize = targetFrame.size
                                // Size tolerance of 50px to account for rounding
                                sizeMatches = abs(axSize.width - targetSize.width) < 50 &&
                                             abs(axSize.height - targetSize.height) < 50
                            }
                        }
                        
                        if sizeMatches {
                            logger.debug("Matched window by position+size: AX=(\(position.x), \(position.y)), CG=(\(targetPosition.x), \(targetPosition.y))")
                            // Cache it: matching by position again later can confuse windows
                            axElementCache[window.windowID] = axWindow
                            return axWindow
                        }
                    }
                }
            }
        }
        
        // FALLBACK: If no exact match by position+size, try position only (with exclusion)
        // This handles edge cases where size might have changed
        for axWindow in windows {
            if let exclude = excludeElements, exclude.contains(ObjectIdentifier(axWindow)) {
                continue
            }
            
            var positionRef: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
            
            if posResult == .success, let posValue = positionRef {
                var position = CGPoint.zero
                if AXValueGetValue(posValue as! AXValue, .cgPoint, &position) {
                    let targetFrame = overrideFrame ?? window.frame
                    let targetPosition = targetFrame.origin
                    
                    let positionMatches = abs(position.x - targetPosition.x) < 50 &&
                                         abs(position.y - targetPosition.y) < 50
                    
                    if positionMatches {
                        logger.debug("Matched window by position only (size mismatch): AX=(\(position.x), \(position.y))")
                        axElementCache[window.windowID] = axWindow
                        return axWindow
                    }
                }
            }
        }
        
        // If only one window AND window title is empty (can't verify by title), use it
        // This is a safe fallback because we can't verify identity without a title
        if windows.count == 1 && window.title.isEmpty {
            if let first = windows.first {
                if let exclude = excludeElements, exclude.contains(ObjectIdentifier(first)) {
                    logger.debug("Single window fallback but element already used, skipping")
                } else {
                    logger.debug("Only one window available and target has no title, using it")
                    return first
                }
            }
        }
        
        // Don't fall back to an arbitrary window: that would resize the wrong window.
        // If we couldn't match by title or position, the target window may have been closed.
        // Returning a different window would cause unintended operations.
        logger.warning("No match found for '\(window.title, privacy: .public)' (windowID=\(window.windowID)) - window may have been closed")
        return nil
    }
    
    @discardableResult
    func setWindowPosition(_ window: WindowInfo, position: CGPoint, file: String = #file, line: Int = #line, function: String = #function) -> Bool {
        let caller = "\((file as NSString).lastPathComponent):\(line) \(function)"
        debugLog("AccessibilityService", " setWindowPosition '\(window.title)' to (\(position.x), \(position.y)) [caller: \(caller)]")
        
        guard let axWindow = getAXWindow(for: window) else {
            logger.error("Could not find AXWindow for '\(window.title, privacy: .public)'")
            return false
        }
        
        var point = position
        guard let positionValue = AXValueCreate(.cgPoint, &point) else {
            logger.error("Failed to create AXValue for position")
            return false
        }
        
        let result = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        logger.info("Set position result: \(result.rawValue) (success=\(result == .success))")
        return result == .success
    }
    
    @discardableResult
    func setWindowSize(_ window: WindowInfo, size: CGSize) -> Bool {
        logger.info("Setting size for '\(window.title, privacy: .public)' to (\(size.width) x \(size.height))")
        
        guard let axWindow = getAXWindow(for: window) else {
            logger.error("Could not find AXWindow for '\(window.title, privacy: .public)'")
            return false
        }
        
        var sizeValue = size
        guard let axSize = AXValueCreate(.cgSize, &sizeValue) else {
            logger.error("Failed to create AXValue for size")
            return false
        }
        
        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        logger.info("Set size result: \(result.rawValue) (success=\(result == .success))")
        return result == .success
    }
    
    /// Set both position and size of a window atomically (single AXWindow lookup)
    /// This avoids race conditions where position change invalidates the lookup for size.
    func setWindowPositionAndSize(_ window: WindowInfo, position: CGPoint, size: CGSize) -> (position: Bool, size: Bool) {
        if TourSandboxWindows.contains(window.windowID) {
            let ok = MainActor.assumeIsolated {
                TourSandboxWindows.shared.setCGFrame(CGRect(origin: position, size: size), for: window.windowID)
            }
            return (ok, ok)
        }
        debugLog("AccessibilityService", "setWindowPositionAndSize '\(window.title)' to (\(position.x), \(position.y)), size=\(size.width)x\(size.height)")
        
        guard let axWindow = getAXWindow(for: window) else {
            logger.error("Could not find AXWindow for '\(window.title, privacy: .public)'")
            return (false, false)
        }
        
        var point = position
        guard let positionValue = AXValueCreate(.cgPoint, &point) else {
            logger.error("Failed to create AXValue for position")
            return (false, false)
        }
        
        let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        let positionSuccess = posResult == .success
        logger.info("Set position result: \(posResult.rawValue) (success=\(positionSuccess))")
        
        var sizeValue = size
        guard let axSize = AXValueCreate(.cgSize, &sizeValue) else {
            logger.error("Failed to create AXValue for size")
            return (positionSuccess, false)
        }
        
        let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        let sizeSuccess = sizeResult == .success
        logger.info("Set size result: \(sizeResult.rawValue) (success=\(sizeSuccess))")
        
        return (positionSuccess, sizeSuccess)
    }
    
    /// Pre-cache AXWindow references for a batch of windows
    /// This should be called BEFORE moving any windows, as position-based matching
    /// will fail after windows move to positions where other windows were.
    func batchGetAXWindows(for windows: [WindowInfo]) -> [CGWindowID: AXUIElement] {
        var result: [CGWindowID: AXUIElement] = [:]
        
        // Use fresh frames from CGWindowList. The model's WindowInfo.frame holds the target frame
        // from the last redistribute, not the current one, so two windows with the same target
        // (a new window spawning at the same spot) would match the same element.
        let windowListInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var freshFrames: [CGWindowID: CGRect] = [:]
        for info in windowListInfo {
            if let windowID = info[kCGWindowNumber as String] as? CGWindowID,
               let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let x = bounds["X"], let y = bounds["Y"],
               let w = bounds["Width"], let h = bounds["Height"] {
                freshFrames[windowID] = CGRect(x: x, y: y, width: w, height: h)
            }
        }
        
        debugLog("AccessibilityService", "🔍 batchGetAXWindows: \(windows.count) windows, \(freshFrames.count) fresh frames from CGWindowList")
        
        // Track used AXUIElements so one element is never matched to two windows.
        // This matters when several windows share a position (iTerm2)
        var usedAXElements: Set<ObjectIdentifier> = []
        
        for window in windows {
            let freshFrame = freshFrames[window.windowID]
            debugLog("AccessibilityService", "  🪟 Looking up windowID=\(window.windowID) '\(window.title)': freshFrame=\(freshFrame?.debugDescription ?? "nil")")
            if let axWindow = getAXWindow(for: window, overrideFrame: freshFrame, excludeElements: usedAXElements) {
                result[window.windowID] = axWindow
                usedAXElements.insert(ObjectIdentifier(axWindow))
            } else {
                debugLog("AccessibilityService", "    ❌ NOT FOUND AXElement for windowID=\(window.windowID)")
            }
        }
        
        logger.debug("Batch lookup: \(result.count)/\(windows.count) windows found")
        return result
    }
    
    /// A single window and target CG frame for `batchSetWindowFrames`.
    struct BatchFrameTarget {
        let window: WindowInfo
        let axWindow: AXUIElement?
        let frame: CGRect
    }

    private struct UncheckedAXBox: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
    }

    /// Whether two frames already match within `tolerance` points on every edge.
    nonisolated static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// Groups target indices by owning PID while preserving relative order inside each app bucket.
    /// Distinct PIDs can safely receive AX frame updates concurrently; windows of the same app run in order.
    nonisolated static func groupTargetsByPID(_ items: [(index: Int, pid: pid_t)]) -> [[Int]] {
        var bucketIndexByPID: [pid_t: Int] = [:]
        var buckets: [[Int]] = []
        for item in items {
            if let bucketIndex = bucketIndexByPID[item.pid] {
                buckets[bucketIndex].append(item.index)
            } else {
                bucketIndexByPID[item.pid] = buckets.count
                buckets.append([item.index])
            }
        }
        return buckets
    }

    /// Moves and resizes multiple windows simultaneously so layout changes happen in one calm beat
    /// instead of a serial domino sequence. Windows already at their expected frame are skipped,
    /// distinct apps receive AX updates concurrently, and all windows share a single verification pass.
    @discardableResult
    func batchSetWindowFrames(
        _ targets: [BatchFrameTarget],
        onWillMove: (() -> Void)? = nil
    ) -> [CGWindowID: Bool] {
        guard !targets.isEmpty else { return [:] }

        var results: [CGWindowID: Bool] = [:]
        let initialCGFrames = onScreenCGFramesByWindowID()

        struct PendingMove {
            let window: WindowInfo
            let axWindow: AXUIElement
            let frame: CGRect
            let expected: CGRect
        }

        var pending: [PendingMove] = []
        for target in targets {
            let wid = target.window.windowID
            if TourSandboxWindows.contains(wid) {
                let ok = MainActor.assumeIsolated {
                    TourSandboxWindows.shared.setCGFrame(target.frame, for: wid)
                }
                results[wid] = ok
                continue
            }
            guard let axWindow = target.axWindow ?? getAXWindow(for: target.window) else {
                debugLog("AccessibilityService", "❌ batchSetWindowFrames could not find AXWindow for '\(target.window.title)' windowID=\(wid)")
                results[wid] = false
                continue
            }
            let expected = expectedFrame(target.frame, windowID: wid)
            if let current = initialCGFrames[wid] ?? axFrame(of: axWindow),
               Self.framesMatch(current, expected, tolerance: 1.5) {
                debugLog("AccessibilityService", "🎯 batchSetWindowFrames '\(target.window.title)' windowID=\(wid) already in place")
                results[wid] = true
                continue
            }
            pending.append(PendingMove(window: target.window, axWindow: axWindow, frame: target.frame, expected: expected))
        }

        guard !pending.isEmpty else { return results }
        onWillMove?()

        func applyBatch(_ items: [PendingMove]) {
            let boxes = items.map { UncheckedAXBox(element: $0.axWindow, frame: $0.frame) }
            let buckets = Self.groupTargetsByPID(items.enumerated().map { ($0.offset, $0.element.window.ownerPID) })
            let sendableBoxes = boxes
            let sendableBuckets = buckets
            DispatchQueue.concurrentPerform(iterations: sendableBuckets.count) { bucketIdx in
                for itemIdx in sendableBuckets[bucketIdx] {
                    let box = sendableBoxes[itemIdx]
                    var point = box.frame.origin
                    var size = box.frame.size
                    guard let posVal = AXValueCreate(.cgPoint, &point),
                          let sizeVal = AXValueCreate(.cgSize, &size) else { continue }
                    // Size, position, size: prevents large windows moving to smaller edge slots from clamping
                    AXUIElementSetAttributeValue(box.element, kAXSizeAttribute as CFString, sizeVal)
                    AXUIElementSetAttributeValue(box.element, kAXPositionAttribute as CFString, posVal)
                    AXUIElementSetAttributeValue(box.element, kAXSizeAttribute as CFString, sizeVal)
                }
            }
        }

        applyBatch(pending)

        var unverified = pending
        for attempt in 1...3 {
            usleep(20000) // One shared 20ms settle window for the whole batch
            let liveFrames = onScreenCGFramesByWindowID()
            var stillMismatched: [PendingMove] = []

            for item in unverified {
                let wid = item.window.windowID
                let actualFrame = liveFrames[wid] ?? axFrame(of: item.axWindow)
                guard let actualFrame else {
                    if attempt == 3 { results[wid] = true } else { stillMismatched.append(item) }
                    continue
                }
                func sizeMatches(_ target: CGRect) -> Bool {
                    abs(actualFrame.size.width - target.size.width) < 10 && abs(actualFrame.size.height - target.size.height) < 10
                }
                let positionMatch = abs(actualFrame.origin.x - item.frame.origin.x) < 10 && abs(actualFrame.origin.y - item.frame.origin.y) < 10

                if positionMatch && sizeMatches(item.frame) {
                    if let minimum = minimumSizes[wid],
                       item.frame.width < minimum.width - 10 || item.frame.height < minimum.height - 10 {
                        minimumSizes.removeValue(forKey: wid)
                    }
                    results[wid] = true
                } else if positionMatch && item.expected != item.frame && sizeMatches(item.expected) {
                    results[wid] = true
                } else if attempt < 3 {
                    stillMismatched.append(item)
                } else if positionMatch,
                          actualFrame.width > item.frame.width + 1 || actualFrame.height > item.frame.height + 1,
                          actualFrame.width > item.frame.width - 10, actualFrame.height > item.frame.height - 10 {
                    let known = minimumSizes[wid] ?? .zero
                    minimumSizes[wid] = CGSize(
                        width: actualFrame.width > item.frame.width + 1 ? max(known.width, actualFrame.width) : known.width,
                        height: actualFrame.height > item.frame.height + 1 ? max(known.height, actualFrame.height) : known.height
                    )
                    results[wid] = true
                } else {
                    results[wid] = false
                }
            }

            unverified = stillMismatched
            if unverified.isEmpty { break }
            if attempt < 3 {
                applyBatch(unverified)
            }
        }

        debugLog("AccessibilityService", "🎯 batchSetWindowFrames placed \(results.values.filter { $0 }.count)/\(targets.count) window(s)")
        return results
    }

    private func onScreenCGFramesByWindowID() -> [CGWindowID: CGRect] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var frames: [CGWindowID: CGRect] = [:]
        frames.reserveCapacity(list.count)
        for info in list {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            frames[wid] = CGRect(x: x, y: y, width: w, height: h)
        }
        return frames
    }

    /// Set window frame using a pre-cached AXUIElement reference
    /// Use this when moving multiple windows to avoid position matching issues.
    /// - Parameters:
    ///   - windowID: Optional CGWindowID for precise verification (critical for same-title windows)
    @discardableResult
    func setWindowFrame(axWindow: AXUIElement, frame: CGRect, windowTitle: String = "", windowID: CGWindowID? = nil) -> Bool {
        let expected = windowID.map { expectedFrame(frame, windowID: $0) } ?? frame
        // Setting a frame the window already has still makes some apps redraw, which shows as a flicker
        if let current = axFrame(of: axWindow),
           abs(current.minX - expected.minX) < 1, abs(current.minY - expected.minY) < 1,
           abs(current.width - expected.width) < 1, abs(current.height - expected.height) < 1 {
            debugLog("AccessibilityService", "🎯 setWindowFrame '\(windowTitle)' windowID=\(windowID ?? 0) already in place")
            return true
        }
        debugLog("AccessibilityService", "🎯 setWindowFrame '\(windowTitle)' windowID=\(windowID ?? 0) target=(\(frame.origin.x),\(frame.origin.y) \(frame.size.width)x\(frame.size.height))")
        
        var point = frame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &point) else {
            logger.error("Failed to create AXValue for position")
            debugLog("AccessibilityService", "❌ Failed to create AXValue for position")
            return false
        }
        var sizeValue = frame.size
        guard let axSize = AXValueCreate(.cgSize, &sizeValue) else {
            logger.error("Failed to create AXValue for size")
            debugLog("AccessibilityService", "❌ Failed to create AXValue for size")
            return false
        }
        
        // Size, position, size: moved first at its old size, a large window going to a smaller slot
        // near the screen edge gets pushed back by macOS and lands off target
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        let posResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        let positionSuccess = posResult == .success
        let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        let sizeSuccess = sizeResult == .success
        
        // WORKAROUND: Retry mechanism for windows that don't apply frame immediately
        // Some apps (iTerm2, Terminal) may not respond to single AX commands in Release builds
        // We verify using CGWindowList (real coordinates) and retry if needed
        for attempt in 1...3 {
            usleep(20000)  // 20ms delay between attempts
            
            // Verify using CGWindowList (real coordinates, not AX cache)
            // Use windowID for precise matching when available (same-title windows)
            let actualFrame: CGRect?
            if let wid = windowID {
                actualFrame = getWindowFrameFromCGWindowList(for: wid)
            } else {
                actualFrame = getWindowFrameFromCGWindowList(axWindow: axWindow)
            }
            
            if let actualFrame = actualFrame {
                func sizeMatches(_ target: CGRect) -> Bool {
                    abs(actualFrame.size.width - target.size.width) < 10 && abs(actualFrame.size.height - target.size.height) < 10
                }
                let positionMatch = abs(actualFrame.origin.x - frame.origin.x) < 10 && abs(actualFrame.origin.y - frame.origin.y) < 10
                
                if positionMatch && sizeMatches(frame) {
                    // A window that got smaller than its known minimum can shrink further now
                    if let wid = windowID, let minimum = minimumSizes[wid],
                       frame.width < minimum.width - 10 || frame.height < minimum.height - 10 {
                        minimumSizes.removeValue(forKey: wid)
                    }
                    debugLog("AccessibilityService", "✅ VERIFIED '\(windowTitle)' (attempt \(attempt))")
                    return true
                } else if positionMatch && expected != frame && sizeMatches(expected) {
                    debugLog("AccessibilityService", "✅ VERIFIED '\(windowTitle)' at its smallest size \(Int(expected.width))x\(Int(expected.height)) (attempt \(attempt))")
                    return true
                } else if attempt < 3 {
                    debugLog("AccessibilityService", "⚠️ RETRY \(attempt) '\(windowTitle)': mismatch")
                    AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
                    AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
                    AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
                } else if let wid = windowID, positionMatch,
                          actualFrame.width > frame.width + 1 || actualFrame.height > frame.height + 1,
                          actualFrame.width > frame.width - 10, actualFrame.height > frame.height - 10 {
                    let known = minimumSizes[wid] ?? .zero
                    minimumSizes[wid] = CGSize(
                        width: actualFrame.width > frame.width + 1 ? max(known.width, actualFrame.width) : known.width,
                        height: actualFrame.height > frame.height + 1 ? max(known.height, actualFrame.height) : known.height
                    )
                    debugLog("AccessibilityService", "📏 '\(windowTitle)' windowID=\(wid) won't get smaller than \(Int(actualFrame.width))x\(Int(actualFrame.height)) (asked \(Int(frame.width))x\(Int(frame.height)))")
                } else {
                    debugLog("AccessibilityService", "❌ FAILED '\(windowTitle)' windowID=\(windowID ?? 0) after 3 attempts")
                }
            } else {
                debugLog("AccessibilityService", "⚠️ Could not verify frame for '\(windowTitle)' (attempt \(attempt))")
                if attempt == 3 {
                    return positionSuccess && sizeSuccess  // Fallback to AX result
                }
            }
        }
        
        return positionSuccess && sizeSuccess
    }
    
    private func axFrame(of axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
    
    @discardableResult
    func raiseWindow(axWindow: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        let success = result == .success
        if success {
            logger.debug("✅ AXRaiseAction succeeded (cached)")
        } else {
            logger.warning("❌ AXRaiseAction failed (cached): \(result.rawValue)")
        }
        return success
    }
    
    /// Presses the window's close button, as if the user clicked it. The app may ask
    /// to save changes first.
    @discardableResult
    func closeWindow(_ window: WindowInfo) -> Bool {
        guard let axWindow = getAXWindow(for: window) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let button = value as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
    
    /// Moves and resizes a window, looking its AXWindow up once for both
    @discardableResult
    func setWindowFrame(_ window: WindowInfo, frame: CGRect) -> Bool {
        if TourSandboxWindows.contains(window.windowID) {
            return MainActor.assumeIsolated {
                TourSandboxWindows.shared.setCGFrame(frame, for: window.windowID)
            }
        }
        // MARK: - Workaround: Single AXWindow lookup for position+size
        // Cause: After setWindowPosition the window moves, but window.frame stays stale.
        //        Looking the AXWindow up again (for setWindowSize) then fails to match by position.
        // Context: Xcode and other apps with several AX windows weren't resized when switching to Auto Tiling.
        
        guard let axWindow = getAXWindow(for: window) else {
            debugLog("AccessibilityService", "❌ setWindowFrame could not find AXWindow for '\(window.title)' windowID=\(window.windowID)")
            return false
        }
        
        return setWindowFrame(axWindow: axWindow, frame: frame, windowTitle: window.title, windowID: window.windowID)
    }
    
    /// - Returns: The current frame in CG coordinates, or nil if failed
    func getWindowFrame(_ window: WindowInfo) -> CGRect? {
        if TourSandboxWindows.contains(window.windowID) {
            return MainActor.assumeIsolated {
                TourSandboxWindows.shared.cgFrame(for: window.windowID)
            }
        }
        guard let axWindow = getAXWindow(for: window) else {
            return nil
        }
        
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        
        guard posResult == .success, sizeResult == .success,
              let posValue = positionRef,
              let sizeValue = sizeRef else {
            return nil
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }
    
    // MARK: - Workaround:
    // Cause: In macOS 27 Mission Control reports the frames of the shrunken window thumbnails
    //        through CGWindowList, while AX reports the real ones. Slots updated from such frames shrink.
    // Context: Trust a CGWindowList frame only if it matches the AX frame.
    /// Whether the window's CGWindowList frame is its real frame, not a scaled Mission Control thumbnail
    func isShownAtRealFrame(_ window: WindowInfo) -> Bool {
        guard let axFrame = getWindowFrame(window) else { return false }
        let tolerance: CGFloat = 4
        return abs(axFrame.minX - window.frame.minX) <= tolerance
            && abs(axFrame.minY - window.frame.minY) <= tolerance
            && abs(axFrame.width - window.frame.width) <= tolerance
            && abs(axFrame.height - window.frame.height) <= tolerance
    }
    
    /// - Returns: The current frame in CG coordinates, or nil if failed
    func getWindowFrame(axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        
        let posResult = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        let sizeResult = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
        
        guard posResult == .success, sizeResult == .success,
              let posValue = positionRef,
              let sizeValue = sizeRef else {
            return nil
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }
    
    /// Get window frame from CGWindowList by CGWindowID (most reliable)
    private func getWindowFrameFromCGWindowList(for windowID: CGWindowID) -> CGRect? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        
        for info in windowList {
            guard let currentWindowID = info[kCGWindowNumber as String] as? CGWindowID,
                  currentWindowID == windowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            
            return CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
        }
        
        return nil
    }
    
    /// Get window frame from CGWindowList by AXUIElement (legacy, less reliable for same-title windows)
    private func getWindowFrameFromCGWindowList(axWindow: AXUIElement) -> CGRect? {
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        let axTitle = titleRef as? String ?? ""
        
        var positionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
        var axPosition = CGPoint.zero
        if let posValue = positionRef {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &axPosition)
        }
        
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        
        for info in windowList {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            
            let windowTitle = info[kCGWindowName as String] as? String ?? ""
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            
            let titleMatch = !axTitle.isEmpty && windowTitle == axTitle
            let positionMatch = abs(frame.origin.x - axPosition.x) < 50 && abs(frame.origin.y - axPosition.y) < 50
            
            if titleMatch || positionMatch {
                return frame
            }
        }
        
        return nil
    }
    
    // MARK: - Window Minimize Methods
    
    @discardableResult
    func minimizeWindow(_ window: WindowInfo) -> Bool {
        logger.info("Minimizing window '\(window.title, privacy: .public)'")
        
        guard let axWindow = getAXWindow(for: window) else {
            logger.error("Could not find AXWindow for '\(window.title, privacy: .public)'")
            return false
        }
        
        let result = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
        
        if result != .success {
            logger.warning("Failed to minimize window '\(window.title, privacy: .public)': \(result.rawValue)")
        }
        
        return result == .success
    }
    
    func isWindowMinimized(_ window: WindowInfo) -> Bool {
        guard let axWindow = getAXWindow(for: window) else {
            return false
        }
        
        var minimizedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            &minimizedRef
        )
        
        if result == .success, let isMinimized = minimizedRef as? Bool {
            return isMinimized
        }
        
        return false
    }

    /// Whether a window is in macOS full screen. Falls back to its frame covering a whole display,
    /// since some apps don't answer for a full screen window.
    func isWindowFullScreen(_ window: WindowInfo) -> Bool {
        if let axWindow = getAXWindow(for: window) {
            var fullScreenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
               let isFullScreen = fullScreenRef as? Bool, isFullScreen {
                return true
            }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.contains { screen in
            let cgFrame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
            return window.frame.integral == cgFrame.integral
        }
    }
    
    // MARK: - Window Raise Methods
    
    /// Raise a window to the front and activate its application
    @discardableResult
    func raiseWindow(_ window: WindowInfo) -> Bool {
        if TourSandboxWindows.contains(window.windowID) {
            return MainActor.assumeIsolated {
                TourSandboxWindows.shared.raise(windowID: window.windowID)
            }
        }
        debugLog("AccessibilityService", "raiseWindow called for '\(window.title)' (windowID: \(window.windowID), PID: \(window.ownerPID))")
        
        guard let axWindow = getAXWindow(for: window) else {
            debugLog("AccessibilityService", "❌ Could not find AXWindow for '\(window.title)' (windowID: \(window.windowID))")
            return false
        }
        
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        
        if raiseResult != .success {
            debugLog("AccessibilityService", "⚠️ AXRaiseAction failed with: \(raiseResult.rawValue)")
        } else {
            debugLog("AccessibilityService", "✅ AXRaiseAction succeeded for '\(window.title)'")
        }
        
        let app = AXUIElementCreateApplication(window.ownerPID)
        let activateResult = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        
        if activateResult != .success {
            debugLog("AccessibilityService", "⚠️ Failed to set frontmost for PID \(window.ownerPID)")
        }
        
        return raiseResult == .success || activateResult == .success
    }
    
    /// Raise a non-frontmost window from the same app that's at the same position
    /// Used for cycling through same-app windows in a group where getAXWindow fails
    /// because multiple windows have the same position and empty titles
    /// - Parameters:
    ///   - window: The WindowInfo of the window to raise (used for PID and position)
    ///   - skipCount: Number of matching windows to skip (0 = first match, 1 = second match, etc.)
    @discardableResult
    func raiseNonFrontmostWindowAtPosition(_ window: WindowInfo, skipCount: Int = 1) -> Bool {
        debugLog("AccessibilityService", "raiseNonFrontmostWindowAtPosition: target windowID=\(window.windowID), title='\(window.title)', skipCount=\(skipCount)")
        
        guard AppResponsiveness.isResponding(window.ownerPID) else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(window.ownerPID) {
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        }
        
        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            debugLog("AccessibilityService", "❌ Failed to get windows for PID \(window.ownerPID)")
            return false
        }
        
        debugLog("AccessibilityService", "Total AX windows for PID \(window.ownerPID): \(windows.count)")
        
        var matchingWindows: [(axWindow: AXUIElement, windowID: CGWindowID?, title: String)] = []
        let tolerance: CGFloat = 50
        
        for (index, axWindow) in windows.enumerated() {
            var positionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                  let posValue = positionRef else {
                continue
            }
            
            var position = CGPoint.zero
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position) else {
                continue
            }
            
            var axWindowID: CGWindowID? = nil
            var axWindowIDRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "_AXWindowID" as CFString, &axWindowIDRef) == .success,
               let num = axWindowIDRef as? NSNumber {
                axWindowID = CGWindowID(num.uint32Value)
            }
            
            var title = ""
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String {
                title = t
            }
            
            debugLog("AccessibilityService", "  AX window[\(index)]: ID=\(axWindowID.map { String($0) } ?? "nil"), title='\(title)', pos=(\(position.x), \(position.y))")
            
            let positionMatches = abs(position.x - window.frame.origin.x) < tolerance &&
                                 abs(position.y - window.frame.origin.y) < tolerance
            
            if positionMatches {
                matchingWindows.append((axWindow, axWindowID, title))
            }
        }
        
        debugLog("AccessibilityService", "Found \(matchingWindows.count) windows at position (\(window.frame.origin.x), \(window.frame.origin.y))")
        
        guard matchingWindows.count > skipCount else {
            debugLog("AccessibilityService", "⚠️ Not enough windows at position to skip \(skipCount), found only \(matchingWindows.count)")
            if let firstMatch = matchingWindows.first {
                debugLog("AccessibilityService", "Fallback: raising first match ID=\(firstMatch.windowID.map { String($0) } ?? "nil")")
                let raiseResult = AXUIElementPerformAction(firstMatch.axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                return raiseResult == .success
            }
            return false
        }
        
        // AX windows list is typically in z-order (front to back)
        // So skipCount=1 means we want the second window (the one behind the frontmost)
        let target = matchingWindows[skipCount]
        debugLog("AccessibilityService", "Raising window at z-index \(skipCount): ID=\(target.windowID.map { String($0) } ?? "nil"), title='\(target.title)'")
        
        let raiseResult = AXUIElementPerformAction(target.axWindow, kAXRaiseAction as CFString)
        
        if raiseResult != .success {
            debugLog("AccessibilityService", "⚠️ AXRaiseAction failed: \(raiseResult.rawValue)")
        } else {
            debugLog("AccessibilityService", "✅ AXRaiseAction succeeded")
        }
        
        let activateResult = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        
        if activateResult != .success {
            debugLog("AccessibilityService", "⚠️ Failed to set frontmost")
        }
        
        return raiseResult == .success || activateResult == .success
    }
    
    /// Front-to-back place of a window among the windows (in z-order) whose origin is near `origin`.
    /// Windows elsewhere on the screen don't count: AX windows are matched by position too.
    nonisolated static func zIndex(of windowID: CGWindowID, among windows: [(id: CGWindowID, origin: CGPoint)], near origin: CGPoint, tolerance: CGFloat) -> Int? {
        let colocated = windows.filter { abs($0.origin.x - origin.x) < tolerance && abs($0.origin.y - origin.y) < tolerance }
        return colocated.firstIndex { $0.id == windowID }
    }
    
    /// Raise a specific window by its CGWindowID using z-order matching
    /// This method finds the target window's position in z-order and uses the correct skipCount
    @discardableResult
    func raiseWindowByZOrder(_ window: WindowInfo) -> Bool {
        if TourSandboxWindows.contains(window.windowID) {
            return MainActor.assumeIsolated {
                TourSandboxWindows.shared.raise(windowID: window.windowID)
            }
        }
        debugLog("AccessibilityService", "raiseWindowByZOrder called for windowID: \(window.windowID), PID: \(window.ownerPID)")
        
        guard AppResponsiveness.isResponding(window.ownerPID) else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(window.ownerPID) {
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        }
        
        guard result == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            debugLog("AccessibilityService", "❌ Failed to get AX windows for PID \(window.ownerPID)")
            return false
        }
        
        let cgWindowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let appCGWindows = cgWindowList.filter { dict in
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0 else { return false }
            return pid == window.ownerPID
        }
        
        debugLog("AccessibilityService", "Found \(axWindows.count) AX windows, \(appCGWindows.count) CG windows for PID \(window.ownerPID)")
        
        for axWindow in axWindows {
            var axWindowIDRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, "_AXWindowID" as CFString, &axWindowIDRef) == .success,
               let axWindowID = axWindowIDRef as? NSNumber,
               CGWindowID(axWindowID.uint32Value) == window.windowID {
                let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                debugLog("AccessibilityService", "Raised window \(window.windowID) by _AXWindowID: \(raiseResult == .success)")
                return raiseResult == .success
            }
        }
        
        let cgWindows: [(id: CGWindowID, origin: CGPoint)] = appCGWindows.compactMap { dict in
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return (windowID, bounds.origin)
        }
        let targetOrigin = cgWindows.first { $0.id == window.windowID }?.origin ?? window.frame.origin
        let tolerance: CGFloat = 50
        
        guard let targetZIndex = Self.zIndex(of: window.windowID, among: cgWindows, near: targetOrigin, tolerance: tolerance) else {
            debugLog("AccessibilityService", "⚠️ Window not in CG list, using standard raise")
            return raiseWindow(window)
        }
        
        debugLog("AccessibilityService", "Target window \(window.windowID) z-index at its position: \(targetZIndex)")
        
        var matchingAXWindows: [AXUIElement] = []
        
        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                  let posValue = positionRef else {
                continue
            }
            
            var position = CGPoint.zero
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position) else {
                continue
            }
            
            let positionMatches = abs(position.x - targetOrigin.x) < tolerance &&
                                 abs(position.y - targetOrigin.y) < tolerance
            
            if positionMatches {
                matchingAXWindows.append(axWindow)
            }
        }
        
        debugLog("AccessibilityService", "Found \(matchingAXWindows.count) AX windows at position")
        
        // Use targetZIndex as skipCount (AX windows list should be in same z-order)
        let skipCount = min(targetZIndex, matchingAXWindows.count - 1)
        
        guard skipCount >= 0 && skipCount < matchingAXWindows.count else {
            debugLog("AccessibilityService", "⚠️ Invalid skipCount \(skipCount), using standard raise")
            return raiseWindow(window)
        }
        
        let targetAXWindow = matchingAXWindows[skipCount]
        
        debugLog("AccessibilityService", "Raising window at z-index \(skipCount)")
        
        let raiseResult = AXUIElementPerformAction(targetAXWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        
        if raiseResult == .success {
            debugLog("AccessibilityService", "✅ Successfully raised window by z-order")
        } else {
            debugLog("AccessibilityService", "⚠️ AXRaiseAction failed: \(raiseResult.rawValue)")
        }
        
        return raiseResult == .success
    }
}
