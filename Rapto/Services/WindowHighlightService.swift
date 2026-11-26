//
//  WindowHighlightService.swift
//  Rapto
//
//  Service for highlighting the active/focused window with a colored border.
//

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "WindowHighlightService")

@_silgen_name("_AXUIElementGetWindow")
private func HighlightAXGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
class WindowHighlightService: ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isActive: Bool = false
    
    /// When true, mouse events are ignored (e.g., during overlay mode)
    var suppressMouseEvents: Bool = false
    
    /// Not @Published to avoid the "Publishing changes from within view updates" warning
    var borderColor: NSColor = .systemBlue.withAlphaComponent(0.6)
    
    /// Not @Published to avoid the "Publishing changes from within view updates" warning
    var borderWidth: CGFloat = 2
    
    private let windowManager: WindowManager
    private let accessibilityService: AccessibilityService
    
    private var highlightWindow: NSWindow?
    private var highlightView: HighlightBorderView?
    
    // MARK: - Observers
    
    private var focusObserver: Any?
    private var windowObservers: [Any] = []
    
    /// AXObserver for window move/resize events (event-driven, no polling)
    private var axObserver: AXObserver?
    private var observedWindowElement: AXUIElement?
    /// Window ID of `observedWindowElement` (the app's focused window), which may differ from the highlighted one
    private var observedWindowID: CGWindowID?
    /// App whose focus and minimize events are observed. Stays set while the highlight is hidden,
    /// so restoring a minimized window can bring the highlight back
    private var observedPID: pid_t = 0
    
    /// Windows that were just minimized, with the time. They stay in the on-screen window list
    /// until the minimize animation ends, so they must be skipped explicitly for that long
    private var recentlyMinimized: [CGWindowID: Date] = [:]
    private static let minimizeAnimationAllowance: TimeInterval = 1.5
    
    /// Windows that were just closed, with the time. The window list can still show a closed window
    /// for a moment (Dia), and the border would come back around it and stay there
    private var recentlyClosed: [CGWindowID: Date] = [:]
    
    private var currentHighlightedWindowID: CGWindowID?
    
    private var currentHighlightedPID: pid_t = 0
    
    /// Currently highlighted app's bundle identifier (for adaptive corner radius)
    private var currentBundleIdentifier: String?
    
    private var lastKnownFrame: CGRect = .zero
    
    /// Mouse drag monitor for real-time resize tracking (only active during drag)
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var minimizeKeyMonitor: Any?
    
    private var isDragging: Bool = false
    
    /// Where the current drag started, whether it has moved the highlighted window,
    /// and whether drag events still need to poll the window position
    private var dragStartLocation: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragMovedWindow = false
    private var dragPollingActive = false
    
    /// The border is hidden while the highlighted window is resized: the window list lags behind
    /// a live resize, so the border would trail the window's edge
    private var hiddenForResize = false

    /// One log line per resize about what tried to show the border
    private var loggedUpdateDuringResize = false

    /// Nested count of active batch layout transitions; while > 0 (or during the brief post-move settle)
    /// the border stays hidden so it never flashes or chases intermediate window positions.
    private var layoutTransitionDepth: Int = 0
    private var layoutTransitionRestoreTask: Task<Void, Never>?
    private var fadeInNextShow: Bool = false

    private var isInLayoutTransition: Bool {
        layoutTransitionDepth > 0 || layoutTransitionRestoreTask != nil
    }

    /// Fade-in duration for the highlight border after a batch layout transition.
    nonisolated static func fadeInDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.08 : 0.14
    }
    
    /// Pending verification task (one-shot, not polling)
    /// Used to verify window still exists after suspicious events
    private var pendingVerificationTask: Task<Void, Never>?
    
    private var activationFollowUpTask: Task<Void, Never>?
    
    // MARK: - Corner Shapes
    
    /// Measured corner shapes per window, with the window size they were measured at
    private var cornerShapes: [CGWindowID: (shape: WindowCornerShape, size: CGSize)] = [:]
    
    /// Last measured shape per app, used for new windows until they are measured
    private var cornerShapesByBundle: [String: WindowCornerShape] = [:]
    
    /// Windows whose corners couldn't be read, with the size they were tried at
    private var unreadableCornerWindows: [CGWindowID: CGSize] = [:]
    
    private var cornerProbeTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(windowManager: WindowManager, accessibilityService: AccessibilityService) {
        self.windowManager = windowManager
        self.accessibilityService = accessibilityService
    }
    
    // MARK: - Public Methods

    /// Re-evaluates the active-window border immediately (e.g. after ignoring or un-ignoring an app).
    func refresh() {
        guard isActive else { return }
        updateHighlight()
    }

    /// Temporarily hides the active-window border while Rapto repositions multiple windows in a batch.
    func beginLayoutTransition() {
        layoutTransitionDepth += 1
        layoutTransitionRestoreTask?.cancel()
        layoutTransitionRestoreTask = nil
        if layoutTransitionDepth == 1 {
            highlightWindow?.orderOut(nil)
        }
    }

    /// Ends a batch layout transition and gently fades the border back in once frames settle.
    func endLayoutTransition() {
        guard layoutTransitionDepth > 0 else { return }
        layoutTransitionDepth -= 1
        guard layoutTransitionDepth == 0 else { return }
        layoutTransitionRestoreTask?.cancel()
        layoutTransitionRestoreTask = Task { @MainActor [weak self] in
            // Let WindowServer commit the batch move before placing the border
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let self else { return }
            self.layoutTransitionRestoreTask = nil
            guard self.isActive, self.layoutTransitionDepth == 0 else { return }
            self.fadeInNextShow = true
            self.updateHighlight()
            self.fadeInNextShow = false
        }
    }
    
    func start() {
        guard !isActive else {
            logger.debug("WindowHighlightService already active, updating highlight")
            updateHighlight()
            return
        }
        
        logger.info("Starting WindowHighlightService")
        
        setupFocusObserver()
        isActive = true
        
        // Initial highlight with slight delay for Space transition to complete
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
            self?.updateHighlight()
        }
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping WindowHighlightService")
        
        removeFocusObserver()
        stopObservingWindowEvents()
        stopMouseDragTracking()
        cancelPendingVerification()
        activationFollowUpTask?.cancel()
        layoutTransitionRestoreTask?.cancel()
        layoutTransitionRestoreTask = nil
        layoutTransitionDepth = 0
        fadeInNextShow = false
        
        // Destroy highlight window completely (it stays on old Space otherwise)
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        highlightView = nil
        currentHighlightedWindowID = nil
        currentHighlightedPID = 0
        
        isActive = false
    }
    
    /// Rapto saw windows open or close. Catches windows closed without any notification and
    /// without a click or key we watch, like quitting Dia from the Dock.
    func windowsChanged() {
        guard isActive else { return }
        if currentHighlightedWindowID == nil {
            // An app's first window can open seconds after the app became active (Dia on launch)
            updateHighlight()
        } else {
            verifyWindowStillExists()
        }
    }
    
    func setColor(_ color: NSColor) {
        borderColor = color
        updateHighlightAppearance()
    }
    
    func setBorderWidth(_ width: CGFloat) {
        borderWidth = width
        updateHighlightAppearance()
    }
    
    /// Recreate highlight window for new Space (since windows are stationary)
    func recreateForNewSpace() {
        guard isActive else { return }
        
        stopObservingWindowEvents()
        stopMouseDragTracking()
        
        // Destroy old window (stays on old Space, invisible)
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        highlightView = nil
        currentHighlightedWindowID = nil
        currentHighlightedPID = 0
        
        updateHighlight()
    }
    
    // MARK: - Focus Observer
    
    private func setupFocusObserver() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateHighlight()
                // Restoring a minimized window from the Dock activates its app before the window
                // is back on screen, and its deminimize event arrives before we observe that app
                self.activationFollowUpTask?.cancel()
                self.activationFollowUpTask = Task { @MainActor [weak self] in
                    for delay: UInt64 in [300_000_000, 500_000_000] {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled, let self, self.isActive else { return }
                        self.updateHighlight()
                    }
                }
            }
        }
        
        // Window move/resize/destroy events come from an AXObserver, set up in
        // startObservingWindowEvents() when a window becomes active, so nothing polls while idle.
        // One-shot delayed checks (scheduleVerification) catch cases where AX notifications don't fire.
        //
        // NSWindow.didMiniaturizeNotification only fires for this app's own windows. Other apps'
        // minimizes come from kAXWindowMiniaturizedNotification and the minimize click/Cmd+M monitors.
        
        let hideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateHighlight()
            }
        }
        windowObservers.append(hideObserver)
        
        // Observe when ANY app loses focus (deactivates)
        // This catches when user clicks on Desktop, Finder, etc.
        let deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let deactivatedPID = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                if deactivatedPID == self.currentHighlightedPID {
                    // The highlight should update via didActivateApplication, but schedule
                    // a verification as a safety net
                    self.scheduleVerification(delay: 0.2)
                }
            }
        }
        windowObservers.append(deactivateObserver)
        
        let terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let terminatedPID = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                if terminatedPID == self.currentHighlightedPID {
                    self.updateHighlight()
                }
            }
        }
        windowObservers.append(terminateObserver)
        
        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                // First update after 1 second to let screen coordinates stabilize
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
                guard self?.isActive == true else { return }
                self?.recreateForNewSpace()
                
                // Second update after 2 more seconds in case windows took longer to settle
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 sec
                guard self?.isActive == true else { return }
                self?.updateHighlight()
            }
        }
        windowObservers.append(wakeObserver)
        
        let screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                // Delay to let screen coordinates stabilize
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
                guard self?.isActive == true else { return }
                self?.recreateForNewSpace()
            }
        }
        windowObservers.append(screenChangeObserver)
        
        let spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self = self, self.isActive else { return }
                self.recreateForNewSpace()
            }
        }
        windowObservers.append(spaceChangeObserver)
        
        // The border window is .stationary, so Mission Control would show it over the thumbnails
        let missionControlOpenObserver = NotificationCenter.default.addObserver(
            forName: .missionControlDidOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.activationFollowUpTask?.cancel()
                self.hideHighlight()
            }
        }
        windowObservers.append(missionControlOpenObserver)
        
        let missionControlCloseObserver = NotificationCenter.default.addObserver(
            forName: .missionControlDidClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                // Windows fly back from their thumbnails for a moment after Mission Control closes
                self.activationFollowUpTask?.cancel()
                self.activationFollowUpTask = Task { @MainActor [weak self] in
                    for delay: UInt64 in [350_000_000, 450_000_000] {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled, let self, self.isActive else { return }
                        self.updateHighlight()
                    }
                }
            }
        }
        windowObservers.append(missionControlCloseObserver)

        let spaceBarMoveEndObserver = NotificationCenter.default.addObserver(
            forName: .spaceBarMoveDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.updateHighlight()
            }
        }
        windowObservers.append(spaceBarMoveEndObserver)
    }
    
    private func removeFocusObserver() {
        if let observer = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            focusObserver = nil
        }
        
        stopObservingWindowEvents()
        stopMouseDragTracking()
        cancelPendingVerification()
        
        // The list mixes observers of both centers
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
    
    // MARK: - Mouse Drag Tracking for Real-Time Resize
    
    private func startMouseDragTracking() {
        guard mouseDragMonitor == nil else { return }
        
        // Monitor for left mouse down to detect start of drag
        // We use global monitors to track even when other apps are active
        // Use DispatchQueue.main.async for lowest latency (faster than Task)
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentHighlightedPID != 0 else { return }
                
                // Skip event handling when overlay is visible (to prevent accidental window dragging)
                if self.suppressMouseEvents { return }
                
                if event.type == .leftMouseDown {
                    if self.isOverMinimizeButton(NSEvent.mouseLocation) {
                        self.hideForMinimize()
                        return
                    }
                    if self.isOverCloseButton(NSEvent.mouseLocation) {
                        self.hideForClose()
                        return
                    }
                    self.isDragging = true
                    self.dragStartLocation = NSEvent.mouseLocation
                    self.dragStartFrame = self.lastKnownFrame
                    self.dragMovedWindow = false
                    self.dragPollingActive = true
                } else if event.type == .leftMouseDragged && self.isDragging && self.dragPollingActive {
                    guard !self.hiddenForResize else { return }
                    if let windowID = self.currentHighlightedWindowID,
                       let frame = self.windowManager.frame(of: windowID),
                       frame.size != self.dragStartFrame.size {
                        self.hiddenForResize = true
                        self.dragMovedWindow = true
                        self.highlightWindow?.orderOut(nil)
                        return
                    }
                    self.updateHighlightPositionFromAX()
                    if self.lastKnownFrame != self.dragStartFrame {
                        self.dragMovedWindow = true
                    } else if !self.dragMovedWindow,
                              WindowManager.pointerMovedPastGiveUpDistance(from: self.dragStartLocation) {
                        // Not a window drag; AX move/resize notifications still cover the rest
                        self.dragPollingActive = false
                    }
                }
            }
        }
        
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // Skip event handling when overlay is visible (to prevent accidental window dragging)
                if self.suppressMouseEvents { return }
                
                let wasDragging = self.isDragging
                self.isDragging = false
                
                if wasDragging && self.hiddenForResize {
                    self.showAfterResize()
                } else if wasDragging {
                    self.updateHighlightPositionFromAX()
                    if let windowID = self.currentHighlightedWindowID, self.lastKnownFrame != .zero {
                        self.refreshCornerShapeIfNeeded(for: WindowInfo(
                            windowID: windowID,
                            ownerPID: self.currentHighlightedPID,
                            title: "",
                            ownerName: "",
                            frame: self.lastKnownFrame
                        ))
                    }
                }
                
                // Verify after mouse up to catch same-app window switches, for when
                // kAXFocusedWindowChangedNotification doesn't fire. The delays let window focus settle first.
                self.scheduleVerification(delays: Self.closeCheckDelays)
                self.watchForClose()
            }
        }
        
        minimizeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased(), ["m", "w", "q"].contains(key) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentHighlightedPID != 0, !self.suppressMouseEvents else { return }
                if key == "m" {
                    self.hideForMinimize()
                } else {
                    self.scheduleVerification(delays: Self.closeCheckDelays)
                    self.watchForClose()
                }
            }
        }
    }
    
    // MARK: - Workaround: Minimize Detection
    // Problem: On macOS 27, minimizing doesn't post kAXWindowMiniaturizedNotification for some apps
    //          (Cursor), and for ~0.5 s the app doesn't answer AX requests, so every check made after
    //          the click is late and the border lingers over the minimize animation.
    // Solution: Hide on the minimize click or Cmd+M itself, before the animation starts. If the window
    //           doesn't actually minimize, the follow-up update brings the border back.
    
    /// Whether the point (AppKit coordinates) is over the minimize button of the highlighted window
    private func isOverMinimizeButton(_ location: CGPoint) -> Bool {
        guard lastKnownFrame != .zero, let primaryScreen = NSScreen.screens.first else { return false }
        let point = CGPoint(x: location.x, y: primaryScreen.frame.height - location.y)
        // Traffic lights sit in the top-left corner; skip the AX hit test for every other click
        let buttonArea = CGRect(x: lastKnownFrame.minX, y: lastKnownFrame.minY, width: 120, height: 60)
        guard buttonArea.contains(point) else { return false }
        
        // A timeout set on the system-wide element would apply to every AX call Rapto makes
        guard currentHighlightedPID != 0, AppResponsiveness.isResponding(currentHighlightedPID) else { return false }
        let app = AXUIElementCreateApplication(currentHighlightedPID)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return (subroleRef as? String) == kAXMinimizeButtonSubrole as String
    }
    
    private func hideForMinimize() {
        guard let windowID = currentHighlightedWindowID else { return }
        logger.debug("Minimize started for window \(windowID), hiding highlight")
        recentlyMinimized[windowID] = Date()
        hideHighlight(keepObservingApp: true)
        // Move to another window once the animation is over, and bring the border back
        // if the window didn't minimize after all (click released off the button)
        activationFollowUpTask?.cancel()
        activationFollowUpTask = Task { @MainActor [weak self] in
            for delay: UInt64 in [600_000_000, 1_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.updateHighlight()
            }
        }
    }
    
    /// Called when the resize service sees a slot being resized. The drag check above reads the window
    /// list, which lags behind a quick drag, and could leave the border on for the whole resize.
    func hideForResize() {
        guard isDragging, !hiddenForResize, currentHighlightedWindowID != nil,
              NSEvent.pressedMouseButtons & 1 == 1 else { return }
        hiddenForResize = true
        dragMovedWindow = true
        highlightWindow?.orderOut(nil)
    }

    /// Bring the border back at the window's final frame. Accessibility reports it at once, the window list may still lag
    private func showAfterResize() {
        hiddenForResize = false
        guard let windowID = currentHighlightedWindowID,
              let frame = getWindowFrameViaAX(pid: currentHighlightedPID) ?? windowManager.frame(of: windowID) else { return }
        lastKnownFrame = frame
        updateHighlightPosition(for: WindowInfo(
            windowID: windowID,
            ownerPID: currentHighlightedPID,
            title: "",
            ownerName: "",
            frame: frame
        ))
        highlightWindow?.alphaValue = 1
        highlightWindow?.orderFront(nil)
    }
    
    /// Removes the mouse and key monitors
    private func stopMouseDragTracking() {
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        if let monitor = minimizeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            minimizeKeyMonitor = nil
        }
        isDragging = false
    }
    
    // MARK: - One-Shot Window Verification (No Polling!)
    
    /// A single delayed check triggered by an event, not polling
    private func scheduleVerification(delay: TimeInterval = 0.3) {
        scheduleVerification(delays: [delay])
    }
    
    /// Several checks, each delay counted from now
    private func scheduleVerification(delays: [TimeInterval]) {
        pendingVerificationTask?.cancel()
        
        pendingVerificationTask = Task { @MainActor [weak self] in
            var elapsed: TimeInterval = 0
            for delay in delays.sorted() {
                do {
                    try await Task.sleep(nanoseconds: UInt64((delay - elapsed) * 1_000_000_000))
                } catch {
                    return // Task was cancelled - that's fine
                }
                elapsed = delay
                guard let self, self.currentHighlightedWindowID != nil else { return }
                self.verifyWindowStillExists()
            }
        }
    }
    
    // MARK: - Workaround: Windows Closed Without a Notification
    // Problem: Some apps (Ardia/Dia) close a window without posting kAXUIElementDestroyedNotification,
    //          and the window stays in the window list for ~0.5 s after the click or Cmd+W,
    //          so a single early check still finds it and the border is left on screen.
    // Solution: Check again a few times while a close animation could still be running.
    //           The window's accessibility element dies (or the window leaves the screen) right away,
    //           so both are checked every 0.1 s for 2 s after a click or Cmd+W/Cmd+Q.
    private static let closeCheckDelays: [TimeInterval] = [0.15, 0.6, 1.2]
    
    private var closeWatchTask: Task<Void, Never>?
    
    /// Close button of the highlighted window (CG coordinates), read again when the window frame changes
    private var closeButtonCache: (windowFrame: CGRect, button: CGRect?)?
    
    /// Whether the point (AppKit coordinates) is over the close button of the highlighted window.
    /// Some apps (Ardia) don't put it in the top-left corner.
    private func isOverCloseButton(_ location: CGPoint) -> Bool {
        guard lastKnownFrame != .zero, let element = observedWindowElement,
              let primaryScreen = NSScreen.screens.first else { return false }
        let point = CGPoint(x: location.x, y: primaryScreen.frame.height - location.y)
        guard lastKnownFrame.contains(point) else { return false }
        if closeButtonCache?.windowFrame != lastKnownFrame {
            closeButtonCache = (lastKnownFrame, closeButtonFrame(of: element))
            debugLog("WindowHighlight", "Close button of window \(currentHighlightedWindowID ?? 0): \(closeButtonCache?.button.map { "\($0)" } ?? "none")")
        }
        return closeButtonCache?.button?.insetBy(dx: -2, dy: -2).contains(point) ?? false
    }
    
    private func closeButtonFrame(of window: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(window, 0.1)
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let buttonRef, CFGetTypeID(buttonRef) == AXUIElementGetTypeID() else { return nil }
        let button = buttonRef as! AXUIElement
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        var position = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
    
    /// Hide on the close click itself, so the border goes away together with the window
    private func hideForClose() {
        guard let windowID = currentHighlightedWindowID else { return }
        debugLog("WindowHighlight", "Close button pressed on window \(windowID), hiding highlight")
        recentlyClosed[windowID] = Date()
        hideHighlight(keepObservingApp: true)
        // Move to another window of the app, and bring the border back if the click was released off the button
        activationFollowUpTask?.cancel()
        activationFollowUpTask = Task { @MainActor [weak self] in
            for delay: UInt64 in [400_000_000, 1_300_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, self.isActive else { return }
                self.updateHighlight()
            }
        }
    }
    
    private func watchForClose() {
        closeWatchTask?.cancel()
        guard let element = observedWindowElement, let windowID = currentHighlightedWindowID else { return }
        closeWatchTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, self.currentHighlightedWindowID == windowID else { return }
                AXUIElementSetMessagingTimeout(element, 0.1)
                var roleRef: CFTypeRef?
                // On Quit from the Dock, Dia takes its window off screen while the element stays valid
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .invalidUIElement
                    || !Self.isOnScreen(windowID) {
                    debugLog("WindowHighlight", "Window \(windowID) closed without a notification, updating highlight")
                    self.highlightedWindowClosed()
                    return
                }
            }
        }
    }
    
    private static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let window = info.first else { return false }
        return window[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
    
    /// The window list can still show the closed window for a moment, so it is skipped for a while
    private func highlightedWindowClosed() {
        if let windowID = currentHighlightedWindowID {
            recentlyClosed[windowID] = Date()
        }
        updateHighlight()
        // If the window wasn't actually closed, bring the border back once it's no longer skipped
        activationFollowUpTask?.cancel()
        activationFollowUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.minimizeAnimationAllowance + 0.1) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.updateHighlight()
        }
    }
    
    private func cancelPendingVerification() {
        pendingVerificationTask?.cancel()
        pendingVerificationTask = nil
    }
    
    /// Verify that the currently highlighted window still exists and is still focused
    /// Called once after suspicious events (including mouse clicks), not continuously
    private func verifyWindowStillExists() {
        guard !isInLayoutTransition,
              let windowID = currentHighlightedWindowID, currentHighlightedPID != 0 else {
            return
        }
        
        guard let runningApp = NSRunningApplication(processIdentifier: currentHighlightedPID),
              !runningApp.isTerminated else {
            logger.debug("Verify: app terminated, updating highlight")
            updateHighlight()
            return
        }
        
        if runningApp.isHidden {
            logger.debug("Verify: app hidden, hiding highlight")
            hideHighlight()
            return
        }
        
        let windows = windowManager.enumerateWindows()
        let windowStillExists = windows.contains { $0.windowID == windowID && $0.frame.width > 0 && $0.frame.height > 0 }
        
        if !windowStillExists {
            logger.debug("Verify: window \(windowID) no longer exists, updating")
            updateHighlight()
            return
        }
        
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier == currentHighlightedPID else {
            logger.debug("Verify: app no longer frontmost, updating")
            updateHighlight()
            return
        }
        
        // Check if the focused window within the same app has changed.
        // This catches same-app window switches that kAXFocusedWindowChangedNotification missed
        if let focusedPos = accessibilityService.getFocusedWindowPosition(for: currentHighlightedPID) {
            let appWindows = windows.filter { $0.ownerPID == currentHighlightedPID }
            let tolerance: CGFloat = 50
            
            if let focusedWindow = appWindows.first(where: {
                abs($0.frame.origin.x - focusedPos.x) < tolerance &&
                abs($0.frame.origin.y - focusedPos.y) < tolerance
            }) {
                if focusedWindow.windowID != windowID {
                    logger.debug("Verify: focused window changed within app (\(windowID) -> \(focusedWindow.windowID)), updating")
                    updateHighlight()
                }
            }
        }
    }
    
    /// Update highlight position during drag
    /// Uses CGWindowListCopyWindowInfo (via windowManager) for real-time position during drag,
    /// as Accessibility API can lag behind actual window position
    /// Returns true if the window moved or resized since the last update
    @discardableResult
    private func updateHighlightPositionFromAX() -> Bool {
        guard let windowID = currentHighlightedWindowID,
              let frame = windowManager.frame(of: windowID) else { return false }
        
        // Most drags (selecting text, dragging files) don't move the highlighted window
        guard frame != lastKnownFrame else { return false }
        
        lastKnownFrame = frame
        updateHighlightPosition(for: WindowInfo(
            windowID: windowID,
            ownerPID: currentHighlightedPID,
            title: "",
            ownerName: "",
            frame: frame
        ))
        return true
    }
    
    // MARK: - AXObserver for Window Events (Event-Driven, Zero CPU in Idle)
    
    /// Observe the app's focus, minimize, restore and window-created events, and move/resize/destroy of its focused window
    private func startObservingWindowEvents(pid: pid_t) {
        stopObservingWindowEvents()
        guard AppResponsiveness.isResponding(pid) else { return }
        
        let callback: AXObserverCallback = { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let service = Unmanaged<WindowHighlightService>.fromOpaque(refcon).takeUnretainedValue()
            
            Task { @MainActor in
                service.handleWindowEvent(element: element, notification: notification as String)
            }
        }
        
        var observer: AXObserver?
        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let axObserver = observer else {
            logger.warning("Failed to create AXObserver for PID \(pid): \(result.rawValue)")
            return
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        self.axObserver = axObserver
        self.observedPID = pid
        
        // Unretained, not weak: the callback assumes the service outlives the observer
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        // App-level events: window switching within the app, and minimize/restore of any of its windows.
        // A restored window isn't the focused one while minimized, so these can't be window-level.
        AppResponsiveness.shared.ask(pid) {
            AXObserverAddNotification(axObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        }
        // The observer stays, so that it is cleaned up like any other; the app tells nothing
        // until Rapto watches it again
        guard AppResponsiveness.isResponding(pid) else { return }
        AXObserverAddNotification(axObserver, appElement, kAXWindowMiniaturizedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXWindowDeminiaturizedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        
        // Observe the focused window, not the first one in the list, so switching between
        // windows of the same app follows the right one
        var focusedWindowRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        
        let focusedWindow: AXUIElement
        if focusResult == .success, let windowElement = focusedWindowRef {
            focusedWindow = (windowElement as! AXUIElement)
        } else {
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let firstWindow = windows.first else {
                logger.debug("No window element for PID \(pid), observing app events only")
                return
            }
            focusedWindow = firstWindow
        }
        
        self.observedWindowElement = focusedWindow
        var focusedWindowID: CGWindowID = 0
        observedWindowID = HighlightAXGetWindow(focusedWindow, &focusedWindowID) == .success && focusedWindowID != 0 ? focusedWindowID : nil
        
        AXObserverAddNotification(axObserver, focusedWindow, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, focusedWindow, kAXResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObserver, focusedWindow, kAXUIElementDestroyedNotification as CFString, refcon)
    }
    
    private func stopObservingWindowEvents() {
        guard let observer = axObserver else { return }
        
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        // Removing a notification asks the app too. One that is not answering is not asked:
        // the observer is released below either way
        let answers = observedPID == 0 || AppResponsiveness.isResponding(observedPID)
        
        if answers, let windowElement = observedWindowElement {
            AXObserverRemoveNotification(observer, windowElement, kAXMovedNotification as CFString)
            AXObserverRemoveNotification(observer, windowElement, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(observer, windowElement, kAXUIElementDestroyedNotification as CFString)
        }
        
        if answers, observedPID != 0 {
            let appElement = AXUIElementCreateApplication(observedPID)
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXWindowDeminiaturizedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
        }
        
        axObserver = nil
        observedWindowElement = nil
        observedWindowID = nil
        observedPID = 0
    }
    
    private func handleWindowEvent(element: AXUIElement, notification: String) {
        guard observedPID != 0, !isInLayoutTransition else { return }
        
        logger.debug("AX event: \(notification)")
        
        // Focus moved to another window of the same app. updateHighlight() calls
        // startObservingWindowEvents(), which observes the newly focused window
        if notification == kAXFocusedWindowChangedNotification as String {
            logger.debug("Focus changed within app, updating to new focused window")
            updateHighlight()
            return
        }
        
        if notification == kAXWindowMiniaturizedNotification as String {
            var windowID: CGWindowID = 0
            let known = HighlightAXGetWindow(element, &windowID) == .success && windowID != 0
            if known {
                recentlyMinimized[windowID] = Date()
            }
            if !known || windowID == currentHighlightedWindowID {
                logger.debug("Highlighted window minimized, hiding highlight")
                hideHighlight(keepObservingApp: true)
            }
            // Move to another window of the app, if any, once the minimize animation is over
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.updateHighlight()
            }
            return
        }
        
        if notification == kAXWindowDeminiaturizedNotification as String {
            var windowID: CGWindowID = 0
            if HighlightAXGetWindow(element, &windowID) == .success {
                recentlyMinimized[windowID] = nil
            } else {
                recentlyMinimized.removeAll()
            }
            logger.debug("Window restored from minimized, updating highlight")
            // Let the restore animation finish, then check again in case it ran long
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.updateHighlight()
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.updateHighlight()
            }
            return
        }
        
        if notification == kAXWindowCreatedNotification as String {
            // A new window usually takes focus, which is handled above; this covers an app
            // whose first window opens after it became active, with no border shown yet
            guard currentHighlightedWindowID == nil else { return }
            Task { @MainActor [weak self] in
                for delay: UInt64 in [100_000_000, 300_000_000] {
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self, self.isActive, self.currentHighlightedWindowID == nil else { return }
                    self.updateHighlight()
                }
            }
            return
        }
        
        guard currentHighlightedWindowID != nil else { return }
        
        if notification == kAXUIElementDestroyedNotification as String {
            // Also posted for elements inside the window (sheets, popovers): those leave the window open
            if let observed = observedWindowElement, !CFEqual(element, observed) {
                logger.debug("Element inside the observed window destroyed, keeping highlight")
                return
            }
            // The observed window is another window of the app than the highlighted one: that one is still open
            if let observedWindowID, observedWindowID != currentHighlightedWindowID {
                logger.debug("Observed window \(observedWindowID) destroyed, highlighted window stays")
                updateHighlight()
                return
            }
            logger.debug("Window destroyed, updating highlight")
            highlightedWindowClosed()
            // Schedule a follow-up verification in case updateHighlight doesn't find a new window
            scheduleVerification(delay: 0.3)
            return
        }
        
        guard let frame = getWindowFrameViaAX(pid: currentHighlightedPID) else {
            logger.debug("Could not get window frame, updating highlight")
            updateHighlight()
            return
        }
        
        guard frame != lastKnownFrame else { return }
        lastKnownFrame = frame
        let tempWindow = WindowInfo(
            windowID: currentHighlightedWindowID!,
            ownerPID: currentHighlightedPID,
            title: "",
            ownerName: "",
            frame: frame
        )
        updateHighlightPosition(for: tempWindow)
    }
    
    /// Get window frame via Accessibility API (cheaper than CGWindowList)
    /// Uses cached window element when available for better performance
    private func getWindowFrameViaAX(pid: pid_t) -> CGRect? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let windowElement: AXUIElement
        if let cached = observedWindowElement {
            windowElement = cached
        } else {
            let appElement = AXUIElementCreateApplication(pid)
            
            var windowsRef: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard windowResult == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let firstWindow = windows.first else {
                return nil
            }
            windowElement = firstWindow
        }
        
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }
        
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }

    /// Get the focused window frame via Accessibility API
    /// Useful after wake when CGWindowList may return stale bounds
    private func getFocusedWindowFrameViaAX(pid: pid_t, expectedWindowID: CGWindowID) -> CGRect? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let focusedWindowRef else {
            return nil
        }
        let focusedWindow = focusedWindowRef as! AXUIElement
        
        // During a minimize animation AX can still report the minimizing window as focused
        var focusedID: CGWindowID = 0
        if HighlightAXGetWindow(focusedWindow, &focusedID) == .success, focusedID != expectedWindowID {
            return nil
        }
        
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }
        
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }
    
    // MARK: - Highlight Management
    
    private func isDialogInFront(pid: pid_t) -> Bool {
        var focusedRef: CFTypeRef?
        guard AppResponsiveness.isResponding(pid),
              AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedWindow = focusedRef as! AXUIElement
        
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow"].contains(subrole) {
            return true
        }
        
        var sizeSettable: DarwinBoolean = true
        return AXUIElementIsAttributeSettable(focusedWindow, kAXSizeAttribute as CFString, &sizeSettable) == .success
            && !sizeSettable.boolValue
    }
    
    private func updateHighlight() {
        guard !isInLayoutTransition else { return }

        // Stand down while the Desktops Bar carries a window between Spaces so WindowClassifier
        // never blocks the main thread on an App-Napped app mid-move.
        if SpaceBarController.isDrivingMouse {
            hideHighlight()
            return
        }

        // The border is hidden while its window is resized and comes back on mouse up. A check that
        // runs in between (a timer, an AX call that timed out on the busy app) would show it again.
        if hiddenForResize, isDragging, NSEvent.pressedMouseButtons & 1 == 1 {
            if !loggedUpdateDuringResize {
                loggedUpdateDuringResize = true
                let caller = Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | ")
                debugLog("WindowHighlightService", "updateHighlight during a resize, border stays hidden. Called from: \(caller)")
            }
            return
        }
        loggedUpdateDuringResize = false

        // Mission Control shows windows as thumbnails, the border is restored once it closes
        if MissionControlWatcher.shared.isOpen {
            hideHighlight()
            return
        }
        
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.debug("updateHighlight: no frontmost app")
            hideHighlight()
            return
        }
        
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            logger.debug("updateHighlight: Rapto is frontmost, hiding")
            hideHighlight()
            return
        }
        
        let windows = windowManager.enumerateWindows()
        let now = Date()
        recentlyMinimized = recentlyMinimized.filter { now.timeIntervalSince($0.value) < Self.minimizeAnimationAllowance }
        recentlyClosed = recentlyClosed.filter { now.timeIntervalSince($0.value) < Self.minimizeAnimationAllowance }
        let appWindows = windows.filter { 
            $0.ownerPID == frontApp.processIdentifier && 
            $0.frame.width > 0 && 
            $0.frame.height > 0 &&
            recentlyMinimized[$0.windowID] == nil &&
            recentlyClosed[$0.windowID] == nil &&
            WindowClassifier.shared.isTilableForUI($0)
        }
        
        guard !appWindows.isEmpty else {
            logger.debug("updateHighlight: no window found for \(frontApp.localizedName ?? "unknown") (PID \(frontApp.processIdentifier)), windows: \(windows.count)")
            hideHighlight()
            // Keep listening to the app so restoring its minimized window brings the highlight back
            startObservingWindowEvents(pid: frontApp.processIdentifier)
            return
        }
        
        // With a dialog or a fixed-size settings window in front, the app's other windows are not active:
        // the border would sit on a window the user isn't using
        if isDialogInFront(pid: frontApp.processIdentifier) {
            logger.debug("updateHighlight: dialog in front of \(frontApp.localizedName ?? "unknown"), hiding")
            hideHighlight()
            startObservingWindowEvents(pid: frontApp.processIdentifier)
            return
        }
        
        // Ask AX for the focused window's position: in multi-window apps (Cursor) the
        // window list alone can pick the wrong window
        let focusedWindow: WindowInfo
        if appWindows.count == 1 {
            focusedWindow = appWindows[0]
        } else if let focusedPos = accessibilityService.getFocusedWindowPosition(for: frontApp.processIdentifier) {
            let tolerance: CGFloat = 50
            if let matched = appWindows.first(where: { 
                abs($0.frame.origin.x - focusedPos.x) < tolerance && 
                abs($0.frame.origin.y - focusedPos.y) < tolerance 
            }) {
                focusedWindow = matched
            } else {
                focusedWindow = appWindows[0]
            }
        } else {
            focusedWindow = appWindows[0]
        }
        
        logger.debug("updateHighlight: showing for '\(focusedWindow.title)'")
        
        currentHighlightedWindowID = focusedWindow.windowID
        currentHighlightedPID = focusedWindow.ownerPID
        currentBundleIdentifier = frontApp.bundleIdentifier
        
        // Prefer AX frame for accurate bounds (especially after wake)
        let highlightWindow: WindowInfo
        if let axFrame = getFocusedWindowFrameViaAX(pid: frontApp.processIdentifier, expectedWindowID: focusedWindow.windowID) {
            highlightWindow = WindowInfo(
                id: focusedWindow.id,
                windowID: focusedWindow.windowID,
                ownerPID: focusedWindow.ownerPID,
                title: focusedWindow.title,
                ownerName: focusedWindow.ownerName,
                bundleIdentifier: focusedWindow.bundleIdentifier,
                frame: axFrame,
                thumbnail: focusedWindow.thumbnail
            )
            lastKnownFrame = axFrame
        } else {
            highlightWindow = focusedWindow
            lastKnownFrame = focusedWindow.frame
        }
        
        showHighlight(for: highlightWindow, bundleIdentifier: frontApp.bundleIdentifier)
        
        startObservingWindowEvents(pid: focusedWindow.ownerPID)
        
        startMouseDragTracking()
        
        // Schedule a one-shot verification after 0.5s to catch edge cases
        // where the window closes immediately after being highlighted.
        // This is NOT polling - just a single delayed check.
        scheduleVerification(delay: 0.5)
    }
    
    private func showHighlight(for window: WindowInfo, bundleIdentifier: String?) {
        if highlightWindow == nil {
            createHighlightWindow()
        }
        
        if let cached = cornerShapes[window.windowID] {
            highlightView?.cornerShape = cached.shape
        } else {
            highlightView?.cornerShape = bundleIdentifier.flatMap { cornerShapesByBundle[$0] }
                ?? HighlightBorderView.fallbackShape(for: bundleIdentifier)
        }
        
        let shouldFadeIn = fadeInNextShow
        fadeInNextShow = false

        updateHighlightPosition(for: window, bundleIdentifier: bundleIdentifier)
        guard let highlightWindow else { return }
        if shouldFadeIn {
            let duration = Self.fadeInDuration(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            highlightWindow.alphaValue = 0
            highlightWindow.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                highlightWindow.animator().alphaValue = 1
            }
        } else {
            highlightWindow.alphaValue = 1
            highlightWindow.orderFront(nil)
        }
    }
    
    // MARK: - Corner Shape Measurement
    
    /// Measure the window's real corners unless a measurement for its current size exists.
    /// Corners can change with the size (for example, full screen has square corners),
    /// so a size change triggers a new measurement once the window settles.
    private func refreshCornerShapeIfNeeded(for window: WindowInfo) {
        // Measure once the mouse is released, not on every drag step
        guard !isDragging else { return }
        
        let windowID = window.windowID
        let size = window.frame.size
        
        if let cached = cornerShapes[windowID], cached.size.isClose(to: size) { return }
        if let triedSize = unreadableCornerWindows[windowID], triedSize.isClose(to: size) { return }
        
        cornerProbeTask?.cancel()
        let bundleIdentifier = currentBundleIdentifier
        
        cornerProbeTask = Task { @MainActor [weak self] in
            // Let open/resize animations finish so the capture shows the final shape
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, !self.isDragging else { return }
            
            let shape = await WindowCornerProbe.measure(windowID: windowID)
            guard !Task.isCancelled else { return }
            self.cornerProbeTask = nil
            
            if self.cornerShapes.count > 200 { self.cornerShapes.removeAll() }
            if self.unreadableCornerWindows.count > 200 { self.unreadableCornerWindows.removeAll() }
            
            guard let shape else {
                self.unreadableCornerWindows[windowID] = size
                return
            }
            self.cornerShapes[windowID] = (shape, size)
            self.unreadableCornerWindows[windowID] = nil
            if let bundleIdentifier {
                self.cornerShapesByBundle[bundleIdentifier] = shape
            }
            if self.currentHighlightedWindowID == windowID {
                self.highlightView?.cornerShape = shape
            }
        }
    }
    
    private func updateHighlightPosition(for window: WindowInfo, bundleIdentifier: String? = nil) {
        guard let highlightWindow = highlightWindow else { return }
        
        // Window frame is in CG coordinates (top-left origin)
        // Need to convert to AppKit coordinates (bottom-left origin)
        //
        // macOS coordinate systems:
        // - CG: origin at top-left of PRIMARY screen, Y increases downward
        // - AppKit: origin at bottom-left of PRIMARY screen, Y increases upward
        //
        // NSScreen.screens[0] is ALWAYS the primary screen (where menu bar lives)
        // NSScreen.main is the screen with keyboard focus (can change!)
        
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryScreenHeight = primaryScreen.frame.height
        
        let windowFrame = CGRect(
            x: window.frame.origin.x,
            y: primaryScreenHeight - window.frame.origin.y - window.frame.height,
            width: window.frame.width,
            height: window.frame.height
        )
        
        // The border is drawn outside the window, so the overlay window extends past it
        let expansion = HighlightBorderView.expansion(for: borderWidth)
        let expandedFrame = windowFrame.insetBy(dx: -expansion, dy: -expansion)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightWindow.setFrame(expandedFrame, display: false, animate: false)
        CATransaction.commit()
        
        refreshCornerShapeIfNeeded(for: window)
    }
    
    private func hideHighlight(keepObservingApp: Bool = false) {
        if !keepObservingApp {
            stopObservingWindowEvents()
        }
        stopMouseDragTracking()
        cancelPendingVerification()
        cornerProbeTask?.cancel()
        cornerProbeTask = nil
        hiddenForResize = false
        highlightWindow?.orderOut(nil)
        currentHighlightedWindowID = nil
        currentHighlightedPID = 0
        currentBundleIdentifier = nil
    }
    
    private func createHighlightWindow() {
        let window = HighlightNSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        // Use level just above normal windows but below floating/modal windows
        // This prevents highlight from appearing over Xcode Organizer, system dialogs, etc.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        // .stationary prevents the window from moving to other Spaces during drag
        // .ignoresCycle removes from Cmd+Tab and Mission Control
        // Do NOT use .canJoinAllSpaces - it causes ghost highlight on Space switch
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        
        window.contentView?.wantsLayer = true
        window.contentView?.layerContentsRedrawPolicy = .never
        
        let view = HighlightBorderView()
        view.borderColor = borderColor
        view.borderWidth = borderWidth
        window.contentView = view
        
        self.highlightWindow = window
        self.highlightView = view
    }
    
    private func updateHighlightAppearance() {
        // CAShapeLayer updates automatically via didSet observers
        highlightView?.borderColor = borderColor
        highlightView?.borderWidth = borderWidth
        
        // Re-position with new border width
        if let windowID = currentHighlightedWindowID {
            let windows = windowManager.enumerateWindows()
            if let window = windows.first(where: { $0.windowID == windowID }) {
                updateHighlightPosition(for: window, bundleIdentifier: currentBundleIdentifier)
            }
        }
    }
}

// MARK: - Custom NSWindow that completely bypasses hit-testing

/// Custom window that ensures zero hit-testing overhead
/// This is critical for eliminating CPU usage during mouse movement
private class HighlightNSWindow: NSWindow {
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    /// Tell the window server this window doesn't need mouse events
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .mouseExited,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return
        default:
            super.sendEvent(event)
        }
    }
}

private extension CGSize {
    func isClose(to other: CGSize) -> Bool {
        abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

// MARK: - Highlight Border View (CAShapeLayer based - no CPU hit-testing overhead)

/// Draws the border along the window outline, entirely outside the window.
/// Uses CAShapeLayer instead of draw() to avoid CPU spikes during mouse movement.
private class HighlightBorderView: NSView {
    var borderColor: NSColor = .systemBlue.withAlphaComponent(0.6) {
        didSet { updateBorderLayer() }
    }
    var borderWidth: CGFloat = 2 {
        didSet { updateBorderLayer() }
    }
    var cornerShape: WindowCornerShape = .uniform(radius: standardCornerRadius) {
        didSet {
            guard cornerShape != oldValue else { return }
            updateBorderLayer()
        }
    }
    
    /// How far the highlight window extends past the target window.
    /// One extra point keeps the anti-aliased outer edge inside the highlight window.
    static func expansion(for borderWidth: CGFloat) -> CGFloat {
        borderWidth + 1
    }
    
    // MARK: - Fallback Corner Radius
    // Used only until the real corners are measured, or when they can't be measured
    // (no Screen Recording permission, see-through window content)
    
    /// Measured on macOS 26: windows without a toolbar (most third-party apps, TextEdit)
    private static let standardCornerRadius: CGFloat = 17
    
    /// Measured on macOS 26: windows with a toolbar (Finder, Safari, Xcode, System Settings)
    private static let toolbarCornerRadius: CGFloat = 27.5
    
    static func fallbackShape(for bundleIdentifier: String?) -> WindowCornerShape {
        let isAppleApp = bundleIdentifier?.hasPrefix("com.apple.") ?? false
        return .uniform(radius: isAppleApp ? toolbarCornerRadius : standardCornerRadius)
    }
    
    // MARK: - Layers
    
    private let borderLayer = CAShapeLayer()
    /// Hides the inner half of the stroke so the border never covers the window
    private let outsideMask = CAShapeLayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        
        borderLayer.fillColor = nil
        borderLayer.lineJoin = .round
        borderLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull(), "strokeColor": NSNull()]
        
        outsideMask.fillRule = .evenOdd
        outsideMask.fillColor = CGColor.black
        outsideMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        
        borderLayer.mask = outsideMask
        layer?.addSublayer(borderLayer)
    }
    
    override func layout() {
        super.layout()
        updateBorderLayer()
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        borderLayer.contentsScale = scale
        outsideMask.contentsScale = scale
        updateBorderLayer()
    }
    
    /// Always return nil - never participate in hit-testing
    /// This ensures zero CPU overhead during mouse movement
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
    
    private func updateBorderLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let expansion = HighlightBorderView.expansion(for: borderWidth)
        let windowRect = bounds.insetBy(dx: expansion, dy: expansion)
        guard windowRect.width > 0, windowRect.height > 0 else {
            borderLayer.path = nil
            CATransaction.commit()
            return
        }
        
        let outline = cornerShape.path(in: windowRect)
        
        borderLayer.frame = bounds
        borderLayer.path = outline
        borderLayer.lineWidth = borderWidth * 2
        borderLayer.strokeColor = borderColor.cgColor
        
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addPath(outline)
        outsideMask.frame = bounds
        outsideMask.path = maskPath
        
        CATransaction.commit()
    }
}
