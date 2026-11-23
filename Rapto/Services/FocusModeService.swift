//
//  FocusModeService.swift
//  Rapto
//
//  Service for Focus Mode - expand active window to full screen and restore on toggle.
//  Supports hotkey activation and Option+double-click on window.
//

import Foundation
import AppKit
import Carbon
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "FocusModeService")

enum FocusModeModifierKey: String, CaseIterable, Codable {
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

@MainActor
class FocusModeService: ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isActive: Bool = false
    
    struct FocusedWindow {
        let window: WindowInfo
        /// Where the window was before focus mode, i.e. its slot
        let slotFrame: CGRect
        let focusFrame: CGRect
        let screenID: String
        let spaceID: String

        var windowID: CGWindowID { window.windowID }
    }

    /// One focused window per desktop of each display
    @Published private(set) var focusedWindows: [CGWindowID: FocusedWindow] = [:]

    var isInFocusMode: Bool { !focusedWindows.isEmpty }

    /// The current desktop of a display
    var spaceIDForScreen: ((NSScreen) -> String)?

    /// A floating window can't go into focus mode
    var isWindowFloating: ((CGWindowID) -> Bool)?

    /// Called when a window enters Focus Mode (windowID, AppKit targetFrame, screen).
    var onWindowExpanded: ((CGWindowID, CGRect, NSScreen) -> Void)?
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let screenManager: ScreenManager
    private let windowManager: WindowManager
    
    // MARK: - Stored Window State

    /// Focused windows that were closed, minimized or went full screen, kept until they come back
    private var pendingReturns: [CGWindowID: FocusedWindow] = [:]
    
    // MARK: - Hotkey
    
    private var hotkeyID: EventHotKeyID?
    private var hotkeyRef: EventHotKeyRef?
    private static var sharedInstance: FocusModeService?
    
    // MARK: - Double-tap Detection
    
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var lastClickTime: Date?
    private var lastClickWindowID: CGWindowID?
    private var mouseDownPosition: CGPoint?
    private let doubleTapInterval: TimeInterval = 0.3
    private let maxDragDistance: CGFloat = 10 // If mouse moves more than this, it's a drag
    
    var doubleTapEnabled: Bool = true
    
    var doubleTapModifier: FocusModeModifierKey = .option
    
    /// Custom zone for focus mode, normalized 0-1 within the visible frame (AppKit, origin bottom-left).
    /// If nil, uses the whole visible frame
    var customZone: CGRect? = nil
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, screenManager: ScreenManager, windowManager: WindowManager) {
        self.accessibilityService = accessibilityService
        self.screenManager = screenManager
        self.windowManager = windowManager
        FocusModeService.sharedInstance = self
    }
    
    // MARK: - Public Methods
    
    func start() {
        guard !isActive else { return }
        
        logger.info("Starting FocusModeService")
        setupDoubleTapMonitor()
        isActive = true
    }
    
    /// Restores every focused window and removes the monitors and hotkey
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping FocusModeService")
        removeDoubleTapMonitor()
        unregisterHotkey()
        
        for focused in focusedWindows.values {
            restoreWindow(focused)
        }
        pendingReturns = [:]
        
        isActive = false
    }
    
    /// Toggle focus mode on the frontmost window's desktop: return its focused window, or focus the frontmost one
    func toggleFocusMode() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("No frontmost application")
            return
        }
        guard let frontWindow = windowManager.enumerateWindows().first(where: { $0.ownerPID == frontApp.processIdentifier }) else {
            logger.warning("No window found for frontmost app")
            return
        }
        let screen = screenManager.screen(for: frontWindow)
        if let focused = focusedWindow(on: screen) {
            restoreWindow(focused)
        } else if isWindowFloating?(frontWindow.windowID) == true {
            debugLog("FocusModeService", "Window \(frontWindow.windowID) is floating, not putting it in focus mode")
        } else {
            expand(frontWindow, on: screen)
        }
    }

    func isDoubleTapModifierHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        isActive && doubleTapEnabled && doubleTapModifier.matches(flags)
    }
    
    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
            hotkeyID = nil
            logger.debug("Focus mode hotkey unregistered")
        }
    }
    
    // MARK: - Focus Mode Logic
    
    private func desktop(of screen: NSScreen) -> (screenID: String, spaceID: String) {
        (screenManager.identifier(for: screen), spaceIDForScreen?(screen) ?? "")
    }

    private func focusedWindow(on screen: NSScreen) -> FocusedWindow? {
        let (screenID, spaceID) = desktop(of: screen)
        return focusedWindows.values.first { $0.screenID == screenID && $0.spaceID == spaceID }
    }

    private func isOnCurrentDesktop(_ focused: FocusedWindow) -> Bool {
        guard let screen = screenManager.screen(for: focused.screenID) else { return false }
        return spaceIDForScreen?(screen) == focused.spaceID
    }

    func screensShowingFocusedWindow() -> Set<String> {
        Set(focusedWindows.values.filter(isOnCurrentDesktop).map(\.screenID))
    }

    private func expand(_ window: WindowInfo, on screen: NSScreen) {
        pendingReturns.removeValue(forKey: window.windowID)
        
        let screenFrame = screenManager.visibleFrame(for: screen)
        let targetFrame: CGRect
        
        if let zone = customZone {
            targetFrame = CGRect(
                x: screenFrame.origin.x + zone.origin.x * screenFrame.width,
                y: screenFrame.origin.y + zone.origin.y * screenFrame.height,
                width: zone.width * screenFrame.width,
                height: zone.height * screenFrame.height
            )
            logger.debug("Using custom focus zone: \(String(describing: zone)) -> \(String(describing: targetFrame))")
        } else {
            targetFrame = screenFrame
        }
        
        let cgFrame = screenManager.convertToCGCoordinates(frame: targetFrame)
        
        let posSuccess = accessibilityService.setWindowPosition(window, position: cgFrame.origin)
        let sizeSuccess = accessibilityService.setWindowSize(window, size: cgFrame.size)
        
        if posSuccess && sizeSuccess {
            let (screenID, spaceID) = desktop(of: screen)
            focusedWindows[window.windowID] = FocusedWindow(window: window, slotFrame: window.frame,
                                                            focusFrame: cgFrame, screenID: screenID, spaceID: spaceID)
            debugLog("FocusModeService", "Window \(window.windowID) is in focus mode on \(screenID), desktop \(spaceID)")
            onWindowExpanded?(window.windowID, targetFrame, screen)
        } else {
            logger.error("Failed to expand window to focus mode")
        }
    }
    
    /// Leaves focus mode when its window was closed. Returns whether it did.
    @discardableResult
    func endIfFocusedWindowClosed() -> Bool {
        let closed = focusedWindows.values.filter { !windowManager.windowExists($0.windowID) }
        for focused in closed {
            debugLog("FocusModeService", "Focused window \(focused.windowID) was closed, leaving focus mode")
            leaveUntilWindowReturns(focused)
        }
        return !closed.isEmpty
    }

    /// Leaves focus mode when its window was minimized (missing from the visible windows of the desktop it is on)
    /// or went full screen.
    func endIfFocusedWindowHidden(visibleWindowIDs: Set<CGWindowID>) {
        for focused in focusedWindows.values {
            if isOnCurrentDesktop(focused) && !visibleWindowIDs.contains(focused.windowID) {
                debugLog("FocusModeService", "Focused window \(focused.windowID) was minimized, leaving focus mode")
                leaveUntilWindowReturns(focused)
            } else if accessibilityService.isWindowFullScreen(focused.window) {
                debugLog("FocusModeService", "Focused window \(focused.windowID) went full screen, leaving focus mode")
                leaveUntilWindowReturns(focused)
            }
        }
    }

    /// Some apps report a minimized or full screen window as closed, so all cases keep its slot frame for when it comes back.
    private func leaveUntilWindowReturns(_ focused: FocusedWindow) {
        focusedWindows.removeValue(forKey: focused.windowID)
        pendingReturns[focused.windowID] = focused
    }

    /// A window that left focus mode comes back from the Dock or from full screen at the focus frame;
    /// put it back in its slot.
    func returnPendingWindows() {
        guard !pendingReturns.isEmpty else { return }
        for window in windowManager.enumerateWindows() {
            guard let focused = pendingReturns[window.windowID],
                  !accessibilityService.isWindowFullScreen(window) else { continue }
            pendingReturns.removeValue(forKey: window.windowID)
            debugLog("FocusModeService", "Window \(window.windowID) is back, returning it to its slot \(focused.slotFrame)")
            accessibilityService.setWindowPosition(window, position: focused.slotFrame.origin)
            accessibilityService.setWindowSize(window, size: focused.slotFrame.size)
        }
    }

    /// Leaves focus mode without moving the window, when something else takes over its frame (floating, an Auto Tiling layout change).
    func forgetWindow(_ windowID: CGWindowID) {
        guard isFocusedWindow(windowID) else { return }
        debugLog("FocusModeService", "Window \(windowID) leaves focus mode, its frame is set elsewhere")
        focusedWindows.removeValue(forKey: windowID)
    }

    /// The focused window can't be moved, swapped or resized with its neighbours.
    func isFocusedWindow(_ windowID: CGWindowID) -> Bool {
        focusedWindows[windowID] != nil
    }

    /// Puts a dragged focused window back where focus mode placed it.
    func putBackFocusedWindow(_ window: WindowInfo) {
        guard let focusFrame = focusedWindows[window.windowID]?.focusFrame else { return }
        // Auto Tiling calls this on every mouse up; size is not compared because of windows with a minimum size
        let offset = hypot(window.frame.origin.x - focusFrame.origin.x, window.frame.origin.y - focusFrame.origin.y)
        guard offset > 4 else { return }
        debugLog("FocusModeService", "Focused window \(window.windowID) was moved, putting it back to \(focusFrame)")
        accessibilityService.setWindowPosition(window, position: focusFrame.origin)
        accessibilityService.setWindowSize(window, size: focusFrame.size)
    }

    private func restoreWindow(_ focused: FocusedWindow) {
        // Cleared first so rapid toggles don't restore twice
        focusedWindows.removeValue(forKey: focused.windowID)
        let frameToRestore = focused.slotFrame
        
        guard let window = windowManager.enumerateWindows().first(where: { $0.windowID == focused.windowID }) else {
            logger.warning("Original window no longer exists")
            return
        }
        
        // The window is raised first; the frame is set a moment later, once the raise has taken effect
        accessibilityService.raiseWindow(window)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            
            let posSuccess = self?.accessibilityService.setWindowPosition(window, position: frameToRestore.origin) ?? false
            let sizeSuccess = self?.accessibilityService.setWindowSize(window, size: frameToRestore.size) ?? false
            
            if posSuccess && sizeSuccess {
                logger.info("Restored '\(window.title)' from focus mode")
            } else {
                logger.warning("Failed to fully restore window")
            }
        }
    }
    
    // MARK: - Double-tap Detection
    
    private func setupDoubleTapMonitor() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseDown(event)
            }
        }
        
        // The double-tap is detected on mouse up, so a drag can be told apart
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseUp(event)
            }
        }
        logger.debug("Double-tap monitor set up")
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
        logger.debug("Double-tap monitor removed")
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
        // the user pressed it during a drag, not for double-tap
        guard let downPos = mouseDownPosition else {
            lastClickTime = nil
            lastClickWindowID = nil
            return
        }
        
        let currentPos = NSEvent.mouseLocation
        let distance = hypot(currentPos.x - downPos.x, currentPos.y - downPos.y)
        if distance > maxDragDistance {
            logger.debug("Ignoring \(self.doubleTapModifier.displayName)+click - was a drag (distance: \(distance)px)")
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
            logger.debug("\(self.doubleTapModifier.displayName)+Double-tap detected on window '\(windowUnderCursor.title)', isInFocusMode=\(self.isInFocusMode)")
            
            let screen = screenManager.screen(for: windowUnderCursor)
            if let focused = focusedWindows[windowUnderCursor.windowID] {
                restoreWindow(focused)
            } else if focusedWindow(on: screen) == nil, isWindowFloating?(windowUnderCursor.windowID) != true {
                // Raised first so it is frontmost when it expands
                accessibilityService.raiseWindow(windowUnderCursor)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.expand(windowUnderCursor, on: screen)
                }
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
        // Window frames are relative to the top of the primary display
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        
        for window in windows {
            let windowFrameAppKit = CGRect(
                x: window.frame.origin.x,
                y: screenHeight - window.frame.origin.y - window.frame.height,
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
