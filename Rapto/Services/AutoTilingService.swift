//
//  AutoTilingService.swift
//  Rapto
//
//  Handles automatic window tiling functionality (Yabai/Aerospace-style).
//  Automatically arranges all windows according to the selected grid template.
//  
//  Slot assignments are read from WindowLayoutManager, the single source of truth.
//
//  KNOWN ISSUE: Space Switch Race Condition
//  When switching between Spaces with different modes (e.g., Auto-tiling on Space 1,
//  Drag-to-Snap on Space 2), there's a brief moment where CGWindowListCopyWindowInfo()
//  returns windows from BOTH Spaces. This happens because:
//  1. CGWindowList is a low-level API that shows real-time WindowServer state
//  2. NSWorkspace.activeSpaceDidChangeNotification arrives AFTER the switch completes
//  3. Even with animations disabled, the notification is async
//  
//  Mitigation: redistribution pauses for 0.8 sec after a Space change, windows that
//  Accessibility cannot reach are filtered out, and a window change must still be there
//  after a short verify delay (see checkForWindowChanges). The verify delay adds about
//  0.2 sec latency to the timer-driven auto-tiling response.
//  

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "AutoTilingService")

@MainActor
class AutoTilingService: ObservableObject {
    
    // MARK: - Properties
    
    /// Whether the service is active on any screen
    @Published private(set) var isActive: Bool = false
    
    private var activeScreens: Set<String> = []
    
    /// Template of the screen that was laid out most recently
    @Published private(set) var activeTemplate: GridTemplate?
    
    private var screenTemplates: [String: GridTemplate] = [:]
    
    @Published private(set) var managedWindowCount: Int = 0
    
    /// Dynamic auto-tiling preferences (template per window count)
    var preferences: AutoTilingPreferences = .default
    
    var allTemplates: [GridTemplate] = []
    
    /// Callback to get per-screen max windows (returns nil to use global preferences.maxWindows)
    var getMaxWindowsForScreen: ((String) -> Int?)? = nil
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let screenManager: ScreenManager
    private let windowManager: WindowManager
    
    /// Reference to unified layout manager (single source of truth)
    private weak var layoutManager: WindowLayoutManager?
    
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowCheckTimer: Timer?
    
    // MARK: - Window Cache
    
    /// Per-screen cache of known eligible window IDs for change detection
    /// Always use filterEligibleWindows() before updating this cache
    /// Using per-screen cache prevents cross-monitor redistribution when windows change on one screen
    private var knownWindowIDsPerScreen: [String: Set<CGWindowID>] = [:]

    /// Redistributions asked for while a Space change settles (screen → saved Space), run when it ends
    private var redistributionsAfterSpaceChange: [String: String?] = [:]

    /// Visible area (CG coordinates) each screen's slots were laid out for
    private var slotsVisibleFrame: [String: CGRect] = [:]
    
    private let redistributeDebounceDelay: TimeInterval = 0.15
    
    /// Per-screen debounce work items to allow independent redistribution
    private var redistributeWorkItems: [String: DispatchWorkItem] = [:]
    
    // MARK: - Snap-back on drag
    
    private var mouseUpMonitor: Any?
    
    /// Disables snap-back while true. Nothing sets it at present
    private var snapBackDisabled: Bool = false

    /// When the last drag ended in a swap. Only that mouse up skips the snap-back
    private var lastSwapDropAt: Date?
    
    /// Flag to pause redistribution during Space changes (prevents race conditions)
    private var spaceChangeInProgress: Bool = false
    
    // MARK: - Callbacks
    
    var onWindowsRedistributed: ((_ windows: [WindowInfo]) -> Void)?

    /// Called after one or more windows snapped back to their Auto-tiling slot (CG slot frame, screenID).
    var onWindowSnappedBack: ((CGRect, String) -> Void)?

    /// Called with `true` right before a batch window move starts and `false` once it completes.
    var onLayoutTransition: ((Bool) -> Void)? = nil
    
    var isFollowAppToMonitorEnabled: (() -> Bool)? = nil

    /// Floating windows stay out of the layout
    var isWindowFloating: ((CGWindowID) -> Bool)?

    /// A window in focus mode keeps its slot but is shown at the focus frame, so snap-back leaves it to focus mode
    var isWindowFocused: ((CGWindowID) -> Bool)?
    var onFocusedWindowReleased: ((WindowInfo) -> Void)?
    /// Any layout change ends focus mode on that desktop; a desktop switch does not
    var onFocusEnded: ((CGWindowID) -> Void)?

    /// The layout a window floated out of, by slot index
    private struct FloatedLayout {
        let templateID: UUID
        let slots: [(frame: CGRect, windowIDs: [CGWindowID])]
    }
    private var floatedLayouts: [CGWindowID: FloatedLayout] = [:]
    /// Read by redistributeWindows while a floating window comes back
    private var returningFloatedLayout: FloatedLayout?
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, screenManager: ScreenManager, windowManager: WindowManager, layoutManager: WindowLayoutManager? = nil) {
        self.accessibilityService = accessibilityService
        self.screenManager = screenManager
        self.windowManager = windowManager
        self.layoutManager = layoutManager
    }
    
    func setLayoutManager(_ manager: WindowLayoutManager) {
        self.layoutManager = manager
    }
    
    deinit {
        // Cleanup handled in stop()
    }
    
    // MARK: - Public Methods
    
    func start(with template: GridTemplate, forScreenID screenID: String) {
        guard !activeScreens.contains(screenID) else {
            redistributeWindows(forScreenID: screenID)
            return
        }
        
        logger.info("Starting AutoTilingService for screen \(screenID)")
        
        screenTemplates[screenID] = template
        activeScreens.insert(screenID)
        
        if !isActive {
            setupWorkspaceObservers()
            setupMouseMonitor()
            isActive = true
        }
        
        activeTemplate = template
        redistributeWindows(forScreenID: screenID)
    }
    
    /// Start auto-tiling with dynamic template selection for a specific screen
    /// - Parameters:
    ///   - skipInitialRedistribute: If true, skips the initial redistribute (used when restoring saved layout)
    func startDynamic(forScreenID screenID: String, skipInitialRedistribute: Bool = false) {
        guard !activeScreens.contains(screenID) else {
            if !skipInitialRedistribute {
                redistributeWindows(forScreenID: screenID)
            }
            return
        }
        
        logger.info("Starting AutoTilingService with dynamic selection for screen \(screenID)")
        
        activeScreens.insert(screenID)
        
        if !isActive {
            setupWorkspaceObservers()
            setupMouseMonitor()
            isActive = true
        }
        
        if !skipInitialRedistribute {
            redistributeWindows(forScreenID: screenID)
        } else {
            // Update known windows cache ONLY for this screen (not all screens)
            // This prevents overwriting other screens' caches and breaking their removal detection
            updateKnownWindowsForScreen(screenID)
        }
    }
    
    private func updateKnownWindowsForScreen(_ screenID: String) {
        guard let screen = screenManager.screen(for: screenID) else { return }
        
        let currentWindows = windowManager.enumerateWindows()
        let filteredWindows = filterEligibleWindows(currentWindows)
        let windowsOnScreen = filterWindowsOnScreen(filteredWindows, screen: screen)
        let eligibleWindows = windowsOnScreen.filter { accessibilityService.isWindowAccessible($0) }
        
        knownWindowIDsPerScreen[screenID] = Set(eligibleWindows.map { $0.windowID })
        logger.debug("Updated known windows cache for screen \(screenID): \(eligibleWindows.count) windows")
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping AutoTilingService for all screens")
        
        removeWorkspaceObservers()
        removeMouseMonitor()
        
        for (_, workItem) in redistributeWorkItems {
            workItem.cancel()
        }
        redistributeWorkItems.removeAll()
        
        for screenID in activeScreens {
            layoutManager?.clearLayout(forScreenID: screenID)
        }
        
        activeTemplate = nil
        screenTemplates.removeAll()
        knownWindowIDsPerScreen.removeAll()
        redistributionsAfterSpaceChange.removeAll()
        slotsVisibleFrame.removeAll()
        activeScreens.removeAll()
        managedWindowCount = 0
        isActive = false
    }
    
    func stop(forScreenID screenID: String) {
        guard activeScreens.contains(screenID) else { return }
        
        logger.info("Stopping AutoTilingService for screen \(screenID)")
        
        activeScreens.remove(screenID)
        screenTemplates.removeValue(forKey: screenID)
        knownWindowIDsPerScreen.removeValue(forKey: screenID)
        redistributionsAfterSpaceChange.removeValue(forKey: screenID)
        slotsVisibleFrame.removeValue(forKey: screenID)
        redistributeWorkItems[screenID]?.cancel()
        redistributeWorkItems.removeValue(forKey: screenID)
        layoutManager?.clearLayout(forScreenID: screenID)
        
        if activeScreens.isEmpty {
            stop()
        }
    }
    
    func isActive(forScreenID screenID: String) -> Bool {
        return activeScreens.contains(screenID)
    }
    
    func redistributeNow() {
        for screenID in activeScreens {
            redistributeWindows(forScreenID: screenID)
        }
    }
    
    func redistributeNow(forScreenID screenID: String) {
        redistributeWindows(forScreenID: screenID)
    }
    
    /// Forget a window that left the layout (floated), so its slot stays empty instead of
    /// being read as a closed window and collapsed
    func forgetWindow(_ windowID: CGWindowID) {
        for screenID in knownWindowIDsPerScreen.keys {
            knownWindowIDsPerScreen[screenID]?.remove(windowID)
        }
    }

    /// Call before the window leaves its slot, so unfloating can bring this layout back
    func rememberLayout(beforeFloating windowID: CGWindowID, forScreenID screenID: String) {
        guard activeScreens.contains(screenID),
              let state = layoutManager?.state(forScreenID: screenID),
              let template = state.template else { return }
        let slots = state.slots.sorted { $0.index < $1.index }.map { (frame: $0.frame, windowIDs: $0.windows.map(\.windowID)) }
        floatedLayouts[windowID] = FloatedLayout(templateID: template.id, slots: slots)
    }

    /// The remaining windows take the floating window's place right away
    func retileAfterFloating(_ windowID: CGWindowID, forScreenID screenID: String) {
        forgetWindow(windowID)
        leaveFocusMode(onScreenID: screenID)
        redistributeWindows(forScreenID: screenID)
    }

    /// With the same windows tiled as when it floated, the old layout comes back as it was;
    /// otherwise the window joins as a new one
    func retileAfterUnfloating(_ windowID: CGWindowID, forScreenID screenID: String) {
        leaveFocusMode(onScreenID: screenID)
        returningFloatedLayout = floatedLayouts.removeValue(forKey: windowID)
        redistributeWindows(forScreenID: screenID)
        returningFloatedLayout = nil
    }

    /// The focused window goes back to its slot, so a layout that changes under it doesn't leave it covering the others
    private func leaveFocusMode(onScreenID screenID: String) {
        guard let layoutManager, isWindowFocused != nil else { return }
        let slots = layoutManager.state(forScreenID: screenID).slots
        guard slots.contains(where: { $0.windows.contains { isWindowFocused?($0.windowID) == true } }) else { return }
        let currentWindows = windowManager.enumerateWindows()
        for slot in slots {
            for slotWindow in slot.windows where isWindowFocused?(slotWindow.windowID) == true {
                debugLog("AutoTiling", " Layout changes on \(screenID): window \(slotWindow.windowID) leaves focus mode")
                onFocusEnded?(slotWindow.windowID)
                if let window = currentWindows.first(where: { $0.windowID == slotWindow.windowID }) {
                    _ = accessibilityService.setWindowFrame(window, frame: slot.frame)
                }
            }
        }
    }

    /// Update known window IDs without triggering redistribution
    /// Call this when switching Spaces to prevent false "window changed" detections
    /// - Parameter onlyLaidOut: Leave out windows that a screen's layout doesn't hold, so the window
    ///   check tiles them. A window dragged onto a screen while a Space change settled is one of them
    func updateKnownWindowsWithoutRedistribute(onlyLaidOut: Bool = false) {
        let currentWindows = windowManager.enumerateWindows()
        let eligibleWindows = filterEligibleWindows(currentWindows)
        
        for screenID in activeScreens {
            guard let screen = screenManager.screen(for: screenID) else { continue }
            let windowsOnScreen = filterWindowsOnScreen(eligibleWindows, screen: screen)
            let accessibleWindows = windowsOnScreen.filter { accessibilityService.isWindowAccessible($0) }
            var laidOut: Set<CGWindowID>?
            if onlyLaidOut, let state = layoutManager?.state(forScreenID: screenID), state.isActive {
                laidOut = Set(state.slots.flatMap(\.windows).map(\.windowID))
            }
            let known = Self.knownWindowIDs(onScreen: Set(accessibleWindows.map { $0.windowID }), laidOut: laidOut)
            if known.count < accessibleWindows.count {
                debugLog("AutoTiling", " \(accessibleWindows.count - known.count) window(s) on screen \(screenID) are outside its layout, the window check will tile them")
            }
            knownWindowIDsPerScreen[screenID] = known
        }
        
        let totalCount = knownWindowIDsPerScreen.values.reduce(0) { $0 + $1.count }
        logger.debug("Updated known windows cache without redistribute: \(totalCount) windows across \(self.activeScreens.count) screens")
    }
    
    /// Windows the change check takes as already handled: all on the screen, or only those its layout holds
    nonisolated static func knownWindowIDs(onScreen: Set<CGWindowID>, laidOut: Set<CGWindowID>?) -> Set<CGWindowID> {
        guard let laidOut else { return onScreen }
        return onScreen.intersection(laidOut)
    }
    
    /// Layouts of other screens that lost a window to this one: saved and their indicators updated
    var onWindowsLeftScreens: ((Set<String>) -> Void)?

    /// A window that arrived on this screen leaves the layout of the screen it came from,
    /// or it would stay in two layouts and that screen would keep its slot
    private func takeFromOtherScreens(_ windowIDs: Set<CGWindowID>, into screenID: String) {
        guard let layoutManager else { return }
        var left: Set<String> = []
        for windowID in windowIDs {
            for otherScreenID in layoutManager.screensWithActiveLayouts where otherScreenID != screenID {
                if layoutManager.removeWindow(windowID, forScreenID: otherScreenID) != nil {
                    debugLog("AutoTiling", " Window \(windowID) arrived on screen \(screenID), removed from the layout of \(otherScreenID)")
                    left.insert(otherScreenID)
                }
            }
        }
        if !left.isEmpty {
            onWindowsLeftScreens?(left)
        }
    }

    /// Runs work that met another layout operation once that one is done. Gives up after 3 seconds
    private func retryWhenLayoutIsFree(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.isActive else { return }
                if self.layoutManager?.canPerform(operation: .redistributing) == true {
                    work()
                    return
                }
            }
        }
    }
    
    /// End of a Space change pause: refresh the known windows and run what was asked for meanwhile
    private func finishSpaceChangePause() {
        updateKnownWindowsWithoutRedistribute(onlyLaidOut: true)
        spaceChangeInProgress = false
        let pending = redistributionsAfterSpaceChange
        redistributionsAfterSpaceChange.removeAll()
        for (screenID, savedSpaceID) in pending {
            debugLog("AutoTiling", " Space change settled, redistributing screen \(screenID) as asked during it")
            redistributeWindows(forScreenID: screenID, savedSpaceID: savedSpaceID)
        }
    }
    
    /// Each Space change gets a number: only the latest one ends the pause, so the timer of
    /// the first of two quick switches doesn't resume tiling in the middle of the second one.
    private var spaceChangeGeneration = 0
    
    private func nextSpaceChangeGeneration() -> Int {
        spaceChangeGeneration += 1
        return spaceChangeGeneration
    }
    
    var isPausedForSpaceChange: Bool { spaceChangeInProgress }
    
    /// Pause redistribution until the Space switch animation is over, then refresh the known windows
    func pauseUntilSpaceSettles(nanoseconds: UInt64) {
        spaceChangeInProgress = true
        let generation = nextSpaceChangeGeneration()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, generation == self.spaceChangeGeneration else { return }
            self.finishSpaceChangePause()
            logger.debug("Space change complete - resumed auto-tiling")
        }
    }
    
    /// The drag that is ending swaps windows, so its mouse up must not snap them back.
    /// The next drag snaps back as usual, however soon it comes.
    func skipSnapBackForCurrentDrop() {
        lastSwapDropAt = Date()
    }

    // MARK: - Workspace Observers
    
    private func setupWorkspaceObservers() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        
        let launchObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app {
                logger.debug("App launched: \(app.localizedName ?? "unknown")")
            }
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleRedistribution()
                guard let app, app.activationPolicy == .regular else { return }
                // A launched app answers Accessibility only after a moment
                for delay in [0.3, 1.5, 3.0] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, self.isActive, !app.isTerminated else { return }
                    self.observeWindows(of: app.processIdentifier)
                }
            }
        }
        workspaceObservers.append(launchObserver)
        
        let terminateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app {
                logger.debug("App terminated: \(app.localizedName ?? "unknown")")
            }
            guard let self else { return }
            Task { @MainActor [weak self] in
                if let app { self?.stopObservingWindows(of: app.processIdentifier) }
                self?.scheduleRedistribution()
            }
        }
        workspaceObservers.append(terminateObserver)
        
        let activateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                // Skip during Space change to avoid false redistributions
                // App activation fires when switching Spaces (focus changes to app in new Space)
                guard !self.spaceChangeInProgress, UserSession.isActive else {
                    logger.debug("Skipping activation check - Space change in progress or session in background")
                    return
                }
                
                let currentWindows = self.windowManager.enumerateWindows()
                let filteredWindows = self.filterEligibleWindows(currentWindows)
                
                for screenID in self.activeScreens {
                    guard let screen = self.screenManager.screen(for: screenID) else { continue }
                    let windowsOnScreen = self.filterWindowsOnScreen(filteredWindows, screen: screen)
                    let currentIDs = Set(windowsOnScreen.map { $0.windowID })
                    let knownIDs = self.knownWindowIDsPerScreen[screenID] ?? []
                    
                    if currentIDs != knownIDs {
                        logger.debug("Activate observer: window count changed on screen \(screenID) (\(knownIDs.count) -> \(currentIDs.count))")
                        self.scheduleRedistribution(forScreenID: screenID)
                    }
                }
                // Don't update knownWindowIDsPerScreen here - let redistributeWindows do it
                // This prevents false updates when redistribute is skipped
            }
        }
        workspaceObservers.append(activateObserver)
        
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logger.info("Screen parameters changed, redistributing")
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleRedistribution()
            }
        }
        workspaceObservers.append(screenObserver)
        
        let unhideObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logger.debug("App unhidden, redistributing")
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.scheduleRedistribution()
            }
        }
        workspaceObservers.append(unhideObserver)
        
        // Observe Space changes - pause redistribution to avoid race conditions
        // When Space changes, windows from other Spaces may briefly appear in the window list
        let spaceChangeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Set flag SYNCHRONOUSLY before any async work
            // This prevents the timer (0.5 sec interval) from triggering redistribute during Space animation
            // Using MainActor.assumeIsolated because we're on .main queue (MainActor context)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spaceChangeInProgress = true
                logger.debug("Space change detected - pausing auto-tiling SYNCHRONOUSLY")
                
                for (_, workItem) in self.redistributeWorkItems {
                    workItem.cancel()
                }
                self.redistributeWorkItems.removeAll()
                
                // Pause for Space animation to complete
                // macOS Space switch animation is typically 0.5-0.7 sec
                self.pauseUntilSpaceSettles(nanoseconds: 800_000_000) // 0.8 sec
            }
        }
        workspaceObservers.append(spaceChangeObserver)
        
        // Timer to detect new windows or minimized/unminimized windows
        // This catches cases that notifications miss (new windows within existing apps, minimize/unminimize)
        // Check per-screen to avoid cross-monitor redistribution
        // 0.5s interval balances responsiveness vs CPU usage (isWindowAccessible uses heavy AX calls)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForWindowChanges(verifyDelay: 0.2)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowCheckTimer = timer

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeWindows(of: app.processIdentifier)
        }
        
        logger.debug("Workspace observers set up")
    }

    /// Set while a check runs, so the timer and a window notification don't check at the same time
    private var isCheckingWindows = false
    /// A window notification came during a check that may have looked before the change
    private var recheckRequested = false

    /// Compares each screen's windows with the known ones and lays the screen out again when they changed.
    /// The change has to still be there after `verifyDelay`: windows of other desktops flash by during a switch
    private func checkForWindowChanges(verifyDelay: TimeInterval) async {
        guard isActive, UserSession.isActive else { return }
        guard !isCheckingWindows else {
            recheckRequested = true
            return
        }
        guard !spaceChangeInProgress else {
            logger.debug("Skipping window check - Space change in progress")
            return
        }
        isCheckingWindows = true
        await compareWindowsWithKnown(verifyDelay: verifyDelay)
        isCheckingWindows = false
        if recheckRequested {
            recheckRequested = false
            await checkForWindowChanges(verifyDelay: 0.05)
        }
    }

    private func compareWindowsWithKnown(verifyDelay: TimeInterval) async {
        // A window being dragged is between screens; it is handled after the drop
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let currentWindows = self.windowManager.enumerateWindows()
        let filteredWindows = self.filterEligibleWindows(currentWindows)
        
        for screenID in self.activeScreens {
            guard let screen = self.screenManager.screen(for: screenID) else { continue }
            
            let windowsOnScreen = self.filterWindowsOnScreen(filteredWindows, screen: screen)
            // Filter by accessibility to exclude windows on other Spaces
            let eligibleWindows = windowsOnScreen.filter { self.accessibilityService.isWindowAccessible($0) }
            let currentIDs = Set(eligibleWindows.map { $0.windowID })
            let knownIDs = self.knownWindowIDsPerScreen[screenID] ?? []
            
            if currentIDs != knownIDs {
                logger.debug("Window count changed on screen \(screenID) (\(knownIDs.count) -> \(currentIDs.count)), verifying...")
                
                try? await Task.sleep(nanoseconds: UInt64(verifyDelay * 1_000_000_000))
                
                guard !self.spaceChangeInProgress, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                
                let verifyWindows = self.windowManager.enumerateWindows()
                let verifyFiltered = self.filterEligibleWindows(verifyWindows)
                let verifyOnScreen = self.filterWindowsOnScreen(verifyFiltered, screen: screen)
                let verifyEligible = verifyOnScreen.filter { self.accessibilityService.isWindowAccessible($0) }
                let verifyIDs = Set(verifyEligible.map { $0.windowID })
                
                if verifyIDs != knownIDs {
                    self.knownWindowIDsPerScreen[screenID] = verifyIDs
                    
                    let addedWindows = verifyIDs.subtracting(knownIDs)
                    let removedWindows = knownIDs.subtracting(verifyIDs)
                    debugLog("AutoTiling", " Windows changed on screen \(screenID): +\(addedWindows.count) -\(removedWindows.count) (\(verifyDelay < 0.1 ? "window notification" : "timer"))")
                    self.leaveFocusMode(onScreenID: screenID)
                    
                    if !addedWindows.isEmpty {
                        logger.debug("Windows added on screen \(screenID) (\(addedWindows.count))")
                        self.takeFromOtherScreens(addedWindows, into: screenID)
                        
                        if self.isFollowAppToMonitorEnabled?() == true {
                            for addedWindowID in addedWindows {
                                guard let addedWindow = verifyEligible.first(where: { $0.windowID == addedWindowID }) else { continue }
                                
                                if let targetScreenID = self.findScreenWithSameApp(addedWindow, excludingScreen: screenID) {
                                    logger.info("Redirecting '\(addedWindow.ownerName)' from \(screenID) to \(targetScreenID) (Follow App to Monitor)")
                                    
                                    if let targetScreen = self.screenManager.screen(for: targetScreenID) {
                                        let targetFrame = targetScreen.visibleFrame
                                        let appKitOrigin = CGPoint(
                                            x: targetFrame.origin.x + (targetFrame.width - addedWindow.frame.width) / 2,
                                            y: targetFrame.origin.y + (targetFrame.height - addedWindow.frame.height) / 2
                                        )
                                        // Convert to CG coordinates (AppKit has bottom-left origin, CG has top-left)
                                        let appKitFrame = CGRect(origin: appKitOrigin, size: addedWindow.frame.size)
                                        let cgFrame = self.screenManager.convertToCGCoordinates(frame: appKitFrame, for: targetScreen)
                                        _ = self.accessibilityService.setWindowPosition(addedWindow, position: cgFrame.origin)
                                        
                                        self.knownWindowIDsPerScreen[screenID]?.remove(addedWindowID)
                                        self.knownWindowIDsPerScreen[targetScreenID]?.insert(addedWindowID)
                                        
                                        self.scheduleRedistribution(forScreenID: targetScreenID)
                                        continue
                                    }
                                }
                            }
                        }
                        
                        self.scheduleRedistribution(forScreenID: screenID)
                    } else if !removedWindows.isEmpty {
                        logger.debug("Windows removed from screen \(screenID) (\(removedWindows.count)), syncing layout")
                        self.syncLayoutAfterWindowRemovalForScreen(screenID: screenID, visibleWindowIDs: verifyIDs)
                    }
                } else {
                    logger.debug("Window change on screen \(screenID) was transient, ignoring")
                }
            }
        }
    }

    // MARK: - Window Notifications

    /// Per app: macOS tells about windows opened, closed, minimized and brought back, so a change is
    /// handled at once instead of at the next timer check. The timer stays for apps that don't tell
    private var windowObservers: [pid_t: AXObserver] = [:]
    private var windowNotificationWorkItem: DispatchWorkItem?

    private func observeWindows(of pid: pid_t) {
        guard windowObservers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard AppResponsiveness.isResponding(pid) else { return }
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let service = Unmanaged<AutoTilingService>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                service.windowNotificationArrived()
            }
        }, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]
        // An app that isn't ready for Accessibility yet takes none; it is tried again after launch
        // Each request waits for the app, so stop at the first one a hung app never answers
        let added = notifications.filter { notification in
            guard AppResponsiveness.isResponding(pid) else { return false }
            return AppResponsiveness.shared.ask(pid) {
                AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            } == .success
        }
        guard !added.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        windowObservers[pid] = observer
    }

    private func stopObservingWindows(of pid: pid_t) {
        guard let observer = windowObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func stopObservingAllWindows() {
        for pid in Array(windowObservers.keys) {
            stopObservingWindows(of: pid)
        }
    }

    /// Menus and tooltips send these too, and one window change sends several: one check after they stop
    private func windowNotificationArrived() {
        windowNotificationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkForWindowChanges(verifyDelay: 0.05)
            }
        }
        windowNotificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
    
    private func removeWorkspaceObservers() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        
        windowCheckTimer?.invalidate()
        windowCheckTimer = nil
        stopObservingAllWindows()
        windowNotificationWorkItem?.cancel()
        
        logger.debug("Workspace observers removed")
    }
    
    // MARK: - Follow App to Monitor
    
    private func findScreenWithSameApp(_ window: WindowInfo, excludingScreen: String) -> String? {
        guard let layoutManager = layoutManager else { return nil }
        
        for otherScreenID in activeScreens where otherScreenID != excludingScreen {
            let screenState = layoutManager.state(forScreenID: otherScreenID)
            
            let hasSameApp = screenState.slots.contains { slot in
                slot.windows.contains { existingWindow in
                    // The window itself: it was just moved away from there
                    guard existingWindow.windowID != window.windowID else { return false }
                    return existingWindow.ownerPID == window.ownerPID ||
                    // Only compare bundleIdentifiers if both are non-nil to avoid nil == nil matching
                    (existingWindow.bundleIdentifier != nil && window.bundleIdentifier != nil && 
                     existingWindow.bundleIdentifier == window.bundleIdentifier) ||
                    existingWindow.ownerName == window.ownerName
                }
            }
            
            if hasSameApp {
                logger.debug("Found same app '\(window.ownerName)' on screen \(otherScreenID)")
                return otherScreenID
            }
        }
        
        return nil
    }
    
    // MARK: - Mouse Monitor for Snap-back
    
    private func setupMouseMonitor() {
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self else { return }
            let releasedAt = Date()
            Task { @MainActor [weak self] in
                // Delay to let resize service process first (it runs on mouse up too)
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                self?.snapBackWindows(releasedAt: releasedAt)
            }
        }
        logger.debug("Mouse monitor set up for snap-back")
    }
    
    private func removeMouseMonitor() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        logger.debug("Mouse monitor removed")
    }
    
    /// Snap windows back to their assigned slots if they've been moved.
    /// Reads slot assignments from layoutManager and handles cross-screen moves
    private func snapBackWindows(releasedAt: Date) {
        guard !snapBackDisabled else {
            debugLog("AutoTiling", "Snap-back skipped (disabled for resize)")
            return
        }
        // The swap service handles the same mouse up a moment later than this monitor
        if let swapDrop = lastSwapDropAt, abs(swapDrop.timeIntervalSince(releasedAt)) < 0.25 {
            debugLog("AutoTiling", "Snap-back skipped (this drop swapped windows)")
            return
        }
        
        guard let layoutManager = layoutManager,
              layoutManager.canPerform(operation: .snappingBack) else {
            logger.debug("Snap-back blocked by operation mode")
            return
        }
        
        let windows = windowManager.enumerateWindows()
        let eligibleWindows = filterEligibleWindows(windows)
        
        var crossScreenMoves: [(window: WindowInfo, fromScreenID: String, toScreenID: String)] = []
        var firstSnappedSlot: (frame: CGRect, screenID: String)?
        
        for screenID in activeScreens {
            let screenState = layoutManager.state(forScreenID: screenID)
            guard screenState.isActive else { continue }
            
            for slot in screenState.slots {
                guard let primaryWindow = slot.primaryWindow,
                      let window = eligibleWindows.first(where: { $0.windowID == primaryWindow.windowID }) else {
                    continue
                }

                if isWindowFocused?(window.windowID) == true {
                    onFocusedWindowReleased?(window)
                    continue
                }
                
                let targetFrame = slot.frame
                
                // Check if window POSITION has changed significantly from its slot
                // We only check position, NOT size. This prevents race condition when
                // a window has minimum size constraints and can't shrink to slot size.
                // If we checked size, we'd infinitely try to resize a window that can't resize.
                let positionDelta = hypot(
                    window.frame.origin.x - targetFrame.origin.x,
                    window.frame.origin.y - targetFrame.origin.y
                )
                
                // A small leftover offset still breaks the gaps, so only rounding is ignored
                if positionDelta > 4 {
                    let currentScreen = screenManager.screen(for: window)
                    let currentScreenID = screenManager.identifier(for: currentScreen)
                    
                    if currentScreenID != screenID {
                        logger.debug("Window '\(window.title)' moved to different screen (\(screenID) -> \(currentScreenID))")
                        crossScreenMoves.append((window, screenID, currentScreenID))
                        continue
                    }
                    
                    // Window stayed on same screen - snap it back
                    // setWindowFrame looks up the AXWindow once, so apps with multiple AX windows get the right one
                    debugLog("AutoTiling", "Snapping back '\(window.ownerName)' to slot \(slot.index + 1)")
                    let success = accessibilityService.setWindowFrame(window, frame: targetFrame)
                    if success {
                        layoutManager.updateWindowFrame(window.windowID, newFrame: accessibilityService.expectedFrame(targetFrame, windowID: window.windowID), forScreenID: screenID)
                        if firstSnappedSlot == nil {
                            firstSnappedSlot = (targetFrame, screenID)
                        }
                    }
                }
            }
        }

        if let snapped = firstSnappedSlot {
            onWindowSnappedBack?(snapped.frame, snapped.screenID)
        }
        
        for (window, fromScreenID, toScreenID) in crossScreenMoves {
            logger.info("Transferring '\(window.title)' from \(fromScreenID) to \(toScreenID) in Auto-tiling")
            
            if activeScreens.contains(toScreenID) {
                // Both screens are laid out again for their new window counts: putting the window into
                // a slot of the target would group it with a window there when no slot is empty
                layoutManager.removeWindowFromAnyScreen(window.windowID)
                knownWindowIDsPerScreen[fromScreenID]?.remove(window.windowID)
                knownWindowIDsPerScreen[toScreenID]?.insert(window.windowID)
                debugLog("AutoTiling", " '\(window.ownerName)' moved to screen \(toScreenID), laying out both screens again")
                scheduleRedistribution(forScreenID: toScreenID)
                if activeScreens.contains(fromScreenID) {
                    scheduleRedistribution(forScreenID: fromScreenID)
                }
            } else {
                layoutManager.removeWindowFromAnyScreen(window.windowID)
            }
        }
    }
    
    /// Sync layout after windows are removed from a SPECIFIC screen only
    /// This is the per-screen version to avoid cross-monitor redistribution
    private func syncLayoutAfterWindowRemovalForScreen(screenID: String, visibleWindowIDs: Set<CGWindowID>) {
        guard !spaceChangeInProgress, UserSession.isActive else {
            logger.debug("Skipping syncLayoutAfterWindowRemovalForScreen - Space change in progress or session in background")
            return
        }
        
        guard let layoutManager = layoutManager else { return }
        
        guard layoutManager.canPerform(operation: .redistributing) else {
            debugLog("AutoTiling", " Screen \(screenID) waits for \(layoutManager.operationMode.description) to finish before updating after a removed window")
            retryWhenLayoutIsFree { [weak self] in
                guard let self else { return }
                self.syncLayoutAfterWindowRemovalForScreen(screenID: screenID, visibleWindowIDs: self.knownWindowIDsPerScreen[screenID] ?? visibleWindowIDs)
            }
            return
        }
        
        guard let screen = screenManager.screen(for: screenID) else {
            logger.warning("Screen not found for ID: \(screenID) during sync")
            return
        }
        
        let allWindows = windowManager.enumerateWindows()
        let windowsOnScreen = filterWindowsOnScreen(allWindows, screen: screen)
        let visibleWindowsOnScreen = windowsOnScreen.filter { visibleWindowIDs.contains($0.windowID) }
        let screenWindowCount = visibleWindowsOnScreen.count
        
        let currentState = layoutManager.state(forScreenID: screenID)
        let currentSlotCount = currentState.slots.count
        
        logger.debug("Screen \(screenID): \(screenWindowCount) visible windows, current template has \(currentSlotCount) slots")
        
        if let newTemplate = selectTemplate(for: screenWindowCount),
           newTemplate.zones.count != currentSlotCount {
            logger.debug("Template change needed (\(currentSlotCount) -> \(newTemplate.zones.count) slots), preserving positions")
            redistributeWindowsPreservingPositions(
                forScreenID: screenID,
                newTemplate: newTemplate,
                visibleWindowIDs: visibleWindowIDs
            )
        } else {
            // Template stays the same - check if we need to redistribute
            // Sync first to remove closed windows
            layoutManager.syncWithVisibleWindows(visibleWindowIDs, forScreenID: screenID)
            
            let updatedState = layoutManager.state(forScreenID: screenID)
            let emptySlotCount = updatedState.slots.filter { $0.isEmpty }.count
            let groupCount = updatedState.slots.filter { $0.hasGroup }.count
            
            // If there are empty slots AND no groups to fill them, trigger full redistribution
            // This ensures windows spread evenly when closing windows
            if emptySlotCount > 0 && groupCount == 0 && screenWindowCount > 0 {
                logger.debug("Empty slots (\(emptySlotCount)) with no groups - triggering full redistribution")
                if let template = selectTemplate(for: screenWindowCount) {
                    redistributeWindowsPreservingPositions(
                        forScreenID: screenID,
                        newTemplate: template,
                        visibleWindowIDs: visibleWindowIDs
                    )
                } else {
                    if let currentTemplate = currentState.template {
                        redistributeWindowsPreservingPositions(
                            forScreenID: screenID,
                            newTemplate: currentTemplate,
                            visibleWindowIDs: visibleWindowIDs
                        )
                    }
                }
            } else {
                for (slotIndex, window) in layoutManager.windowsNeedingRepositioning(forScreenID: screenID) {
                    let slot = layoutManager.state(forScreenID: screenID).slots[slotIndex]
                    _ = accessibilityService.setWindowFrame(window, frame: slot.frame)
                    logger.debug("Repositioned '\(window.title)' to slot \(slotIndex + 1)")
                }
            }
        }
        
        let freshWindows = windowManager.enumerateWindows()
        let state = layoutManager.state(forScreenID: screenID)
        let managedIDs = state.managedWindowIDs
        let managedWindows = freshWindows.filter { managedIDs.contains($0.windowID) }
        onWindowsRedistributed?(managedWindows)
    }
    
    /// Redistribute windows to a new template while preserving existing positions
    /// Windows stay in their current slot indices if possible; excess windows are grouped
    private func redistributeWindowsPreservingPositions(
        forScreenID screenID: String,
        newTemplate: GridTemplate,
        visibleWindowIDs: Set<CGWindowID>
    ) {
        guard !spaceChangeInProgress else {
            logger.debug("Skipping redistributeWindowsPreservingPositions - Space change in progress")
            return
        }
        
        guard let layoutManager = layoutManager else { return }
        
        guard layoutManager.canPerform(operation: .redistributing) else {
            logger.debug("Skipping redistributeWindowsPreservingPositions - conflicting operation: \(layoutManager.operationMode.description)")
            return
        }
        
        let currentState = layoutManager.state(forScreenID: screenID)
        let newSlotCount = newTemplate.zones.count
        
        logger.debug("redistributeWindowsPreservingPositions: current slots = \(currentState.slots.count), new template slots = \(newSlotCount)")
        logger.debug("visibleWindowIDs count = \(visibleWindowIDs.count)")
        
        // SPECIAL CASE: When only 1 window remains, don't preserve positions - 
        // just redistribute to put the single window in slot 0 (primary slot by fillOrder).
        // This ensures the window goes to the CENTER in Center Focus template,
        // not a side panel.
        if visibleWindowIDs.count == 1 {
            logger.debug("Single window remaining - using full redistribute for proper slot 0 placement")
            redistributeWindows(forScreenID: screenID)
            return
        }
        
        var windowsBySlotIndex: [Int: [WindowInfo]] = [:]
        
        for slot in currentState.slots {
            logger.debug("Slot \(slot.index): \(slot.windows.count) windows - \(slot.windows.map { "\($0.title) (ID:\($0.windowID))" })")
            let visibleWindows = slot.windows.filter { visibleWindowIDs.contains($0.windowID) }
            logger.debug("  -> \(visibleWindows.count) visible after filter")
            if !visibleWindows.isEmpty {
                windowsBySlotIndex[slot.index] = visibleWindows
            }
        }
        
        guard let screen = screenManager.screen(for: screenID) else { return }
        let screenFrame = screenManager.visibleFrame(for: screen)
        let sortedZones = newTemplate.zones.sorted { $0.fillOrder < $1.fillOrder }

        let placed = windowsBySlotIndex.sorted { $0.key < $1.key }.map { entry in
            (frame: currentState.slots.first { $0.index == entry.key }?.frame ?? .zero, windows: entry.value)
        }
        let newSlotAssignments = assignSlotsByPosition(
            placed: placed,
            newWindows: [],
            slotFrames: defaultSlotFrames(for: sortedZones, on: screen)
        )
        
        logger.debug("Final slot assignments: \(newSlotAssignments.enumerated().map { "slot \($0.offset): \($0.element.count) windows" })")
        
        // Refresh window info with current positions before building slots
        // The WindowInfo objects in newSlotAssignments may have stale positions from when they were
        // added to their slots. Windows may have moved due to snap-back or other operations.
        // If we don't refresh, AccessibilityService won't find them by position matching.
        let freshWindows = windowManager.enumerateWindows()
        let freshWindowsByID: [CGWindowID: WindowInfo] = Dictionary(
            uniqueKeysWithValues: freshWindows.map { ($0.windowID, $0) }
        )
        
        var newSlots: [Slot] = []
        for (index, zone) in sortedZones.enumerated() {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            
            let refreshedWindows = newSlotAssignments[index].compactMap { staleWindow -> WindowInfo? in
                if let fresh = freshWindowsByID[staleWindow.windowID] {
                    return fresh
                } else {
                    logger.debug("Window '\(staleWindow.title)' (ID: \(staleWindow.windowID)) no longer exists, removing from slot")
                    return nil
                }
            }
            
            let slot = Slot(
                id: zone.id,
                index: index,
                frame: cgFrame,
                windows: refreshedWindows
            )
            newSlots.append(slot)
        }
        
        layoutManager.setLayoutWithSlots(template: newTemplate, slots: newSlots, forScreenID: screenID)
        slotsVisibleFrame[screenID] = screenManager.visibleCGFrame(for: screen)
        screenTemplates[screenID] = newTemplate
        activeTemplate = newTemplate
        
        // Pre-cache ALL AXWindow references BEFORE moving any windows!
        // This is necessary because position-based window matching fails after windows move.
        // When Window A moves to position X, searching for Window B at position X will find Window A.
        let allWindowsToPosition = newSlots.flatMap { $0.windows }
        let axWindowCache = accessibilityService.batchGetAXWindows(for: allWindowsToPosition)

        var batchTargets: [AccessibilityService.BatchFrameTarget] = []
        batchTargets.reserveCapacity(allWindowsToPosition.count)
        for slot in newSlots where !slot.isEmpty {
            for window in slot.windows.reversed() {
                batchTargets.append(
                    AccessibilityService.BatchFrameTarget(
                        window: window,
                        axWindow: axWindowCache[window.windowID],
                        frame: slot.frame
                    )
                )
            }
        }

        var startedTransition = false
        _ = accessibilityService.batchSetWindowFrames(batchTargets) { [weak self] in
            startedTransition = true
            self?.onLayoutTransition?(true)
        }

        // Only a group needs its primary on top; raising every tile reshuffles the stacking order
        for slot in newSlots where slot.windowCount > 1 {
            if let primary = slot.primaryWindow, let cachedAXWindow = axWindowCache[primary.windowID] {
                accessibilityService.raiseWindow(axWindow: cachedAXWindow)
            }
        }
        if startedTransition {
            onLayoutTransition?(false)
        }
    }
    
    // MARK: - Window Redistribution
    
    /// Schedule a debounced window redistribution for a specific screen only
    /// This prevents cross-monitor redistribution when windows change on one screen
    private func scheduleRedistribution(forScreenID screenID: String) {
        guard !spaceChangeInProgress else {
            logger.debug("Skipping scheduleRedistribution for screen \(screenID) - Space change in progress")
            return
        }
        
        redistributeWorkItems[screenID]?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.spaceChangeInProgress, UserSession.isActive else {
                    logger.debug("Skipping redistribution for screen \(screenID) after debounce - Space change in progress")
                    return
                }
                self.redistributeWindows(forScreenID: screenID)
            }
        }
        
        redistributeWorkItems[screenID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + redistributeDebounceDelay, execute: workItem)
    }
    
    /// Schedule a debounced window redistribution for all active screens
    /// Use this sparingly - prefer scheduleRedistribution(forScreenID:) for targeted updates
    private func scheduleRedistribution() {
        guard !spaceChangeInProgress else {
            logger.debug("Skipping scheduleRedistribution - Space change in progress")
            return
        }
        
        for screenID in activeScreens {
            scheduleRedistribution(forScreenID: screenID)
        }
    }
    
    /// Redistribute windows on a specific screen
    /// Selects template based on window count and uses smart grouping
    /// If savedSpaceID is provided, tries to restore saved layout first (preserves window order on Space return)
    func redistributeWindows(forScreenID screenID: String, savedSpaceID: String? = nil) {
        logger.info("redistributeWindows called for screen \(screenID), savedSpaceID: \(savedSpaceID ?? "nil")")
        
        // Check Space change flag to prevent incorrect redistribution
        // During Space animation, CGWindowListCopyWindowInfo may return windows from multiple Spaces
        guard !spaceChangeInProgress else {
            redistributionsAfterSpaceChange[screenID] = savedSpaceID
            debugLog("AutoTiling", " Space change in progress, redistributing screen \(screenID) once it settles")
            return
        }
        
        guard let layoutManager = layoutManager else {
            logger.warning("No layoutManager set")
            return
        }
        
        guard layoutManager.canPerform(operation: .redistributing) else {
            debugLog("AutoTiling", " Screen \(screenID) waits for \(layoutManager.operationMode.description) to finish before redistributing")
            retryWhenLayoutIsFree { [weak self] in
                self?.redistributeWindows(forScreenID: screenID, savedSpaceID: savedSpaceID)
            }
            return
        }
        
        guard activeScreens.contains(screenID) else {
            logger.debug("Screen \(screenID) is not active for auto-tiling")
            return
        }
        
        guard let screen = screenManager.screen(for: screenID) else {
            logger.warning("Screen not found for ID: \(screenID)")
            return
        }
        
        layoutManager.setMode(.redistributing)
        
        // Clear manual modifications flag since we're recalculating layout
        // User resize modifications are lost when window count changes
        layoutManager.clearManualModifications(forScreenID: screenID)
        
        let allWindows = windowManager.enumerateWindows()
        logger.info("Found \(allWindows.count) total windows")
        
        let windowsOnScreen = filterWindowsOnScreen(allWindows, screen: screen)
        
        let filteredWindows = filterEligibleWindows(windowsOnScreen)
        
        // Filter by accessibility - windows on other Spaces are not accessible via AX API
        // CGWindowListCopyWindowInfo returns ALL windows across ALL Spaces, but we only want
        // windows on the current Space. AX API cannot access windows on other Spaces.
        let eligibleWindows = filteredWindows.filter { window in
            let isAccessible = accessibilityService.isWindowAccessible(window)
            return isAccessible
        }
        
        logger.info("Screen \(screenID): \(eligibleWindows.count) eligible windows (filtered from \(filteredWindows.count))")
        
        if eligibleWindows.isEmpty {
            logger.debug("No eligible windows to redistribute on screen \(screenID)")
            layoutManager.clearLayout(forScreenID: screenID)
            screenTemplates.removeValue(forKey: screenID)
            layoutManager.setMode(.idle)
            return
        }
        
        var totalManaged = 0
        for activeScreenID in activeScreens {
            if let state = layoutManager.screenStates[activeScreenID] {
                totalManaged += state.managedWindowIDs.count
            }
        }
        managedWindowCount = totalManaged + eligibleWindows.count
        
        let maxWindows = getMaxWindowsForScreen?(screenID) ?? preferences.maxWindows
        let effectiveWindowCount = min(eligibleWindows.count, maxWindows)
        
        debugLog("AutoTiling", " maxWindows=\(maxWindows), eligibleCount=\(eligibleWindows.count), effectiveCount=\(effectiveWindowCount)")
        
        guard let template = selectTemplate(for: effectiveWindowCount) else {
            logger.warning("No template found for \(effectiveWindowCount) windows")
            layoutManager.setMode(.idle)
            return
        }
        
        let previousTemplate = screenTemplates[screenID]
        if previousTemplate?.id != template.id {
            logger.info("Template changed for screen \(screenID): \(template.name)")
            screenTemplates[screenID] = template
            // Clear the AXUIElement cache when the template changes.
            // This forces re-matching of windows to prevent position-based confusion
            accessibilityService.clearAllAXCache()
        }
        
        activeTemplate = template
        
        logger.info("Using template: \(template.name) with \(template.zones.count) slots for \(eligibleWindows.count) windows on screen \(screenID)")
        
        let screenFrame = screenManager.visibleFrame(for: screen)
        
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        // Try to restore saved layout first (preserves window order on Space return),
        // so windows do not swap positions on the first Space return
        var slotWindowAssignments: [[WindowInfo]]
        var savedLayoutInfo: SavedLayoutInfo? = nil
        var layoutFrames = defaultSlotFrames(for: sortedZones, on: screen)
        
        if let floated = returningFloatedLayout,
           floated.templateID == template.id,
           floated.slots.count == sortedZones.count,
           Set(floated.slots.flatMap(\.windowIDs)) == Set(eligibleWindows.map(\.windowID)) {
            let eligibleByID = Dictionary(eligibleWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            slotWindowAssignments = floated.slots.map { $0.windowIDs.compactMap { eligibleByID[$0] } }
            layoutFrames = floated.slots.map(\.frame)
            debugLog("AutoTiling", " Floating window is back to the same windows: restoring the layout it left")
        } else if let spaceID = savedSpaceID,
           let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: spaceID, screenID: screenID),
           savedInfo.templateID == template.id {
            slotWindowAssignments = restoreWindowAssignmentsFromSaved(
                savedInfo: savedInfo,
                eligibleWindows: eligibleWindows,
                slotCount: sortedZones.count
            )
            savedLayoutInfo = savedInfo
            logger.info("Restored window assignments from saved layout for space '\(spaceID)'")
        } else {
            let sortedWindows = sortWindowsByPriority(eligibleWindows, forScreenID: screenID)
            let eligibleByID = Dictionary(eligibleWindows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            // Groups only hold what doesn't fit; with a slot for every window, the others of a group are new
            let oneWindowPerSlot = eligibleWindows.count <= sortedZones.count
            let placed: [(frame: CGRect, windows: [WindowInfo])] = layoutManager.state(forScreenID: screenID).slots
                .sorted { $0.index < $1.index }
                .compactMap { slot in
                    var windows = slot.windows.compactMap { eligibleByID[$0.windowID] }
                    if oneWindowPerSlot { windows = Array(windows.prefix(1)) }
                    return windows.isEmpty ? nil : (slot.frame, windows)
                }

            if placed.isEmpty {
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                debugLog("AutoTiling", " Assigning \(sortedWindows.count) windows to \(sortedZones.count) slots")
                slotWindowAssignments = layoutManager.assignWindowsToSlots(
                    windows: sortedWindows,
                    slotCount: sortedZones.count,
                    frontmostPID: frontmostPID
                )
            } else {
                if savedSpaceID == nil {
                    layoutFrames = slotFrames(
                        for: template,
                        sortedZones: sortedZones,
                        windowCount: eligibleWindows.count,
                        on: screen,
                        screenID: screenID
                    )
                }
                let placedIDs = Set(placed.flatMap { $0.windows.map(\.windowID) })
                let newWindows = sortedWindows.filter { !placedIDs.contains($0.windowID) }
                debugLog("AutoTiling", " Assigning by position: \(placed.count) placed slot(s), \(newWindows.count) new window(s), \(sortedZones.count) slots")
                slotWindowAssignments = assignSlotsByPosition(
                    placed: placed,
                    newWindows: newWindows,
                    slotFrames: layoutFrames,
                    newestTakesLargest: previousTemplate?.id != template.id
                )
            }
        }
        
        // Build slots from assignments
        // Use saved frames if available (preserves manual resize), otherwise calculate from template
        var newSlots: [Slot] = []
        debugLog("AutoTiling", " Building slots for screen \(screenID), visibleFrame=\(screenFrame), backingScale=\(screen.backingScaleFactor)")
        for (index, zone) in sortedZones.enumerated() {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let defaultFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            
            var finalFrame = layoutFrames[index]
            if let savedInfo = savedLayoutInfo,
               let savedSlot = savedInfo.slots.first(where: { $0.index == index }),
               let savedFrame = savedSlot.frame {
                // Validate saved frame - ensure it's reasonable (not corrupted)
                let screenArea = screenFrame.width * screenFrame.height
                let savedArea = savedFrame.width * savedFrame.height
                let screenCoverage = savedArea / screenArea
                let templateArea = defaultFrame.width * defaultFrame.height
                let sizeRatio = templateArea > 0 ? savedArea / templateArea : 1.0
                
                if screenCoverage > 0.85 {
                    logger.warning("Ignoring corrupted saved frame for slot \(index) - covers \(Int(screenCoverage * 100))% of screen")
                } else if sizeRatio > 1.5 {
                    logger.warning("Ignoring corrupted saved frame for slot \(index) - \(Int(sizeRatio * 100))% of template size")
                } else {
                    finalFrame = savedFrame
                    debugLog("AutoTiling", "   Slot \(index): using SAVED frame \(savedFrame)")
                }
            }

            let slot = Slot(
                id: zone.id,
                index: index,
                frame: finalFrame,
                windows: slotWindowAssignments[index]
            )
            newSlots.append(slot)
        }

        layoutManager.setLayoutWithSlots(template: template, slots: newSlots, forScreenID: screenID)
        slotsVisibleFrame[screenID] = screenManager.visibleCGFrame(for: screen)
        
        // Batch-lookup ALL AXUIElements BEFORE moving any windows
        // This prevents position-based matching errors when windows move during redistribute.
        // Without this, when Window A moves to position X, searching for Window B at position X finds Window A.
        let allWindowsToPosition = newSlots.flatMap { $0.windows }
        let axWindowCache = accessibilityService.batchGetAXWindows(for: allWindowsToPosition)
        debugLog("AutoTiling", "📦 Batch cached \(axWindowCache.count)/\(allWindowsToPosition.count) AXWindows before positioning")
        
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontmostWindowToRaise: WindowInfo?
        var focusedWindowToRaise: WindowInfo?
        var batchTargets: [AccessibilityService.BatchFrameTarget] = []
        var groupedFrontWindowsToRaise: [WindowInfo] = []

        for slot in newSlots {
            guard !slot.isEmpty else { continue }

            // Only a desktop return gets here with a focused window: its slot stays as the user left it
            if let focused = slot.windows.first(where: { isWindowFocused?($0.windowID) == true }) {
                focusedWindowToRaise = focused
                continue
            }

            if slot.windowCount == 1 {
                let window = slot.primaryWindow!
                batchTargets.append(
                    AccessibilityService.BatchFrameTarget(
                        window: window,
                        axWindow: axWindowCache[window.windowID],
                        frame: slot.frame
                    )
                )
                if window.ownerPID == frontmostPID {
                    frontmostWindowToRaise = window
                }
            } else {
                logger.info("Slot \(slot.index + 1) has \(slot.windowCount) windows (group)")
                let frontmostInGroup = slot.windows.first { $0.ownerPID == frontmostPID }

                // Queue non-frontmost windows first (reversed so primary runs last), then frontmost last
                for window in slot.windows.reversed() where window.windowID != frontmostInGroup?.windowID {
                    batchTargets.append(
                        AccessibilityService.BatchFrameTarget(
                            window: window,
                            axWindow: axWindowCache[window.windowID],
                            frame: slot.frame
                        )
                    )
                }

                if let frontmost = frontmostInGroup {
                    batchTargets.append(
                        AccessibilityService.BatchFrameTarget(
                            window: frontmost,
                            axWindow: axWindowCache[frontmost.windowID],
                            frame: slot.frame
                        )
                    )
                    frontmostWindowToRaise = frontmost
                    groupedFrontWindowsToRaise.append(frontmost)
                } else if let activeWindow = slot.primaryWindow {
                    groupedFrontWindowsToRaise.append(activeWindow)
                }
            }
        }

        var startedTransition = false
        let moveResults = accessibilityService.batchSetWindowFrames(batchTargets) { [weak self] in
            startedTransition = true
            self?.onLayoutTransition?(true)
        }

        for target in batchTargets where moveResults[target.window.windowID] == true {
            layoutManager.updateWindowFrame(
                target.window.windowID,
                newFrame: accessibilityService.expectedFrame(target.frame, windowID: target.window.windowID),
                forScreenID: screenID
            )
        }

        // Keep grouped slots' active window on top without activating background apps
        for frontWindow in groupedFrontWindowsToRaise {
            if let axWin = axWindowCache[frontWindow.windowID] {
                accessibilityService.raiseWindow(axWindow: axWin)
            }
        }

        // Keep the focused/frontmost window on top without re-activating an already-frontmost app
        if let frontmost = focusedWindowToRaise ?? frontmostWindowToRaise {
            if frontmost.ownerPID == frontmostPID, let axWin = axWindowCache[frontmost.windowID] {
                accessibilityService.raiseWindow(axWindow: axWin)
            } else {
                accessibilityService.raiseWindow(frontmost)
            }
            logger.info("Raised frontmost window '\(frontmost.title)' after redistribution")
        }

        if startedTransition {
            onLayoutTransition?(false)
        }
        
        let currentWindowIDs = Set(eligibleWindows.map { $0.windowID })
        knownWindowIDsPerScreen[screenID] = currentWindowIDs
        
        // Remove these window IDs from OTHER screen caches.
        // Otherwise a window moved from screen A to B is still in knownWindowIDsPerScreen[A]
        // and is not seen as new when it comes back to A
        for otherScreenID in activeScreens where otherScreenID != screenID {
            knownWindowIDsPerScreen[otherScreenID]?.subtract(currentWindowIDs)
        }
        
        // Return to idle mode after positioning completes.
        // setLayoutWithSlots switches to .applyingLayout and back to .idle after 100 ms;
        // this clears .redistributing in case it is still set
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, let layoutManager = self.layoutManager else { return }
            
            if layoutManager.operationMode == .redistributing {
                layoutManager.setMode(.idle)
            }
            
            let freshWindows = self.windowManager.enumerateWindows()
            let state = layoutManager.state(forScreenID: screenID)
            let managedIDs = state.managedWindowIDs
            let managedWindows = freshWindows.filter { managedIDs.contains($0.windowID) }
            self.onWindowsRedistributed?(managedWindows)
        }
    }
    
    // MARK: - Slot Assignment by Position

    /// Template frames for the zones, in CG coordinates
    private func defaultSlotFrames(for sortedZones: [Zone], on screen: NSScreen) -> [CGRect] {
        let screenFrame = screenManager.visibleFrame(for: screen)
        return sortedZones.map { zone in
            let absoluteFrame = screenManager.calculateAbsoluteFrame(relativeFrame: zone.relativeFrame, in: screenFrame)
            return screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
        }
    }

    /// Frames to lay out with. While the layout and the number of windows stay the same, the slots keep
    /// the sizes the user gave them; any change of the window count brings back the template's sizes
    private func slotFrames(
        for template: GridTemplate,
        sortedZones: [Zone],
        windowCount: Int,
        on screen: NSScreen,
        screenID: String
    ) -> [CGRect] {
        let defaults = defaultSlotFrames(for: sortedZones, on: screen)
        guard let layoutManager else { return defaults }
        let state = layoutManager.state(forScreenID: screenID)
        guard state.template?.id == template.id,
              state.slots.count == defaults.count,
              state.managedWindowIDs.count == windowCount else { return defaults }
        let visible = screenManager.visibleCGFrame(for: screen)
        let laidOutFor = slotsVisibleFrame[screenID] ?? visible
        debugLog("AutoTiling", " Same layout and \(windowCount) window(s): keeping the current slot sizes")
        return state.slots.sorted { $0.index < $1.index }.map { screenManager.rescale($0.frame, from: laidOutFor, to: visible) }
    }

    /// Each slot's windows go to the nearest slot of the new layout, so a layout change only resizes them.
    /// New windows take the slots left over, in fill order; with none left they join their app's slot or the last one.
    /// With `newestTakesLargest`, a layout with one clearly larger slot gives it to the newest window
    private func assignSlotsByPosition(
        placed: [(frame: CGRect, windows: [WindowInfo])],
        newWindows: [WindowInfo],
        slotFrames: [CGRect],
        newestTakesLargest: Bool = false
    ) -> [[WindowInfo]] {
        var assignments: [[WindowInfo]] = Array(repeating: [], count: slotFrames.count)
        guard !slotFrames.isEmpty else { return assignments }

        // With fewer windows than slots a template fills only its first slots (Center Focus puts one window in the center)
        let usableSlots = max(1, min(slotFrames.count, placed.count + newWindows.count))
        let usableFrames = Array(slotFrames.prefix(usableSlots))

        var used = Array(repeating: false, count: usableFrames.count)
        var remainingNewWindows = newWindows
        // Only while the new window gets a slot of its own, so no placed window is pushed into a group
        if newestTakesLargest, let newest = newWindows.first, placed.count < usableFrames.count,
           let largest = Self.clearlyLargestSlot(in: usableFrames) {
            assignments[largest] = [newest]
            used[largest] = true
            remainingNewWindows.removeFirst()
            debugLog("AutoTiling", "   Newest window '\(newest.ownerName)' takes the large slot \(largest + 1)")
        }

        let costs = placed.map { group in
            usableFrames.map { hypot(group.frame.midX - $0.midX, group.frame.midY - $0.midY) }
        }

        // At most 8 slots, so an exhaustive search for the least total movement is cheap
        let mustPlace = min(placed.count, used.filter { !$0 }.count)
        var best: [Int?] = []
        var bestCost = CGFloat.infinity
        var current: [Int?] = []

        func search(_ group: Int, _ cost: CGFloat, _ placedCount: Int) {
            guard cost < bestCost else { return }
            if group == placed.count {
                if placedCount == mustPlace {
                    bestCost = cost
                    best = current
                }
                return
            }
            for slot in usableFrames.indices where !used[slot] {
                used[slot] = true
                current.append(slot)
                search(group + 1, cost + costs[group][slot], placedCount + 1)
                current.removeLast()
                used[slot] = false
            }
            if placed.count - group > mustPlace - placedCount {
                current.append(nil)
                search(group + 1, cost, placedCount)
                current.removeLast()
            }
        }
        search(0, 0, 0)

        var leftover: [WindowInfo] = []
        for (group, slot) in best.enumerated() {
            if let slot {
                assignments[slot] = placed[group].windows
            } else {
                leftover.append(contentsOf: placed[group].windows)
            }
        }

        for window in remainingNewWindows + leftover {
            if let free = assignments.prefix(usableSlots).firstIndex(where: { $0.isEmpty }) {
                assignments[free] = [window]
                continue
            }
            let sameApp = assignments.prefix(usableSlots).firstIndex { slotWindows in
                slotWindows.contains {
                    if let bundleID = window.bundleIdentifier, let other = $0.bundleIdentifier { return bundleID == other }
                    return $0.ownerName == window.ownerName
                }
            }
            assignments[sameApp ?? usableSlots - 1].append(window)
        }

        return assignments
    }

    /// The slot at least 1.5 times the area of every other one (the big slot of 1 + 2, the center of 2 + 1 + 2)
    private static func clearlyLargestSlot(in frames: [CGRect]) -> Int? {
        let areas = frames.map { $0.width * $0.height }
        guard areas.count >= 2, let largest = areas.indices.max(by: { areas[$0] < areas[$1] }) else { return nil }
        let runnerUp = areas.indices.filter { $0 != largest }.map { areas[$0] }.max() ?? 0
        return areas[largest] >= runnerUp * 1.5 ? largest : nil
    }

    // MARK: - Dynamic Template Selection
    
    private func selectTemplate(for windowCount: Int) -> GridTemplate? {
        guard let templateID = preferences.templateID(for: windowCount) else {
            return activeTemplate ?? allTemplates.first
        }
        
        return allTemplates.first { $0.id == templateID } ?? activeTemplate
    }
    
    // MARK: - Smart Window Assignment
    // Window-to-slot assignment itself lives in WindowLayoutManager.assignWindowsToSlots()
    
    private func filterEligibleWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        let tiledIDs = knownWindowIDsPerScreen.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }
        return windows.filter { window in
            // Exclude small windows (likely dialogs, color pickers, popovers)
            let minSize = WindowManager.minimumTilableSize
            guard window.frame.width >= minSize && window.frame.height >= minSize else {
                logger.debug("Excluding small window: '\(window.title)' (\(Int(window.frame.width))x\(Int(window.frame.height)))")
                return false
            }
            
            // Exclude dialogs, sheets, and floating windows using WindowClassifier.
            // A tiled window stays while it can't be told apart for a moment: while it is resized, its
            // accessibility frame and the window list disagree, and dropping it rearranges every window
            switch WindowClassifier.shared.classify(window).decision {
            case .tilable:
                break
            case .unknown where tiledIDs.contains(window.windowID):
                break
            default:
                logger.debug("Excluding non-tilable window: '\(window.title)'")
                return false
            }

            if isWindowFloating?(window.windowID) == true {
                return false
            }
            
            return true
        }
    }
    
    private func filterWindowsOnScreen(_ windows: [WindowInfo], screen: NSScreen) -> [WindowInfo] {
        let screenFrame = screen.frame
        
        return windows.filter { window in
            let windowCenter = CGPoint(
                x: window.frame.midX,
                y: window.frame.midY
            )
            
            // Convert window center from CG coordinates to AppKit coordinates
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
            let appKitY = primaryScreenHeight - windowCenter.y
            let appKitCenter = CGPoint(x: windowCenter.x, y: appKitY)
            
            return screenFrame.contains(appKitCenter)
        }
    }
    
    /// Sort windows by priority for zone assignment
    /// Newest/most recently activated window gets the first (largest) zone
    /// - Parameters:
    ///   - screenID: Screen ID for per-screen cache lookup (optional, uses all caches if nil)
    private func sortWindowsByPriority(_ windows: [WindowInfo], forScreenID screenID: String? = nil) -> [WindowInfo] {
        let frontApp = NSWorkspace.shared.frontmostApplication
        
        let knownIDs: Set<CGWindowID>
        if let screenID = screenID {
            knownIDs = knownWindowIDsPerScreen[screenID] ?? []
        } else {
            knownIDs = knownWindowIDsPerScreen.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }
        }
        let newWindowIDs = Set(windows.map { $0.windowID }).subtracting(knownIDs)

        // Windows already in slots keep their order, including the user's swaps
        var currentSlotIndex: [CGWindowID: Int] = [:]
        if let screenID, let layoutManager {
            for slot in layoutManager.state(forScreenID: screenID).slots {
                for slotWindow in slot.windows where currentSlotIndex[slotWindow.windowID] == nil {
                    currentSlotIndex[slotWindow.windowID] = slot.index
                }
            }
        }

        return windows.sorted { w1, w2 in
            let w1IsNew = newWindowIDs.contains(w1.windowID)
            let w2IsNew = newWindowIDs.contains(w2.windowID)

            if w1IsNew != w2IsNew {
                return w1IsNew
            }

            if let i1 = currentSlotIndex[w1.windowID], let i2 = currentSlotIndex[w2.windowID], i1 != i2 {
                return i1 < i2
            }

            let w1IsFront = w1.ownerPID == frontApp?.processIdentifier
            let w2IsFront = w2.ownerPID == frontApp?.processIdentifier
            
            if w1IsFront != w2IsFront {
                return w1IsFront
            }
            
            // Then sort by window ID (HIGHER IDs = newer windows = first in list)
            return w1.windowID > w2.windowID
        }
    }
    
    /// Restore window-to-slot assignments from saved layout info
    /// Matches windows by bundleIdentifier or ownerName to preserve order across Space switches
    private func restoreWindowAssignmentsFromSaved(
        savedInfo: SavedLayoutInfo,
        eligibleWindows: [WindowInfo],
        slotCount: Int
    ) -> [[WindowInfo]] {
        guard slotCount > 0 else { return [] }
        guard !eligibleWindows.isEmpty else { return Array(repeating: [], count: slotCount) }
        
        var slotAssignments: [[WindowInfo]] = Array(repeating: [], count: slotCount)
        var matchedWindowIDs = Set<CGWindowID>()
        
        debugLog("AutoTiling", " Restoring window assignments from saved layout (\(savedInfo.slots.count) slots)")
        
        for savedSlot in savedInfo.slots {
            guard savedSlot.index < slotCount else { continue }
            
            let matchingWindow = eligibleWindows.first { window in
                guard !matchedWindowIDs.contains(window.windowID) else { return false }
                
                if let savedBundle = savedSlot.bundleIdentifier,
                   let windowBundle = window.bundleIdentifier,
                   savedBundle == windowBundle {
                    return true
                }
                
                if let savedOwner = savedSlot.ownerName,
                   window.ownerName == savedOwner {
                    return true
                }
                
                return false
            }
            
            if let window = matchingWindow {
                slotAssignments[savedSlot.index].append(window)
                matchedWindowIDs.insert(window.windowID)
                debugLog("AutoTiling", "   Slot \(savedSlot.index + 1): restored '\(window.ownerName)' (expected '\(savedSlot.ownerName ?? "?")')")
            }
        }
        
        let unmatchedWindows = eligibleWindows.filter { !matchedWindowIDs.contains($0.windowID) }
        if !unmatchedWindows.isEmpty {
            debugLog("AutoTiling", "   \(unmatchedWindows.count) unmatched windows to distribute:")
            for w in unmatchedWindows {
                debugLog("AutoTiling", "     - '\(w.ownerName)' (\(w.bundleIdentifier ?? "no bundle"))")
            }
            
            var emptySlotIndices: [Int] = []
            for i in 0..<slotCount {
                if slotAssignments[i].isEmpty {
                    emptySlotIndices.append(i)
                }
            }
            debugLog("AutoTiling", "   Empty slot indices: \(emptySlotIndices)")
            
            for window in unmatchedWindows {
                if let emptySlotIndex = emptySlotIndices.first {
                    slotAssignments[emptySlotIndex].append(window)
                    emptySlotIndices.removeFirst()
                    debugLog("AutoTiling", "   Slot \(emptySlotIndex + 1): new window '\(window.ownerName)'")
                } else {
                    var targetSlot: Int? = nil
                    
                    for (index, windowsInSlot) in slotAssignments.enumerated() {
                        if let existingWindow = windowsInSlot.first {
                            if let windowBundle = window.bundleIdentifier,
                               let existingBundle = existingWindow.bundleIdentifier,
                               windowBundle == existingBundle {
                                targetSlot = index
                                break
                            }
                            if window.ownerName == existingWindow.ownerName {
                                targetSlot = index
                                break
                            }
                        }
                    }
                    
                    let finalSlot = targetSlot ?? (slotCount - 1)
                    slotAssignments[finalSlot].append(window)
                    debugLog("AutoTiling", "   Slot \(finalSlot + 1): grouped new window '\(window.ownerName)'")
                }
            }
        }
        
        let totalAssigned = slotAssignments.reduce(0) { $0 + $1.count }
        debugLog("AutoTiling", " Restored \(totalAssigned)/\(eligibleWindows.count) windows")
        
        return slotAssignments
    }
}
