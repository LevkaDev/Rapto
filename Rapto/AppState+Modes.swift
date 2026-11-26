//
//  AppState+Modes.swift
//  Rapto
//
//  Switching between Manual, Auto Tiling, Drag to Snap and None.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Mode Management
    
    /// Does nothing. Mode changes are handled per screen through setupSpaceChangeHandler and handleModeChange.
    func setupModeObservation() {
    }
    
    /// Suspends or resumes all active window-management services without altering saved modes or layouts.
    func handlePauseStateChanged() {
        if isPaused {
            for screen in screenManager.allScreens() {
                let screenID = screenManager.identifier(for: screen)
                if layoutManager.state(forScreenID: screenID).isActive {
                    updateSlotFramesFromWindows(forScreenID: screenID)
                    layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: screen), screenID: screenID)
                }
            }
            if isOverlayVisible {
                isOverlayVisible = false
            }
            dragSnapService?.stop()
            autoTilingService?.stop()
            snapBackService?.stop()
            windowSwapService?.stop()
            windowResizeService?.stop()
            windowHighlightService?.stop()
            focusModeService?.stop()
            removeManualModeGroupingObservers()
            groupIndicatorManager?.hideAll()
            checkPassthroughState()
            logger.info("Rapto paused: window management and shortcuts suspended")
            debugLog("AppState", " Rapto paused")
        } else {
            checkPassthroughState()
            if focusModeEnabled {
                focusModeService?.start()
                focusModeService?.doubleTapEnabled = focusModeDoubleTapEnabled
            }
            if isGroupingEnabled && autoGroupSameApp {
                setupWindowMonitoring()
            }
            applyInitialModesToAllScreens()
            setupSwapHotkeys()
            groupIndicatorManager?.updateIndicators()
            logger.info("Rapto resumed: window management and shortcuts active")
            debugLog("AppState", " Rapto resumed")
        }
    }

    /// Apply saved tiling modes to ALL connected screens at app startup
    /// This ensures that modes selected on empty screens work when windows appear later
    func applyInitialModesToAllScreens() {
        guard !isPaused else {
            debugLog("AppState", " Skipping applyInitialModesToAllScreens while paused")
            return
        }
        debugLog("AppState", " Applying initial modes to all \(NSScreen.screens.count) screens")
        
        for screen in NSScreen.screens {
            let screenID = screenManager.identifier(for: screen)
            let screenMode = mode(for: screen)
            
            debugLog("AppState", " Screen '\(screenManager.displayName(for: screen))' (ID: \(screenID)): mode=\(screenMode.displayName)")
            
            handleModeChange(to: screenMode, for: screen)
        }
        
        updateHighlightForCurrentMode()
    }
    
    func updateHighlightForCurrentMode() {
        guard !isPaused else {
            windowHighlightService?.stop()
            return
        }
        let mode = currentMode
        debugLog("AppState", " updateHighlightForCurrentMode: highlightActiveWindow=\(highlightActiveWindow), disableInDragSnap=\(disableHighlightInDragSnapMode), currentMode=\(mode.displayName)")
        
        guard highlightActiveWindow else {
            debugLog("AppState", " → Stopping highlight (disabled)")
            windowHighlightService?.stop()
            return
        }
        
        if mode == .none {
            debugLog("AppState", " → Stopping highlight (None mode)")
            windowHighlightService?.stop()
            return
        }
        
        if disableHighlightInDragSnapMode && mode == .dragSnap {
            debugLog("AppState", " → Stopping highlight (Drag-to-Snap mode)")
            windowHighlightService?.stop()
        } else {
            debugLog("AppState", " → Starting highlight")
            windowHighlightService?.start()
        }
    }
    
    /// Puts the windows back into the Manual layout kept when the desktop left Manual. Returns whether it did.
    private func bringBackManualLayout(for screen: NSScreen, screenID: String, spaceID: String) -> Bool {
        guard let snapshot = layoutManager.loadManualLayout(forSpaceID: spaceID, screenID: screenID) else { return false }
        layoutManager.removeManualLayout(forSpaceID: spaceID, screenID: screenID)
        guard let template = allTemplates.first(where: { $0.id == snapshot.templateID }) else {
            debugLog("AppState", "The kept Manual layout's template is gone, not bringing it back")
            return false
        }
        return putWindowsBack(snapshot, template: template, screen: screen, screenID: screenID, spaceID: spaceID)
    }

    /// In Manual mode, picking a template again brings back how its windows were arranged.
    /// Returns true when it handled the pick: the template is already on screen, or its arrangement came back.
    func switchManualTemplate(to template: GridTemplate, screen: NSScreen) -> Bool {
        guard mode(for: screen) == .manualAssignment else { return false }
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        let current = layoutManager.state(forScreenID: screenID)
        let hasWindows = current.slots.contains { !$0.isEmpty }
        if hasWindows, current.template?.id == template.id {
            debugLog("AppState", "Template '\(template.name)' is already on screen \(screenID), leaving the windows as they are")
            return true
        }
        if hasWindows {
            layoutManager.saveTemplateArrangement(forSpaceID: screenSpaceID, screenID: screenID)
        }
        guard let snapshot = layoutManager.loadTemplateArrangement(template.id, forSpaceID: screenSpaceID, screenID: screenID),
              putWindowsBack(snapshot, template: template, screen: screen, screenID: screenID, spaceID: screenSpaceID) else {
            return false
        }
        finishTemplateApply(template: template, screen: screen)
        logger.info("Brought back the arrangement of '\(template.name)' on screen \(screenID)")
        return true
    }

    /// Which source Manual mode uses when entered on a screen.
    nonisolated enum ManualModeRestoreSource: Equatable, Sendable {
        case inheritAutoTiling
        case restoreManualSnapshot
        case restoreSavedLayout
        case applyTemplate
    }

    /// Pure decision rule for entering Manual mode:
    /// an active Auto-tiling grid is inherited in place (zero window moves) before falling back
    /// to a kept Manual snapshot (when returning from None / Drag-to-Snap) or a saved layout.
    nonisolated static func manualModeRestoreSource(
        hasActiveAutoTiling: Bool,
        hasManualSnapshot: Bool,
        hasSavedLayout: Bool
    ) -> ManualModeRestoreSource {
        if hasActiveAutoTiling { return .inheritAutoTiling }
        if hasManualSnapshot { return .restoreManualSnapshot }
        if hasSavedLayout { return .restoreSavedLayout }
        return .applyTemplate
    }

    private func putWindowsBack(_ snapshot: ManualLayoutSnapshot, template: GridTemplate, screen: NSScreen, screenID: String, spaceID: String) -> Bool {
        let windowsOnScreen = filterWindowsOnScreen(windowManager.enumerateWindows(), screen: screen)
        guard layoutManager.restoreManualLayout(snapshot, template: template, currentWindows: windowsOnScreen, forScreenID: screenID) else {
            return false
        }

        // Assign any unassigned windows BEFORE moving so every window moves in one quiet batch
        let initialState = layoutManager.state(forScreenID: screenID)
        processUnassignedWindowsAfterRestore(
            allWindowsOnScreen: windowsOnScreen,
            restoredWindows: initialState.slots.flatMap(\.windows),
            forScreenID: screenID,
            repositionMoved: false
        )

        let finalState = layoutManager.state(forScreenID: screenID)
        let allSlotWindows = finalState.slots.flatMap(\.windows)
        let axCache = accessibilityService.batchGetAXWindows(for: allSlotWindows)

        var batchTargets: [AccessibilityService.BatchFrameTarget] = []
        batchTargets.reserveCapacity(allSlotWindows.count)
        for slot in finalState.slots {
            for window in slot.windows.reversed() {
                batchTargets.append(
                    AccessibilityService.BatchFrameTarget(
                        window: window,
                        axWindow: axCache[window.windowID],
                        frame: slot.frame
                    )
                )
            }
        }

        var startedTransition = false
        _ = accessibilityService.batchSetWindowFrames(batchTargets) { [weak self] in
            startedTransition = true
            self?.windowHighlightService?.beginLayoutTransition()
            self?.groupIndicatorManager?.hideAll()
        }

        // Only grouped slots need their front window raised; use silent AXRaiseAction so background
        // apps never flash the menu bar or steal keyboard focus from the active window.
        for slot in finalState.slots where slot.windows.count >= 2 {
            if let front = slot.primaryWindow, let axWin = axCache[front.windowID] {
                _ = accessibilityService.raiseWindow(axWindow: axWin)
            }
        }

        layoutManager.saveLayoutInfo(forSpaceID: spaceID, screenID: screenID)
        windowResizeService?.setManagedLayout(windows: finalState.allWindows)
        if isGroupingEnabled && autoGroupSameApp {
            setupManualModeGroupingObservers()
        }
        setupSwapHotkeys()
        groupIndicatorManager?.updateIndicators()
        if startedTransition {
            windowHighlightService?.endLayoutTransition()
        }
        return true
    }

    func handleModeChange(to mode: TilingMode, for screen: NSScreen, inheritAutoTilingLayout: Bool = true) {
        guard !isPaused else {
            debugLog("AppState", " Skipping handleModeChange while paused")
            return
        }
        let screenID = screenManager.identifier(for: screen)
        let screenName = screenManager.displayName(for: screen)
        logger.info("Tiling mode changed to: \(mode.displayName) for screen: \(screenName) (ID: \(screenID))")
        
        // Capture current Auto-tiling layout BEFORE stopping services
        // This allows Manual mode to inherit the current window arrangement
        let previousAutoTilingState: LayoutState?
        if inheritAutoTilingLayout, autoTilingService?.isActive(forScreenID: screenID) == true {
            previousAutoTilingState = layoutManager.state(forScreenID: screenID)
            debugLog("AppState", " Captured Auto-tiling state: \(previousAutoTilingState?.slots.count ?? 0) slots")
        } else {
            previousAutoTilingState = nil
        }
        dragSnapService?.stop(forScreenID: screenID)
        autoTilingService?.stop(forScreenID: screenID)
        snapBackService?.stop(forScreenID: screenID)
        
        // Clear layout for this screen - each mode applies its own
        layoutManager.clearLayout(forScreenID: screenID)
        
        // windowSwapService and windowResizeService are global services,
        // they don't have per-screen logic. They operate on whatever windows are managed.
        // GroupIndicators also work globally based on layoutManager state.
        
        switch mode {
        case .none:
            // None mode - no window management for this desktop
            // Don't hide ALL indicators - just update them (other screens may still have groups)
            // The updateIndicators() call at the end will handle showing/hiding per-screen
            
            let allScreenModes = NSScreen.screens.map { screen -> TilingMode in
                let sid = screenManager.identifier(for: screen)
                let screenSpaceID = self.spaceID(for: screen)
                return ScreenConfigurationStorage.configuration(forSpaceID: screenSpaceID, screenID: sid, in: screenConfigurations).mode
            }
            let anyActiveMode = allScreenModes.contains { $0 != .none }
            if !anyActiveMode {
                windowSwapService?.stop()
                windowResizeService?.stop()
                debugLog("AppState", " All screens in None mode - stopped global services")
            }
            logger.info("None mode for screen \(screenName): all services disabled")
            
        case .manualAssignment:
            if !(windowSwapService?.isActive ?? false) {
                windowSwapService?.start()
            }
            if !(windowResizeService?.isActive ?? false) {
                windowResizeService?.start()
            }
            if snapBackEnabled {
                snapBackService?.start(forScreenID: screenID)
            }
            
            // Use correct spaceID for THIS screen (not primary display's spaceID)
            let currentSpaceID = spaceID(for: screen)
            debugLog("AppState", " handleModeChange Manual: screen=\(screenID), spaceID=\(currentSpaceID)")
            
            // PRIORITY 1: If switching from Auto-tiling, inherit its live grid right where the
            // windows already sit (zero window moves) instead of yanking them back to an older snapshot.
            if let autoState = previousAutoTilingState, autoState.isActive, let template = autoState.template {
                debugLog("AppState", " Inheriting Auto-tiling layout: \(template.name) with \(autoState.slots.count) slots")
                layoutManager.removeManualLayout(forSpaceID: currentSpaceID, screenID: screenID)
                layoutManager.setLayoutWithSlots(template: template, slots: autoState.slots, forScreenID: screenID)
                layoutManager.saveLayoutInfo(forSpaceID: currentSpaceID, screenID: screenID)
                
                let managedWindows = layoutManager.state(forScreenID: screenID).allWindows
                if !managedWindows.isEmpty {
                    windowResizeService?.setManagedLayout(windows: managedWindows)
                }
                
                if isGroupingEnabled && autoGroupSameApp {
                    setupManualModeGroupingObservers()
                }
                setupSwapHotkeys()
                groupIndicatorManager?.updateIndicators()
                
                logger.info("Manual mode for screen \(screenName): inherited Auto-tiling layout (\(template.name)), swap=ON, resize=ON, snapBack=\(self.snapBackEnabled)")
                updateHighlightForCurrentMode()
                return
            }

            // PRIORITY 2: Returning from None or Drag-to-Snap restores the kept Manual snapshot
            if bringBackManualLayout(for: screen, screenID: screenID, spaceID: currentSpaceID) {
                logger.info("Manual mode for screen \(screenName): brought back the earlier Manual layout")
                updateHighlightForCurrentMode()
                return
            }
            
            // PRIORITY 2: Try to restore saved layout (for Space switches within Manual mode)
            if let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: currentSpaceID, screenID: screenID),
               let template = allTemplates.first(where: { $0.id == savedInfo.templateID }) {
                
                let currentWindows = windowManager.enumerateWindows()
                let windowsOnScreen = filterWindowsOnScreen(currentWindows, screen: screen)
                
                if layoutManager.restoreLayout(from: savedInfo, template: template, currentWindows: windowsOnScreen, forScreenID: screenID) {
                    debugLog("AppState", " ✅ Restored saved layout for space '\(currentSpaceID)' screen '\(screenID)' - no repositioning")
                    
                    // Setup services without repositioning
                    // Use screen-specific state (not default state which is for primary screen)
                    let restoredWindows = layoutManager.state(forScreenID: screenID).allWindows
                    if !restoredWindows.isEmpty {
                        windowResizeService?.setManagedLayout(windows: restoredWindows)
                    }
                    
                    if isGroupingEnabled && autoGroupSameApp {
                        setupManualModeGroupingObservers()
                    }
                    setupSwapHotkeys()
                    groupIndicatorManager?.updateIndicators()
                    
                    // Process windows that appeared while on another Space
                    // These are windows NOT in the restored layout but visible on this screen
                    processUnassignedWindowsAfterRestore(
                        allWindowsOnScreen: windowsOnScreen,
                        restoredWindows: restoredWindows,
                        forScreenID: screenID
                    )
                    
                    logger.info("Manual mode for screen \(screenName): restored layout, swap=ON, resize=ON, snapBack=\(self.snapBackEnabled)")
                    updateHighlightForCurrentMode()
                    return
                }
            }
            
            debugLog("AppState", " No saved layout for space '\(currentSpaceID)' screen '\(screenID)' - applying template")
            applyManualModeTemplate(for: screen)
            
            logger.info("Manual mode for screen \(screenName): swap=ON, resize=ON, snapBack=\(self.snapBackEnabled)")
            
        case .dragSnap:
            dragSnapService?.start(forScreenID: screenID)
            logger.info("Drag-snap mode started for screen: \(screenName)")
            
        case .autoTiling:
            if !(windowSwapService?.isActive ?? false) {
                windowSwapService?.start()
            }
            if !(windowResizeService?.isActive ?? false) {
                windowResizeService?.start()
            }
            
            // When switching to Auto-tiling (especially from another Space), CGWindowListCopyWindowInfo
            // may return incomplete window list during Space transition animation.
            // Strategy: Always delay initial redistribute to after Space animation completes.
            
            // Use correct spaceID for THIS screen (not primary display's spaceID)
            let currentSpaceID = spaceID(for: screen)
            debugLog("AppState", " handleModeChange AutoTiling: screen=\(screenID), spaceID=\(currentSpaceID)")
            
            // Check if we have a saved layout (for logging purposes)
            if let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: currentSpaceID, screenID: screenID) {
                debugLog("AppState", " Found saved auto-tiling layout for space '\(currentSpaceID)': \(savedInfo.slots.count) slots")
            }
            
            // Start auto-tiling but ALWAYS skip initial redistribute during Space transition
            // This prevents incorrect layout due to incomplete window enumeration
            autoTilingService?.startDynamic(forScreenID: screenID, skipInitialRedistribute: true)
            
            // Redistribute after the Space transition animation completes.
            // savedSpaceID restores the window order from the saved layout, so windows keep their slots on the first return to the Space.
            let capturedSpaceID = currentSpaceID
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6 sec - after Space animation
                guard let self else { return }
                
                // Verify this screen is still on the same Space (user might have switched during delay)
                let currentSpace = self.spaceID(for: screen)
                let savedSpaceID: String? = (currentSpace == capturedSpaceID) ? capturedSpaceID : nil
                
                if savedSpaceID == nil && currentSpace != capturedSpaceID {
                    debugLog("AppState", " Space changed during delay (\(capturedSpaceID) -> \(currentSpace)), skipping saved layout restore")
                }
                
                // Now CGWindowListCopyWindowInfo should return correct window list
                debugLog("AppState", " Space transition complete, redistributing windows for auto-tiling")
                self.autoTilingService?.redistributeWindows(forScreenID: screenID, savedSpaceID: savedSpaceID)
            }
            
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000) // 0.7 sec
                self?.setupSwapHotkeys()
                self?.groupIndicatorManager?.updateIndicators()
            }
            logger.info("Auto-tiling mode started for screen: \(screenName) (delayed redistribute)")
        }
        
        updateHighlightForCurrentMode()
        
        // Always update group indicators (handles multi-monitor - other screens may still have groups)
        groupIndicatorManager?.updateIndicators()
    }
    
    /// Start services for a screen WITHOUT clearing its layout
    /// Used when a new display is detected - we want to start services but preserve any existing window tracking
    func startServicesForScreen(screenID: String, mode: TilingMode, screen: NSScreen) {
        guard !isPaused else {
            debugLog("AppState", " Skipping startServicesForScreen while paused")
            return
        }
        let screenName = screenManager.displayName(for: screen)
        debugLog("AppState", " startServicesForScreen: screen=\(screenName), mode=\(mode.displayName)")
        
        switch mode {
        case .none:
            debugLog("AppState", " None mode - no services to start")
            
        case .manualAssignment:
            if !(windowSwapService?.isActive ?? false) {
                windowSwapService?.start()
            }
            if !(windowResizeService?.isActive ?? false) {
                windowResizeService?.start()
            }
            if snapBackEnabled {
                snapBackService?.start(forScreenID: screenID)
            }
            if isGroupingEnabled && autoGroupSameApp {
                setupManualModeGroupingObservers()
            }
            setupSwapHotkeys()
            debugLog("AppState", " Manual mode services started for \(screenName)")
            
        case .autoTiling:
            if !(autoTilingService?.isActive(forScreenID: screenID) ?? false) {
                let currentSpaceID = spaceID(for: screen)
                let screenConfig = configuration(forSpaceID: currentSpaceID, screenID: screenID)
                if let templateID = screenConfig.templateID,
                   let template = allTemplates.first(where: { $0.id == templateID }) {
                    autoTilingService?.start(with: template, forScreenID: screenID)
                } else if let defaultTemplate = allTemplates.first {
                    autoTilingService?.start(with: defaultTemplate, forScreenID: screenID)
                }
            }
            debugLog("AppState", " Auto-tiling started for \(screenName)")
            
        case .dragSnap:
            if !(dragSnapService?.isActive(forScreenID: screenID) ?? false) {
                dragSnapService?.start(forScreenID: screenID)
            }
            debugLog("AppState", " Drag-snap started for \(screenName)")
        }
        
        updateHighlightForCurrentMode()
        groupIndicatorManager?.updateIndicators()
    }
    
    private func applyManualModeTemplate(for screen: NSScreen) {
        // Use correct spaceID for THIS screen (not primary display's spaceID)
        let currentSpaceID = spaceID(for: screen)
        let screenID = screenManager.identifier(for: screen)
        
        let screenConfig = configuration(forSpaceID: currentSpaceID, screenID: screenID)
        let legacyConfig = spaceConfigurations[currentSpaceID] ?? .default
        
        let hasConfiguredTemplate = screenConfig.templateID != nil || legacyConfig.templateID != nil
        let template: GridTemplate
        if let templateID = screenConfig.templateID,
           let configuredTemplate = allTemplates.first(where: { $0.id == templateID }) {
            template = configuredTemplate
        } else if let templateID = legacyConfig.templateID,
           let configuredTemplate = allTemplates.first(where: { $0.id == templateID }) {
            template = configuredTemplate
        } else {
            let suggested = DisplayProfile.forScreen(screen).suggestedManualTemplate
            template = allTemplates.first(where: { $0.id == suggested.id }) ?? allTemplates.first ?? suggested
        }
        
        logger.info("Applying manual mode template: \(template.name) for screen \(self.screenManager.displayName(for: screen))")
        if hasFinishedLaunchSetup, !hasConfiguredTemplate {
            didEnterManualWithoutSavedTemplate(on: screen)
        }
        
        let currentWindows = windowManager.enumerateWindows()
        let eligibleWindows = filterEligibleWindowsForTiling(currentWindows)
        
        let windowsOnScreen = filterWindowsOnScreen(eligibleWindows, screen: screen)
        
        guard !windowsOnScreen.isEmpty else {
            logger.info("No eligible windows to arrange on screen \(self.screenManager.displayName(for: screen))")
            return
        }
        
        let sortedWindows: [WindowInfo]
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let frontWindows = windowsOnScreen.filter { $0.ownerPID == frontApp.processIdentifier }
            let otherWindows = windowsOnScreen.filter { $0.ownerPID != frontApp.processIdentifier }
            sortedWindows = frontWindows + otherWindows
        } else {
            sortedWindows = windowsOnScreen
        }
        
        let screenFrame = screenManager.visibleFrame(for: screen)
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let slotWindowAssignments = layoutManager.assignWindowsToSlots(
            windows: sortedWindows,
            slotCount: sortedZones.count,
            frontmostPID: frontmostPID
        )
        
        var newSlots: [Slot] = []
        var allAssignedWindows: [WindowInfo] = []

        for (index, zone) in sortedZones.enumerated() {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)

            let slot = Slot(
                id: zone.id,
                index: index,
                frame: cgFrame,
                windows: slotWindowAssignments[index]
            )
            newSlots.append(slot)
            allAssignedWindows.append(contentsOf: slot.windows)
        }

        let axCache = accessibilityService.batchGetAXWindows(for: allAssignedWindows)
        var batchTargets: [AccessibilityService.BatchFrameTarget] = []
        batchTargets.reserveCapacity(allAssignedWindows.count)
        for slot in newSlots where !slot.isEmpty {
            for window in slot.windows.reversed() {
                batchTargets.append(
                    AccessibilityService.BatchFrameTarget(
                        window: window,
                        axWindow: axCache[window.windowID],
                        frame: slot.frame
                    )
                )
            }
        }

        var startedTransition = false
        _ = accessibilityService.batchSetWindowFrames(batchTargets) { [weak self] in
            startedTransition = true
            self?.windowHighlightService?.beginLayoutTransition()
            self?.groupIndicatorManager?.hideAll()
        }

        // Only grouped slots need their primary window raised; silent AXRaiseAction keeps focus intact.
        for slot in newSlots where slot.windows.count >= 2 {
            if let primary = slot.primaryWindow, let axWin = axCache[primary.windowID] {
                _ = accessibilityService.raiseWindow(axWindow: axWin)
            }
        }
        if startedTransition {
            windowHighlightService?.endLayoutTransition()
        }
        
        layoutManager.setLayoutWithSlots(template: template, slots: newSlots, forScreenID: screenID)
        
        layoutManager.saveLayoutInfo(forSpaceID: currentSpaceID, screenID: screenID)
        
        windowIDsAtLayoutApply = Set(currentWindows.map { $0.windowID })
        
        let windowsForResize = allAssignedWindows
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
            guard let self else { return }
            
            self.windowResizeService?.setManagedLayout(windows: windowsForResize)
            
            if self.isGroupingEnabled && self.autoGroupSameApp {
                self.setupManualModeGroupingObservers()
            }
            
            self.setupSwapHotkeys()
            
            self.groupIndicatorManager?.updateIndicators()
        }
        
        logger.info("Manual mode template applied for screen \(self.screenManager.displayName(for: screen)): \(allAssignedWindows.count) windows in \(template.name)")
    }
    
    func filterWindowsOnScreen(_ windows: [WindowInfo], screen: NSScreen) -> [WindowInfo] {
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
    
    /// Filter windows that are eligible for tiling (excludes dialogs, small windows, etc.)
    private func filterEligibleWindowsForTiling(_ windows: [WindowInfo]) -> [WindowInfo] {
        return windows.filter { window in
            // Exclude small windows (likely dialogs, color pickers, popovers)
            let minSize = WindowManager.minimumTilableSize
            guard window.frame.width >= minSize && window.frame.height >= minSize else {
                logger.debug("Excluding small window: '\(window.title)' (\(Int(window.frame.width))x\(Int(window.frame.height)))")
                return false
            }
            
            if !WindowClassifier.shared.isTilable(window) {
                logger.debug("Excluding non-tilable window: '\(window.title)'")
                return false
            }
            
            return true
        }
    }

    // MARK: - Smart Window Assignment
    // Slot assignment helpers such as assignWindowsToSlots live in WindowLayoutManager
    
    func configuration(forSpaceID spaceID: String) -> SpaceConfiguration {
        return spaceConfigurations[spaceID] ?? .default
    }
}
