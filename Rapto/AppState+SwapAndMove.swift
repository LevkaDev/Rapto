//
//  AppState+SwapAndMove.swift
//  Rapto
//
//  What happens after a window is swapped or moved by dragging.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Cross-Screen Move Callback
    
    /// Updates UI indicators when windows are transferred across monitors
    /// For auto-tiling source screens, triggers redistribute to fill freed slots
    func setupCrossScreenMoveCallback() {
        snapBackService?.screenTilesItself = { [weak self] screenID in
            self?.isAutoTilingScreen(screenID) == true
        }

        snapBackService?.onCrossScreenMoveWithScreenInfo = { [weak self] crossScreenMoves in
            guard let self else { return }
            
            let windowNames = crossScreenMoves.map { $0.window.title }.joined(separator: ", ")
            logger.info("Cross-screen move detected: \(crossScreenMoves.count) windows [\(windowNames)]")
            
            var autoTilingSourceScreens: Set<String> = []
            
            for move in crossScreenMoves {
                let fromScreenID = move.fromScreenID
                
                if let fromScreen = self.screenManager.screen(for: fromScreenID) {
                    let fromSpaceID = self.spaceID(for: fromScreen)
                    let fromConfig = self.configuration(forSpaceID: fromSpaceID, screenID: fromScreenID)
                    
                    if fromConfig.mode == .autoTiling {
                        autoTilingSourceScreens.insert(fromScreenID)
                        debugLog("AppState", " Source screen \(fromScreenID) is in auto-tiling, will redistribute")
                    }
                }
            }
            
            // Trigger redistribute for auto-tiling source screens
            // This will fill the freed slots from groups
            for screenID in autoTilingSourceScreens {
                Task { @MainActor [weak self] in
                    // Small delay to let window settle on target screen
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
                    debugLog("AppState", " Triggering redistribute for auto-tiling source screen \(screenID)")
                    self?.autoTilingService?.redistributeNow(forScreenID: screenID)
                }
            }
            
            self.groupIndicatorManager?.updateIndicators()
            
            // Save layout for all active screens to persist changes
            // Each screen may have its own Space in multi-monitor setups
            for screenID in self.layoutManager.screenStates.keys {
                if self.layoutManager.state(forScreenID: screenID).isActive {
                    if let screen = self.screenManager.screen(for: screenID) {
                        let screenSpaceID = self.spaceID(for: screen)
                        self.layoutManager.saveLayoutInfo(
                            forSpaceID: screenSpaceID,
                            screenID: screenID
                        )
                    }
                }
            }
        }
    }

    // MARK: - Swap Callback
    
    /// Saves a screen's layout under that screen's own Space, when it has a layout
    private func saveLayout(forScreenID screenID: String) {
        guard layoutManager.state(forScreenID: screenID).isActive,
              let screen = screenManager.screen(for: screenID) else { return }
        layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: screen), screenID: screenID)
    }
    
    func setupSwapCallback() {
        windowSwapService?.onSwapStarting = { [weak self] in
            self?.autoTilingService?.skipSnapBackForCurrentDrop()
            self?.snapBackService?.skipSnapBackForCurrentDrop()
        }

        windowSwapService?.swapsOnly = { [weak self] window in
            guard let self else { return false }
            return self.mode(for: self.screenManager.screen(for: window)) == .autoTiling
        }
        windowSwapService?.joinsScreenOf = { [weak self] dragged, target in
            guard let self else { return false }
            let targetScreen = self.screenManager.screen(for: target)
            return self.mode(for: targetScreen) == .autoTiling
                && self.screenManager.identifier(for: targetScreen) != self.screenManager.identifier(for: self.screenManager.screen(for: dragged))
        }
        windowSwapService?.slotFrame = { [weak self] windowID in
            guard let self else { return nil }
            let screens = NSScreen.screens.map { screen in
                (mode: self.mode(for: screen), state: self.layoutManager.state(forScreenID: self.screenManager.identifier(for: screen)))
            }
            return Self.swapSlotFrame(holding: windowID, on: screens)
        }
        
        windowSwapService?.onSwapPerformed = { [weak self] window1ID, window2ID in
            guard let self else { return }
            
            debugLog("AppState", "🔄 onSwapPerformed: window1=\(window1ID), window2=\(window2ID)")

            if let changed = self.dropAcrossScreens(window1ID, onto: window2ID, { dragged, target in
                self.layoutManager.swapWindowsAcrossScreens(dragged: dragged, target: target)
            }) {
                self.windowResizeService?.swapManagedWindows(window1ID: window1ID, window2ID: window2ID)
                self.finishDropAcrossScreens(changed)
                return
            }
            
            let screenID = self.layoutManager.findWindowAcrossScreens(window1ID)?.screenID ?? self.layoutManager.activeScreenID
            if let stateBefore = self.layoutManager.screenStates[screenID] {
                debugLog("AppState", "  BEFORE swap - screenStates[\(screenID)]:")
                for (i, slot) in stateBefore.slots.enumerated() {
                    debugLog("AppState", "    slot[\(i)]: \(slot.windows.count) windows - IDs: \(slot.windows.map { $0.windowID })")
                }
            }
            
            // The layout manager is updated here only, not by the services
            self.layoutManager.swapWindows(window1ID, window2ID)
            
            if let stateAfter = self.layoutManager.screenStates[screenID] {
                debugLog("AppState", "  AFTER swap - screenStates[\(screenID)]:")
                for (i, slot) in stateAfter.slots.enumerated() {
                    debugLog("AppState", "    slot[\(i)]: \(slot.windows.count) windows - IDs: \(slot.windows.map { $0.windowID })")
                }
            }
            
            // Update resize service tracking (doesn't touch layoutManager)
            self.windowResizeService?.swapManagedWindows(window1ID: window1ID, window2ID: window2ID)
            
            // Snap-back is already disabled via onSwapStarting callback
            
            debugLog("AppState", "  Calling groupIndicatorManager?.updateIndicators()")
            self.refreshGroupIndicatorsAfterWindowMove()
            
            self.saveLayout(forScreenID: screenID)
            NotificationCenter.default.post(name: .raptoTourDidSwapWindows, object: nil)
        }
        
        windowSwapService?.onMovePerformed = { [weak self] movedWindowID, targetWindowID in
            guard let self else { return }
            debugLog("AppState", " onMovePerformed: moving window \(movedWindowID) to slot of \(targetWindowID)")

            if let changed = self.dropAcrossScreens(movedWindowID, onto: targetWindowID, { dragged, target in
                self.layoutManager.moveWindowAcrossScreens(dragged, toSlotOf: target.windowID)
            }) {
                self.finishDropAcrossScreens(changed)
                NotificationCenter.default.post(name: .raptoTourDidGroupWindows, object: nil)
                return
            }
            
            // The screen whose layout holds the dragged window, not necessarily the active one
            guard let screenID = self.layoutManager.findWindowAcrossScreens(movedWindowID)?.screenID else {
                debugLog("AppState", " onMovePerformed: window \(movedWindowID) is not in any layout")
                return
            }
            
            self.layoutManager.moveWindowToSlot(windowID: movedWindowID, targetWindowID: targetWindowID, forScreenID: screenID)
            
            self.refreshGroupIndicatorsAfterWindowMove()
            
            self.saveLayout(forScreenID: screenID)
            if self.layoutManager.state(forScreenID: screenID).slots.contains(where: \.hasGroup) {
                NotificationCenter.default.post(name: .raptoTourDidGroupWindows, object: nil)
            }
        }
        
        windowSwapService?.isWindowLocked = { [weak self] windowID in
            self?.focusModeService?.isFocusedWindow(windowID) == true
        }

        windowSwapService?.onMoveToEmptySlot = { [weak self] movedWindowID, slotIndex, screenID in
            guard let self else { return }
            debugLog("AppState", " onMoveToEmptySlot: moving window \(movedWindowID) to empty slot \(slotIndex) on screen \(screenID)")

            if self.layoutManager.findWindowAcrossScreens(movedWindowID)?.screenID != screenID,
               let moved = self.windowManager.refreshWindowInfo(for: movedWindowID) {
                self.finishDropAcrossScreens(self.layoutManager.moveWindowAcrossScreens(moved, toEmptySlot: slotIndex, forScreenID: screenID))
                return
            }
            
            self.layoutManager.moveWindowToEmptySlot(windowID: movedWindowID, slotIndex: slotIndex, forScreenID: screenID)
            
            self.refreshGroupIndicatorsAfterWindowMove()
            
            self.saveLayout(forScreenID: screenID)
        }
        
        autoTilingService?.onWindowsRedistributed = { [weak self] windows in
            debugLog("AppState", "📢 onWindowsRedistributed callback triggered with \(windows.count) windows")
            self?.windowResizeService?.setManagedLayout(windows: windows)
            self?.windowHighlightService?.windowsChanged()
            // Force refresh floating group indicators after auto-tiling redistribution
            // Using forceRefresh() to ensure cache is cleared and indicators are rebuilt
            self?.groupIndicatorManager?.forceRefresh()
        }
        autoTilingService?.onWindowsLeftScreens = { [weak self] screenIDs in
            guard let self else { return }
            self.groupIndicatorManager?.updateIndicators()
            for screenID in screenIDs {
                self.saveLayout(forScreenID: screenID)
            }
        }
    }
    
    /// A drop onto a window whose layout is on another screen than the dragged window's
    /// - Returns: The screens whose layouts changed, or nil when both are on one screen
    private func dropAcrossScreens(_ draggedID: CGWindowID, onto targetID: CGWindowID,
                                   _ apply: (WindowInfo, WindowInfo) -> [String]) -> [String]? {
        guard let targetScreenID = layoutManager.findWindowAcrossScreens(targetID)?.screenID,
              layoutManager.findWindowAcrossScreens(draggedID)?.screenID != targetScreenID,
              let dragged = windowManager.refreshWindowInfo(for: draggedID),
              let target = windowManager.refreshWindowInfo(for: targetID) else { return nil }
        return apply(dragged, target)
    }

    private func finishDropAcrossScreens(_ changedScreenIDs: [String]) {
        refreshGroupIndicatorsAfterWindowMove()
        for screenID in Set(changedScreenIDs) {
            saveLayout(forScreenID: screenID)
        }
    }

    /// The window server commits a moved window's CGWindowList bounds shortly after Accessibility sets its frame.
    private func refreshGroupIndicatorsAfterWindowMove() {
        groupIndicatorManager?.updateIndicators()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.groupIndicatorManager?.updateIndicators()
        }
    }

    /// Setup coordination between resize service and snap-back service
    /// This prevents conflicts when user manually resizes windows
    func setupResizeCoordination() {
        // Snap-back is not paused on mouse down.
        // SnapBackService tells a move from a resize by comparing window sizes:
        // - Size unchanged = move → snap back
        // - Size changed = resize → let resize service handle it
        
        windowResizeService?.isWindowLocked = { [weak self] windowID in
            self?.focusModeService?.isFocusedWindow(windowID) == true
        }

        windowResizeService?.onResizeStarted = { [weak self] in
            logger.info("Resize detected by resize service")
            self?.windowHighlightService?.hideForResize()
        }
        
        windowResizeService?.onResizeCompleted = { [weak self] updatedSlotFrames, screenID in
            guard let self = self else { return }
            
            logger.info("Resize completed - updated \(updatedSlotFrames.count) slots on screen \(screenID)")
            
            // Don't re-read window positions here. WindowResizeService already updated the slot
            // frames through layoutManager.updateSlotFrame(), and Accessibility reads can lag and
            // return old frames, which would overwrite the new slot frames.
            
            self.saveLayout(forScreenID: screenID)
            
            self.groupIndicatorManager?.updateIndicators()
        }
    }
    
    func setupWindowRepositioningSubscription() {
        layoutManager.windowNeedsRepositioning
            .sink { [weak self] (slotIndex, window) in
                guard let self = self else { return }
                debugLog("AppState"," Window '\(window.title)' needs repositioning to slot \(slotIndex)")
                self.positionWindowInZone(window, zoneIndex: slotIndex)
                self.groupIndicatorManager?.updateIndicators()
            }
            .store(in: &cancellables)
    }
}

extension AppState {
    /// Frame of the slot that holds the window, on screens where windows are kept in slots.
    /// A swap uses it instead of the windows' own frames: a window that sits a few points off
    /// its slot, or that the drag has already moved by the time it is identified (a press on an
    /// inactive app's window), would otherwise send the other window to that place.
    static func swapSlotFrame(holding windowID: CGWindowID, on screens: [(mode: TilingMode, state: LayoutState)]) -> CGRect? {
        for screen in screens where (screen.mode == .autoTiling || screen.mode == .manualAssignment) && screen.state.isActive {
            if let slot = screen.state.slots.first(where: { $0.windows.contains { $0.windowID == windowID } }) {
                return slot.frame
            }
        }
        return nil
    }
}
