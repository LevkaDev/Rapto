//
//  AppState+Spaces.swift
//  Rapto
//
//  Desktop (Space) changes and windows moved from the Desktops Bar.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Space Change Handling

    func setupSpaceChangeHandler() {
        previousSpaceID = spaceManager.currentSpaceID
        
        for displayID in spaceManager.allDisplayIDs {
            if let spaceID = spaceManager.currentSpaceID(forDisplayID: displayID) {
                previousDisplaySpaceIDs[displayID] = spaceID
            }
        }
        
        spaceManager.onSpaceChanged = { [weak self] newSpaceID in
            Task { @MainActor in
                self?.handleSpaceChanged(to: newSpaceID)
            }
        }
        
        spaceManager.onDisplaySpaceChanged = { [weak self] displayID, newSpaceID in
            Task { @MainActor in
                self?.handleDisplaySpaceChanged(displayID: displayID, to: newSpaceID)
            }
        }
    }
    
    /// Handle when user switches to a different Space on the PRIMARY display
    /// This only handles global work (highlight, overlay). Per-screen work is handled
    /// by handleDisplaySpaceChanged which fires for ALL displays including primary.
    func handleSpaceChanged(to newSpaceID: String) {
        guard UserSession.isActive else { return }
        let oldSpaceID = previousSpaceID
        previousSpaceID = newSpaceID
        
        debugLog("AppState"," Space changed (primary): '\(oldSpaceID)' -> '\(newSpaceID)' (per-screen work delegated to handleDisplaySpaceChanged)")
        
        // Recreate highlight window on new Space (stationary windows stay on their original Space)
        if !isPaused {
            windowHighlightService?.recreateForNewSpace()
        }
        
        if isOverlayVisible {
            isOverlayVisible = false
        }
        
        // All per-screen work (saving layout, loading config, mode changes, restoring layouts)
        // happens only in handleDisplaySpaceChanged, whose callback fires for every display,
        // the primary one included.
        
        objectWillChange.send()
    }
    
    func handleDisplaySpaceChanged(displayID: String, to newSpaceID: String) {
        // The login window's desktop shows up here during a user switch; the return is reconciled in resyncWindowsAfterSessionReturn
        guard UserSession.isActive else { return }
        let oldSpaceID = previousDisplaySpaceIDs[displayID] ?? ""
        previousDisplaySpaceIDs[displayID] = newSpaceID
        
        guard !isPaused else {
            debugLog("AppState", " Display Space changed while paused: skipping restore")
            return
        }
        
        // Find the screen for this display (displayID is a CGS UUID, not our screenID)
        guard let screen = screenManager.screen(forDisplayID: displayID) else {
            debugLog("AppState", " handleDisplaySpaceChanged: Screen not found for displayID=\(displayID)")
            return
        }
        
        let screenID = screenManager.identifier(for: screen)
        let screenName = screenManager.displayName(for: screen)
        
        debugLog("AppState", " Display Space changed: display=\(displayID) screen=\(screenName) space='\(oldSpaceID)' -> '\(newSpaceID)'")
        if !oldSpaceID.isEmpty {
            let screenState = layoutManager.state(forScreenID: screenID)
            if screenState.isActive {
                updateSlotFramesFromWindows(forScreenID: screenID)
                layoutManager.saveLayoutInfo(forSpaceID: oldSpaceID, screenID: screenID)
            }
        }
        
        let screenConfig = configuration(forSpaceID: newSpaceID, screenID: screenID)
        
        // An empty oldSpaceID means a newly detected display. Treat it as a restore, not as a
        // mode change, which would clear the layout.
        let oldScreenConfig = configuration(forSpaceID: oldSpaceID, screenID: screenID)
        let isNewDisplay = oldSpaceID.isEmpty
        let modeChanged = !isNewDisplay && screenConfig.mode != oldScreenConfig.mode
        
        if modeChanged {
            debugLog("AppState", " Display \(displayID): Mode changed from \(oldScreenConfig.mode.displayName) to \(screenConfig.mode.displayName)")
            handleModeChange(to: screenConfig.mode, for: screen, inheritAutoTilingLayout: false)
        } else if isNewDisplay {
            debugLog("AppState", " Display \(displayID): New display detected, mode=\(screenConfig.mode.displayName) - starting services without clearing layout")
            startServicesForScreen(screenID: screenID, mode: screenConfig.mode, screen: screen)
        } else {
            debugLog("AppState", " Display \(displayID): Same mode (\(screenConfig.mode.displayName)) - restoring layout")
            
            switch screenConfig.mode {
            case .none:
                // Nothing to restore here; other screens may still have groups
                break
                
            case .manualAssignment:
                restoreLayoutForDisplaySpace(spaceID: newSpaceID, screenID: screenID, screen: screen)
                
            case .autoTiling:
                if autoTilingService?.isActive(forScreenID: screenID) ?? false {
                    // Restore saved layout with custom frames if user had resized windows
                    restoreAutoTilingLayoutOnSpaceReturn(spaceID: newSpaceID, screenID: screenID, screen: screen)
                }
                groupIndicatorManager?.updateIndicators()
                
            case .dragSnap:
                if !(dragSnapService?.isActive(forScreenID: screenID) ?? false) {
                    dragSnapService?.start(forScreenID: screenID)
                }
            }
            
            updateHighlightForCurrentMode()
        }
        
        // Trigger a delayed refresh to avoid transient windows during Space transitions
        scheduleGroupIndicatorRefreshAfterSpaceChange()

        // Runs after the restore above, so a moved window is not matched to a slot by its old frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.placeSpaceBarMovedWindows(onSpaceKey: newSpaceID, displayID: displayID)
        }

        // Entering and leaving full screen end with a desktop change; wait for the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let visibleWindowIDs = Set(self.windowManager.enumerateWindows().map(\.windowID))
            self.focusModeService?.endIfFocusedWindowHidden(visibleWindowIDs: visibleWindowIDs)
            self.floatingWindowService?.endForHiddenWindows()
            self.focusModeService?.returnPendingWindows()
            self.floatingWindowService?.returnPendingWindows()
            self.groupIndicatorManager?.updateIndicators()
            if let settledScreen = self.screenManager.screen(forDisplayID: displayID) {
                self.maybeShowSecondDesktopHint(on: settledScreen)
                self.maybeShowWindowFlowOrWorkspacesHint(on: settledScreen)
            }
        }
    }

    // MARK: - Windows moved from the desktops bar

    /// Remember the Manual slot a window is leaving, so moving it back puts it there again.
    func spaceBarWillMoveWindow(_ windowID: CGWindowID, fromSpaceKey spaceKey: String, displayID: String) {
        guard let screen = screenManager.screen(forDisplayID: displayID) else { return }
        let screenID = screenManager.identifier(for: screen)
        guard configuration(forSpaceID: spaceKey, screenID: screenID).mode == .manualAssignment else { return }

        var slotIndex: Int?
        var window: WindowInfo?
        if spaceID(for: screen) == spaceKey {
            let state = layoutManager.state(forScreenID: screenID)
            slotIndex = state.slotIndex(for: windowID)
            window = slotIndex.flatMap { index in state.slots[index].windows.first { $0.windowID == windowID } }
        }
        // A move that starts from another desktop switches to this one first, and the window can
        // be grabbed before the layout of this desktop is back in place. What was saved when the
        // desktop was last left still knows the slot.
        if slotIndex == nil,
           let info = windowManager.refreshWindowInfo(for: windowID),
           let saved = layoutManager.loadSavedLayoutInfo(forSpaceID: spaceKey, screenID: screenID) {
            slotIndex = AppState.savedSlotIndex(pid: info.ownerPID, bundleID: info.bundleIdentifier, in: saved.slots)
            window = info
        }
        guard let slotIndex, let window else {
            logger.info("Desktops bar: no slot to remember for window \(windowID) leaving '\(spaceKey, privacy: .public)'")
            return
        }
        logger.info("Desktops bar: '\(window.ownerName, privacy: .public)' leaves slot \(slotIndex + 1) of '\(spaceKey, privacy: .public)'")
        spaceBarSlotMemory[windowID, default: [:]][spaceKey] = slotIndex
        var saved = UserDefaults.standard.dictionary(forKey: Self.spaceBarSlotMemoryKey) as? [String: Int] ?? [:]
        saved[Self.spaceBarSlotKey(for: window, spaceKey: spaceKey, screenID: screenID)] = slotIndex
        UserDefaults.standard.set(saved, forKey: Self.spaceBarSlotMemoryKey)
    }

    /// The slot of a saved layout that held a window of this app: by process first, then by app.
    nonisolated static func savedSlotIndex(pid: pid_t, bundleID: String?, in slots: [SavedLayoutInfo.SavedSlotInfo]) -> Int? {
        if let slot = slots.first(where: { $0.groupPIDs?.contains(pid) == true }) {
            return slot.index
        }
        guard let bundleID else { return nil }
        let match = slots.first { $0.groupBundleIDs?.contains(bundleID) == true } ?? slots.first { $0.bundleIdentifier == bundleID }
        return match?.index
    }

    private static let spaceBarSlotMemoryKey = "spaceBarSlotMemory"

    /// Window ids change when an app restarts, so the stored slot is per app.
    private static func spaceBarSlotKey(for window: WindowInfo, spaceKey: String, screenID: String) -> String {
        "\(spaceKey)|\(screenID)|\(window.bundleIdentifier ?? window.ownerName)"
    }

    /// `isFromThisSession`: this very window left that slot since Rapto was started. Otherwise
    /// the slot is what was stored for its app some time ago, maybe days.
    private func rememberedSpaceBarSlot(for window: WindowInfo, spaceKey: String, screenID: String) -> (slot: Int, isFromThisSession: Bool)? {
        if let slot = spaceBarSlotMemory[window.windowID]?[spaceKey] {
            return (slot, true)
        }
        let saved = UserDefaults.standard.dictionary(forKey: Self.spaceBarSlotMemoryKey) as? [String: Int]
        return saved?[Self.spaceBarSlotKey(for: window, spaceKey: spaceKey, screenID: screenID)].map { ($0, false) }
    }

    /// The slot for a window that has a remembered one. A window that left it in this session
    /// goes back there whatever is in it now. A slot remembered from an earlier run is taken
    /// only while it is free: nobody recalls an old place, and joining other windows there
    /// while a slot is empty looks random. With no empty slot the remembered one is as good as any.
    nonisolated static func slotForRememberedWindow(remembered: Int, isFromThisSession: Bool, otherWindowCounts: [Int]) -> Int {
        guard !isFromThisSession, otherWindowCounts.indices.contains(remembered), otherWindowCounts[remembered] > 0 else {
            return remembered
        }
        return otherWindowCounts.firstIndex(of: 0) ?? remembered
    }

    /// A window moved onto a Manual desktop gets a slot there as soon as that desktop is on screen.
    func spaceBarDidMoveWindow(_ windowID: CGWindowID, toSpaceKey spaceKey: String, displayID: String) {
        for key in spaceBarPendingPlacements.keys {
            spaceBarPendingPlacements[key]?.remove(windowID)
        }
        guard let screen = screenManager.screen(forDisplayID: displayID) else { return }
        let screenID = screenManager.identifier(for: screen)
        guard configuration(forSpaceID: spaceKey, screenID: screenID).mode == .manualAssignment else { return }
        spaceBarPendingPlacements[spaceKey, default: []].insert(windowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.placeSpaceBarMovedWindows(onSpaceKey: spaceKey, displayID: displayID)
        }
    }

    private func placeSpaceBarMovedWindows(onSpaceKey spaceKey: String, displayID: String) {
        guard var pending = spaceBarPendingPlacements[spaceKey], !pending.isEmpty,
              let screen = screenManager.screen(forDisplayID: displayID),
              spaceID(for: screen) == spaceKey else { return }
        let screenID = screenManager.identifier(for: screen)
        guard configuration(forSpaceID: spaceKey, screenID: screenID).mode == .manualAssignment else {
            spaceBarPendingPlacements[spaceKey] = nil
            return
        }
        let windows = windowManager.enumerateWindows()
        layoutManager.syncWithVisibleWindows(Set(windows.map(\.windowID)), forScreenID: screenID, skipRedistribution: true)
        for windowID in pending {
            // Only windows on the current desktop are listed. Others wait for the next visit.
            guard let window = windows.first(where: { $0.windowID == windowID }) else { continue }
            pending.remove(windowID)
            placeSpaceBarMovedWindow(window, spaceKey: spaceKey, screenID: screenID)
        }
        spaceBarPendingPlacements[spaceKey] = pending.isEmpty ? nil : pending
        layoutManager.saveLayoutInfo(forSpaceID: spaceKey, screenID: screenID)
        groupIndicatorManager?.updateIndicators()
    }

    /// Back into the slot it had on this desktop if that slot is free, otherwise
    /// the usual rules for a new window: first empty slot, then grouping.
    /// Other windows are never moved out of their slots.
    private func placeSpaceBarMovedWindow(_ window: WindowInfo, spaceKey: String, screenID: String) {
        let state = layoutManager.state(forScreenID: screenID)
        let current = state.slotIndex(for: window.windowID)
        let memory = rememberedSpaceBarSlot(for: window, spaceKey: spaceKey, screenID: screenID)
            .flatMap { $0.slot < state.slots.count ? $0 : nil }
        let remembered = memory.map { memory in
            AppState.slotForRememberedWindow(
                remembered: memory.slot, isFromThisSession: memory.isFromThisSession,
                otherWindowCounts: state.slots.map { slot in slot.windows.filter { $0.windowID != window.windowID }.count }
            )
        }
        logger.info("Desktops bar: placing '\(window.ownerName, privacy: .public)', current slot \(current.map { $0 + 1 } ?? 0), remembered slot \(memory.map { $0.slot + 1 } ?? 0) \(memory?.isFromThisSession == true ? "from this session" : "stored", privacy: .public), goes to \(remembered.map { $0 + 1 } ?? 0)")

        guard state.isActive, let remembered else {
            if let current {
                // The restore put it into this slot because the frame it brought from the other
                // desktop overlaps it. Sharing a slot while another one is empty is not what a
                // new window gets, so it takes the empty one.
                if state.isActive,
                   let empty = AppState.emptySlotInsteadOfShared(current: current, windowCounts: state.slots.map { $0.windows.count }) {
                    logger.info("Desktops bar: '\(window.ownerName, privacy: .public)' takes empty slot \(empty + 1) instead of sharing slot \(current + 1)")
                    layoutManager.moveWindowToEmptySlot(windowID: window.windowID, slotIndex: empty, forScreenID: screenID)
                    positionWindowInZone(window, zoneIndex: empty, forScreenID: screenID)
                    return
                }
                positionWindowInZone(window, zoneIndex: current, forScreenID: screenID)
                return
            }
            // The window existed before the layout was applied, which would make it skipped as old.
            windowIDsAtLayoutApply.remove(window.windowID)
            tryAutoGroupWindow(window, forScreenID: screenID)
            return
        }

        // The restore may have put the window in another slot by frame overlap.
        // The remembered slot wins.
        if current != remembered {
            let others = state.slots[remembered].windows.filter { $0.windowID != window.windowID }
            if !others.isEmpty {
                // It shared this slot before it left. Rejoin that group. The others stay put.
                layoutManager.addWindowToSlot(window, slotIndex: remembered, forScreenID: screenID)
                layoutManager.setActiveWindow(window.windowID, in: remembered, forScreenID: screenID)
            } else if current != nil {
                layoutManager.moveWindowToEmptySlot(windowID: window.windowID, slotIndex: remembered, forScreenID: screenID)
            } else {
                layoutManager.assignWindow(window, to: remembered, forScreenID: screenID)
            }
        }
        positionWindowInZone(window, zoneIndex: remembered, forScreenID: screenID)
        setupAXObserver(for: window.ownerPID)
    }

    /// The first empty slot, for a window that shares its slot with others. Nil when it has its
    /// slot to itself or no slot is empty: then it stays where it is.
    nonisolated static func emptySlotInsteadOfShared(current: Int, windowCounts: [Int]) -> Int? {
        guard windowCounts.indices.contains(current), windowCounts[current] > 1 else { return nil }
        return windowCounts.firstIndex(of: 0)
    }

    /// Perform a delayed indicator refresh after Space changes to clear transient artifacts
    private func scheduleGroupIndicatorRefreshAfterSpaceChange() {
        // While Mission Control is open this hides the indicators; they return when it closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.groupIndicatorManager?.updateIndicators()
        }
    }

    func observeMissionControl() {
        // AppState is created before the app finishes launching, too early to create windows
        Task { @MainActor in
            MissionControlWatcher.shared.start()
        }

        NotificationCenter.default.publisher(for: .missionControlDidOpen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.groupIndicatorManager?.hideAll()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .missionControlDidClose)
            // Windows fly back from their thumbnails for a moment after Mission Control closes
            .delay(for: .seconds(0.8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.groupIndicatorManager?.updateIndicators()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .dragSnapGroupsDidChange)
            // The window server reports the new frames a moment later
            .delay(for: .seconds(0.15), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.groupIndicatorManager?.updateIndicators()
            }
            .store(in: &cancellables)
    }
    
    private func restoreLayoutForDisplaySpace(spaceID: String, screenID: String, screen: NSScreen) {
        debugLog("AppState", " Restoring layout for display space='\(spaceID)', screen='\(screenID)'...")
        
        guard let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: spaceID, screenID: screenID) else {
            debugLog("AppState", " No saved layout for space '\(spaceID)' screen '\(screenID)' - not repositioning windows")
            // Still update indicators in case there are groups on other screens
            groupIndicatorManager?.updateIndicators()
            return
        }
        
        guard let template = allTemplates.first(where: { $0.id == savedInfo.templateID }) else {
            debugLog("AppState", " Template not found for saved layout: \(savedInfo.templateID)")
            groupIndicatorManager?.updateIndicators()
            return
        }
        
        // Clear the AXUIElement cache before restoring: after being away from a Space,
        // cached elements may be invalid (apps restarted, windows reopened with new IDs)
        accessibilityService.clearAllAXCache()
        
        let currentWindows = windowManager.enumerateWindows()
        let windowsOnScreen = filterWindowsOnScreen(currentWindows, screen: screen)
            .filter { !isWindowFloating(windowID: $0.windowID) }
        debugLog("AppState", " Found \(windowsOnScreen.count) windows on screen for restore")
        
        if layoutManager.restoreLayout(from: savedInfo, template: template, currentWindows: windowsOnScreen, forScreenID: screenID) {
            debugLog("AppState", " ✅ Layout state restored for space '\(spaceID)' screen '\(screenID)'")
            
            if snapBackEnabled {
                snapBackService?.start(forScreenID: screenID)
            }
            
            let restoredWindows = layoutManager.state(forScreenID: screenID).allWindows
            processUnassignedWindowsAfterRestore(
                allWindowsOnScreen: windowsOnScreen,
                restoredWindows: restoredWindows,
                forScreenID: screenID
            )
            fitWindowsOnAllDesktops(windowsOnScreen, forScreenID: screenID)
        } else {
            debugLog("AppState", " Layout restore failed for space '\(spaceID)' screen '\(screenID)' - windows may have changed")
        }
        
        groupIndicatorManager?.updateIndicators()
    }
    
    /// Restore auto-tiling layout on Space return, preserving manual resize modifications
    /// Only repositions windows if user had resized and window count matches
    private func restoreAutoTilingLayoutOnSpaceReturn(spaceID: String, screenID: String, screen: NSScreen) {
        debugLog("AppState", " restoreAutoTilingLayoutOnSpaceReturn: space='\(spaceID)', screen='\(screenID)'")
        
        // Clear the AXUIElement cache before restoring: after being away from a Space,
        // cached elements may be invalid
        accessibilityService.clearAllAXCache()
        
        guard let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: spaceID, screenID: screenID) else {
            debugLog("AppState", " No saved layout for auto-tiling - using current state")
            autoTilingService?.updateKnownWindowsWithoutRedistribute()
            return
        }
        
        guard let template = allTemplates.first(where: { $0.id == savedInfo.templateID }) else {
            debugLog("AppState", " Template not found for saved layout")
            autoTilingService?.updateKnownWindowsWithoutRedistribute()
            return
        }
        
        let currentWindows = windowManager.enumerateWindows()
        let windowsOnScreen = filterWindowsOnScreen(currentWindows, screen: screen)
        let eligibleWindows = windowsOnScreen.filter { window in
            accessibilityService.isWindowAccessible(window) &&
            window.frame.width >= WindowManager.minimumTilableSize &&
            window.frame.height >= WindowManager.minimumTilableSize &&
            WindowClassifier.shared.isTilable(window) &&
            !isWindowFloating(windowID: window.windowID)
        }
        
        // Count windows in saved layout (non-empty slots)
        let savedWindowCount = savedInfo.slots.filter { $0.ownerName != nil || $0.bundleIdentifier != nil }.count
        let currentWindowCount = eligibleWindows.count
        
        debugLog("AppState", " Saved windows: \(savedWindowCount), current windows: \(currentWindowCount)")
        
        if currentWindowCount != savedWindowCount {
            debugLog("AppState", " Window count changed - triggering redistribute")
            layoutManager.clearManualModifications(forScreenID: screenID)
            autoTilingService?.redistributeWindows(forScreenID: screenID, savedSpaceID: spaceID)
            return
        }
        
        debugLog("AppState", " Restoring layout with saved frames (preserving resize)")
        
        if layoutManager.restoreLayout(from: savedInfo, template: template, currentWindows: eligibleWindows, forScreenID: screenID) {
            debugLog("AppState", " ✅ Layout state restored for auto-tiling space '\(spaceID)'")
            
            let screenState = layoutManager.state(forScreenID: screenID)
            for slot in screenState.slots {
                guard let primaryWindow = slot.primaryWindow else { continue }
                
                guard let currentWindow = eligibleWindows.first(where: { $0.windowID == primaryWindow.windowID }),
                      focusModeService?.isFocusedWindow(currentWindow.windowID) != true else {
                    continue
                }
                
                let success = accessibilityService.setWindowFrame(currentWindow, frame: slot.frame)
                if success {
                    debugLog("AppState", " Repositioned '\(currentWindow.ownerName)' to saved frame")
                }
            }
        } else {
            debugLog("AppState", " Layout restore failed - falling back to redistribute")
            layoutManager.clearManualModifications(forScreenID: screenID)
            autoTilingService?.redistributeWindows(forScreenID: screenID, savedSpaceID: spaceID)
        }
        
        autoTilingService?.updateKnownWindowsWithoutRedistribute()
    }
    
    func updateSlotFramesFromWindows(forScreenID screenID: String) {
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else { return }
        
        guard let screen = screenManager.screen(for: screenID) else { return }
        
        let currentWindows = windowManager.enumerateWindows()
        let screenFrame = screenManager.visibleFrame(for: screen)
        
        for (index, slot) in screenState.slots.enumerated() {
            guard let primaryWindow = slot.primaryWindow,
                  let currentWindow = currentWindows.first(where: { $0.windowID == primaryWindow.windowID }) else {
                continue
            }
            
            guard accessibilityService.isShownAtRealFrame(currentWindow) else { continue }

            // MARK: - Workaround: A window held by a desktop move is not where its slot is
            // Cause: The Desktops Bar holds the window by its title bar while the desktop
            //        switches, and the real mouse still drags it: it is off its place by however
            //        far the hand moved. Taken as the slot's frame, that shift was saved with
            //        the layout and every later window in that slot was put there.
            if primaryWindow.windowID == SpaceBarController.movingWindowID { continue }

            let windowFrame = currentWindow.frame
            let slotFrame = slot.frame

            // Skip update if window is likely maximized or has unreasonable size
            let screenCoverage = (windowFrame.width * windowFrame.height) / (screenFrame.width * screenFrame.height)
            if screenCoverage > 0.85 {
                continue
            }
            
            let slotArea = slotFrame.width * slotFrame.height
            let windowArea = windowFrame.width * windowFrame.height
            if slotArea > 0 && windowArea / slotArea > 1.5 {
                continue
            }
            
            let intersection = slotFrame.intersection(windowFrame)
            let overlapRatio = intersection.isEmpty ? 0 : (intersection.width * intersection.height) / slotArea
            if overlapRatio < 0.2 {
                continue
            }
            
            layoutManager.updateSlotFrame(index, frame: windowFrame, forScreenID: screenID)
        }
    }
}
