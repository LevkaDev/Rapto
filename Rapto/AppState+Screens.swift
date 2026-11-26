//
//  AppState+Screens.swift
//  Rapto
//
//  Display changes and moving windows between displays.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Multi-Monitor Migration
    
    func migrateSpaceToScreenConfigurations() {
        guard !spaceConfigurations.isEmpty else { return }
        
        if !screenConfigurations.isEmpty {
            return
        }
        
        logger.info("Migrating \(self.spaceConfigurations.count) legacy space configurations to screen configurations")
        
        for (spaceID, spaceConfig) in spaceConfigurations {
            let screenConfig = ScreenConfiguration(
                mode: spaceConfig.mode,
                templateID: spaceConfig.templateID
            )
            
            for screen in screenManager.allScreens() {
                let screenID = screenManager.identifier(for: screen)
                ScreenConfigurationStorage.setConfiguration(
                    screenConfig,
                    forSpaceID: spaceID,
                    screenID: screenID,
                    in: &screenConfigurations
                )
            }
        }
        
        logger.info("Migration complete: created \(self.screenConfigurations.count) screen configurations")
    }

    // MARK: - Screen Change Handling
    
    func setupScreenChangeHandler() {
        screenManager.onScreensChanged = { [weak self] in
            Task { @MainActor in
                self?.handleScreensChanged()
            }
        }
        layoutManager.stampSavedFramesWithVisibleArea()
        followVisibleAreaChanges()
    }
    
    /// Slots and snapped windows are kept in points. When a screen's visible area changes
    /// (another resolution, a resized Dock), they are moved to the same place on the new one.
    private func followVisibleAreaChanges() {
        var changes: [(screenID: String, old: CGRect, new: CGRect)] = []
        for screen in screenManager.allScreens() {
            let screenID = screenManager.identifier(for: screen)
            let new = screenManager.visibleCGFrame(for: screen)
            if let old = knownVisibleFrames[screenID], old != new {
                changes.append((screenID, old, new))
            }
            knownVisibleFrames[screenID] = new
        }
        guard !changes.isEmpty else { return }
        
        // Auto-tiling lays its screens out again by itself
        let slotScreens = changes.filter { autoTilingService?.isActive(forScreenID: $0.screenID) != true }
        for change in slotScreens {
            layoutManager.rescaleFrames(forScreenID: change.screenID, from: change.old, to: change.new)
        }
        
        Task { @MainActor [weak self] in
            // macOS is still moving windows to fit the new screen; frames set now would be overridden
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            for change in slotScreens {
                self.snapBackService?.moveWindowsToSlots(forScreenID: change.screenID)
            }
            for change in changes {
                self.dragSnapService?.rescaleSnappedWindows(forScreenID: change.screenID, from: change.old, to: change.new)
            }
            self.groupIndicatorManager?.updateIndicators()
        }
    }
    
    func handleScreensChanged(confirmScreenLoss: Bool = false) {
        guard UserSession.isActive, !isPaused else { return }
        let screenCount = screenManager.screenCount
        logger.info("Screen configuration changed: \(screenCount) screen(s) connected")
        
        let connectedScreenIDs = Set(screenManager.allScreens().map { screenManager.identifier(for: $0) })
        
        let disconnectedScreenIDs = layoutManager.screenStates.keys.filter { !connectedScreenIDs.contains($0) }

        screenLossCheck?.cancel()
        screenLossCheck = nil
        // A monitor that wakes up or switches its input is gone for a moment and comes back with the same ID.
        // Its layout is cleared only if it stays away.
        if !disconnectedScreenIDs.isEmpty, !confirmScreenLoss {
            debugLog("AppState", " Screens gone: \(disconnectedScreenIDs), clearing their layouts if still gone in 3 s")
            screenLossCheck = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.handleScreensChanged(confirmScreenLoss: true)
            }
            return
        }
        
        if !disconnectedScreenIDs.isEmpty {
            logger.info("Detected disconnected screens: \(disconnectedScreenIDs)")
            
            let currentDisplayIDs = Set(spaceManager.allDisplayIDs)
            
            for screenID in disconnectedScreenIDs {
                autoTilingService?.stop(forScreenID: screenID)
                dragSnapService?.stop(forScreenID: screenID)
                
                // Clear layout state for this screen; its saved layout brings it back when the screen returns
                layoutManager.clearLayout(forScreenID: screenID)
                lostScreenIDs.insert(screenID)
                
                logger.info("Cleaned up services and layout for disconnected screen: \(screenID)")
            }
            
            for displayID in previousDisplaySpaceIDs.keys {
                if !currentDisplayIDs.contains(displayID) {
                    previousDisplaySpaceIDs.removeValue(forKey: displayID)
                    debugLog("AppState", " Removed previousDisplaySpaceIDs for disconnected display \(displayID)")
                }
            }
            
            // Hide all indicators (they'll be recreated for remaining screens)
            groupIndicatorManager?.hideAll()
        }
        
        layoutManager.setActiveScreen(screenManager.activeScreen())
        
        followVisibleAreaChanges()
        
        // Initialize previousDisplaySpaceIDs for newly connected displays
        // This prevents the "new display" state from triggering unexpected behavior later
        for displayID in spaceManager.allDisplayIDs {
            if previousDisplaySpaceIDs[displayID] == nil {
                if let currentSpaceID = spaceManager.currentSpaceID(forDisplayID: displayID) {
                    previousDisplaySpaceIDs[displayID] = currentSpaceID
                    debugLog("AppState", " Initialized previousDisplaySpaceIDs for new display \(displayID): \(currentSpaceID)")
                }
            }
        }

        // A screen that comes back gets its layout the way it gets it at launch
        var restoredScreen = false
        for screen in screenManager.allScreens() {
            let screenID = screenManager.identifier(for: screen)
            guard lostScreenIDs.remove(screenID) != nil else { continue }
            debugLog("AppState", " Screen \(screenID) is back, restoring its layout")
            handleModeChange(to: mode(for: screen), for: screen, inheritAutoTilingLayout: false)
            restoredScreen = true
        }
        if restoredScreen {
            updateHighlightForCurrentMode()
        }
        
        // When a monitor is reconnected, windows may have moved between screens.
        // Check all slots on all screens and remove windows that are now on a different screen.
        // This handles the case where macOS moves windows back to a reconnected monitor.
        cleanupWindowsOnWrongScreens()
        
        groupIndicatorManager?.updateIndicators()
        
        // Auto-enable Snap Back when second monitor is connected
        // Required for cross-screen move detection in multi-monitor setup
        if isMultiMonitor && !snapBackEnabled {
            snapBackEnabled = true
            logger.info("Multi-monitor detected: auto-enabled Snap Back for cross-screen move detection")
        }
        
        objectWillChange.send()
    }
    
    /// Remove windows from slots if they are now located on a different screen
    /// This handles the case where macOS moves windows when monitors are reconnected
    private func cleanupWindowsOnWrongScreens() {
        let currentWindows = windowManager.enumerateWindows()
        var removedCount = 0
        
        for screenID in layoutManager.screensWithActiveLayouts {
            let screenState = layoutManager.state(forScreenID: screenID)
            
            for slot in screenState.slots {
                for window in slot.windows {
                    guard let currentWindow = currentWindows.first(where: { $0.windowID == window.windowID }) else {
                        // The window is closed; handleWindowClosed removes it from its slot
                        continue
                    }
                    
                    let actualScreen = screenManager.screen(for: currentWindow)
                    let actualScreenID = screenManager.identifier(for: actualScreen)
                    
                    if actualScreenID != screenID {
                        debugLog("AppState", " Window '\(window.title)' moved from screen \(screenID) to \(actualScreenID) - removing from slot")
                        layoutManager.removeWindow(window.windowID, forScreenID: screenID)
                        removedCount += 1
                    }
                }
            }
        }
        
        if removedCount > 0 {
            logger.info("Cleaned up \(removedCount) windows that moved to different screens")
            
            if isGroupingEnabled && autoGroupSameApp {
                setupManualModeGroupingObservers()
            }
        }
    }

    // MARK: - Multi-Monitor Window Movement
    
    /// Move the frontmost window to another screen
    func moveWindowToScreen(direction: HotkeyManager.MoveToScreenDirection) {
        debugLog("AppState"," ⚠️ moveWindowToScreen CALLED with direction: \(direction)")
        
        guard screenManager.isMultiMonitor else {
            logger.debug("Cannot move window - single monitor setup")
            return
        }
        
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("No frontmost application")
            return
        }
        
        let allWindows = windowManager.enumerateWindows()
        guard let frontWindow = allWindows.first(where: { $0.ownerPID == frontApp.processIdentifier }) else {
            logger.warning("No window found for frontmost app")
            return
        }
        
        let currentScreen = screenManager.screen(for: frontWindow)
        
        let targetDirection: ScreenDirection
        switch direction {
        case .next:
            targetDirection = .next
        case .previous:
            targetDirection = .previous
        case .left:
            targetDirection = .left
        case .right:
            targetDirection = .right
        }
        
        guard let targetScreen = screenManager.nextScreen(from: currentScreen, direction: targetDirection) else {
            logger.debug("No screen found in direction: \(String(describing: direction))")
            return
        }
        
        let targetFrame = calculateTargetFrame(
            forWindow: frontWindow,
            fromScreen: currentScreen,
            toScreen: targetScreen
        )
        
        layoutManager.removeWindowFromAllScreens(frontWindow.windowID)
        
        _ = accessibilityService.setWindowFrame(frontWindow, frame: targetFrame)
        
        logger.info("Moved '\(frontWindow.ownerName)' from \(self.screenManager.displayName(for: currentScreen)) to \(self.screenManager.displayName(for: targetScreen))")
        
        let targetScreenID = screenManager.identifier(for: targetScreen)
        let hasActiveLayout = layoutManager.hasActiveLayout(forScreenID: targetScreenID)
        
        // Get the spaceID for the TARGET screen (not primary display's spaceID)
        // Each display can have independent Spaces, so we need to look up by display UUID
        let targetDisplayID = screenManager.displayIdentifier(for: targetScreen)
        let targetSpaceID = spaceManager.currentSpaceID(forDisplayID: targetDisplayID) ?? spaceManager.currentSpaceID
        
        let targetScreenConfig = ScreenConfigurationStorage.configuration(
            forSpaceID: targetSpaceID,
            screenID: targetScreenID,
            in: screenConfigurations
        )
        let hasSavedManualConfig = targetScreenConfig.mode == .manualAssignment && targetScreenConfig.templateID != nil
        
        debugLog("AppState", " moveWindowToScreen: targetScreenID=\(targetScreenID), targetDisplayID=\(targetDisplayID), targetSpaceID=\(targetSpaceID)")
        debugLog("AppState", " hasActiveLayout=\(hasActiveLayout), hasSavedManualConfig=\(hasSavedManualConfig), configMode=\(targetScreenConfig.mode), templateID=\(targetScreenConfig.templateID?.uuidString ?? "nil")")
        
        for (key, config) in screenConfigurations {
            if key.contains(targetScreenID) {
                debugLog("AppState", " 📋 Saved config key=\(key), mode=\(config.mode), templateID=\(config.templateID?.uuidString ?? "nil")")
            }
        }
        
        // Check auto-tiling FIRST - hasActiveLayout can be true for auto-tiling screens
        // which would incorrectly take the manual mode branch
        if targetScreenConfig.mode == .autoTiling {
            debugLog("AppState", " Target screen is in auto-tiling mode")
            
            let isAutoTilingActive = autoTilingService?.isActive(forScreenID: targetScreenID) ?? false
            debugLog("AppState", " isAutoTilingActive for \(targetScreenID): \(isAutoTilingActive)")
            
            if !isAutoTilingActive {
                debugLog("AppState", " Starting auto-tiling service for target screen")
                autoTilingService?.startDynamic(forScreenID: targetScreenID, skipInitialRedistribute: true)
            }
            
            let sourceScreenID = screenManager.identifier(for: currentScreen)
            let sourceIsAutoTiling = autoTilingService?.isActive(forScreenID: sourceScreenID) ?? false
            
            Task { @MainActor [weak self] in
                // Small delay to let window settle in new position
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                debugLog("AppState", " Triggering redistribute for target \(targetScreenID)")
                self?.autoTilingService?.redistributeNow(forScreenID: targetScreenID)
                
                // Also redistribute source screen if it's in auto-tiling mode
                // Wait for target redistribute to complete before starting source
                if sourceIsAutoTiling {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for layout to complete
                    debugLog("AppState", " Triggering redistribute for source \(sourceScreenID)")
                    self?.autoTilingService?.redistributeNow(forScreenID: sourceScreenID)
                }
            }
        } else if hasActiveLayout || hasSavedManualConfig {
            let updatedWindows = windowManager.enumerateWindows()
            if let updatedWindow = updatedWindows.first(where: { $0.windowID == frontWindow.windowID }) {
                tryAutoGroupWindow(updatedWindow, forScreenID: targetScreenID)
                debugLog("AppState"," Integrated window into target screen \(targetScreenID) layout")
            }
        }
        
        groupIndicatorManager?.updateIndicators()
    }
    
    /// Preserves relative position/size within the visible frame
    private func calculateTargetFrame(
        forWindow window: WindowInfo,
        fromScreen: NSScreen,
        toScreen: NSScreen
    ) -> CGRect {
        let sourceFrame = screenManager.visibleFrame(for: fromScreen)
        let targetVisibleFrame = screenManager.visibleFrame(for: toScreen)
        
        let windowAppKit = screenManager.convertFromCGCoordinates(frame: window.frame, for: fromScreen)
        
        let relativeX = (windowAppKit.origin.x - sourceFrame.origin.x) / sourceFrame.width
        let relativeY = (windowAppKit.origin.y - sourceFrame.origin.y) / sourceFrame.height
        let relativeWidth = windowAppKit.width / sourceFrame.width
        let relativeHeight = windowAppKit.height / sourceFrame.height
        
        let targetAppKit = CGRect(
            x: targetVisibleFrame.origin.x + (relativeX * targetVisibleFrame.width),
            y: targetVisibleFrame.origin.y + (relativeY * targetVisibleFrame.height),
            width: relativeWidth * targetVisibleFrame.width,
            height: relativeHeight * targetVisibleFrame.height
        )
        
        return screenManager.convertToCGCoordinates(frame: targetAppKit, for: toScreen)
    }
}
