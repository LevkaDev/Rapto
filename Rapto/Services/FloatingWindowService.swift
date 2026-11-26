//
//  FloatingWindowService.swift
//  Rapto
//
//  Service for managing floating windows that stay on top and are excluded from tiling.
//  Supports hotkey activation and modifier+double-click on window.
//

import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "FloatingWindowService")

enum FloatingModifierKey: String, CaseIterable, Codable {
    case option = "option"
    case shift = "shift"
    case control = "control"
    case command = "command"
    case optionCommand = "optionCommand"
    
    var displayName: String {
        switch self {
        case .option: return "Option (⌥)"
        case .shift: return "Shift (⇧)"
        case .control: return "Control (⌃)"
        case .command: return "Command (⌘)"
        case .optionCommand: return "Option + Command (⌥⌘)"
        }
    }
    
    var eventModifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .shift: return .shift
        case .control: return .control
        case .command: return .command
        case .optionCommand: return [.option, .command]
        }
    }

    /// Exactly these keys, so Option doesn't also fire for Option + Command
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command]) == eventModifierFlags
    }
}

/// A window's state before it was floated, used to restore it.
struct FloatingWindowOrigin {
    let frame: CGRect
    let slotIndex: Int?  // nil if the window wasn't in a slot
    let wasGrouped: Bool
    let screenID: String?
}

@MainActor
class FloatingWindowService {
    
    // MARK: - Properties
    
    private(set) var floatingWindowIDs: Set<CGWindowID> = []
    
    private var floatingWindowPIDs: [CGWindowID: pid_t] = [:]
    
    private var originalStates: [CGWindowID: FloatingWindowOrigin] = [:]
    
    /// Restores a window to its slot. Set by AppState.
    /// Parameters: window, slotIndex, wasGrouped, screenID
    var onRestoreToSlot: ((WindowInfo, Int, Bool, String?) -> Void)?
    
    /// Takes the window out of its slot before floating it, as the hotkey does
    var onDoubleTap: ((WindowInfo) -> Void)?

    /// Called before a window is floated or unfloated
    var onFloatStateChanging: ((CGWindowID) -> Void)?

    /// A window in focus mode can't be floated by double-click
    var isWindowLocked: ((CGWindowID) -> Bool)?

    /// A double-click that also holds the focus mode modifier is left to focus mode
    var yieldsDoubleTap: ((NSEvent.ModifierFlags) -> Bool)?

    /// Last known info of floating windows, to check them while they are off screen
    private var floatingWindows: [CGWindowID: WindowInfo] = [:]

    /// Floating windows that were closed, minimized or went full screen, kept until they come back
    private var pendingReturns: [CGWindowID: FloatingWindowOrigin] = [:]
    
    private var appActivationObserver: Any?
    
    // MARK: - Double-tap Detection
    
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var lastClickTime: Date?
    private var lastClickWindowID: CGWindowID?
    private var mouseDownPosition: CGPoint?
    private let doubleTapInterval: TimeInterval = 0.3
    private let maxDragDistance: CGFloat = 10
    
    var doubleTapEnabled: Bool = false
    
    var doubleTapModifier: FloatingModifierKey = .optionCommand
    
    private let accessibilityService: AccessibilityService
    private let windowManager: WindowManager
    private let screenManager: ScreenManager
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, windowManager: WindowManager, screenManager: ScreenManager) {
        self.accessibilityService = accessibilityService
        self.windowManager = windowManager
        self.screenManager = screenManager
        
        setupAppActivationObserver()
    }
    
    deinit {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - Double-tap Public Methods
    
    func isDoubleTapModifierHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        doubleTapEnabled && doubleTapModifier.matches(flags)
    }
    
    func updateDoubleTapMonitoring() {
        if doubleTapEnabled {
            setupDoubleTapMonitor()
        } else {
            removeDoubleTapMonitor()
        }
    }
    
    // MARK: - Always On Top Monitoring
    
    /// Keeps floating windows on top when another app is activated
    private func setupAppActivationObserver() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract app info before async context to avoid Sendable warning
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.handleAppActivated(app: app)
            }
        }
    }
    
    private func handleAppActivated(app: NSRunningApplication?) {
        guard !floatingWindowIDs.isEmpty, !SpaceBarController.isDrivingMouse else { return }
        
        guard let activatedApp = app else {
            return
        }
        
        let activatedPID = activatedApp.processIdentifier
        let floatingPIDsInActivatedApp = floatingWindowPIDs.filter { $0.value == activatedPID }
        
        if floatingPIDsInActivatedApp.isEmpty {
            raiseAllFloatingWindows()
        }
    }
    
    func raiseAllFloatingWindows() {
        guard !floatingWindowIDs.isEmpty else { return }
        
        let currentWindows = windowManager.enumerateWindows()
        
        for windowID in floatingWindowIDs {
            if let window = currentWindows.first(where: { $0.windowID == windowID }) {
                accessibilityService.raiseWindow(window)
                logger.debug("Raised floating window '\(window.title, privacy: .public)' to front")
            }
        }
    }
    
    // MARK: - Public Methods
    
    func isFloating(windowID: CGWindowID) -> Bool {
        floatingWindowIDs.contains(windowID)
    }
    
    func toggleFloat(for window: WindowInfo, slotIndex: Int? = nil, wasGrouped: Bool = false) {
        if floatingWindowIDs.contains(window.windowID) {
            unfloat(window: window)
        } else {
            float(window: window, slotIndex: slotIndex, wasGrouped: wasGrouped)
        }
    }
    
    /// Floats a window: centers it on screen and raises it, remembering its slot to restore later.
    func float(window: WindowInfo, slotIndex: Int? = nil, wasGrouped: Bool = false, screenID: String? = nil) {
        guard !floatingWindowIDs.contains(window.windowID) else {
            logger.debug("Window already floating")
            return
        }
        onFloatStateChanging?(window.windowID)
        
        logger.info("Floating window '\(window.title, privacy: .public)' from slot \(slotIndex?.description ?? "none"), grouped: \(wasGrouped), screen: \(screenID ?? "none")")
        
        let origin = FloatingWindowOrigin(
            frame: window.frame,
            slotIndex: slotIndex,
            wasGrouped: wasGrouped,
            screenID: screenID
        )
        originalStates[window.windowID] = origin
        pendingReturns.removeValue(forKey: window.windowID)
        
        floatingWindowIDs.insert(window.windowID)
        floatingWindowPIDs[window.windowID] = window.ownerPID
        floatingWindows[window.windowID] = window
        
        centerWindow(window)
        
        accessibilityService.raiseWindow(window)
        
        debugLog("FloatingWindowService"," Floated '\(window.title)' - slot: \(slotIndex?.description ?? "none"), grouped: \(wasGrouped)")
    }
    
    /// Stops floating a window and restores it to its original slot or frame
    func unfloat(window: WindowInfo) {
        guard floatingWindowIDs.contains(window.windowID) else {
            logger.debug("Window is not floating")
            return
        }
        onFloatStateChanging?(window.windowID)
        
        let origin = originalStates[window.windowID]
        logger.info("Unfloating window '\(window.title, privacy: .public)' to slot \(origin?.slotIndex?.description ?? "none")")
        
        forget(window.windowID)
        if let origin {
            restore(window, to: origin)
        }
    }

    private func restore(_ window: WindowInfo, to origin: FloatingWindowOrigin) {
        if let slotIndex = origin.slotIndex {
            onRestoreToSlot?(window, slotIndex, origin.wasGrouped, origin.screenID)
            debugLog("FloatingWindowService"," Restoring '\(window.title)' to slot \(slotIndex), grouped: \(origin.wasGrouped), screen: \(origin.screenID ?? "default")")
        } else {
            restoreWindowFrame(window, to: origin.frame)
            debugLog("FloatingWindowService"," Restored '\(window.title)' to original frame")
        }
    }

    private func forget(_ windowID: CGWindowID) {
        floatingWindowIDs.remove(windowID)
        floatingWindowPIDs.removeValue(forKey: windowID)
        floatingWindows.removeValue(forKey: windowID)
        originalStates.removeValue(forKey: windowID)
    }
    
    /// Stops floating, keeping the way back for when the window comes back
    private func leaveUntilWindowReturns(_ windowID: CGWindowID) {
        if let origin = originalStates[windowID] {
            pendingReturns[windowID] = origin
        }
        forget(windowID)
    }

    /// Stops floating windows that were minimized or went full screen. Returns whether any did.
    @discardableResult
    func endForHiddenWindows() -> Bool {
        var ended = false
        for (windowID, window) in floatingWindows {
            if accessibilityService.isWindowMinimized(window) {
                debugLog("FloatingWindowService", "Floating window \(windowID) was minimized, no longer floating")
            } else if accessibilityService.isWindowFullScreen(window) {
                debugLog("FloatingWindowService", "Floating window \(windowID) went full screen, no longer floating")
            } else {
                continue
            }
            leaveUntilWindowReturns(windowID)
            ended = true
        }
        return ended
    }

    /// A window that stopped floating comes back from the Dock or from full screen; put it back in its slot.
    func returnPendingWindows() {
        guard !pendingReturns.isEmpty else { return }
        for window in windowManager.enumerateWindows() {
            guard let origin = pendingReturns[window.windowID],
                  !accessibilityService.isWindowFullScreen(window) else { continue }
            pendingReturns.removeValue(forKey: window.windowID)
            debugLog("FloatingWindowService", "Window \(window.windowID) is back, returning it to its slot")
            restore(window, to: origin)
        }
    }
    
    func getFloatingWindowIDs() -> Set<CGWindowID> {
        floatingWindowIDs
    }
    
    /// Forget floating windows that were closed. Returns whether any were.
    @discardableResult
    func cleanupClosedWindows() -> Bool {
        // Some apps report a minimized or full screen window as closed
        let closedFloating = floatingWindowIDs.filter { !windowManager.windowExists($0) }
        for windowID in closedFloating {
            leaveUntilWindowReturns(windowID)
        }
        
        if !closedFloating.isEmpty {
            debugLog("FloatingWindowService", "Forgot \(closedFloating.count) closed floating window(s): \(closedFloating)")
        }
        return !closedFloating.isEmpty
    }
    
    // MARK: - Private Methods
    
    private func centerWindow(_ window: WindowInfo) {
        let screenFrame = screenManager.visibleFrame()
        
        let windowWidth = window.frame.width
        let windowHeight = window.frame.height
        
        let centeredX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let centeredY = screenFrame.origin.y + (screenFrame.height - windowHeight) / 2
        
        // Convert to CG coordinates. These are relative to the primary screen's top-left origin,
        // so the height comes from screens.first (primary screen), not main (focused screen)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgY = primaryScreenHeight - centeredY - windowHeight
        
        let newPosition = CGPoint(x: centeredX, y: cgY)
        
        let success = accessibilityService.setWindowPosition(window, position: newPosition)
        if success {
            logger.debug("Centered window at (\(centeredX), \(cgY))")
        } else {
            logger.warning("Failed to center window")
        }
    }
    
    /// Restore a window to its original frame (CG coordinates, as `WindowInfo.frame`)
    private func restoreWindowFrame(_ window: WindowInfo, to frame: CGRect) {
        _ = accessibilityService.setWindowPosition(window, position: frame.origin)
        _ = accessibilityService.setWindowSize(window, size: frame.size)
    }
    
    // MARK: - Double-tap Detection
    
    private func setupDoubleTapMonitor() {
        guard mouseDownMonitor == nil else { return }
        
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseDown(event)
            }
        }
        
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseUp(event)
            }
        }
        logger.debug("Double-tap monitor set up for floating")
    }
    
    private func removeDoubleTapMonitor() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    /// A click DoubleClickGuard hid from apps, which the monitors above don't get
    func handleHiddenClick(_ event: NSEvent) {
        guard mouseDownMonitor != nil else { return }
        if event.type == .leftMouseDown {
            handleMouseDown(event)
        } else if event.type == .leftMouseUp {
            handleMouseUp(event)
        }
    }

    /// The same click can come both from a monitor and from DoubleClickGuard
    private var lastHandledClick: (type: NSEvent.EventType, timestamp: TimeInterval)?

    private func isNewClick(_ event: NSEvent) -> Bool {
        if let last = lastHandledClick, last.type == event.type, last.timestamp == event.timestamp { return false }
        lastHandledClick = (event.type, event.timestamp)
        return true
    }
    
    private func handleMouseDown(_ event: NSEvent) {
        guard doubleTapEnabled, isNewClick(event) else { return }
        
        let modifierPressed = doubleTapModifier.matches(DoubleClickGuard.heldModifiers(of: event))
        guard modifierPressed else {
            mouseDownPosition = nil
            return
        }
        
        // Recorded to tell a drag from a click
        mouseDownPosition = NSEvent.mouseLocation
    }
    
    private func handleMouseUp(_ event: NSEvent) {
        guard doubleTapEnabled, isNewClick(event) else { return }
        
        let modifierPressed = doubleTapModifier.matches(event.modifierFlags)
        guard modifierPressed else {
            lastClickTime = nil
            lastClickWindowID = nil
            mouseDownPosition = nil
            return
        }
        
        // If mouseDownPosition is nil, the modifier key was not held at mouseDown:
        // the user pressed it during a drag (e.g., for swap), not for double-tap
        guard let downPos = mouseDownPosition else {
            lastClickTime = nil
            lastClickWindowID = nil
            return
        }
        
        let currentPos = NSEvent.mouseLocation
        let distance = hypot(currentPos.x - downPos.x, currentPos.y - downPos.y)
        if distance > maxDragDistance {
            mouseDownPosition = nil
            lastClickTime = nil
            lastClickWindowID = nil
            return
        }
        mouseDownPosition = nil
        
        let currentTime = Date()
        let mouseLocation = currentPos
        
        guard let windowUnderCursor = findWindowAt(mouseLocation) else {
            lastClickTime = nil
            lastClickWindowID = nil
            return
        }
        
        if let lastTime = lastClickTime,
           let lastWindowID = lastClickWindowID,
           lastWindowID == windowUnderCursor.windowID,
           currentTime.timeIntervalSince(lastTime) < doubleTapInterval {
            logger.debug("\(self.doubleTapModifier.displayName)+Double-tap detected on window '\(windowUnderCursor.title)' for floating")
            
            if yieldsDoubleTap?(event.modifierFlags) == true {
                debugLog("FloatingWindowService", "Double-click also holds the focus mode key, leaving it to focus mode")
            } else if isWindowLocked?(windowUnderCursor.windowID) == true {
                debugLog("FloatingWindowService", "Window \(windowUnderCursor.windowID) is in focus mode, not floating it")
            } else if let onDoubleTap {
                onDoubleTap(windowUnderCursor)
            } else {
                toggleFloat(for: windowUnderCursor)
            }
            
            lastClickTime = nil
            lastClickWindowID = nil
        } else {
            lastClickTime = currentTime
            lastClickWindowID = windowUnderCursor.windowID
        }
    }
    
    private func findWindowAt(_ point: CGPoint) -> WindowInfo? {
        let windows = windowManager.enumerateWindows()
        // CG coordinates are relative to the primary screen's top-left origin,
        // so the height comes from screens.first (primary screen), not main (focused screen)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        for window in windows {
            let windowFrameAppKit = CGRect(
                x: window.frame.origin.x,
                y: primaryScreenHeight - window.frame.origin.y - window.frame.height,
                width: window.frame.width,
                height: window.frame.height
            )
            
            if windowFrameAppKit.contains(point) {
                return window
            }
        }
        
        return nil
    }
}
