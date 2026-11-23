//
//  AppState+FocusAndFloating.swift
//  Rapto
//
//  Focus mode zone, focus mode and floating windows.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications
extension AppState {
    // MARK: - Focus Mode Zone
    
    func saveFocusModeZone() {
        if let zone = focusModeZone {
            let dict: [String: CGFloat] = [
                "x": zone.origin.x,
                "y": zone.origin.y,
                "width": zone.width,
                "height": zone.height
            ]
            UserDefaults.standard.set(dict, forKey: "focusModeZone")
        } else {
            UserDefaults.standard.removeObject(forKey: "focusModeZone")
        }
    }
    
    func loadFocusModeZone() {
        if let dict = UserDefaults.standard.dictionary(forKey: "focusModeZone"),
           let x = dict["x"] as? CGFloat,
           let y = dict["y"] as? CGFloat,
           let width = dict["width"] as? CGFloat,
           let height = dict["height"] as? CGFloat {
            focusModeZone = CGRect(x: x, y: y, width: width, height: height)
        }
    }
    
    func loadFocusModeDoubleTapModifier() {
        let defaults = UserDefaults.standard
        if let enabled = defaults.object(forKey: "focusModeEnabled") as? Bool {
            focusModeEnabled = enabled
        }
        if let enabled = defaults.object(forKey: "focusModeDoubleTapEnabled") as? Bool {
            focusModeDoubleTapEnabled = enabled
        }
        minimizeOthersOnApply = defaults.bool(forKey: "minimizeOthersOnApply")
        if let rawValue = UserDefaults.standard.string(forKey: "focusModeDoubleTapModifier"),
           let modifier = FocusModeModifierKey(rawValue: rawValue) {
            focusModeDoubleTapModifier = modifier
        }
    }
    
    func loadFloatingDoubleTapSettings() {
        floatingDoubleTapEnabled = UserDefaults.standard.bool(forKey: "floatingDoubleTapEnabled")
        if let rawValue = UserDefaults.standard.string(forKey: "floatingDoubleTapModifier"),
           let modifier = FloatingModifierKey(rawValue: rawValue) {
            floatingDoubleTapModifier = modifier
        }
    }
    
    /// Clear focus zone (revert to full screen)
    func clearFocusZone() {
        focusModeZone = nil
        debugLog("AppState", "Focus zone cleared, reverting to full screen")
    }
    
    func startFocusZoneCreation() {
        isCreatingFocusZone = true
        isSelectingFocusZone = false
        tempZones = []
    }
    
    func cancelFocusZoneSelection() {
        isSelectingFocusZone = false
        isCreatingFocusZone = false
        tempZones = []
    }
    
    /// Save the first temp zone as focus zone (used in creation mode)
    func saveFocusZoneFromTemp() {
        guard let firstZone = tempZones.first else {
            debugLog("AppState", "No temp zone to save as focus zone")
            return
        }
        focusModeZone = firstZone.relativeFrame
        isCreatingFocusZone = false
        tempZones = []
        debugLog("AppState", "Focus zone saved from temp: \(firstZone.relativeFrame)")
    }

    // MARK: - Focus Mode Setup
    
    func setupFocusMode() {
        focusModeService?.onWindowExpanded = { [weak self] windowID, targetFrame, screen in
            self?.didExpandFocusModeWindow(windowID: windowID, targetFrame: targetFrame, on: screen)
        }
        guard focusModeEnabled else { return }
        
        focusModeService?.start()
        focusModeService?.doubleTapEnabled = focusModeDoubleTapEnabled
        focusModeService?.doubleTapModifier = focusModeDoubleTapModifier
        focusModeService?.customZone = focusModeZone
        // Hotkey is registered via hotkeyManager in applyHotkeyPreset()
        
        focusModeService?.$focusedWindows
            .map { Set($0.keys) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                if ids.isEmpty {
                    self?.oneTimeHints.hideIfShowing(.focusMode)
                }
                self?.groupIndicatorManager?.updateIndicators()
            }
            .store(in: &cancellables)
    }

    // MARK: - Floating Window Setup
    
    /// Wires the floating window callbacks and double-tap monitoring.
    /// The floating hotkey itself is registered by applyHotkeyPreset() from the preset bindings.
    func setupFloatingWindowHotkey() {
        
        floatingWindowService?.onFloatStateChanging = { [weak self] windowID in
            self?.focusModeService?.forgetWindow(windowID)
        }
        floatingWindowService?.isWindowLocked = { [weak self] windowID in
            self?.focusModeService?.isFocusedWindow(windowID) == true
        }
        floatingWindowService?.yieldsDoubleTap = { [weak self] flags in
            self?.focusModeService?.isDoubleTapModifierHeld(flags) == true
        }
        focusModeService?.isWindowFloating = { [weak self] windowID in
            self?.floatingWindowService?.isFloating(windowID: windowID) == true
        }

        floatingWindowService?.onRestoreToSlot = { [weak self] window, slotIndex, wasGrouped, screenID in
            self?.restoreWindowToSlot(window, slotIndex: slotIndex, wasGrouped: wasGrouped, screenID: screenID)
        }
        floatingWindowService?.onDoubleTap = { [weak self] window in
            self?.toggleFloating(window)
        }
        
        floatingWindowService?.doubleTapEnabled = floatingDoubleTapEnabled
        floatingWindowService?.doubleTapModifier = floatingDoubleTapModifier
        floatingWindowService?.updateDoubleTapMonitoring()

        doubleClickGuard.ownsDoubleClick = { [weak self] flags in
            guard let self else { return false }
            return self.floatingWindowService?.isDoubleTapModifierHeld(flags) == true
                || self.focusModeService?.isDoubleTapModifierHeld(flags) == true
        }
        doubleClickGuard.onHiddenClick = { [weak self] event in
            self?.focusModeService?.handleHiddenClick(event)
            self?.floatingWindowService?.handleHiddenClick(event)
        }
        doubleClickGuard.start()
        SettingsWindowDetector.shared.start()
    }
    
    func toggleFloatingWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("AppState"," No frontmost application")
            return
        }
        
        let windows = windowManager.enumerateWindows()
        guard let frontWindow = windows.first(where: { $0.ownerPID == frontApp.processIdentifier }) else {
            debugLog("AppState"," No window found for frontmost app")
            return
        }
        toggleFloating(frontWindow)
    }
    
    private func toggleFloating(_ frontWindow: WindowInfo) {
        if floatingWindowService?.isFloating(windowID: frontWindow.windowID) == true {
            floatingWindowService?.unfloat(window: frontWindow)
            return
        }
        
        let windowScreen = screenManager.screen(for: frontWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        let slotIndex = screenState.slotIndex(for: frontWindow.windowID)
        var wasGrouped = false
        
        let isAutoTiling = isAutoTilingScreen(screenID)
        if let slotIndex = slotIndex {
            let slot = screenState.slots[slotIndex]
            wasGrouped = slot.hasGroup
            if isAutoTiling {
                autoTilingService?.rememberLayout(beforeFloating: frontWindow.windowID, forScreenID: screenID)
            }
            
            layoutManager.removeWindow(frontWindow.windowID, forScreenID: screenID)
            debugLog("AppState"," Removed window from slot \(slotIndex) on screen \(screenID) before floating")
            
            groupIndicatorManager?.updateIndicators()
        }
        
        floatingWindowService?.float(window: frontWindow, slotIndex: slotIndex, wasGrouped: wasGrouped, screenID: screenID)
        if isAutoTiling, slotIndex != nil {
            autoTilingService?.retileAfterFloating(frontWindow.windowID, forScreenID: screenID)
        } else {
            autoTilingService?.forgetWindow(frontWindow.windowID)
        }
    }
    
    private func restoreWindowToSlot(_ window: WindowInfo, slotIndex: Int, wasGrouped: Bool, screenID: String?) {
        let targetScreenID: String
        if let screenID = screenID {
            targetScreenID = screenID
        } else {
            let windowScreen = screenManager.screen(for: window)
            targetScreenID = screenManager.identifier(for: windowScreen)
        }
        
        let screenState = layoutManager.state(forScreenID: targetScreenID)

        if isAutoTilingScreen(targetScreenID) {
            debugLog("AppState", " '\(window.title)' stops floating, Auto Tiling retiles screen \(targetScreenID)")
            autoTilingService?.retileAfterUnfloating(window.windowID, forScreenID: targetScreenID)
            return
        }

        guard slotIndex < screenState.slots.count else {
            debugLog("AppState"," Invalid slot index \(slotIndex) for restore on screen \(targetScreenID)")
            return
        }
        
        if wasGrouped {
            layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: targetScreenID)
        } else {
            // Set as primary window (assign replaces windows)
            layoutManager.assignWindow(window, to: slotIndex, forScreenID: targetScreenID)
        }
        
        positionWindowInZone(window, zoneIndex: slotIndex, forScreenID: targetScreenID)
        
        groupIndicatorManager?.updateIndicators()
        
        debugLog("AppState"," Restored '\(window.title)' to slot \(slotIndex) on screen \(targetScreenID), grouped: \(wasGrouped)")
    }
    
    func isWindowFloating(windowID: CGWindowID) -> Bool {
        floatingWindowService?.isFloating(windowID: windowID) ?? false
    }
}
