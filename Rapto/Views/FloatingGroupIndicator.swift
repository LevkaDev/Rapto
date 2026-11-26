//
//  FloatingGroupIndicator.swift
//  Rapto
//
//  Floating indicator that shows on grouped windows.
//  Shows an app icon per window; click an icon to activate that window, scroll to move left/right.
//

import SwiftUI
import AppKit

enum GroupIndicatorPosition: String, CaseIterable, Identifiable {
    case left = "Left"
    case right = "Right"
    
    var id: String { rawValue }
}

enum GroupIndicatorSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    
    var id: String { rawValue }
    
    var iconSize: CGFloat {
        switch self {
        case .small: return 24
        case .medium: return 36
        case .large: return 48
        }
    }
    
    /// Horizontal padding for the capsule
    var paddingH: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 24
        case .large: return 32
        }
    }
    
    var iconSpacing: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 12
        case .large: return 16
        }
    }
    
    var indicatorHeight: CGFloat {
        switch self {
        case .small: return 40
        case .medium: return 56
        case .large: return 72
        }
    }
    
    /// Vertical padding for the badge content
    var verticalPadding: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 10
        case .large: return 12
        }
    }
    
    /// Horizontal padding for the badge content
    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 12
        case .large: return 16
        }
    }
}

class FloatingGroupIndicatorWindow: NSPanel {
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false  // SwiftUI handles shadow
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = false
    }
    
    /// Area (AppKit coordinates) the indicator may be dragged within
    var dragBounds: NSRect?
    /// Called with the new window origin when the user finishes dragging
    var onDragEnded: ((NSPoint) -> Void)?
    private(set) var isBeingDragged = false
    
    private let dragThreshold: CGFloat = 4
    private var pendingMouseDown: NSEvent?
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    
    // MARK: - Workaround: Delayed mouseDown to tell click from drag
    // SwiftUI's tap gesture would fire on mouseUp even after a drag, because the window moves with
    // the cursor. So mouseDown is held back and only delivered if the mouse is released without dragging.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pendingMouseDown = event
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
            isBeingDragged = false
            return
            
        case .leftMouseDragged:
            guard pendingMouseDown != nil else { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragStartMouse.x
            let dy = mouse.y - dragStartMouse.y
            if !isBeingDragged {
                guard hypot(dx, dy) >= dragThreshold else { return }
                isBeingDragged = true
                NSCursor.closedHand.push()
            }
            setFrameOrigin(clampedOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)))
            return
            
        case .leftMouseUp:
            guard let mouseDown = pendingMouseDown else { break }
            pendingMouseDown = nil
            if isBeingDragged {
                isBeingDragged = false
                NSCursor.pop()
                onDragEnded?(frame.origin)
                return
            }
            super.sendEvent(mouseDown)
            
        default:
            break
        }
        super.sendEvent(event)
    }
    
    // Indicators are rebuilt while a drag can be going on: give the cursor back, mouseUp won't come here
    override func orderOut(_ sender: Any?) {
        endDrag()
        super.orderOut(sender)
    }
    
    override func close() {
        endDrag()
        super.close()
    }
    
    private func endDrag() {
        pendingMouseDown = nil
        guard isBeingDragged else { return }
        isBeingDragged = false
        NSCursor.pop()
    }
    
    func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        guard let bounds = dragBounds else { return origin }
        let x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
        let y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        return NSPoint(x: x, y: y)
    }
}

@MainActor
class FloatingGroupIndicatorManager {
    
    /// Composite key for indicator windows: "screenID|slotID"
    /// This prevents conflicts when multiple screens use the same template (same slot UUIDs)
    private typealias IndicatorKey = String
    
    private var indicatorWindows: [IndicatorKey: FloatingGroupIndicatorWindow] = [:]
    private weak var appState: AppState?
    
    var indicatorSize: GroupIndicatorSize = .large {
        didSet {
            if oldValue != indicatorSize {
                // Force full refresh when size changes
                lastSlotState.removeAll()
            }
        }
    }
    
    /// Cache for app icons (keyed by bundle ID or PID string)
    private var iconCache: [String: NSImage] = [:]
    
    /// Cache for last slot state (to avoid unnecessary updates)
    private var lastSlotState: [IndicatorKey: SlotCacheEntry] = [:]
    
    private func makeKey(screenID: String, slotID: UUID) -> IndicatorKey {
        return "\(screenID)|\(slotID.uuidString)"
    }
    
    /// Windows shown in each indicator, in stable left-to-right icon order.
    /// Kept stable so icons don't jump around when a different window becomes active.
    private var orderedWindows: [IndicatorKey: [WindowInfo]] = [:]
    
    /// Window most recently activated from an indicator. Used for quick consecutive scrolls,
    /// before the window server reports the new z-order.
    private var pendingActive: [IndicatorKey: (windowID: CGWindowID, date: Date)] = [:]
    private let pendingActiveLifetime: TimeInterval = 0.6
    
    /// Indicators the user dragged aside: current window origin (AppKit coordinates)
    private var displacedOrigins: [IndicatorKey: NSPoint] = [:]
    /// Default frame of each indicator (AppKit coordinates), where a dragged indicator returns to
    private var homeFrames: [IndicatorKey: NSRect] = [:]
    /// When the cursor left the home area of a dragged indicator
    private var cursorAwaySince: [IndicatorKey: Date] = [:]
    private var returnTimer: Timer?
    /// How far around the home position the cursor still counts as "working there"
    private let homeAreaMargin: CGFloat = 60
    /// How long the cursor must stay away from the home area before the indicator returns
    private let returnDelay: TimeInterval = 2.0
    
    private struct SlotCacheEntry: Equatable {
        let orderedWindowIDs: [CGWindowID]
        let activeWindowID: CGWindowID?
        let frame: CGRect
        let hasMixedApps: Bool
        /// Their icons are dimmed
        let notRespondingWindowIDs: [CGWindowID]
    }
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func updateIndicators() {
        guard let appState = appState else { 
            debugLog("FloatingIndicator", "⚠️ updateIndicators() - appState is nil!")
            return 
        }
        
        // Indicator windows are .stationary and would float over the Mission Control thumbnails
        if MissionControlWatcher.shared.isOpen {
            hideAll()
            return
        }

        if appState.groupIndicatorsHidden {
            hideAll()
            return
        }
        
        let hasFloatingWindows = !(appState.floatingWindowService?.getFloatingWindowIDs().isEmpty ?? true)
        if hasFloatingWindows {
            hideAll()
            return
        }
        
        // The focused window is expanded and indicators would obscure it
        let screensWithFocus = appState.focusModeService?.screensShowingFocusedWindow() ?? []
        
        let allWindowsInZOrder = getAllWindowsInZOrder()
        
        let windowFramesByID = Dictionary(
            allWindowsInZOrder.map { ($0.windowID, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        )
        
        let windowLevel: NSWindow.Level = .floating
        
        // Collect slots from ALL screens with active layouts, not just the active screen
        // This ensures indicators appear on all monitors
        // Store (slot, screenID) pairs to know which screen each slot belongs to
        // Drag to Snap groups have no layout slot: their windows are the ones snapped to the zone (memberIDs)
        var allSlotsWithScreen: [(slot: Slot, screenID: String, key: IndicatorKey, memberIDs: Set<CGWindowID>?)] = []
        for (screenID, screenState) in appState.layoutManager.screenStates {
            if screenState.isActive {
                for slot in screenState.slots {
                    allSlotsWithScreen.append((slot: slot, screenID: screenID, key: makeKey(screenID: screenID, slotID: slot.id), memberIDs: nil))
                }
            }
        }
        for group in appState.dragSnapService?.snapGroups(windowFrames: windowFramesByID) ?? [] {
            // Inset, so a window snapped right next to the zone doesn't count as covering it
            let slot = Slot(id: UUID(), index: -1, frame: group.frame.insetBy(dx: 2, dy: 2))
            allSlotsWithScreen.append((slot: slot, screenID: group.screenID, key: "snap|\(group.key)", memberIDs: group.windowIDs))
        }
        
        let allVisibleWindows = appState.windowManager.enumerateWindows()
        
        // For each slot, find the windows physically inside the slot area, using CGWindowList positions
        // instead of slot.windows (which can be stale). slot.windows only decides whether a small window counts.
        let visibleSlots = allSlotsWithScreen.map { item -> (slot: Slot, screenID: String, key: IndicatorKey, visibleCount: Int, visibleWindows: [WindowInfo]) in
            let assignedIDs = Set(item.slot.windows.map(\.windowID))
            let visibleWindows = allVisibleWindows.filter { window in
                if let memberIDs = item.memberIDs { return memberIDs.contains(window.windowID) }
                guard let actualFrame = windowFramesByID[window.windowID] else { return false }
                // Use center-point check instead of intersects to prevent false positives
                // from windows barely overlapping adjacent slots or crossing monitor boundaries
                let windowCenter = CGPoint(x: actualFrame.midX, y: actualFrame.midY)
                guard item.slot.frame.contains(windowCenter) else { return false }
                // A small window of an app over the slot, like a browser's new tab bar, is not part of the group
                let fillsSlot = actualFrame.width >= item.slot.frame.width * 0.8
                    && actualFrame.height >= item.slot.frame.height * 0.8
                if fillsSlot || assignedIDs.contains(window.windowID) { return true }
                return false
            }
            return (slot: item.slot, screenID: item.screenID, key: item.key, visibleCount: visibleWindows.count, visibleWindows: visibleWindows)
        }
        
        let slotsWithVisibleGroups = visibleSlots.filter { $0.visibleCount >= 2 && !screensWithFocus.contains($0.screenID) }
        let currentKeys = Set(slotsWithVisibleGroups.map(\.key))
        
        let existingSlotKeys = Set(allSlotsWithScreen.map(\.key))
        orderedWindows = orderedWindows.filter { existingSlotKeys.contains($0.key) }
        pendingActive = pendingActive.filter { existingSlotKeys.contains($0.key) }
        for key in displacedOrigins.keys where !currentKeys.contains(key) {
            clearDisplacement(for: key)
        }
        
        
        for key in indicatorWindows.keys {
            if !currentKeys.contains(key) {
                debugLog("FloatingIndicator", " 🔴 Closing indicator for key: \(key) (slot no longer has 2+ visible windows)")
                indicatorWindows[key]?.close()
                indicatorWindows.removeValue(forKey: key)
                lastSlotState.removeValue(forKey: key)
            }
        }
        
        for slotData in slotsWithVisibleGroups {
            let slot = slotData.slot
            let screenID = slotData.screenID
            let visibleWindowCount = slotData.visibleCount
            let visibleWindows = slotData.visibleWindows
            let indicatorKey = slotData.key
            
            let slotWindowIDs = Set(visibleWindows.map { $0.windowID })
            let hasOverlay = hasOverlayingWindows(slot: slot, slotWindowIDs: slotWindowIDs, allWindows: allWindowsInZOrder)

            if hasOverlay {
                if let existingWindow = indicatorWindows[indicatorKey] {
                    existingWindow.close()
                    indicatorWindows.removeValue(forKey: indicatorKey)
                    lastSlotState.removeValue(forKey: indicatorKey)
                }
                continue
            }
            
            let size = indicatorSize
            let iconsWidth = CGFloat(visibleWindowCount) * size.iconSize + CGFloat(max(0, visibleWindowCount - 1)) * size.iconSpacing
            let indicatorWidth = size.paddingH + iconsWidth
            let indicatorSizeValue = CGSize(width: indicatorWidth, height: size.indicatorHeight)
            
            let margin: CGFloat = 8
            let indicatorPosition = appState.groupIndicatorPosition
            let xPos: CGFloat
            switch indicatorPosition {
            case .left:
                xPos = slot.frame.minX + margin
            case .right:
                xPos = slot.frame.maxX - indicatorSizeValue.width - margin
            }

            // Use primary screen height for CG to AppKit coordinate conversion
            // NSScreen.main changes based on active window, but CG coordinates are always
            // relative to primary screen (top-left origin)
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1440
            // Slot.frame is in CG coordinates (top-left origin)
            // Convert to AppKit coordinates (bottom-left origin) for NSWindow positioning
            // CG Y -> AppKit Y: appKitY = primaryScreenHeight - cgY - height
            let indicatorAppKitY = primaryScreenHeight - (slot.frame.minY + indicatorSizeValue.height + margin)
            
            let indicatorFrame = NSRect(
                x: xPos,
                y: indicatorAppKitY,
                width: indicatorSizeValue.width,
                height: indicatorSizeValue.height
            )

            let slotAppKitFrame = NSRect(
                x: slot.frame.minX,
                y: primaryScreenHeight - slot.frame.maxY,
                width: slot.frame.width,
                height: slot.frame.height
            )
            homeFrames[indicatorKey] = indicatorFrame
            
            // A dragged-aside indicator stays where the user put it until it returns home
            var targetFrame = indicatorFrame
            if let displacedOrigin = displacedOrigins[indicatorKey] {
                targetFrame.origin.x = min(max(displacedOrigin.x, slotAppKitFrame.minX), max(slotAppKitFrame.minX, slotAppKitFrame.maxX - targetFrame.width))
                targetFrame.origin.y = min(max(displacedOrigin.y, slotAppKitFrame.minY), max(slotAppKitFrame.minY, slotAppKitFrame.maxY - targetFrame.height))
            }
            
            // visibleWindows is in z-order (front to back), so the first one is the active window
            let stableWindows = stableOrder(for: indicatorKey, windows: visibleWindows)
            let activeWindowID = visibleWindows.first?.windowID
            
            let cacheEntry = SlotCacheEntry(
                orderedWindowIDs: stableWindows.map { $0.windowID },
                activeWindowID: activeWindowID,
                frame: slot.frame,
                hasMixedApps: visibleWindows.count >= 2 && Set(visibleWindows.compactMap { $0.bundleIdentifier }).count > 1,
                notRespondingWindowIDs: stableWindows.filter { !AppResponsiveness.isResponding($0.ownerPID) }.map { $0.windowID }
            )
            
            // An indicator stays on the desktop it was shown on, and desktops with the same template
            // share slot keys: one left on the previous desktop is made again on this one
            if let staleWindow = indicatorWindows[indicatorKey], staleWindow.isVisible, !staleWindow.isOnActiveSpace {
                debugLog("FloatingIndicator", "Indicator for \(indicatorKey) is on another desktop, making it again")
                staleWindow.close()
                indicatorWindows.removeValue(forKey: indicatorKey)
                lastSlotState.removeValue(forKey: indicatorKey)
            }

            if let existingWindow = indicatorWindows[indicatorKey] {
                configureDrag(for: existingWindow, key: indicatorKey, slotFrame: slotAppKitFrame)
                // Update position - use display: false to avoid triggering SwiftUI update conflicts
                // The window will redraw on the next display cycle automatically
                if !existingWindow.isBeingDragged {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    existingWindow.setFrame(targetFrame, display: false)
                    CATransaction.commit()
                }
                existingWindow.level = windowLevel
                
                if lastSlotState[indicatorKey] != cacheEntry {
                    let grewGroup = cacheEntry.orderedWindowIDs.count > (lastSlotState[indicatorKey]?.orderedWindowIDs.count ?? 0)
                    // Defer content update to next run loop to avoid AttributeGraph conflicts
                    let windowRef = existingWindow
                    let slotIndex = slot.index
                    let screenIDCopy = screenID
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        guard self.indicatorWindows.values.contains(where: { $0 === windowRef }) else { return }
                        self.updateContent(for: windowRef, key: indicatorKey, slotIndex: slotIndex, screenID: screenIDCopy, windows: stableWindows, activeWindowID: activeWindowID)
                        if grewGroup {
                            self.appState?.didShowGroupBadge(frame: windowRef.frame, screenID: screenIDCopy)
                        }
                    }
                    lastSlotState[indicatorKey] = cacheEntry
                }
            } else {
                // Create new indicator - defer to next run loop to avoid AttributeGraph conflicts
                let window = FloatingGroupIndicatorWindow(contentRect: targetFrame)
                window.level = windowLevel
                configureDrag(for: window, key: indicatorKey, slotFrame: slotAppKitFrame)
                indicatorWindows[indicatorKey] = window
                lastSlotState[indicatorKey] = cacheEntry
                
                let slotIndex = slot.index
                let screenIDCopy = screenID
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Verify this indicator wasn't closed by hideAll()/cleanup before async executed
                    guard self.indicatorWindows.values.contains(where: { $0 === window }) else { return }
                    self.updateContent(for: window, key: indicatorKey, slotIndex: slotIndex, screenID: screenIDCopy, windows: stableWindows, activeWindowID: activeWindowID)
                    window.orderFront(nil)
                    self.appState?.didShowGroupBadge(frame: window.frame, screenID: screenIDCopy)
                }
            }
        }
    }
    
    /// Keep previously known windows in their old positions and append new ones at the end
    private func stableOrder(for key: IndicatorKey, windows: [WindowInfo]) -> [WindowInfo] {
        let windowsByID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = (orderedWindows[key] ?? []).compactMap { windowsByID[$0.windowID] }
        let knownIDs = Set(result.map { $0.windowID })
        result.append(contentsOf: windows.filter { !knownIDs.contains($0.windowID) })
        orderedWindows[key] = result
        return result
    }
    
    private func updateContent(for window: FloatingGroupIndicatorWindow, key: IndicatorKey, slotIndex: Int, screenID: String, windows: [WindowInfo], activeWindowID: CGWindowID?) {
        guard let appState = appState else { return }
        
        let appIcons = windows.map { getAppIcon(for: $0) }
        let activeIndex = windows.firstIndex(where: { $0.windowID == activeWindowID }) ?? 0
        let isMixedApps = windows.count >= 2 && Set(windows.compactMap { $0.bundleIdentifier }).count > 1
        
        let contentView = NSHostingView(rootView:
            GroupIndicatorBadge(
                windowCount: windows.count,
                activeIndex: activeIndex,
                isMixedApps: isMixedApps,
                appIcons: appIcons,
                notResponding: windows.map { !AppResponsiveness.isResponding($0.ownerPID) },
                size: indicatorSize,
                onSelect: { [weak self] index in
                    guard let self = self, let windows = self.orderedWindows[key], index < windows.count else { return }
                    debugLog("FloatingIndicator", "=== SELECT icon \(index) === slot \(slotIndex) on screen \(screenID)")
                    self.activateWindow(windows[index].windowID, key: key, slotIndex: slotIndex, screenID: screenID)
                },
                onStep: { [weak self] offset in
                    debugLog("FloatingIndicator", "=== STEP \(offset) === slot \(slotIndex) on screen \(screenID)")
                    self?.stepActiveWindow(by: offset, key: key, slotIndex: slotIndex, screenID: screenID)
                },
                isScrollEnabled: appState.enableScrollToSwitch
            )
        )
        window.contentView = contentView
    }
    
    /// Activate the neighbour of the current active window in icon order (-1 = left, +1 = right), wrapping around
    private func stepActiveWindow(by offset: Int, key: IndicatorKey, slotIndex: Int, screenID: String) {
        guard let windows = orderedWindows[key], windows.count > 1 else { return }
        
        let currentID: CGWindowID?
        if let pending = pendingActive[key], Date().timeIntervalSince(pending.date) < pendingActiveLifetime {
            currentID = pending.windowID
        } else {
            let ids = Set(windows.map { $0.windowID })
            currentID = getAllWindowsInZOrder().first(where: { ids.contains($0.windowID) })?.windowID
        }
        
        let currentIndex = windows.firstIndex(where: { $0.windowID == currentID }) ?? 0
        let nextIndex = ((currentIndex + offset) % windows.count + windows.count) % windows.count
        activateWindow(windows[nextIndex].windowID, key: key, slotIndex: slotIndex, screenID: screenID)
    }
    
    private func activateWindow(_ windowID: CGWindowID, key: IndicatorKey, slotIndex: Int, screenID: String) {
        guard let appState = appState else { return }
        guard let cached = orderedWindows[key]?.first(where: { $0.windowID == windowID }) else { return }
        let window = appState.windowManager.refreshWindowInfo(for: windowID) ?? cached
        
        // Raising it would wait for an answer that does not come
        guard AppResponsiveness.isResponding(window.ownerPID) else {
            appState.showNotRespondingNotice(for: window.ownerPID)
            return
        }
        
        let screenState = appState.layoutManager.state(forScreenID: screenID)
        if slotIndex >= 0, slotIndex < screenState.slots.count, screenState.slots[slotIndex].contains(windowID: windowID) {
            appState.layoutManager.setActiveWindow(windowID, in: slotIndex, forScreenID: screenID)
        }
        
        // Same-app windows stacked at one position can't be told apart by position, so raise by z-order
        let hasSameAppSiblings = (orderedWindows[key] ?? []).contains { $0.windowID != windowID && $0.ownerPID == window.ownerPID }
        debugLog("FloatingIndicator", "Activating window \(windowID) (\(window.ownerName)), hasSameAppSiblings=\(hasSameAppSiblings)")
        
        if hasSameAppSiblings {
            appState.accessibilityService.raiseWindowByZOrder(window)
        } else {
            appState.accessibilityService.raiseWindow(window)
        }
        
        activateAppIfStillBehind(window)
        pendingActive[key] = (windowID, Date())
        NotificationCenter.default.post(name: .raptoTourDidCycleGroup, object: nil)
        updateIndicators()
        // The window server may report the new z-order with a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateIndicators()
        }
    }
    
    // MARK: - Workaround: a locked 1Password keeps the focus
    // Its lock screen turns on secure input, and then macOS ignores the request to make another app frontmost.
    private func activateAppIfStillBehind(_ window: WindowInfo) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let front = NSWorkspace.shared.frontmostApplication
            guard front?.processIdentifier != window.ownerPID,
                  let target = NSRunningApplication(processIdentifier: window.ownerPID) else { return }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let securePID = session?["kCGSSessionSecureInputPID"] as? Int ?? 0
            debugLog("FloatingIndicator", "'\(window.ownerName)' is still behind '\(front?.localizedName ?? "?")' (secure input PID \(securePID)), activating again")
            if #available(macOS 14.0, *) {
                target.activate(from: .current, options: [])
            } else {
                target.activate(options: [])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let now = NSWorkspace.shared.frontmostApplication
                debugLog("FloatingIndicator", "After activating again, frontmost is '\(now?.localizedName ?? "?")'")
            }
        }
    }

    // MARK: - Dragging aside
    
    private func configureDrag(for window: FloatingGroupIndicatorWindow, key: IndicatorKey, slotFrame: NSRect) {
        window.dragBounds = slotFrame
        window.onDragEnded = { [weak self] origin in
            guard let self = self else { return }
            debugLog("FloatingIndicator", "Indicator \(key) dragged aside to \(origin)")
            self.displacedOrigins[key] = origin
            self.cursorAwaySince[key] = nil
            self.startReturnTimerIfNeeded()
        }
    }
    
    private func startReturnTimerIfNeeded() {
        guard returnTimer == nil else { return }
        returnTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDisplacedIndicators()
            }
        }
    }
    
    /// Send a dragged-aside indicator home once the cursor has stayed away from its home area for a while
    private func checkDisplacedIndicators() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        
        for key in Array(displacedOrigins.keys) {
            guard let window = indicatorWindows[key], let home = homeFrames[key] else {
                clearDisplacement(for: key)
                continue
            }
            let cursorNearby = window.isBeingDragged
                || window.frame.contains(mouse)
                || home.insetBy(dx: -homeAreaMargin, dy: -homeAreaMargin).contains(mouse)
            if cursorNearby {
                cursorAwaySince[key] = nil
                continue
            }
            guard let awaySince = cursorAwaySince[key] else {
                cursorAwaySince[key] = now
                continue
            }
            if now.timeIntervalSince(awaySince) >= returnDelay {
                debugLog("FloatingIndicator", "Indicator \(key) returning home")
                clearDisplacement(for: key)
                window.setFrame(home, display: true, animate: true)
            }
        }
    }
    
    private func clearDisplacement(for key: IndicatorKey) {
        displacedOrigins.removeValue(forKey: key)
        cursorAwaySince.removeValue(forKey: key)
        if displacedOrigins.isEmpty {
            returnTimer?.invalidate()
            returnTimer = nil
        }
    }
    
    private func getAppIcon(for window: WindowInfo) -> NSImage? {
        let cacheKey = window.bundleIdentifier ?? "pid-\(window.ownerPID)"
        
        if let cachedIcon = iconCache[cacheKey] {
            return cachedIcon
        }
        
        if let bundleID = window.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            iconCache[cacheKey] = icon
            return icon
        }
        
        if let app = NSRunningApplication(processIdentifier: window.ownerPID),
           let icon = app.icon {
            iconCache[cacheKey] = icon
            return icon
        }
        
        return nil
    }
    
    func hideAll() {
        for window in indicatorWindows.values {
            window.close()
        }
        indicatorWindows.removeAll()
        lastSlotState.removeAll()
        for key in Array(displacedOrigins.keys) {
            clearDisplacement(for: key)
        }
    }
    
    /// Force refresh all indicators by clearing cache
    /// Use this when slot data has changed and indicators need to be rebuilt
    func forceRefresh() {
        debugLog("FloatingIndicator", "🔄 forceRefresh() - clearing cache and updating")
        lastSlotState.removeAll()
        updateIndicators()
    }
    
    /// Get all windows in z-order (front to back) using CGWindowListCopyWindowInfo
    private func getAllWindowsInZOrder() -> [(windowID: CGWindowID, frame: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        
        return windowList.compactMap { dict -> (CGWindowID, CGRect)? in
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = dict[kCGWindowLayer as String] as? Int else {
                return nil
            }
            
            // Only normal windows (layer == 0)
            guard layer == 0 else { return nil }
            
            guard ownerPID != ownPID else { return nil }
            
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            
            // Skip tiny windows (tooltips, popovers, menu items) to avoid false overlay detection
            guard frame.width > 100 && frame.height > 100 else { return nil }
            
            return (windowID, frame)
        }
    }
    
    private func hasOverlayingWindows(slot: Slot, slotWindowIDs: Set<CGWindowID>, allWindows: [(windowID: CGWindowID, frame: CGRect)]) -> Bool {
        // Slot frames are in CG coordinates (top-left origin), like the CGWindowList bounds
        let slotFrameCG = slot.frame

        // Windows are in z-order (front to back)
        // We only care about windows that appear BEFORE any slot window in the list,
        // meaning they are above the slot windows in z-order
        
        for (windowID, windowFrame) in allWindows {
            if slotWindowIDs.contains(windowID) {
                // Once we hit a slot window, all windows after it are below it
                // So we can stop checking
                break
            }
            
            if slotFrameCG.intersects(windowFrame) {
                debugLog("FloatingIndicator", "  Window \(windowID) overlaps slot from above! windowFrame=\(windowFrame)")
                return true
            }
        }
        
        return false
    }
    
}

struct GroupIndicatorBadge: View {
    let windowCount: Int
    let activeIndex: Int
    let isMixedApps: Bool
    /// One entry per window, in icon order; nil when the app icon is unavailable
    let appIcons: [NSImage?]
    /// One entry per icon: the app of that window is not answering. Empty means none
    var notResponding: [Bool] = []
    let size: GroupIndicatorSize
    let onSelect: (Int) -> Void
    /// -1 = activate the window to the left, +1 = to the right
    let onStep: (Int) -> Void
    let isScrollEnabled: Bool
    
    @State private var isHovered = false
    
    var body: some View {
        ScrollWheelView(
            onScrollUp: { onStep(-1) },
            onScrollDown: { onStep(1) },
            isScrollEnabled: isScrollEnabled
        ) {
            HStack(spacing: size.iconSpacing) {
                ForEach(0..<appIcons.count, id: \.self) { index in
                    iconView(appIcons[index])
                        .frame(width: size.iconSize, height: size.iconSize)
                        .opacity(isNotResponding(index) ? 0.2 : (index == activeIndex ? 1.0 : 0.5))
                        .contentShape(Rectangle())
                        .help(isNotResponding(index) ? "Not responding" : "")
                        .onTapGesture {
                            onSelect(index)
                        }
                }
            }
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .fixedSize()
    }
    
    private func isNotResponding(_ index: Int) -> Bool {
        index < notResponding.count && notResponding[index]
    }
    
    @ViewBuilder
    private func iconView(_ icon: NSImage?) -> some View {
        if let icon = icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "macwindow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white)
                .padding(size.iconSize * 0.15)
        }
    }
}

struct ScrollWheelView<Content: View>: NSViewRepresentable {
    let onScrollUp: () -> Void
    let onScrollDown: () -> Void
    let isScrollEnabled: Bool
    let content: () -> Content
    
    init(onScrollUp: @escaping () -> Void, onScrollDown: @escaping () -> Void, isScrollEnabled: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.onScrollUp = onScrollUp
        self.onScrollDown = onScrollDown
        self.isScrollEnabled = isScrollEnabled
        self.content = content
    }
    
    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScrollUp = onScrollUp
        view.onScrollDown = onScrollDown
        view.isScrollEnabled = isScrollEnabled
        
        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        return view
    }
    
    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScrollUp = onScrollUp
        nsView.onScrollDown = onScrollDown
        nsView.isScrollEnabled = isScrollEnabled
    }
}

class ScrollWheelNSView: NSView {
    var onScrollUp: (() -> Void)?
    var onScrollDown: (() -> Void)?
    var isScrollEnabled: Bool = true
    
    private var lastScrollTime: Date = .distantPast
    private let scrollDebounce: TimeInterval = 0.15
    
    override func scrollWheel(with event: NSEvent) {
        guard isScrollEnabled else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) > scrollDebounce else { return }
        lastScrollTime = now
        
        let deltaY = event.scrollingDeltaY
        
        if deltaY > 0.5 {
            onScrollUp?()
        } else if deltaY < -0.5 {
            onScrollDown?()
        }
    }
}

#if DEBUG
struct GroupIndicatorBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            GroupIndicatorBadge(
                windowCount: 3,
                activeIndex: 1,
                isMixedApps: false,
                appIcons: [],
                size: .large,
                onSelect: { _ in },
                onStep: { _ in },
                isScrollEnabled: true
            )
            
            GroupIndicatorBadge(
                windowCount: 2,
                activeIndex: 0,
                isMixedApps: true,
                appIcons: [],
                size: .large,
                onSelect: { _ in },
                onStep: { _ in },
                isScrollEnabled: true
            )
        }
        .padding()
        .background(Color.gray)
        .frame(width: 200, height: 150)
    }
}
#endif
