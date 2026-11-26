//
//  AppState+WindowMonitoring.swift
//  Rapto
//
//  Watching windows open, close and move, and grouping them in Manual mode.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Window Monitoring
    
    /// Setup lightweight window monitoring for grouping (event-based, no polling)
    func setupWindowMonitoring() {
        debugLog("AppState"," Setting up window monitoring for grouping")
        
        let currentWindows = windowManager.enumerateWindows()
        lastKnownWindowIDs = Set(currentWindows.map { $0.windowID })
        
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkGroupsForClosedWindows()
                self?.groupIndicatorManager?.updateIndicators()
            }
        }
        manualModeObservers.append(activateObserver)
        
        debugLog("AppState"," Window monitoring set up (event-based)")
    }

    // MARK: - Auto-Grouping for Manual Mode
    
    func setupManualModeGroupingObservers() {
        // Check if ANY screen has active layout (not just default state)
        let anyScreenHasActiveLayout = !layoutManager.screensWithActiveLayouts.isEmpty
        
        // Also check for screens with saved Manual mode config (layout not yet active)
        // This allows observers to be set up BEFORE any windows appear on empty screens
        let hasManualModeSavedConfig = NSScreen.screens.contains { screen in
            let screenID = screenManager.identifier(for: screen)
            let screenSpaceID = spaceID(for: screen)
            let config = configuration(forSpaceID: screenSpaceID, screenID: screenID)
            return config.mode == .manualAssignment && config.templateID != nil
        }
        
        let shouldSetupObservers = anyScreenHasActiveLayout || hasManualModeSavedConfig
        
        debugLog("AppState"," ========== setupManualModeGroupingObservers ==========")
        debugLog("AppState"," isGroupingEnabled=\(isGroupingEnabled), autoGroupSameApp=\(autoGroupSameApp), anyScreenActive=\(anyScreenHasActiveLayout), hasSavedConfig=\(hasManualModeSavedConfig)")
        
        removeManualModeGroupingObservers()
        
        guard isGroupingEnabled, autoGroupSameApp, shouldSetupObservers else {
            debugLog("AppState"," Guard failed, not setting up observers")
            return
        }
        
        logger.info("Setting up manual mode grouping observers")
        
        let currentWindows = windowManager.enumerateWindows()
        lastKnownWindowIDs = Set(currentWindows.map { $0.windowID })
        debugLog("AppState"," Initial window IDs: \(lastKnownWindowIDs)")
        
        // Use NSWorkspace notifications - more reliable than AXObserver for many apps
        // didActivateApplicationNotification fires when app becomes active (new window opened)
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract app before async context
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                if let app = app {
                    debugLog("AppState"," App activated: \(app.localizedName ?? "unknown") PID=\(app.processIdentifier)")
                    self?.handleAppActivated(app)
                }
            }
        }
        manualModeObservers.append(activateObserver)
        
        // Also observe deactivation to check for closed/minimized windows
        let deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.checkGroupsForClosedWindows()
                }
            }
        }
        manualModeObservers.append(deactivateObserver)
        
        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract app before async context
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                if let app = app {
                    debugLog("AppState"," App launched: \(app.localizedName ?? "unknown") PID=\(app.processIdentifier)")
                    self?.watchLaunchedApp(app)
                }
            }
        }
        manualModeObservers.append(launchObserver)
        
        var pidsToMonitor = Set<pid_t>()
        debugLog("AppState"," screensWithActiveLayouts: \(layoutManager.screensWithActiveLayouts)")
        for screenID in layoutManager.screensWithActiveLayouts {
            let screenState = layoutManager.state(forScreenID: screenID)
            debugLog("AppState"," Screen \(screenID): \(screenState.slots.count) slots, isActive=\(screenState.isActive)")
            for slot in screenState.slots {
                for window in slot.windows {
                    pidsToMonitor.insert(window.ownerPID)
                    debugLog("AppState"," Adding PID \(window.ownerPID) (\(window.ownerName)) to monitor")
                }
            }
        }
        debugLog("AppState"," Total PIDs to monitor: \(pidsToMonitor.count)")
        for pid in pidsToMonitor {
            setupAXObserver(for: pid)
        }
        
        // Setup global event monitor to detect when ANY window becomes key
        // This catches new windows from apps that don't have AXObserver set up
        manualModeClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.debounceWindowCheck()
        }
        
        logger.info("Manual mode observers set up, tracking \(self.lastKnownWindowIDs.count) windows (event-based, no polling)")
    }
    
    /// Schedule a debounced check for new windows (unified mechanism)
    /// All sources of new window detection should use this method
    private func scheduleNewWindowCheck(delay: TimeInterval = 0.3) {
        newWindowCheckWorkItem?.cancel()
        newWindowCheckWorkItem = DispatchWorkItem { [weak self] in
            self?.checkForNewWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: newWindowCheckWorkItem!)
    }
    
    /// A launched app can create its first window seconds later. Watching its window creation places
    /// that window at once; the later checks cover apps that aren't ready for Accessibility yet.
    private func watchLaunchedApp(_ app: NSRunningApplication) {
        scheduleNewWindowCheck(delay: 0.5)
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        for delay in [0.3, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, NSRunningApplication(processIdentifier: pid) != nil else { return }
                self.setupAXObserver(for: pid)
                if delay > 1 {
                    self.scheduleNewWindowCheck(delay: 0)
                }
            }
        }
    }

    private func debounceWindowCheck() {
        scheduleNewWindowCheck()
    }
    
    /// Schedule a debounced update of group indicators
    /// Used when windows are moved/resized (e.g., exiting fullscreen)
    private func debounceIndicatorUpdate() {
        indicatorUpdateWorkItem?.cancel()
        indicatorUpdateWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.groupIndicatorManager?.updateIndicators()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: indicatorUpdateWorkItem!)
    }
    
    /// Handle app activation - check for new windows or slot conflicts
    /// Works across all screens with active layouts
    private func handleAppActivated(_ app: NSRunningApplication) {
        let appPID = app.processIdentifier
        let appBundleID = app.bundleIdentifier
        let appName = app.localizedName ?? ""
        
        debugLog("AppState"," handleAppActivated: \(appName), PID=\(appPID), bundleID=\(appBundleID ?? "nil")")
        
        for screenID in layoutManager.screensWithActiveLayouts {
            let layoutState = layoutManager.state(forScreenID: screenID)
            guard layoutState.isActive else { continue }
            
            debugLog("AppState"," Screen \(screenID) slots: \(layoutState.slots.compactMap { $0.ownerName })")
            
            let isRelevantApp = layoutState.slots.contains { slot in
                slot.windows.contains { window in
                    window.ownerPID == appPID ||
                    // Only compare bundleIdentifiers if both are non-nil to avoid nil == nil matching
                    (window.bundleIdentifier != nil && appBundleID != nil && window.bundleIdentifier == appBundleID) ||
                    window.ownerName == appName
                }
            }
            
            // Check if this app was in ORIGINAL layout but slot was taken by another app
            let isOriginalApp = layoutState.slots.contains { slot in
                slot.originalBundleID == appBundleID ||
                slot.originalOwnerName == appName
            }
            
            let hasEmptySlot = layoutState.slots.contains { $0.isEmpty }
            
            debugLog("AppState"," Screen \(screenID): isRelevantApp=\(isRelevantApp), isOriginalApp=\(isOriginalApp), hasEmptySlot=\(hasEmptySlot)")
        }
        
        // Always check for new windows - tryGroupDuplicateAppsToFreeSlot can free a slot
        debugLog("AppState"," Scheduling new window check")
        scheduleNewWindowCheck()
    }
    
    func setupAXObserver(for pid: pid_t) {
        guard axObservers[pid] == nil else { return }
        // It is watched once it answers again (see appIsRespondingAgain)
        guard AppResponsiveness.isResponding(pid) else { return }
        
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let appState = Unmanaged<AppState>.fromOpaque(refcon).takeUnretainedValue()
            let notificationName = notification as String

            // During a slot resize these are the echo of Rapto's own moves. The final moves after
            // mouse up come through again and schedule the one check that is needed.
            if ResizeEchoGate.shared.isClosed,
               notificationName == kAXWindowMovedNotification as String ||
               notificationName == kAXWindowResizedNotification as String {
                return
            }

            Task { @MainActor in
                
                if notificationName == kAXWindowCreatedNotification as String {
                    appState.handleWindowCreated()
                } else if notificationName == kAXWindowMiniaturizedNotification as String {
                    // Window minimized - preserve slot assignment, just update tracking
                    appState.handleWindowMinimized()
                } else if notificationName == kAXUIElementDestroyedNotification as String {
                    appState.handleWindowClosed()
                } else if notificationName == kAXWindowDeminiaturizedNotification as String {
                    appState.handleWindowRestored()
                } else if notificationName == kAXWindowMovedNotification as String ||
                          notificationName == kAXWindowResizedNotification as String {
                    // Window moved/resized - could be exiting fullscreen or cross-screen drag
                    appState.debounceIndicatorUpdate()
                    // Also check for cross-screen moves that need integration
                    appState.handleWindowMovedOrResized()
                }
            }
        }, &observer)
        
        guard result == .success, let observer = observer else {
            debugLog("AppState"," Failed to create AXObserver for PID \(pid)")
            return
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Each of the six requests below waits for the app. If the first one never comes back,
        // the others would not either
        AppResponsiveness.shared.ask(pid) {
            AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        }
        guard AppResponsiveness.isResponding(pid) else {
            debugLog("AppState"," PID \(pid) is not responding, not watching it for now")
            return
        }
        AXObserverAddNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXWindowDeminiaturizedNotification as CFString, refcon)
        // Track window move/resize to detect exit from fullscreen
        AXObserverAddNotification(observer, appElement, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXWindowResizedNotification as CFString, refcon)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        
        axObservers[pid] = observer
        debugLog("AppState"," AXObserver set up for PID \(pid) (created, minimized, destroyed, deminiaturized, moved, resized)")
    }
    
    // MARK: - Apps That Stop Responding

    /// Called once per hang, when the first request to the app timed out.
    func appStoppedResponding(_ pid: pid_t) {
        showNotRespondingNotice(for: pid)
        groupIndicatorManager?.updateIndicators()
    }

    func showNotRespondingNotice(for pid: pid_t) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        spaceBarController.showNotice(AppResponsiveness.notRespondingMessage(appName: name), on: screenManager.activeScreen())
    }

    /// The app answered a probe, or quit. Whatever was skipped while it hung is caught up with here.
    func appIsRespondingAgain(_ pid: pid_t) {
        groupIndicatorManager?.updateIndicators()
        guard NSRunningApplication(processIdentifier: pid) != nil else { return }
        let isInLayout = layoutManager.screensWithActiveLayouts.contains { screenID in
            layoutManager.state(forScreenID: screenID).slots.contains { slot in
                slot.windows.contains { $0.ownerPID == pid }
            }
        }
        if isInLayout, !manualModeObservers.isEmpty {
            setupAXObserver(for: pid)
        }
        scheduleNewWindowCheck()
        // The app has only just answered; give it a moment before it is asked to move windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.returnWindowsToSlots(ofApp: pid)
        }
    }

    /// A swap, a new gap, a resized slot or a Space return could not reach the windows of an app
    /// that was not answering: the layout changed and they stayed where they were. Put them into
    /// their slots now without reshuffling the rest of the desktop.
    private func returnWindowsToSlots(ofApp pid: pid_t) {
        guard AppResponsiveness.isResponding(pid), layoutManager.canPerform(operation: .idle) else { return }
        let visibleWindows = windowManager.enumerateWindows()
        for screenID in layoutManager.screensWithActiveLayouts {
            let state = layoutManager.state(forScreenID: screenID)
            for (index, slot) in state.slots.enumerated() {
                for window in slot.windows where window.ownerPID == pid {
                    // Only windows of the desktop on screen are listed; the rest are placed when
                    // their desktop is restored. Focus Mode and floating windows are off their
                    // slot on purpose.
                    guard let current = visibleWindows.first(where: { $0.windowID == window.windowID }),
                          focusModeService?.isFocusedWindow(window.windowID) != true,
                          floatingWindowService?.isFloating(windowID: window.windowID) != true else { continue }
                    let target = accessibilityService.expectedFrame(slot.frame, windowID: window.windowID)
                    guard AppState.isOffItsSlot(windowFrame: current.frame, slotFrame: target) else { continue }
                    debugLog("AppState", " '\(current.ownerName)' answers again: back into slot \(index) from \(current.frame)")
                    positionWindowInZone(current, zoneIndex: index, forScreenID: screenID)
                }
            }
        }
        groupIndicatorManager?.updateIndicators()
    }

    /// Whether a window is somewhere else than its slot, beyond what rounding gives.
    nonisolated static func isOffItsSlot(windowFrame: CGRect, slotFrame: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(windowFrame.minX - slotFrame.minX) > tolerance || abs(windowFrame.minY - slotFrame.minY) > tolerance
            || abs(windowFrame.width - slotFrame.width) > tolerance || abs(windowFrame.height - slotFrame.height) > tolerance
    }

    /// Handle window restored from dock - check if slot needs to be freed
    private func handleWindowRestored() {
        debugLog("AppState"," Window restored from dock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            
            guard self.layoutManager.canPerform(operation: .idle) else {
                debugLog("AppState"," handleWindowRestored blocked by mode: \(self.layoutManager.operationMode.description)")
                return
            }
            
            // Do NOT update lastKnownWindowIDs here!
            // handleWindowCreated may be called right after this, and updating
            // lastKnownWindowIDs would prevent new window detection.
            // New windows will be detected via handleWindowCreated -> scheduleNewWindowCheck

            self.focusModeService?.returnPendingWindows()
            self.floatingWindowService?.returnPendingWindows()

            self.groupIndicatorManager?.updateIndicators()
        }
    }
    
    private func handleWindowCreated() {
        scheduleNewWindowCheck(delay: 0.2)
    }
    
    /// Preserves window in slot so it can be restored to the same position
    private func handleWindowMinimized() {
        debugLog("AppState"," Window minimized - preserving slot assignment")
        // Small delay for window state to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, UserSession.isActive else { return }
            
            let currentWindows = self.windowManager.enumerateWindows()
            let currentWindowIDs = Set(currentWindows.map { $0.windowID })
            
            self.focusModeService?.endIfFocusedWindowHidden(visibleWindowIDs: currentWindowIDs)
            self.floatingWindowService?.endForHiddenWindows()

            // Update lastKnownWindowIDs but DON'T remove from slots
            // This ensures the window can be restored to its original slot
            self.lastKnownWindowIDs = currentWindowIDs
            
            self.windowIDsAtLayoutApply = self.windowIDsAtLayoutApply.intersection(currentWindowIDs)
            debugLog("AppState"," Updated windowIDsAtLayoutApply: \(self.windowIDsAtLayoutApply.count) remaining")
            
            // Fill empty slots by promoting windows from groups (2+ windows).
            // Single windows are never moved — only secondary windows from groups.
            self.fillEmptySlotsFromGroups()
            
            self.groupIndicatorManager?.updateIndicators()
        }
    }
    
    /// Checks if window moved to a screen with active layout and integrates it
    private func handleWindowMovedOrResized() {
        guard isGroupingEnabled else { return }
        
        // Check if ANY screen is in Manual mode (not just active screen)
        // This is needed for multi-monitor where active screen might be in different mode
        let hasAnyManualModeScreen = NSScreen.screens.contains { screen in
            mode(for: screen) == .manualAssignment
        }
        guard hasAnyManualModeScreen else { return }
        
        guard !layoutManager.screensWithActiveLayouts.isEmpty else { return }
        
        // A slot resize moves every window of the neighbouring groups many times a second. A check per
        // notification reads all windows each time and keeps Rapto from moving them along, so only the
        // notifications of the final moves after mouse up schedule a check.
        guard windowResizeService?.resizeInProgress != true else { return }
        integrationCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkForWindowsNeedingIntegration()
        }
        integrationCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    /// Check for windows on screens with layouts that aren't in any slot
    /// This handles windows moved between screens - integrates them into the target screen's layout
    private func checkForWindowsNeedingIntegration() {
        guard UserSession.isActive else { return }
        // MARK: - Workaround: The layout in memory can belong to the desktop that was just left
        // Cause: This check runs half a second after a window moved. A desktop switch can
        //        happen in that time, and the new desktop's layout is restored only when the
        //        switch is handled. Until then every window of the new desktop looks like one
        //        that is in no slot, and they were all put into the old desktop's layout.
        // Context: Nothing is integrated while the Desktops Bar is moving a window or a
        //          desktop change is not handled yet. The restore that follows places them.
        guard !SpaceBarController.isDrivingMouse else {
            debugLog("AppState", " Integration check skipped: the Desktops Bar is moving a window")
            return
        }
        if spaceManager.catchUpWithDesktopChange() || hasUnhandledDesktopChange() {
            debugLog("AppState", " Integration check skipped: desktop changed under us")
            return
        }
        let currentWindows = windowManager.enumerateWindows()
        
        for screenID in layoutManager.screensWithActiveLayouts where !isAutoTilingScreen(screenID) {
            let layoutState = layoutManager.state(forScreenID: screenID)
            guard layoutState.isActive else { continue }
            
            let windowIDsInSlots = Set(layoutState.slots.flatMap { $0.windows.map { $0.windowID } })
            
            for window in currentWindows {
                let windowScreen = screenManager.screen(for: window)
                let windowScreenID = screenManager.identifier(for: windowScreen)
                
                guard windowScreenID == screenID else { continue }
                guard !windowIDsInSlots.contains(window.windowID) else { continue }
                
                let isInAnySlot = layoutManager.screensWithActiveLayouts.contains { otherScreenID in
                    let otherState = layoutManager.state(forScreenID: otherScreenID)
                    return otherState.slots.contains { $0.contains(windowID: window.windowID) }
                }
                guard !isInAnySlot else { continue }
                
                debugLog("AppState", " Found unmanaged window '\(window.title)' on screen '\(screenID)' - integrating")
                tryAutoGroupWindow(window, forScreenID: screenID)
            }
        }
    }
    
    /// SpaceManager already knows a display's new desktop, but handleDisplaySpaceChanged
    /// (delivered in a Task) has not restored that desktop's layout yet.
    private func hasUnhandledDesktopChange() -> Bool {
        spaceManager.allDisplayIDs.contains { displayID in
            guard let handled = previousDisplaySpaceIDs[displayID] else { return false }
            return spaceManager.currentSpaceID(forDisplayID: displayID) != handled
        }
    }

    /// Windows hidden while another user was in front come back with the same IDs.
    /// Treat the current list as the baseline so they are not taken for new windows.
    func resyncWindowsAfterSessionReturn() {
        handleScreensChanged()
        if spaceManager.currentSpaceID != previousSpaceID {
            handleSpaceChanged(to: spaceManager.currentSpaceID)
        }
        for (displayID, oldSpaceID) in previousDisplaySpaceIDs {
            if let spaceID = spaceManager.currentSpaceID(forDisplayID: displayID), spaceID != oldSpaceID {
                handleDisplaySpaceChanged(displayID: displayID, to: spaceID)
            }
        }
        lastKnownWindowIDs = Set(windowManager.enumerateWindows().map { $0.windowID })
        autoTilingService?.updateKnownWindowsWithoutRedistribute()
        groupIndicatorManager?.updateIndicators()
    }
    
    /// Removes window from slot and redistributes if needed
    private func handleWindowClosed() {
        debugLog("AppState"," Element destroyed - checking for closed windows")
        // Small delay for window state to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, UserSession.isActive else { return }

            // Indicators stay hidden while a window floats or is in focus mode, so a closed one must be let go
            let forgotFloating = self.floatingWindowService?.cleanupClosedWindows() ?? false
            let leftFocusMode = self.focusModeService?.endIfFocusedWindowClosed() ?? false
            if forgotFloating || leftFocusMode {
                self.groupIndicatorManager?.updateIndicators()
            }
            
            let currentWindows = self.windowManager.enumerateWindows()
            let currentWindowIDs = Set(currentWindows.map { $0.windowID })
            
            // kAXUIElementDestroyedNotification fires for ALL UI elements (tooltips, menus,
            // popovers), not just windows. Skip expensive sync if no tracked window disappeared.
            if !self.lastKnownWindowIDs.isEmpty && currentWindowIDs.isSuperset(of: self.lastKnownWindowIDs) {
                debugLog("AppState"," No windows closed (non-window element destroyed), skipping sync")
                return
            }
            
            // Only drop the closed ones: a window that opened meanwhile (a document replacing an Open panel)
            // must stay unknown, or checkForNewWindows won't place it
            self.lastKnownWindowIDs.formIntersection(currentWindowIDs)
            
            self.windowIDsAtLayoutApply = self.windowIDsAtLayoutApply.intersection(currentWindowIDs)
            debugLog("AppState"," Updated windowIDsAtLayoutApply: \(self.windowIDsAtLayoutApply.count) remaining")
            
            // Sync slots: remove closed windows from the slots of every Manual screen.
            // The parameterless version only cleans the active screen;
            // we must iterate all screens to avoid ghost indicators on non-active monitors
            // skipRedistribution must be true here because visibleWindowIDs
            // contains windows from ALL screens — redistribution would move cross-screen
            // windows into wrong slots. fillEmptySlotsFromGroups() handles this correctly.
            let manualScreenIDs = self.layoutManager.screenStates.keys.filter { !self.isAutoTilingScreen($0) }
            guard !manualScreenIDs.isEmpty else { return }
            for screenID in manualScreenIDs {
                self.layoutManager.syncWithVisibleWindows(currentWindowIDs, forScreenID: screenID, skipRedistribution: true)
            }
            
            self.fillEmptySlotsFromGroups()
            
            self.groupIndicatorManager?.updateIndicators()
        }
    }
    
    /// The group window that moves into the slot `emptyIndex` whose windows are all minimized:
    /// a visible window behind the front one of another group
    nonisolated static func groupWindowToPromote(into emptyIndex: Int, slots: [Slot], visibleWindowIDs: Set<CGWindowID>) -> (slotIndex: Int, window: WindowInfo)? {
        for (index, slot) in slots.enumerated() where index != emptyIndex && slot.windowCount >= 2 {
            if let window = slot.secondaryWindows.first(where: { visibleWindowIDs.contains($0.windowID) }) {
                return (index, window)
            }
        }
        return nil
    }
    
    /// Fill empty slots by promoting windows from groups
    /// Works across all screens with active layouts
    private func fillEmptySlotsFromGroups() {
        guard isGroupingEnabled, UserSession.isActive else { return }
        
        guard layoutManager.canPerform(operation: .idle) else {
            debugLog("AppState"," fillEmptySlotsFromGroups blocked by mode: \(layoutManager.operationMode.description)")
            return
        }
        
        let currentWindows = windowManager.enumerateWindows()
        let visibleWindowIDs = Set(currentWindows.map { $0.windowID })
        
        for screenID in layoutManager.screensWithActiveLayouts where !isAutoTilingScreen(screenID) {
            let screenState = layoutManager.state(forScreenID: screenID)
            guard screenState.isActive else { continue }
            
            let slots = screenState.slots
            
            for (slotIndex, slot) in slots.enumerated() {
                guard !slot.windows.isEmpty else { continue }
                
                let hasAnyVisibleWindow = slot.windows.contains { visibleWindowIDs.contains($0.windowID) }
                
                // Slot needs filling only if ALL its windows are minimized/hidden
                if !hasAnyVisibleWindow {
                    debugLog("AppState"," Slot \(slotIndex) on screen \(screenID) has no visible windows (all \(slot.windowCount) minimized)")
                    
                    if let (groupSlotIndex, windowToPromote) = Self.groupWindowToPromote(into: slotIndex, slots: slots, visibleWindowIDs: visibleWindowIDs) {
                        debugLog("AppState"," Promoting '\(windowToPromote.title)' from slot \(groupSlotIndex) to slot \(slotIndex) on screen \(screenID)")
                        
                        layoutManager.removeWindow(windowToPromote.windowID, forScreenID: screenID)
                        
                        layoutManager.assignWindow(windowToPromote, to: slotIndex, forScreenID: screenID)
                        
                        positionWindowInZone(windowToPromote, zoneIndex: slotIndex, forScreenID: screenID)
                        
                        setupAXObserver(for: windowToPromote.ownerPID)
                        
                        if let screen = screenManager.screen(for: screenID) {
                            layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: screen), screenID: screenID)
                        }
                        
                        logger.info("Promoted '\(windowToPromote.title)' to empty slot \(slotIndex) on screen \(screenID)")
                        
                        // Only fill one slot at a time per screen
                        break
                    }
                }
            }
        }
    }
    
    func removeManualModeGroupingObservers() {
        for observer in manualModeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        manualModeObservers.removeAll()
        if let monitor = manualModeClickMonitor {
            NSEvent.removeMonitor(monitor)
            manualModeClickMonitor = nil
        }
        
        for (pid, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            debugLog("AppState"," Removed AXObserver for PID \(pid)")
        }
        axObservers.removeAll()
        
        lastKnownWindowIDs.removeAll()
    }
    
    private func checkForNewWindows() {
        guard !isPaused else { return }
        guard !isCheckingForNewWindows, UserSession.isActive else {
            debugLog("AppState"," checkForNewWindows already in progress or session in background, skipping")
            return
        }
        // While the Desktops Bar carries a window to another desktop, the windows of both
        // desktops are on screen at once and the incoming ones are not new
        guard !SpaceBarController.isDrivingMouse else {
            debugLog("AppState"," checkForNewWindows put off: the Desktops Bar is moving a window")
            scheduleNewWindowCheck(delay: 0.5)
            return
        }
        isCheckingForNewWindows = true
        defer { isCheckingForNewWindows = false }
        
        let anyScreenHasActiveLayout = !layoutManager.screensWithActiveLayouts.isEmpty
        
        debugLog("AppState"," checkForNewWindows called")
        debugLog("AppState"," isGroupingEnabled=\(isGroupingEnabled), autoGroupSameApp=\(autoGroupSameApp)")
        debugLog("AppState"," currentMode=\(currentMode.rawValue), anyScreenActive=\(anyScreenHasActiveLayout)")
        
        guard isGroupingEnabled, autoGroupSameApp else {
            debugLog("AppState"," Grouping not enabled, skipping")
            return
        }
        
        // Check per-screen: need at least one screen with manual mode (active layout OR saved config)
        // Don't use global currentMode - it may differ from per-screen modes
        let hasAnyManualModeScreen = NSScreen.screens.contains { screen in
            let screenID = screenManager.identifier(for: screen)
            let layoutState = layoutManager.state(forScreenID: screenID)
            
            if layoutState.isActive {
                let screenSpaceID = self.spaceID(for: screen)
                let screenConfig = configuration(forSpaceID: screenSpaceID, screenID: screenID)
                return screenConfig.mode == .manualAssignment
            }
            
            // Screen has saved manual mode config (layout not yet active) - use per-screen spaceID
            let screenSpaceID = self.spaceID(for: screen)
            let config = configuration(forSpaceID: screenSpaceID, screenID: screenID)
            return config.mode == .manualAssignment && config.templateID != nil
        }
        
        guard hasAnyManualModeScreen else {
            debugLog("AppState"," No screen with manual mode (active or saved config), skipping")
            return
        }
        
        let listedWindows = windowManager.enumerateWindows()
        // While macOS animates between desktops the list holds the windows of all of them
        let hiddenWindowIDs = spaceManager.windowsOnHiddenDesktops(among: Set(listedWindows.map { $0.windowID }))
        if !hiddenWindowIDs.isEmpty {
            debugLog("AppState"," Leaving out \(hiddenWindowIDs.count) window(s) of other desktops")
        }
        let currentWindows = listedWindows.filter { !hiddenWindowIDs.contains($0.windowID) }
        let currentWindowIDs = Set(currentWindows.map { $0.windowID })
        let isInFocusMode = currentWindowIDs.contains { focusModeService?.isFocusedWindow($0) == true }
        debugLog("AppState"," Current windows: \(currentWindowIDs.count), Last known: \(lastKnownWindowIDs.count)")

        // Activating an app on another desktop shows that desktop before macOS reports the switch.
        // Its windows are not new: the desktop's own layout is restored once the switch is handled.
        if spaceManager.catchUpWithDesktopChange() || hasUnhandledDesktopChange() {
            debugLog("AppState"," Desktop changed under us - skipping new window detection")
            lastKnownWindowIDs = currentWindowIDs
            return
        }
        
        // When focus mode is active, don't track window changes to prevent layout instability
        // Windows may appear/disappear temporarily due to focus expansion
        if isInFocusMode {
            debugLog("AppState"," Focus mode active - skipping new window detection")
            return
        }
        
        let newWindowIDs = currentWindowIDs.subtracting(lastKnownWindowIDs)
        
        // Filter out windows that are already in slots on ANY screen - they're not truly "new"
        // This handles the case where a window was minimized and is now restored,
        // AND prevents stealing windows from other screens (e.g. auto-tiling on second monitor)
        var windowIDsInSlots = Set<CGWindowID>()
        for screenID in layoutManager.screensWithActiveLayouts {
            let screenState = layoutManager.state(forScreenID: screenID)
            for slot in screenState.slots {
                for window in slot.windows {
                    windowIDsInSlots.insert(window.windowID)
                }
            }
        }
        // Also check default screen state
        for slot in layoutManager.state.slots {
            for window in slot.windows {
                windowIDsInSlots.insert(window.windowID)
            }
        }
        let trulyNewWindowIDs = newWindowIDs.subtracting(windowIDsInSlots)
        
        if !trulyNewWindowIDs.isEmpty {
            logger.info("Detected \(trulyNewWindowIDs.count) new window(s)")
            
            for newWindowID in trulyNewWindowIDs {
                if let newWindow = currentWindows.first(where: { $0.windowID == newWindowID }) {
                    tryAutoGroupWindow(newWindow)
                }
            }
        }
        
        checkForClosedWindowsInGroups(currentWindowIDs: currentWindowIDs)
        
        lastKnownWindowIDs = currentWindowIDs
    }
    
    func checkGroupsForClosedWindows() {
        guard isGroupingEnabled else { return }
        let currentWindows = windowManager.enumerateWindows()
        let currentWindowIDs = Set(currentWindows.map { $0.windowID })
        checkForClosedWindowsInGroups(currentWindowIDs: currentWindowIDs)
    }
    
    /// The slot that holds at least half of the window, so a window already in place keeps its slot.
    private func slotContainingWindow(_ window: WindowInfo, forScreenID screenID: String) -> Int? {
        let windowArea = window.frame.width * window.frame.height
        guard windowArea > 0 else { return nil }
        let slots = layoutManager.state(forScreenID: screenID).slots
        let best = slots.indices.max { a, b in
            let ia = slots[a].frame.intersection(window.frame), ib = slots[b].frame.intersection(window.frame)
            return ia.width * ia.height < ib.width * ib.height
        }
        guard let index = best else { return nil }
        let overlap = slots[index].frame.intersection(window.frame)
        return overlap.width * overlap.height / windowArea >= 0.5 ? index : nil
    }

    /// Restore leaves windows where they are, but a window on all desktops still has the frame
    /// of the desktop it was last fitted on.
    func fitWindowsOnAllDesktops(_ windowsOnScreen: [WindowInfo], forScreenID screenID: String) {
        let visible = Dictionary(windowsOnScreen.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let tolerance: CGFloat = 4
        for (slotIndex, slot) in layoutManager.state(forScreenID: screenID).slots.enumerated() {
            for window in slot.windows {
                guard let current = visible[window.windowID],
                      spaceBarController.isOnAllDesktops(window.windowID) else { continue }
                let frame = current.frame
                let fits = abs(frame.minX - slot.frame.minX) <= tolerance && abs(frame.minY - slot.frame.minY) <= tolerance &&
                    abs(frame.width - slot.frame.width) <= tolerance && abs(frame.height - slot.frame.height) <= tolerance
                guard !fits else { continue }
                debugLog("AppState", " '\(current.ownerName)' is on all desktops, fitting it into slot \(slotIndex) of this desktop")
                positionWindowInZone(current, zoneIndex: slotIndex, forScreenID: screenID)
            }
        }
    }

    /// Decides which slot each unassigned window takes after a Manual layout is restored:
    /// - Pass 1: windows already sitting over an empty slot keep that slot without moving.
    /// - Pass 2: remaining windows sitting over an occupied slot take the first remaining empty
    ///   slot instead of piling into a group while another slot sits empty; when no slot is empty,
    ///   they join the slot they sit over. Windows over no slot return `nil` for `tryAutoGroupWindow`.
    nonisolated static func unassignedRestoreSlots(
        containingSlots: [Int?],
        initialWindowCounts: [Int]
    ) -> [Int?] {
        var counts = initialWindowCounts
        var assignments = Array<Int?>(repeating: nil, count: containingSlots.count)
        var remainingIndices: [Int] = []

        for (index, containing) in containingSlots.enumerated() {
            if let slot = containing, counts.indices.contains(slot), counts[slot] == 0 {
                assignments[index] = slot
                counts[slot] += 1
            } else {
                remainingIndices.append(index)
            }
        }

        for index in remainingIndices {
            guard let containing = containingSlots[index], counts.indices.contains(containing) else {
                continue
            }
            if let empty = counts.firstIndex(of: 0) {
                assignments[index] = empty
                counts[empty] += 1
            } else {
                assignments[index] = containing
                counts[containing] += 1
            }
        }

        return assignments
    }

    /// Process windows that were not assigned to any slot during layout restoration
    /// This handles windows that appeared while the user was on a different Space or mode
    func processUnassignedWindowsAfterRestore(
        allWindowsOnScreen: [WindowInfo],
        restoredWindows: [WindowInfo],
        forScreenID screenID: String,
        repositionMoved: Bool = true
    ) {
        // Callers using `state.allWindows` only list each slot's front window; include every
        // window already restored into any slot so restored group members are never reassigned.
        let currentState = layoutManager.state(forScreenID: screenID)
        var managedWindowIDs = Set(restoredWindows.map { $0.windowID })
        for slot in currentState.slots {
            for window in slot.windows {
                managedWindowIDs.insert(window.windowID)
            }
        }
        let minSize = WindowClassifier.minimumTilableSize
        let unassignedWindows = allWindowsOnScreen.filter { window in
            !managedWindowIDs.contains(window.windowID) &&
            window.windowID != SpaceBarController.movingWindowID &&
            !isWindowFloating(windowID: window.windowID) &&
            window.frame.width >= minSize &&
            window.frame.height >= minSize &&
            WindowClassifier.shared.classify(window).decision == .tilable
        }
        
        guard !unassignedWindows.isEmpty else {
            debugLog("AppState", " No unassigned windows after restore")
            return
        }
        
        debugLog("AppState", " Found \(unassignedWindows.count) unassigned windows after restore, processing...")
        
        let containingSlots = unassignedWindows.map { slotContainingWindow($0, forScreenID: screenID) }
        let targetSlots = AppState.unassignedRestoreSlots(
            containingSlots: containingSlots,
            initialWindowCounts: currentState.slots.map { $0.windows.count }
        )

        for (index, window) in unassignedWindows.enumerated() {
            debugLog("AppState", "   - '\(window.ownerName)' - '\(window.title)'")
            let containing = containingSlots[index]
            if let slotIndex = targetSlots[index] {
                if slotIndex != containing {
                    layoutManager.assignWindow(window, to: slotIndex, forScreenID: screenID)
                    if repositionMoved {
                        positionWindowInZone(window, zoneIndex: slotIndex, forScreenID: screenID)
                    }
                    setupAXObserver(for: window.ownerPID)
                    debugLog("AppState", "   Moved to empty slot \(slotIndex) instead of joining occupied slot \(containing ?? -1)")
                } else {
                    layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: screenID)
                    setupAXObserver(for: window.ownerPID)
                    debugLog("AppState", "   Joined slot \(slotIndex) where it already sits")
                }
            } else {
                tryAutoGroupWindow(window, forScreenID: screenID)
            }
        }
        
        let screen = screenManager.screen(for: screenID) ?? screenManager.activeScreen()
        let targetSpaceID = spaceID(for: screen)
        layoutManager.saveLayoutInfo(forSpaceID: targetSpaceID, screenID: screenID)
        
        let allManagedWindows = layoutManager.state(forScreenID: screenID).allWindows
        if !allManagedWindows.isEmpty {
            windowResizeService?.setManagedLayout(windows: allManagedWindows)
        }
        
        if repositionMoved {
            groupIndicatorManager?.updateIndicators()
        }
    }
    
    /// Lets floating and focus mode drop closed windows, then refreshes the highlight and indicators.
    /// Slots are not synced here: handleWindowClosed does that, and minimized windows keep
    /// their slot (handleWindowMinimized).
    private func checkForClosedWindowsInGroups(currentWindowIDs: Set<CGWindowID>) {
        debugLog("AppState"," checkForClosedWindowsInGroups: \(currentWindowIDs.count) visible windows")
        
        floatingWindowService?.cleanupClosedWindows()
        focusModeService?.endIfFocusedWindowClosed()
        // A player's own full screen hides the window without changing the desktop
        focusModeService?.returnPendingWindows()
        floatingWindowService?.returnPendingWindows()
        windowHighlightService?.windowsChanged()

        groupIndicatorManager?.updateIndicators()
    }
    
    /// Try to auto-group a new window with an existing slot, or fill empty slot
    /// - Parameters:
    ///   - screenID: Optional screen ID to use. If nil, determines from window position.
    func tryAutoGroupWindow(_ newWindow: WindowInfo, forScreenID screenID: String? = nil) {
        let targetScreenID: String
        if let explicitScreenID = screenID {
            targetScreenID = explicitScreenID
        } else {
            let windowScreen = screenManager.screen(for: newWindow)
            let positionBasedScreenID = screenManager.identifier(for: windowScreen)
            
            let positionScreenState = layoutManager.state(forScreenID: positionBasedScreenID)
            let appExistsOnPositionScreen = positionScreenState.slots.contains { slot in
                slot.windows.contains { window in
                    window.ownerPID == newWindow.ownerPID ||
                    // Only compare bundleIdentifiers if both are non-nil to avoid nil == nil matching
                    (window.bundleIdentifier != nil && window.bundleIdentifier == newWindow.bundleIdentifier) ||
                    window.ownerName == newWindow.ownerName
                }
            }
            
            if appExistsOnPositionScreen || !redirectNewWindowsToAppMonitor {
                targetScreenID = positionBasedScreenID
                if !redirectNewWindowsToAppMonitor {
                    logger.info("App '\(newWindow.ownerName)' redirect disabled, using position screen \(positionBasedScreenID)")
                } else {
                    logger.info("App '\(newWindow.ownerName)' exists on position screen \(positionBasedScreenID), using it")
                }
            } else {
                // App does NOT exist on position screen - check if it exists on another screen
                // This handles the case when macOS creates new window at last saved position
                // on the old screen, but user has moved the app to a different screen
                var screenWithSameApp: String? = nil
                let activeLayouts = layoutManager.screensWithActiveLayouts
                
                for activeScreenID in activeLayouts where activeScreenID != positionBasedScreenID {
                    let screenState = layoutManager.state(forScreenID: activeScreenID)
                    let hasSameApp = screenState.slots.contains { slot in
                        slot.windows.contains { window in
                            window.ownerPID == newWindow.ownerPID ||
                            // Only compare bundleIdentifiers if both are non-nil to avoid nil == nil matching
                            (window.bundleIdentifier != nil && window.bundleIdentifier == newWindow.bundleIdentifier) ||
                            window.ownerName == newWindow.ownerName
                        }
                    }
                    if hasSameApp {
                        screenWithSameApp = activeScreenID
                        break
                    }
                }
                
                if let appScreenID = screenWithSameApp {
                    targetScreenID = appScreenID
                    logger.info("App '\(newWindow.ownerName)' moved to screen \(appScreenID), redirecting from \(positionBasedScreenID)")
                } else {
                    targetScreenID = positionBasedScreenID
                    logger.info("App '\(newWindow.ownerName)' not in any layout, using position screen \(positionBasedScreenID)")
                }
            }
        }
        
        debugLog("AppState"," ========== tryAutoGroupWindow ==========")
        debugLog("AppState"," New window: '\(newWindow.title)', Owner: \(newWindow.ownerName), PID: \(newWindow.ownerPID)")
        debugLog("AppState"," Target screen: \(targetScreenID)")
        
        // Check operation mode - don't interfere during other operations
        guard layoutManager.canPerform(operation: .idle) else {
            debugLog("AppState"," Operation blocked by mode: \(layoutManager.operationMode.description)")
            return
        }
        
        if isWindowFloating(windowID: newWindow.windowID) {
            debugLog("AppState"," Window is floating, skipping auto-group")
            return
        }
        
        let classification = WindowClassifier.shared.classify(newWindow)
        if classification.decision != .tilable {
            debugLog("AppState"," Window not tilable (\(classification.reasonDescription)), skipping auto-group")
            return
        }
        
        // Additional size check for auto-grouping (catches small utility windows)
        let minSize = WindowClassifier.minimumTilableSize
        if newWindow.frame.width < minSize || newWindow.frame.height < minSize {
            debugLog("AppState"," Window too small for tiling (\(Int(newWindow.frame.width))x\(Int(newWindow.frame.height))), skipping")
            return
        }
        
        var layoutState = layoutManager.state(forScreenID: targetScreenID)
        
        // Skip if window is already in any slot on this screen
        // This prevents duplicate entries when processUnassignedWindowsAfterRestore is called
        let alreadyInSlot = layoutState.slots.contains { slot in
            slot.windows.contains { $0.windowID == newWindow.windowID }
        }
        if alreadyInSlot {
            debugLog("AppState"," Window already in layout (windowID: \(newWindow.windowID)), skipping")
            return
        }
        
        // Get the correct spaceID for the target screen (each display can have independent Spaces)
        let targetScreen = screenManager.screen(for: targetScreenID) ?? screenManager.activeScreen()
        let targetSpaceID = spaceID(for: targetScreen)
        
        let screenConfig = configuration(
            forSpaceID: targetSpaceID,
            screenID: targetScreenID
        )
        
        if !layoutState.isActive {
            debugLog("AppState"," No active layout for screen \(targetScreenID), checking saved config")
            debugLog("AppState"," screenConfig.mode=\(screenConfig.mode.rawValue), templateID=\(screenConfig.templateID?.uuidString ?? "nil")")
            
            // A saved layout keeps the slot sizes the user set; building a fresh one from the template would overwrite them
            if screenConfig.mode == .manualAssignment,
               let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: targetSpaceID, screenID: targetScreenID),
               let savedTemplate = allTemplates.first(where: { $0.id == savedInfo.templateID }),
               layoutManager.restoreLayout(
                   from: savedInfo,
                   template: savedTemplate,
                   currentWindows: filterWindowsOnScreen(windowManager.enumerateWindows(), screen: targetScreen),
                   forScreenID: targetScreenID
               ) {
                debugLog("AppState"," Restored saved layout '\(savedTemplate.name)' for screen \(targetScreenID) before placing '\(newWindow.ownerName)'")
                layoutState = layoutManager.state(forScreenID: targetScreenID)
                if snapBackEnabled {
                    snapBackService?.start(forScreenID: targetScreenID)
                }
                setupSwapHotkeys()
                groupIndicatorManager?.updateIndicators()
                // Restore matches a window that overlaps its saved slot but doesn't move it; a new window has to be fitted
                if let slotIndex = layoutState.slots.firstIndex(where: { slot in
                    slot.windows.contains { $0.windowID == newWindow.windowID }
                }) {
                    positionWindowInZone(newWindow, zoneIndex: slotIndex, forScreenID: targetScreenID)
                    setupAXObserver(for: newWindow.ownerPID)
                    layoutManager.saveLayoutInfo(forSpaceID: targetSpaceID, screenID: targetScreenID)
                    groupIndicatorManager?.updateIndicators()
                    return
                }
            } else if screenConfig.mode == .manualAssignment,
               let templateID = screenConfig.templateID,
               let template = allTemplates.first(where: { $0.id == templateID }) {
                
                debugLog("AppState"," Found saved template '\(template.name)' for screen \(targetScreenID), initializing layout")
                
                layoutManager.setLayout(template: template, windows: [], forScreenID: targetScreenID)
                
                layoutState = layoutManager.state(forScreenID: targetScreenID)
                
                layoutManager.assignWindow(newWindow, to: 0, forScreenID: targetScreenID)
                positionWindowInZone(newWindow, zoneIndex: 0, forScreenID: targetScreenID)
                setupAXObserver(for: newWindow.ownerPID)
                layoutManager.saveLayoutInfo(forSpaceID: targetSpaceID, screenID: targetScreenID)
                groupIndicatorManager?.updateIndicators()
                
                if snapBackEnabled {
                    snapBackService?.start(forScreenID: targetScreenID)
                }
                
                setupSwapHotkeys()
                
                logger.info("Initialized layout '\(template.name)' with '\(newWindow.title)' on screen \(targetScreenID)")
                return
            }
            
            if !layoutState.isActive {
                debugLog("AppState"," No saved template config or not in manual mode, skipping")
                return
            }
        }
        
        // Check if this screen is in manual mode - only process manual mode screens
        // Exception: If we redirected the window to a different screen (AutoTiling), move it there
        if screenConfig.mode != .manualAssignment {
            let windowScreen = screenManager.screen(for: newWindow)
            let windowScreenID = screenManager.identifier(for: windowScreen)
            
            if windowScreenID != targetScreenID {
                logger.info("Moving '\(newWindow.ownerName)' to AutoTiling screen \(targetScreenID)")
                
                if let targetNSScreen = screenManager.screen(for: targetScreenID) {
                    let screenFrame = screenManager.visibleFrame(for: targetNSScreen)
                    let appKitX = screenFrame.midX - newWindow.frame.width / 2
                    let appKitY = screenFrame.midY - newWindow.frame.height / 2
                    let appKitFrame = CGRect(x: appKitX, y: appKitY, width: newWindow.frame.width, height: newWindow.frame.height)
                    // Convert to CG coordinates (AppKit has bottom-left origin, CG has top-left)
                    let cgFrame = screenManager.convertToCGCoordinates(frame: appKitFrame, for: targetNSScreen)
                    
                    accessibilityService.setWindowPosition(newWindow, position: cgFrame.origin)
                    
                    // AutoTilingService will pick it up - trigger redistribution after a short delay
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 sec
                        self?.autoTilingService?.redistributeNow(forScreenID: targetScreenID)
                    }
                }
            }
            
            debugLog("AppState"," Screen \(targetScreenID) is not in manual mode (mode=\(screenConfig.mode.rawValue)), skipping further processing")
            return
        }
        
        // Check if this is actually a "renewed" window (same PID but different windowID)
        // This happens after fullscreen exit when macOS creates a new window ID for the same window
        // Also check title - if titles differ, these are different windows (e.g. two Xcode projects)
        // Empty titles should NOT be considered as matching - multiple windows can have empty titles
        // If another same-title window is visible on this screen, do NOT treat as renewal
        let hasSameTitleSiblingOnScreen: Bool
        if !newWindow.title.isEmpty {
            let sameTitleWindowsOnScreen = windowManager.enumerateWindows().filter { window in
                guard window.ownerPID == newWindow.ownerPID,
                      window.title == newWindow.title else {
                    return false
                }
                let windowScreenID = screenManager.identifier(for: screenManager.screen(for: window))
                return windowScreenID == targetScreenID
            }
            hasSameTitleSiblingOnScreen = sameTitleWindowsOnScreen.contains { $0.windowID != newWindow.windowID }
            if hasSameTitleSiblingOnScreen {
                debugLog("AppState"," Renewal check skipped: another '\(newWindow.title)' window is visible on screen \(targetScreenID)")
            }
        } else {
            hasSameTitleSiblingOnScreen = false
        }
        for (slotIndex, slot) in layoutState.slots.enumerated() {
            for existingWindow in slot.windows {
                // Skip if either title is empty - can't reliably identify window by empty title
                let hasValidTitle = !existingWindow.title.isEmpty && !newWindow.title.isEmpty
                
                if existingWindow.ownerPID == newWindow.ownerPID &&
                   existingWindow.windowID != newWindow.windowID &&
                   existingWindow.ownerName == newWindow.ownerName &&
                   hasValidTitle &&
                   existingWindow.title == newWindow.title &&
                   !hasSameTitleSiblingOnScreen {  // Same title only counts if no sibling window is visible
                    debugLog("AppState"," Window '\(newWindow.title)' appears to be renewed (old ID: \(existingWindow.windowID), new ID: \(newWindow.windowID))")
                    
                    layoutManager.updateWindowInSlot(slotIndex: slotIndex, oldWindowID: existingWindow.windowID, newWindow: newWindow, forScreenID: targetScreenID)
                    debugLog("AppState"," ✅ Updated window ID in slot \(slotIndex)")
                    return
                }
            }
        }
        
        let appAlreadyInLayout = layoutState.slots.contains { slot in
            slot.windows.contains { window in
                window.ownerPID == newWindow.ownerPID ||
                // Only compare bundleIdentifiers if both are non-nil to avoid nil == nil matching
                (window.bundleIdentifier != nil && window.bundleIdentifier == newWindow.bundleIdentifier) ||
                window.ownerName == newWindow.ownerName
            }
        }
        
        // Skip windows that existed when layout was applied AND app is NOT in layout
        // (windows of apps already in layout should be allowed to group)
        if windowIDsAtLayoutApply.contains(newWindow.windowID) && !appAlreadyInLayout {
            debugLog("AppState"," Window existed at layout apply time and app not in layout, skipping")
            return
        }
        
        // Sync slots with actually visible windows before checking for empty slots.
        // This removes stale window references (closed but not cleaned up) so that
        // slot.isEmpty reflects physical reality instead of stale internal state.
        let currentVisibleIDs = Set(windowManager.enumerateWindows().map { $0.windowID })
        layoutManager.syncWithVisibleWindows(currentVisibleIDs, forScreenID: targetScreenID, skipRedistribution: true)
        layoutState = layoutManager.state(forScreenID: targetScreenID)
        
        var slots = layoutState.slots

        // macOS often reopens windows where they stood in the same layout, so a window that
        // opened at an empty slot's corner stays in that slot: untouched if it fills it, fitted otherwise.
        // An occupied slot doesn't keep it while another slot is free: apps reopen where they were last,
        // which may be a group they were put into only because no slot was free then.
        if let (slotIndex, fills) = slotStartingAt(newWindow, in: slots), slots[slotIndex].isEmpty {
            debugLog("AppState"," '\(newWindow.title)' opened at slot \(slotIndex) (fills=\(fills)), keeping it there")
            layoutManager.assignWindow(newWindow, to: slotIndex, forScreenID: targetScreenID)
            if !fills { positionWindowInZone(newWindow, zoneIndex: slotIndex, forScreenID: targetScreenID) }
            setupAXObserver(for: newWindow.ownerPID)
            layoutManager.saveLayoutInfo(forSpaceID: targetSpaceID, screenID: targetScreenID)
            groupIndicatorManager?.updateIndicators()
            return
        }

        for (slotIndex, slot) in slots.enumerated() {
            // Slot is empty only if it has NO windows at all
            // A slot with minimized windows is NOT empty - those windows still belong there
            let isEmpty = slot.isEmpty
            
            if isEmpty {
                debugLog("AppState"," Found empty slot at index \(slotIndex), assigning new window there")
                
                layoutManager.assignWindow(newWindow, to: slotIndex, forScreenID: targetScreenID)
                positionWindowInZone(newWindow, zoneIndex: slotIndex, forScreenID: targetScreenID)
                setupAXObserver(for: newWindow.ownerPID)
                layoutManager.saveLayoutInfo(forSpaceID: targetSpaceID, screenID: targetScreenID)
                groupIndicatorManager?.updateIndicators()
                
                logger.info("Assigned '\(newWindow.title)' to empty slot at index \(slotIndex) on screen \(targetScreenID)")
                return
            }
        }
        
        slots = layoutManager.state(forScreenID: targetScreenID).slots

        if let slotIndex = slotHoldingApp(of: newWindow, in: slots) {
            debugLog("AppState"," '\(newWindow.ownerName)' already sits in slot \(slotIndex), adding the new window there")
            groupWindowWithSlot(newWindow, slotIndex: slotIndex, forScreenID: targetScreenID)
            return
        }

        // With every slot taken, a window reopened exactly over a slot joins that slot's group where it stands
        if let (slotIndex, fills) = slotStartingAt(newWindow, in: slots), fills {
            debugLog("AppState"," '\(newWindow.title)' opened over slot \(slotIndex), grouping it there")
            groupWindowWithSlot(newWindow, slotIndex: slotIndex, forScreenID: targetScreenID, reposition: false)
            return
        }

        debugLog("AppState"," App not in any slot, using round-robin distribution")
        
        var minWindowCount = Int.max
        var targetSlotIndex: Int? = nil
        
        for (index, slot) in slots.enumerated() {
            let windowCount = slot.windowCount
            if windowCount < minWindowCount {
                minWindowCount = windowCount
                targetSlotIndex = index
            }
        }
        
        if let slotIndex = targetSlotIndex {
            debugLog("AppState"," Found slot \(slotIndex) with \(minWindowCount) windows (fewest)")
            groupWindowWithSlot(newWindow, slotIndex: slotIndex, forScreenID: targetScreenID)
            return
        }
        
        debugLog("AppState"," No slots available, window '\(newWindow.title)' will remain free")
        showSlotFullNotification(windowTitle: newWindow.title)
    }
    
    /// The slot with another window of the same app, matched by process first, then by bundle id.
    private func slotHoldingApp(of newWindow: WindowInfo, in slots: [Slot]) -> Int? {
        let others = { (slot: Slot) in slot.windows.filter { $0.windowID != newWindow.windowID } }
        if let index = slots.firstIndex(where: { others($0).contains { $0.ownerPID == newWindow.ownerPID } }) {
            return index
        }
        guard let bundleID = newWindow.bundleIdentifier else { return nil }
        return slots.firstIndex { others($0).contains { $0.bundleIdentifier == bundleID } }
    }

    /// The slot whose top-left corner matches the window's, and whether the window also has the slot's size.
    private func slotStartingAt(_ window: WindowInfo, in slots: [Slot]) -> (index: Int, fills: Bool)? {
        let frame = (windowManager.refreshWindowInfo(for: window.windowID) ?? window).frame
        let tolerance: CGFloat = 4
        guard let index = slots.firstIndex(where: {
            abs($0.frame.minX - frame.minX) <= tolerance && abs($0.frame.minY - frame.minY) <= tolerance
        }) else { return nil }
        let slotFrame = slots[index].frame
        let fills = abs(slotFrame.width - frame.width) <= tolerance && abs(slotFrame.height - frame.height) <= tolerance
        return (index, fills)
    }

    private func showSlotFullNotification(windowTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Rapto"
        content.body = "All slots are in use. '\(windowTitle)' is not managed."
        content.sound = nil
        
        let request = UNNotificationRequest(
            identifier: "slot-full-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("AppState"," Failed to show notification: \(error)")
            }
        }
    }
    
    /// - Parameters:
    ///   - screenID: Target screen ID (uses active screen if nil)
    private func groupWindowWithSlot(_ newWindow: WindowInfo, slotIndex: Int, forScreenID screenID: String? = nil, reposition: Bool = true) {
        let targetScreenID = screenID ?? layoutManager.activeScreenID
        
        guard layoutManager.canPerform(operation: .idle) else {
            debugLog("AppState"," groupWindowWithSlot blocked by mode: \(layoutManager.operationMode.description)")
            return
        }
        
        let layoutState = layoutManager.state(forScreenID: targetScreenID)
        guard slotIndex < layoutState.slots.count else {
            debugLog("AppState"," Invalid slot index \(slotIndex) for screen \(targetScreenID)")
            return
        }
        
        let slot = layoutState.slots[slotIndex]
        let slotOwnerName = slot.ownerName ?? "unknown"
        
        debugLog("AppState"," Grouping '\(newWindow.title)' with slot \(slotIndex) (app: \(slotOwnerName)) on screen \(targetScreenID)")
        
        layoutManager.addWindowToSlot(newWindow, slotIndex: slotIndex, forScreenID: targetScreenID)
        
        layoutManager.setActiveWindow(newWindow.windowID, in: slotIndex, forScreenID: targetScreenID)
        
        let updatedLayoutState = layoutManager.state(forScreenID: targetScreenID)
        let windowCount = updatedLayoutState.slots[slotIndex].windowCount
        debugLog("AppState"," ✅ Added to slot group (now \(windowCount) windows), set as primary")
        logger.info("Auto-grouped window '\(newWindow.title, privacy: .public)' into slot group as primary")
        
        setupAXObserver(for: newWindow.ownerPID)
        
        if reposition {
            positionWindowInZone(newWindow, zoneIndex: slotIndex, forScreenID: targetScreenID)
        }
        
        raiseWindowViaAccessibility(newWindow)
        
        groupIndicatorManager?.updateIndicators()
        
        if let screen = screenManager.screen(for: targetScreenID) {
            layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: screen), screenID: targetScreenID)
        }
    }
    
    /// Position a window in a specific zone (uses current slot frame, preserving any user resizing)
    /// - Parameters:
    ///   - screenID: Target screen ID (uses active screen if nil)
    ///   - attempt: Retry number after a failed placement (0 for the first try)
    func positionWindowInZone(_ window: WindowInfo, zoneIndex: Int, forScreenID screenID: String? = nil, attempt: Int = 0) {
        let targetScreenID = screenID ?? layoutManager.activeScreenID
        let layoutState = layoutManager.state(forScreenID: targetScreenID)
        
        guard zoneIndex < layoutState.slots.count else {
            debugLog("AppState"," positionWindowInZone: Invalid zone \(zoneIndex) for screen \(targetScreenID)")
            return
        }
        
        let cgFrame = layoutState.slots[zoneIndex].frame
        
        // Refresh WindowInfo to get current position
        // The stored WindowInfo may have stale frame data if the window was moved
        // (e.g., promoted from one slot to another)
        let windowToPosition: WindowInfo
        if let freshWindow = windowManager.refreshWindowInfo(for: window.windowID) {
            windowToPosition = freshWindow
            if freshWindow.frame != window.frame {
                debugLog("AppState"," positionWindowInZone: Refreshed stale WindowInfo for '\(window.title)' (old: \(window.frame.origin), new: \(freshWindow.frame.origin))")
            }
        } else {
            // Window may have been closed - try with original anyway
            windowToPosition = window
            debugLog("AppState"," positionWindowInZone: Could not refresh WindowInfo for '\(window.title)', using original")
        }
        
        let windowCurrentScreen = screenManager.identifier(for: screenManager.screen(for: windowToPosition))
        debugLog("AppState"," positionWindowInZone: '\(windowToPosition.title)' zone \(zoneIndex) frame = \(cgFrame) on screen \(targetScreenID), windowCurrentScreen=\(windowCurrentScreen)")
        
        let success = accessibilityService.setWindowFrame(windowToPosition, frame: cgFrame)
        
        if success {
            debugLog("AppState"," Positioned '\(windowToPosition.title)' in zone \(zoneIndex) at \(cgFrame)")
            windowsToPlaceAfterUnlock.removeValue(forKey: window.windowID)
        } else {
            debugLog("AppState"," Failed to position '\(windowToPosition.title)'")
            // The element found for a window that is still being created can belong to another one
            accessibilityService.clearAXCache(for: window.windowID)
            if UserSession.isScreenLocked {
                debugLog("AppState", "Screen is locked, will put '\(windowToPosition.ownerName)' into slot \(zoneIndex + 1) after unlock")
                windowsToPlaceAfterUnlock[window.windowID] = (zoneIndex, targetScreenID)
            } else if attempt < Self.maxPlacementRetries {
                retryPositionWindowInZone(window.windowID, zoneIndex: zoneIndex, screenID: targetScreenID, attempt: attempt + 1)
            }
        }
    }

    // MARK: - Workaround: A window that is still being created can't be moved yet
    // Apps that open a window right after an update, a tab tear-off or an Open panel can refuse
    // the first move. The placement is retried a couple of times while the window keeps its slot.
    
    private static let maxPlacementRetries = 2
    
    private func retryPositionWindowInZone(_ windowID: CGWindowID, zoneIndex: Int, screenID: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let slots = self.layoutManager.state(forScreenID: screenID).slots
            // Skip windows closed, moved to another slot or being dragged by the user meanwhile
            guard NSEvent.pressedMouseButtons == 0,
                  zoneIndex < slots.count,
                  slots[zoneIndex].windows.contains(where: { $0.windowID == windowID }),
                  let window = self.windowManager.refreshWindowInfo(for: windowID) else { return }
            debugLog("AppState", "Retrying to put '\(window.ownerName)' into slot \(zoneIndex + 1), attempt \(attempt)")
            self.positionWindowInZone(window, zoneIndex: zoneIndex, forScreenID: screenID, attempt: attempt)
        }
    }

    // MARK: - Workaround: Windows can't be moved while the screen is locked
    // An app updated or launched behind the lock screen opens its window there, and macOS refuses
    // to move it. Such windows are put into their slots once the screen is unlocked.
    
    func observeScreenUnlock() {
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.windowsToPlaceAfterUnlock.isEmpty else { return }
                // Windows are not accessible again the moment the lock screen goes away
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.placeWindowsAfterUnlock()
                }
            }
        }
    }
    
    private func placeWindowsAfterUnlock() {
        let pending = windowsToPlaceAfterUnlock
        windowsToPlaceAfterUnlock.removeAll()
        let openWindows = Dictionary(windowManager.enumerateWindows().map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        for (windowID, target) in pending {
            let slots = layoutManager.state(forScreenID: target.screenID).slots
            // Skip windows closed, moved to another slot or left on another desktop meanwhile
            guard let window = openWindows[windowID],
                  target.zoneIndex < slots.count,
                  slots[target.zoneIndex].windows.contains(where: { $0.windowID == windowID }) else { continue }
            debugLog("AppState", "Screen unlocked, putting '\(window.ownerName)' into slot \(target.zoneIndex + 1) it couldn't be moved to before")
            positionWindowInZone(window, zoneIndex: target.zoneIndex, forScreenID: target.screenID)
        }
        groupIndicatorManager?.updateIndicators()
    }
}
