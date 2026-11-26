//
//  WindowClassifier.swift
//  Rapto
//
//  Single source of truth for window tilability decisions.
//  Used by AutoTilingService, AppState, WindowHighlightService, etc.
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Enums and Structs

enum WindowTilability: Equatable {
    case tilable
    case notTilable
    case unknown          // Cannot determine - treat as notTilable for auto-operations
}

/// Why a window was classified as not tilable.
/// Divided into "hard stops" (cannot be overridden) and "heuristics" (can be overridden by user whitelist).
enum ExclusionReason: String, CaseIterable {
    // Hard stops: the whitelist cannot override these.
    case modal = "modal"
    case sheet = "sheet"
    case minimized = "minimized"
    case fullscreen = "fullscreen"
    case hiddenApp = "hidden_app"
    case axUnavailable = "ax_unavailable"
    case noConfidentMatch = "no_confident_match"
    case systemDialog = "system_dialog"
    case floatingWindow = "floating_window"
    
    // Heuristics: the whitelist can override these.
    case tooSmall = "too_small"
    case titleHeuristic = "title_heuristic"
    case appSpecificRule = "app_specific_rule"
    case userBlacklist = "user_blacklist"
    case unknownSubrole = "unknown_subrole"
    case fixedSize = "fixed_size"
    
}

struct WindowClassification: Equatable {
    let decision: WindowTilability
    let reasons: Set<ExclusionReason>
    
    var reasonDescription: String {
        if reasons.isEmpty {
            return decision == .tilable ? "tilable" : "unknown"
        }
        return reasons.map { $0.rawValue }.joined(separator: ", ")
    }
    
    static let tilable = WindowClassification(decision: .tilable, reasons: [])
    
    static func notTilable(_ reasons: ExclusionReason...) -> WindowClassification {
        WindowClassification(decision: .notTilable, reasons: Set(reasons))
    }
    
    static func unknown(_ reasons: ExclusionReason...) -> WindowClassification {
        WindowClassification(decision: .unknown, reasons: Set(reasons))
    }
}

/// Single point of decision for window tilability
/// All services (AutoTiling, AppState, WindowHighlight, etc.) should use this
class WindowClassifier {
    
    static let shared = WindowClassifier()
    
    // MARK: - Constants
    
    /// Minimum width and height, in points, for a window with a non-standard subrole.
    static let minimumTilableSize: CGFloat = 300
    
    /// Frame tolerance for AX <-> CGWindow matching, wide enough to absorb window shadows.
    private let frameTolerance: CGFloat = 50
    
    private let cacheTTL: TimeInterval = 2.0
    
    /// The oldest entry is evicted when the cache is full.
    private let maxCacheSize = 100
    
    // MARK: - Cache
    
    private struct CacheEntry {
        let classification: WindowClassification
        let timestamp: Date
    }
    
    private var cache: [CGWindowID: CacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "app.rapto.mac.windowclassifier.cache")
    
    /// Only a change in classification is logged, to avoid log spam.
    private var lastLoggedClassification: [CGWindowID: WindowClassification] = [:]
    
    // MARK: - User Settings (loaded from AppState/UserDefaults)
    
    var userExcludedBundleIDs: Set<String> = []
    
    /// Bundle IDs that user has whitelisted (can override heuristics, but NOT hard stops)
    // Nothing fills this set and there is no UI for it, so `canOverrideHeuristics` is always false.
    var userWhitelistedBundleIDs: Set<String> = []
    
    private init() {}
    
    // MARK: - Public API
    
    /// Results are cached per window for `cacheTTL` seconds.
    func classify(_ window: WindowInfo) -> WindowClassification {
        if let cached = getCachedClassification(for: window.windowID) {
            return cached
        }
        
        let classification = performClassification(window)
        
        cacheClassification(classification, for: window.windowID)
        
        logClassification(window, classification)
        
        return classification
    }
    
    /// For auto-operations: unknown is treated as notTilable.
    func isTilable(_ window: WindowInfo) -> Bool {
        let classification = classify(window)
        return classification.decision == .tilable
    }
    
    /// For UI display: unknown windows can be shown but not auto-operated on.
    func isTilableForUI(_ window: WindowInfo) -> Bool {
        let classification = classify(window)
        return classification.decision == .tilable || classification.decision == .unknown
    }
    
    // MARK: - Private Classification Logic
    
    private func performClassification(_ window: WindowInfo) -> WindowClassification {
        if TourSandboxWindows.contains(window.windowID) {
            return .tilable
        }
        
        if let bundleID = window.bundleIdentifier, userExcludedBundleIDs.contains(bundleID) {
            return .notTilable(.userBlacklist)
        }
        
        // System Settings is never tiled, even when the user takes it off the ignored apps
        if window.bundleIdentifier == "com.apple.systempreferences" {
            return .notTilable(.appSpecificRule)
        }
        
        if SettingsWindowDetector.shared.isSettingsWindow(window) {
            return .notTilable(.appSpecificRule)
        }
        
        guard AppResponsiveness.isResponding(window.ownerPID) else {
            return .unknown(.axUnavailable)
        }
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        
        var hiddenRef: CFTypeRef?
        let hiddenResult = AppResponsiveness.shared.ask(window.ownerPID) {
            AXUIElementCopyAttributeValue(appElement, kAXHiddenAttribute as CFString, &hiddenRef)
        }
        if hiddenResult == .success, let isHidden = hiddenRef as? Bool, isHidden {
            return .notTilable(.hiddenApp)
        }
        guard AppResponsiveness.isResponding(window.ownerPID) else {
            return .unknown(.axUnavailable)
        }
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return .unknown(.axUnavailable)
        }
        
        guard let axWindow = findMatchingAXWindow(for: window, in: axWindows) else {
            // No confident AX match. When the app lists no AX windows at all, its window has
            // probably not appeared in AX yet, and a large one is likely tilable.
            // When the app already lists other windows, this one is an overlay it doesn't expose
            // (Canary Mail's What's New): it can't be moved, and AX calls would reach the main window
            if axWindows.isEmpty && window.frame.width >= 400 && window.frame.height >= 300 {
                return .tilable
            }
            return .unknown(.noConfidentMatch)
        }
        
        let attrs = collectAXAttributes(from: axWindow)
        
        if let hardStop = checkHardStops(attrs) {
            return hardStop
        }
        
        let canOverrideHeuristics = window.bundleIdentifier.map { userWhitelistedBundleIDs.contains($0) } ?? false
        
        // The AX title is preferred; the CGWindow title is often empty.
        if !canOverrideHeuristics {
            let effectiveTitle = attrs.title ?? window.title
            if let appRule = checkAppSpecificRules(window, axTitle: effectiveTitle) {
                return appRule
            }
        }
        
        // A window that can't be resized can't fill a slot. Its title is often a section name ("General"),
        // so the title heuristics below miss it
        if !canOverrideHeuristics, attrs.hasFixedSize == true {
            return .notTilable(.fixedSize)
        }
        
        if !canOverrideHeuristics {
            let effectiveTitle = attrs.title ?? window.title
            if let titleRule = checkTitleHeuristics(window, axTitle: effectiveTitle) {
                return titleRule
            }
        }
        
        return classifyBySubrole(attrs, window: window, canOverrideHeuristics: canOverrideHeuristics)
    }
    
    // MARK: - AX Window Matching
    
    private func findMatchingAXWindow(for window: WindowInfo, in axWindows: [AXUIElement]) -> AXUIElement? {
        var sameSizeWindows: [AXUIElement] = []
        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posValue = positionRef,
                  let sizeValue = sizeRef else {
                continue
            }
            
            var position = CGPoint.zero
            var size = CGSize.zero
            
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
                continue
            }
            
            let positionMatches = abs(position.x - window.frame.origin.x) < frameTolerance &&
                                  abs(position.y - window.frame.origin.y) < frameTolerance
            let sizeMatches = abs(size.width - window.frame.width) < frameTolerance &&
                              abs(size.height - window.frame.height) < frameTolerance
            
            if positionMatches && sizeMatches {
                return axWindow
            }
            if sizeMatches {
                sameSizeWindows.append(axWindow)
            }
            
            var titleRef: CFTypeRef?
            if !window.title.isEmpty,
               AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let axTitle = titleRef as? String,
               axTitle == window.title {
                return axWindow
            }
        }
        
        // While a window is being dragged the window list lags behind its AX position.
        // Its size doesn't change, so the only window of that size is the one
        if sameSizeWindows.count == 1 {
            return sameSizeWindows[0]
        }
        return nil
    }
    
    // MARK: - AX Attribute Collection
    
    private struct AXAttributes {
        var subrole: String?
        var role: String?
        var title: String?  // More reliable than the CGWindow title, which can be empty
        var isModal: Bool = false
        var isMinimized: Bool = false
        var isFullScreen: Bool = false
        var canResize: Bool = false
        /// The app reports the window's size as fixed (Safari Settings). Nil when AX gave no answer.
        var hasFixedSize: Bool?
    }
    
    private func collectAXAttributes(from axWindow: AXUIElement) -> AXAttributes {
        var attrs = AXAttributes()
        
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success {
            attrs.subrole = subroleRef as? String
        }
        
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef) == .success {
            attrs.role = roleRef as? String
        }
        
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success {
            attrs.title = titleRef as? String
        }
        
        var modalRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXModalAttribute as CFString, &modalRef) == .success,
           let modalValue = modalRef as? Bool {
            attrs.isModal = modalValue
        }
        
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimizedValue = minimizedRef as? Bool {
            attrs.isMinimized = minimizedValue
        }
        
        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
           let fullScreenValue = fullScreenRef as? Bool {
            attrs.isFullScreen = fullScreenValue
        }
        
        // A window with a grow area is resizable.
        var actionsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXGrowArea" as CFString, &actionsRef) == .success {
            attrs.canResize = true
        }
        
        var sizeSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute as CFString, &sizeSettable) == .success {
            attrs.hasFixedSize = !sizeSettable.boolValue
        }
        
        return attrs
    }
    
    // MARK: - Hard Stop Checks
    
    private func checkHardStops(_ attrs: AXAttributes) -> WindowClassification? {
        if attrs.isModal {
            return .notTilable(.modal)
        }
        
        if attrs.isMinimized {
            return .notTilable(.minimized)
        }
        
        if attrs.isFullScreen {
            return .notTilable(.fullscreen)
        }
        
        if let subrole = attrs.subrole {
            switch subrole {
            case "AXDialog":
                return .notTilable(.modal)
            case "AXSheet":
                return .notTilable(.sheet)
            case "AXSystemDialog":
                return .notTilable(.systemDialog)
            case "AXFloatingWindow", "AXSystemFloatingWindow":
                return .notTilable(.floatingWindow)
            default:
                break
            }
        }
        
        return nil
    }
    
    // MARK: - App-Specific Rules
    
    private func checkAppSpecificRules(_ window: WindowInfo, axTitle: String) -> WindowClassification? {
        let title = axTitle.isEmpty ? window.title : axTitle
        
        if window.ownerName == "Xcode" {
            let nonTilableXcodeWindows = ["Archives", "Organizer", "Devices and Simulators", "Create a new Xcode project", "Welcome to Xcode"]
            if nonTilableXcodeWindows.contains(where: { title.contains($0) }) {
                return .notTilable(.appSpecificRule)
            }
        }
        
        // Gemini Settings is an ordinary window titled after the section ("General"); the main window is "Gemini — <chat>"
        if window.bundleIdentifier == "com.google.GeminiMacOS", !title.isEmpty, !title.hasPrefix("Gemini") {
            return .notTilable(.appSpecificRule)
        }
        
        if window.ownerName == "Finder" {
            if title == "Finder Preferences" || title.hasSuffix(" Info") {
                return .notTilable(.appSpecificRule)
            }
            
            // A Finder window titled after a mounted volume (DMG, external drive) is not tiled, so installer windows stay put
            if isMountedVolume(title) {
                return .notTilable(.appSpecificRule)
            }
        }
        
        return nil
    }
    
    // MARK: - Mounted Volume Detection
    
    /// Mounted volume names, without the boot volume.
    private var cachedMountedVolumes: Set<String> = []
    private var volumeCacheTimestamp: Date = .distantPast
    private let volumeCacheTTL: TimeInterval = 5.0
    
    private func isMountedVolume(_ title: String) -> Bool {
        guard !title.isEmpty else { return false }
        
        if Date().timeIntervalSince(volumeCacheTimestamp) > volumeCacheTTL {
            refreshMountedVolumesCache()
        }
        
        return cachedMountedVolumes.contains(title)
    }
    
    private func refreshMountedVolumesCache() {
        cachedMountedVolumes = Self.externalVolumeNames(in: URL(fileURLWithPath: "/Volumes"))
        volumeCacheTimestamp = Date()
        
    }
    
    /// Names in /Volumes except the startup disk, which is listed there as a link to "/".
    /// All the others count as "installer" volumes: DMGs, external drives, network shares, etc.
    nonisolated static func externalVolumeNames(in volumesURL: URL) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil)) ?? []
        return Set(entries.filter { $0.resolvingSymlinksInPath().path != "/" }.map(\.lastPathComponent))
    }
    
    // MARK: - Title Heuristics
    
    private func checkTitleHeuristics(_ window: WindowInfo, axTitle: String) -> WindowClassification? {
        let title = axTitle.isEmpty ? window.title : axTitle
        return Self.isDialogTitle(title, ownerName: window.ownerName) ? .notTilable(.titleHeuristic) : nil
    }
    
    /// Whole titles only: a browser tab or a document called "Settings – GitHub" is a normal window
    static func isDialogTitle(_ title: String, ownerName: String) -> Bool {
        let dialogTitles: Set<String> = [
            "Preferences", "Settings", "Info", "Open", "Save", "Save As", "Export", "Import", "Print",
            "About \(ownerName)", "\(ownerName) Settings", "\(ownerName) Preferences"
        ]
        return dialogTitles.contains(title.trimmingCharacters(in: .whitespaces))
    }
    
    // MARK: - Subrole Classification
    
    private func classifyBySubrole(_ attrs: AXAttributes, window: WindowInfo, canOverrideHeuristics: Bool) -> WindowClassification {
        if attrs.subrole == "AXStandardWindow" {
            return .tilable
        }
        
        if attrs.subrole == nil || attrs.subrole?.isEmpty == true {
            if canOverrideHeuristics {
                return .tilable
            }
            
            // Large + resizable = likely Electron/Qt app, allow it
            if attrs.canResize && window.frame.width >= 400 && window.frame.height >= 300 {
                return .tilable
            }
            
            return .unknown(.unknownSubrole)
        }
        
        if !canOverrideHeuristics {
            if window.frame.width < Self.minimumTilableSize || window.frame.height < Self.minimumTilableSize {
                return .notTilable(.tooSmall)
            }
        }
        
        return .tilable
    }
    
    // MARK: - Cache Management
    
    private func getCachedClassification(for windowID: CGWindowID) -> WindowClassification? {
        return cacheQueue.sync {
            guard let entry = cache[windowID] else { return nil }
            
            if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
                cache.removeValue(forKey: windowID)
                return nil
            }
            
            return entry.classification
        }
    }
    
    private func cacheClassification(_ classification: WindowClassification, for windowID: CGWindowID) {
        cacheQueue.sync {
            if cache.count >= maxCacheSize {
                if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
                    cache.removeValue(forKey: oldest.key)
                }
            }
            
            cache[windowID] = CacheEntry(classification: classification, timestamp: Date())
        }
    }
    
    // MARK: - Logging
    
    private func logClassification(_ window: WindowInfo, _ classification: WindowClassification) {
        if let lastClassification = lastLoggedClassification[window.windowID],
           lastClassification == classification {
            return
        }
        
        lastLoggedClassification[window.windowID] = classification
        
        if lastLoggedClassification.count > 100 {
            let cachedWindowIDs = cacheQueue.sync { Set(cache.keys) }
            lastLoggedClassification = lastLoggedClassification.filter { cachedWindowIDs.contains($0.key) }
        }
        
        let decisionStr: String
        switch classification.decision {
        case .tilable:
            decisionStr = "✅ TILABLE"
        case .notTilable:
            decisionStr = "❌ NOT TILABLE"
        case .unknown:
            decisionStr = "❓ UNKNOWN"
        }
        
        debugLog("WindowClassifier", """
            \(decisionStr): '\(window.ownerName)' - '\(window.title)'
            reasons: \(classification.reasonDescription)
            """)
    }
}
