//
//  AppState+Hotkeys.swift
//  Rapto
//
//  Global shortcuts, layout shortcuts and shortcut presets.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
extension AppState {
    // MARK: - Hotkey Setup
    
    /// Does nothing. The overlay and window-move hotkeys are registered by applyHotkeyPreset from the preset bindings.
    func setupHotkey() {
    }
    
    func setupGroupCyclingHotkeys() {
        debugLog("AppState"," setupGroupCyclingHotkeys: isGroupingEnabled=\(isGroupingEnabled)")
        guard isGroupingEnabled else {
            debugLog("AppState"," Grouping disabled, not registering group cycling hotkey")
            return
        }
        
        let tabKeyCode: UInt32 = 0x30
        let modifiers = UInt32(controlKey)
        
        debugLog("AppState"," Registering group cycling: Control+Tab")
        
        hotkeyManager.registerGroupCyclingHotkey(
            keyCode: tabKeyCode,
            modifiers: modifiers
        ) { [weak self] in
            Task { @MainActor in
                debugLog("AppState"," Control+Tab pressed - cycling windows")
                self?.cycleActiveWindowGroup(direction: .backward)
            }
        }
    }
    
    private func toggleGroupForFrontmostWindow() {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("toggleGroup: no focused app")
            return
        }
        
        let focusedPID = focusedApp.processIdentifier
        
        let windows = windowManager.enumerateWindows()
        guard let focusedWindow = windows.first(where: { $0.ownerPID == focusedPID }) else {
            logger.warning("toggleGroup: no window found for frontmost app")
            return
        }
        
        let windowScreen = screenManager.screen(for: focusedWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        guard let result = layoutManager.toggleGroupSameApp(
            frontmostWindowID: focusedWindow.windowID,
            forScreenID: screenID
        ) else {
            logger.warning("toggleGroup: toggle operation failed")
            return
        }
        
        if !result.didPerformAction {
            logger.debug("toggleGroup: no action needed (only 1 window)")
            return
        }
        
        logger.info("toggleGroup: \(result.wasGrouping ? "GROUPED" : "UNGROUPED") windows, logical count: \(result.logicalWindowCount)")
        
        for (slotIndex, window) in result.windowsToReposition {
            let screenState = layoutManager.state(forScreenID: screenID)
            guard slotIndex < screenState.slots.count else { continue }
            
            let slot = screenState.slots[slotIndex]
            _ = accessibilityService.setWindowFrame(window, frame: slot.frame)
            logger.debug("Repositioned '\(window.title)' to slot \(slotIndex + 1)")
        }
        
        if result.wasGrouping {
            // The template is not changed on group; the user or the next redistribution changes it
        } else {
            // The windows are already positioned; the template changes on the next window event
        }
        
        groupIndicatorManager?.updateIndicators()
    }
    
    private func toggleGroupIndicatorsVisibility() {
        groupIndicatorsHidden.toggle()
        debugLog("AppState", "Group indicators \(groupIndicatorsHidden ? "hidden" : "visible")")
    }
    
    private func cycleActiveWindowGroup(direction: CycleDirection) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("Cannot cycle - no focused window")
            return
        }
        
        let focusedPID = focusedApp.processIdentifier
        
        let windows = windowManager.enumerateWindows()
        guard let focusedWindow = windows.first(where: { $0.ownerPID == focusedPID }) else {
            logger.warning("Cannot cycle - no window found for frontmost app")
            return
        }
        
        let windowScreen = screenManager.screen(for: focusedWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        
        guard let slotIndex = screenState.slotIndex(for: focusedWindow.windowID) else {
            if !cycleSnapGroup(of: focusedWindow, windows: windows) {
                logger.debug("No slot found for focused window on screen \(screenID)")
            }
            return
        }
        
        let slot = screenState.slots[slotIndex]
        guard slot.hasGroup else {
            logger.debug("Slot has no group to cycle")
            return
        }
        
        let visibleWindowIDs = Set(windows.map { $0.windowID })
        
        let visibleInSlot = slot.windows.filter { visibleWindowIDs.contains($0.windowID) }
        guard visibleInSlot.count > 1 else {
            debugLog("AppState", " Only \(visibleInSlot.count) visible window(s) in slot, cannot cycle")
            return
        }
        
        // Cycle windows in the slot on THIS screen (only among visible ones)
        // Always use BACKWARD - it works reliably with skipCount: 1
        layoutManager.cycleWindowsSkippingMinimized(in: slotIndex, direction: .backward, visibleWindowIDs: visibleWindowIDs, forScreenID: screenID)
        
        let updatedScreenState = layoutManager.state(forScreenID: screenID)
        if let newActiveWindow = updatedScreenState.slots[slotIndex].primaryWindow {
            let windowToRaise = windowManager.refreshWindowInfo(for: newActiveWindow.windowID) ?? newActiveWindow
            
            // Check if there are OTHER windows in the slot from the SAME app
            // If so, getAXWindow can't distinguish them by position, need to use z-order
            let allSlotWindows = updatedScreenState.slots[slotIndex].windows
            let sameAppWindowsInSlot = allSlotWindows.filter { $0.ownerPID == newActiveWindow.ownerPID }
            let hasSameAppSiblings = sameAppWindowsInSlot.count > 1
            
            debugLog("AppState", " Raising window \(windowToRaise.windowID) (\(windowToRaise.ownerName)), hasSameAppSiblings=\(hasSameAppSiblings)")
            
            if hasSameAppSiblings {
                // Same-app siblings: always use skipCount: 1 (backward logic works)
                accessibilityService.raiseNonFrontmostWindowAtPosition(windowToRaise, skipCount: 1)
            } else {
                accessibilityService.raiseWindow(windowToRaise)
            }
        }
        
        groupIndicatorManager?.updateIndicators()
    }
    
    /// Brings the backmost window of a Drag to Snap group to the front, so repeated presses go through all of them.
    /// - Parameter windows: visible windows, front to back
    private func cycleSnapGroup(of focusedWindow: WindowInfo, windows: [WindowInfo]) -> Bool {
        let frames = Dictionary(windows.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        guard let group = dragSnapService?.snapGroups(windowFrames: frames).first(where: { $0.windowIDs.contains(focusedWindow.windowID) }) else {
            return false
        }
        let members = windows.filter { group.windowIDs.contains($0.windowID) }
        guard members.count > 1, let next = members.last else { return true }
        
        let hasSameAppSiblings = members.contains { $0.windowID != next.windowID && $0.ownerPID == next.ownerPID }
        debugLog("AppState", " Cycling snap group \(group.key): raising \(next.windowID) (\(next.ownerName)), hasSameAppSiblings=\(hasSameAppSiblings)")
        if hasSameAppSiblings {
            accessibilityService.raiseWindowByZOrder(next)
        } else {
            accessibilityService.raiseWindow(next)
        }
        groupIndicatorManager?.updateIndicators()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.groupIndicatorManager?.updateIndicators()
        }
        return true
    }
    
    /// Setup swap and move-to-slot hotkeys using the current preset
    func setupSwapHotkeys() {
        // For auto-tiling mode, don't require isActive - layout activates dynamically
        // For manual mode, require isActive
        // Check ANY screen has active layout, not just the default "state"
        let anyScreenHasActiveLayout = layoutManager.screensWithActiveLayouts.count > 0
        let shouldRegister = currentMode == .autoTiling || anyScreenHasActiveLayout || layoutManager.state.isActive
        
        debugLog("AppState"," setupSwapHotkeys: currentMode=\(currentMode.displayName), anyScreenHasActiveLayout=\(anyScreenHasActiveLayout), state.isActive=\(layoutManager.state.isActive), shouldRegister=\(shouldRegister)")
        
        guard shouldRegister else {
            debugLog("AppState"," Layout not active and not in auto-tiling mode, not registering swap hotkeys")
            return
        }
        
        let storage = HotkeyPresetStorage()
        let preset = storage.loadCurrentPreset()
        
        debugLog("AppState"," Registering swap and move hotkeys from preset: \(preset.type.rawValue)")
        
        registerSwapHotkeys(from: preset)
        registerMoveHotkeys(from: preset)
    }
    
    private func swapWithAdjacentSlot(direction: HotkeyManager.SwapDirection) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("AppState"," Swap ignored - no frontmost application")
            return
        }
        
        // Use AX API to get the REAL focused window position
        // CGWindowList data may be stale after a swap, but AX API always returns current position
        guard let focusedPos = accessibilityService.getFocusedWindowPosition(for: focusedApp.processIdentifier) else {
            debugLog("AppState"," Swap ignored - could not get focused window position from AX")
            return
        }
        
        debugLog("AppState"," Focused window AX position: \(focusedPos)")
        
        let focusedScreen = screenManager.screen(at: focusedPos) ?? screenManager.activeScreen()
        let screenID = screenManager.identifier(for: focusedScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            debugLog("AppState"," Swap ignored - no active layout on screen \(screenID)")
            return
        }
        
        debugLog("AppState"," 📊 BEFORE swap - slots on \(screenID):")
        for (i, slot) in screenState.slots.enumerated() {
            let windowIDs = slot.windows.map { $0.windowID }
            let frames = slot.windows.map { "(\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)))" }
            debugLog("AppState","   slot[\(i)]: \(windowIDs) frames: \(frames)")
        }
        
        // Find the slot that contains the focused position
        // This uses layoutManager.screenStates which is always up-to-date after swaps,
        // unlike CGWindowList which may have stale frame data
        // The nearest slot, so that two windows of one app side by side are told apart
        let sourceSlotIndex = screenState.findSlotIndex(forPID: focusedApp.processIdentifier, windowOrigin: focusedPos)
        let focusedWindow = sourceSlotIndex.flatMap { index in
            screenState.slots[index].windows.first { $0.ownerPID == focusedApp.processIdentifier }
        }
        
        guard let sourceSlotIndex = sourceSlotIndex, focusedWindow != nil else {
            debugLog("AppState"," Swap ignored - focused window not found in any slot on screen \(screenID)")
            return
        }
        
        guard let targetSlotIndex = findAdjacentSlotOnScreen(from: sourceSlotIndex, direction: direction, screenID: screenID) else {
            debugLog("AppState"," Swap ignored - no adjacent slot found in direction \(direction)")
            return
        }
        
        debugLog("AppState"," Swapping active window from slot \(sourceSlotIndex) with slot \(targetSlotIndex) on screen \(screenID) (direction: \(direction))")
        
        let preSwapState = layoutManager.state(forScreenID: screenID)
        let window1 = preSwapState.slots[sourceSlotIndex].primaryWindow
        let window2 = preSwapState.slots[targetSlotIndex].primaryWindow
        
        // Cache AXUIElement for BOTH windows BEFORE any operations
        // This prevents position-based matching failures when both windows belong to the same app.
        // After moving window1, its new position would be where
        // window2 was, causing getAXWindow(for: window2) to return window1 instead.
        let w1AXElement = window1.flatMap { accessibilityService.getAXWindow(for: $0) }
        let w2AXElement = window2.flatMap { accessibilityService.getAXWindow(for: $0) }
        
        if window1 != nil && w1AXElement == nil {
            debugLog("AppState"," ⚠️ Could not cache AXElement for window1 (\(window1?.title ?? "?"))")
        }
        if window2 != nil && w2AXElement == nil {
            debugLog("AppState"," ⚠️ Could not cache AXElement for window2 (\(window2?.title ?? "?"))")
        }
        
        // Now perform the swap in layout manager (updates internal model only)
        _ = layoutManager.swapActiveWindowsOnly(slot1Index: sourceSlotIndex, slot2Index: targetSlotIndex, forScreenID: screenID)
        
        let layoutState = layoutManager.state(forScreenID: screenID)
        let targetFrame = layoutState.slots[targetSlotIndex].frame
        let sourceFrame = layoutState.slots[sourceSlotIndex].frame
        
        if let w1 = window1, let axElement = w1AXElement {
            let success = accessibilityService.setWindowFrame(axWindow: axElement, frame: targetFrame, windowTitle: w1.title)
            debugLog("AppState"," Positioned '\(w1.title)' in zone \(targetSlotIndex) using cached AXElement: \(success)")
            if success {
                // Update stored frame so next swap can find window by position
                layoutManager.updateWindowFrame(w1.windowID, newFrame: targetFrame, forScreenID: screenID)
            }
        }
        if let w2 = window2, let axElement = w2AXElement {
            let success = accessibilityService.setWindowFrame(axWindow: axElement, frame: sourceFrame, windowTitle: w2.title)
            debugLog("AppState"," Positioned '\(w2.title)' in zone \(sourceSlotIndex) using cached AXElement: \(success)")
            if success {
                // Update stored frame so next swap can find window by position
                layoutManager.updateWindowFrame(w2.windowID, newFrame: sourceFrame, forScreenID: screenID)
            }
        }
        
        let afterState = layoutManager.state(forScreenID: screenID)
        debugLog("AppState"," 📊 AFTER swap - slots on \(screenID):")
        for (i, slot) in afterState.slots.enumerated() {
            let windowIDs = slot.windows.map { $0.windowID }
            let frames = slot.windows.map { "(\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)))" }
            debugLog("AppState","   slot[\(i)]: \(windowIDs) frames: \(frames)")
        }
        
        let screenSpaceID = spaceID(for: focusedScreen)
        layoutManager.saveLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID)
        
        groupIndicatorManager?.updateIndicators()
        
        debugLog("AppState"," ✅ Swap complete")
    }
    
    /// Move the focused window to an adjacent slot without swapping (Option+Shift+Arrows in the default preset)
    private func moveToAdjacentSlot(direction: HotkeyManager.SwapDirection) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("AppState"," Move ignored - no frontmost application")
            return
        }
        
        // Use AX API to get the REAL focused window position
        // CGWindowList data may be stale after a move, but AX API always returns current position
        guard let focusedPos = accessibilityService.getFocusedWindowPosition(for: focusedApp.processIdentifier) else {
            debugLog("AppState"," Move ignored - could not get focused window position from AX")
            return
        }
        
        let focusedScreen = screenManager.screen(at: focusedPos) ?? screenManager.activeScreen()
        let screenID = screenManager.identifier(for: focusedScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            debugLog("AppState"," Move ignored - no active layout on screen \(screenID)")
            return
        }
        
        // Find the slot that contains the focused position
        // This uses layoutManager.screenStates which is always up-to-date,
        // unlike CGWindowList which may have stale frame data
        // The nearest slot, so that two windows of one app side by side are told apart
        let sourceSlotIndex = screenState.findSlotIndex(forPID: focusedApp.processIdentifier, windowOrigin: focusedPos)
        let focusedWindow = sourceSlotIndex.flatMap { index in
            screenState.slots[index].windows.first { $0.ownerPID == focusedApp.processIdentifier }
        }
        
        guard let sourceSlotIndex = sourceSlotIndex, let focusedWindow = focusedWindow else {
            debugLog("AppState"," Move ignored - focused window not found in any slot on screen \(screenID)")
            return
        }
        
        guard let targetSlotIndex = findAdjacentSlotOnScreen(from: sourceSlotIndex, direction: direction, screenID: screenID) else {
            debugLog("AppState"," Move ignored - no adjacent slot found in direction \(direction)")
            return
        }
        
        debugLog("AppState"," Moving window from slot \(sourceSlotIndex) to slot \(targetSlotIndex) on screen \(screenID) (direction: \(direction))")
        
        layoutManager.removeWindow(focusedWindow.windowID, forScreenID: screenID)
        
        layoutManager.addWindowToSlot(focusedWindow, slotIndex: targetSlotIndex, forScreenID: screenID)
        
        positionWindowInZone(focusedWindow, zoneIndex: targetSlotIndex, forScreenID: screenID)
        
        let screenSpaceID = spaceID(for: focusedScreen)
        layoutManager.saveLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID)
        
        groupIndicatorManager?.updateIndicators()
        
        debugLog("AppState"," Move complete - window now in slot \(targetSlotIndex)")
    }
    
    private func findAdjacentSlotOnScreen(from slotIndex: Int, direction: HotkeyManager.SwapDirection, screenID: String) -> Int? {
        let screenState = layoutManager.state(forScreenID: screenID)
        let slots = screenState.slots
        guard slotIndex < slots.count else { return nil }
        
        let currentSlot = slots[slotIndex]
        let currentFrame = currentSlot.frame
        
        guard currentFrame.width > 0 && currentFrame.height > 0 else { return nil }
        
        let currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        var bestCandidate: (index: Int, distance: CGFloat)?
        
        for (index, slot) in slots.enumerated() {
            guard index != slotIndex else { continue }
            // Allow swapping with empty slots - this moves window to empty slot
            
            let targetFrame = slot.frame
            guard targetFrame.width > 0 && targetFrame.height > 0 else { continue }
            
            let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            
            let isValidDirection: Bool
            switch direction {
            case .left:
                isValidDirection = targetCenter.x < currentCenter.x
            case .right:
                isValidDirection = targetCenter.x > currentCenter.x
            case .up:
                isValidDirection = targetCenter.y < currentCenter.y
            case .down:
                isValidDirection = targetCenter.y > currentCenter.y
            }
            
            guard isValidDirection else { continue }
            
            let dx = abs(targetCenter.x - currentCenter.x)
            let dy = abs(targetCenter.y - currentCenter.y)
            
            let distance: CGFloat
            switch direction {
            case .left, .right:
                distance = dx + dy * 0.5
            case .up, .down:
                distance = dy + dx * 0.5
            }
            
            if bestCandidate == nil || distance < bestCandidate!.distance {
                bestCandidate = (index, distance)
            }
        }
        
        return bestCandidate?.index
    }
    
    /// Refreshes WindowInfo before raising to ensure current position is used
    func raiseWindowViaAccessibility(_ window: WindowInfo) {
        let windowToRaise = windowManager.refreshWindowInfo(for: window.windowID) ?? window
        accessibilityService.raiseWindow(windowToRaise)
    }

    // MARK: - Template Hotkeys
    
    func loadAndRegisterTemplateHotkeys() {
        // A shortcut of a layout that no longer exists has no row in Settings, so it could never be cleared
        let existing = Set(allTemplates.map(\.id))
        templateHotkeys = templateHotkeys.filter { existing.contains($0.templateID) }
        
        for hotkey in templateHotkeys {
            hotkeyManager.registerTemplateHotkey(
                templateID: hotkey.templateID,
                keyCode: hotkey.keyCode,
                modifiers: hotkey.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.applyTemplateDirectly(templateID: hotkey.templateID)
                }
            }
        }
        
        if !templateHotkeys.isEmpty {
            logger.info("Registered \(self.templateHotkeys.count) template hotkeys")
        }
    }
    
    func removeHotkey(from template: GridTemplate) {
        templateHotkeys = templateHotkeyStorage.removeHotkey(forTemplateID: template.id, from: templateHotkeys)
        hotkeyManager.unregisterTemplateHotkey(templateID: template.id)
        
        logger.info("Removed hotkey from template '\(template.name)'")
    }
    
    func assignCustomHotkey(to template: GridTemplate, binding: HotkeyBinding) {
        let hotkey = TemplateHotkey(
            templateID: template.id,
            templateName: template.name,
            keyCode: binding.keyCode,
            modifiers: binding.modifiers
        )
        
        templateHotkeys = templateHotkeyStorage.setHotkey(hotkey, in: templateHotkeys)
        
        hotkeyManager.registerTemplateHotkey(
            templateID: template.id,
            keyCode: binding.keyCode,
            modifiers: binding.modifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.applyTemplateDirectly(templateID: template.id)
            }
        }
        
        logger.info("Assigned custom hotkey to template '\(template.name)'")
    }
    
    func hotkey(for template: GridTemplate) -> TemplateHotkey? {
        return templateHotkeyStorage.hotkey(forTemplateID: template.id, in: templateHotkeys)
    }
    
    /// Apply a template directly to current windows (without overlay)
    /// Groups windows intelligently: same-app windows together, excess windows in last slot
    func applyTemplateDirectly(templateID: UUID) {
        guard let template = allTemplates.first(where: { $0.id == templateID }) else {
            logger.warning("Template not found for ID: \(templateID)")
            return
        }
        let activeScreen = screenManager.activeScreen()
        if switchManualTemplate(to: template, screen: activeScreen) { return }
        
        if !accessibilityService.checkPermission() {
            logger.error("Accessibility permission not granted!")
            accessibilityService.requestPermission()
            return
        }
        
        let screenID = screenManager.identifier(for: activeScreen)
        let zoneCount = template.zones.count
        debugLog("AppState"," applyTemplateDirectly: template='\(template.name)' (\(zoneCount) zones) on screen '\(screenID)', groupingEnabled=\(isGroupingEnabled)")
        
        var allWindows: [WindowInfo] = []
        
        let screenState = layoutManager.state(forScreenID: screenID)
        if screenState.isActive {
            // Use windows from current layout (preserves order and grouping info)
            allWindows = screenState.allWindows
            debugLog("AppState"," Using \(allWindows.count) windows from current layout")
        }
        
        // Also get fresh windows to catch any new ones; other displays keep their windows
        let allFreshWindows = windowManager.enumerateWindows()
        let freshWindows = allFreshWindows.filter { window in
            screenManager.identifier(for: screenManager.screen(for: window)) == screenID
        }
        let existingIDs = Set(allWindows.map { $0.windowID })
        for fresh in freshWindows {
            if !existingIDs.contains(fresh.windowID) {
                allWindows.append(fresh)
            }
        }
        
        // Update window info with fresh data (positions may have changed)
        allWindows = allWindows.compactMap { window in
            freshWindows.first(where: { $0.windowID == window.windowID })
        }
        
        debugLog("AppState"," Total windows to distribute: \(allWindows.count)")
        
        guard !allWindows.isEmpty else {
            logger.warning("No windows to tile")
            return
        }
        
        var slotAssignments: [[WindowInfo]] = Array(repeating: [], count: zoneCount)
        var assignedWindowIDs: Set<CGWindowID> = []
        
        if isGroupingEnabled && allWindows.count > zoneCount {
            debugLog("AppState"," \(allWindows.count) windows > \(zoneCount) zones - grouping required")
            
            var windowsByApp: [String: [WindowInfo]] = [:]
            for window in allWindows {
                let appKey = window.bundleIdentifier ?? window.ownerName
                windowsByApp[appKey, default: []].append(window)
            }
            
            debugLog("AppState"," Windows grouped into \(windowsByApp.count) apps")
            
            // Sort app groups by size (largest first) to prioritize same-app grouping
            let sortedAppGroups = windowsByApp.sorted { $0.value.count > $1.value.count }
            
            var currentSlot = 0
            
            for (appKey, appWindows) in sortedAppGroups {
                if currentSlot >= zoneCount {
                    for window in appWindows where !assignedWindowIDs.contains(window.windowID) {
                        slotAssignments[zoneCount - 1].append(window)
                        assignedWindowIDs.insert(window.windowID)
                        debugLog("AppState"," Overflow: '\(window.title)' -> last slot")
                    }
                    continue
                }
                
                // First window of this app gets its own slot (or shares if already assigned)
                var appSlotIndex: Int? = nil
                
                for window in appWindows {
                    if assignedWindowIDs.contains(window.windowID) { continue }
                    
                    if appSlotIndex == nil {
                        if currentSlot < zoneCount {
                            appSlotIndex = currentSlot
                            slotAssignments[currentSlot].append(window)
                            assignedWindowIDs.insert(window.windowID)
                            debugLog("AppState"," Primary: '\(window.title)' (\(appKey)) -> slot \(currentSlot)")
                            currentSlot += 1
                        } else {
                            appSlotIndex = zoneCount - 1
                            slotAssignments[zoneCount - 1].append(window)
                            assignedWindowIDs.insert(window.windowID)
                            debugLog("AppState"," Overflow primary: '\(window.title)' -> last slot")
                        }
                    } else {
                        slotAssignments[appSlotIndex!].append(window)
                        assignedWindowIDs.insert(window.windowID)
                        debugLog("AppState"," Grouped: '\(window.title)' (\(appKey)) -> slot \(appSlotIndex!)")
                    }
                }
            }
        } else {
            for (index, window) in allWindows.enumerated() {
                let slotIndex = min(index, zoneCount - 1)
                slotAssignments[slotIndex].append(window)
                assignedWindowIDs.insert(window.windowID)
                debugLog("AppState"," Simple: '\(window.title)' -> slot \(slotIndex)")
            }
        }
        
        let screenFrame = screenManager.visibleFrame(for: activeScreen)
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        var primaryWindows: [WindowInfo] = []
        
        for (slotIndex, windows) in slotAssignments.enumerated() {
            guard slotIndex < sortedZones.count, !windows.isEmpty else { continue }
            
            let zone = sortedZones[slotIndex]
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: activeScreen)
            
            // Position all windows in this slot. setWindowFrame looks up the AX window once per window,
            // which matters for apps such as Xcode that expose several AX windows.
            for (windowIndex, window) in windows.enumerated() {
                _ = accessibilityService.setWindowFrame(window, frame: cgFrame)
                
                if windowIndex == 0 {
                    primaryWindows.append(window)
                    debugLog("AppState"," Positioned primary '\(window.title)' in zone \(slotIndex + 1)")
                } else {
                    debugLog("AppState"," Positioned grouped '\(window.title)' in zone \(slotIndex + 1)")
                }
            }
        }
        
        for window in primaryWindows.reversed() {
            accessibilityService.raiseWindow(window)
        }
        
        layoutManager.setLayout(template: template, windows: primaryWindows, forScreenID: screenID)
        
        if isGroupingEnabled {
            let slotCount = layoutManager.state(forScreenID: screenID).slots.count
            for (slotIndex, windows) in slotAssignments.enumerated() {
                guard slotIndex < slotCount else { continue }
                
                for window in windows.dropFirst() {
                    layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: screenID)
                    debugLog("AppState"," Added grouped '\(window.title)' to slot \(slotIndex)")
                }
            }
        }
        
        groupIndicatorManager?.updateIndicators()
        
        let currentSpaceID = spaceID(for: activeScreen)
        layoutManager.saveLayoutInfo(forSpaceID: currentSpaceID, screenID: screenID)
        
        var screenConfig = ScreenConfigurationStorage.configuration(
            forSpaceID: currentSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        screenConfig.templateID = template.id
        ScreenConfigurationStorage.setConfiguration(
            screenConfig,
            forSpaceID: currentSpaceID,
            screenID: screenID,
            in: &screenConfigurations
        )
        
        // Also update legacy SpaceConfiguration for backward compatibility
        var legacyConfig = spaceConfigurations[currentSpaceID] ?? .default
        legacyConfig.templateID = template.id
        spaceConfigurations[currentSpaceID] = legacyConfig
        SpaceConfigurationStorage.save(spaceConfigurations)
        
        windowIDsAtLayoutApply = Set(allFreshWindows.map { $0.windowID })
        
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            let updatedWindows = self.windowManager.enumerateWindows().filter { window in
                assignedWindowIDs.contains(window.windowID)
            }
            self.windowResizeService?.setManagedLayout(windows: updatedWindows)
            
            if self.isGroupingEnabled && self.autoGroupSameApp && self.currentMode == .manualAssignment {
                self.setupManualModeGroupingObservers()
            }
            
            self.setupSwapHotkeys()
        }
        
        let groupedSlots = slotAssignments.filter { $0.count > 1 }.count
        logger.info("Template '\(template.name)' applied: \(allWindows.count) windows in \(zoneCount) zones (\(groupedSlots) slots with groups)")
    }
    
    func applyTemplateToScreen(template: GridTemplate, screen: NSScreen) {
        if switchManualTemplate(to: template, screen: screen) { return }
        let screenID = screenManager.identifier(for: screen)
        let screenFrame = screenManager.visibleFrame(for: screen)
        let zoneCount = template.zones.count
        
        debugLog("AppState", " applyTemplateToScreen: template='\(template.name)' to screen '\(screenID)'")
        
        let allWindows = windowManager.enumerateWindows()
        let windowsOnScreen = allWindows.filter { window in
            let windowScreen = screenManager.screen(for: window)
            return screenManager.identifier(for: windowScreen) == screenID
        }
        
        guard !windowsOnScreen.isEmpty else {
            logger.info("No windows on screen \(screenID) to tile - initializing empty layout")
            saveTemplateConfig(template: template, forScreen: screen)
            // Also initialize layoutManager with empty slots for the new template
            // This ensures the new template is active when windows appear
            layoutManager.setLayout(template: template, windows: [], forScreenID: screenID)
            return
        }
        
        debugLog("AppState", " Found \(windowsOnScreen.count) windows on screen \(screenID)")
        
        var slotAssignments: [[WindowInfo]] = Array(repeating: [], count: zoneCount)
        var assignedWindowIDs: Set<CGWindowID> = []
        
        if isGroupingEnabled && windowsOnScreen.count > zoneCount {
            var windowsByApp: [String: [WindowInfo]] = [:]
            for window in windowsOnScreen {
                let appKey = window.bundleIdentifier ?? window.ownerName
                windowsByApp[appKey, default: []].append(window)
            }
            
            let sortedAppGroups = windowsByApp.sorted { $0.value.count > $1.value.count }
            var currentSlot = 0
            
            for (_, appWindows) in sortedAppGroups {
                var appSlotIndex: Int? = nil
                
                for window in appWindows {
                    if assignedWindowIDs.contains(window.windowID) { continue }
                    
                    if appSlotIndex == nil {
                        if currentSlot < zoneCount {
                            appSlotIndex = currentSlot
                            slotAssignments[currentSlot].append(window)
                            assignedWindowIDs.insert(window.windowID)
                            currentSlot += 1
                        } else {
                            appSlotIndex = zoneCount - 1
                            slotAssignments[zoneCount - 1].append(window)
                            assignedWindowIDs.insert(window.windowID)
                        }
                    } else {
                        slotAssignments[appSlotIndex!].append(window)
                        assignedWindowIDs.insert(window.windowID)
                    }
                }
            }
        } else {
            for (index, window) in windowsOnScreen.enumerated() {
                let slotIndex = min(index, zoneCount - 1)
                slotAssignments[slotIndex].append(window)
                assignedWindowIDs.insert(window.windowID)
            }
        }
        
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        var primaryWindows: [WindowInfo] = []
        
        for (slotIndex, windows) in slotAssignments.enumerated() {
            guard slotIndex < sortedZones.count, !windows.isEmpty else { continue }
            
            let zone = sortedZones[slotIndex]
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            
            // setWindowFrame looks up the AX window once per window, which matters for apps
            // such as Xcode that expose several AX windows
            for (windowIndex, window) in windows.enumerated() {
                _ = accessibilityService.setWindowFrame(window, frame: cgFrame)
                
                if windowIndex == 0 {
                    primaryWindows.append(window)
                }
            }
        }
        
        for window in primaryWindows.reversed() {
            accessibilityService.raiseWindow(window)
        }
        
        layoutManager.setLayout(template: template, windows: primaryWindows, forScreenID: screenID)
        
        if isGroupingEnabled {
            let screenState = layoutManager.state(forScreenID: screenID)
            for (slotIndex, windows) in slotAssignments.enumerated() {
                guard slotIndex < screenState.slots.count else { continue }
                for window in windows.dropFirst() {
                    layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: screenID)
                }
            }
        }
        
        finishTemplateApply(template: template, screen: screen)
        logger.info("Template '\(template.name)' applied to screen \(screenID): \(windowsOnScreen.count) windows")
    }
    
    /// Put the given windows into the slots of a template on one screen. Slot `i` gets
    /// `slotAssignments[i]` (first window in front, the rest grouped) and, when given,
    /// the frame `slotFrames[i]` in CG coordinates instead of the template's zone.
    func placeWindows(_ slotAssignments: [[WindowInfo]], in template: GridTemplate, on screen: NSScreen, slotFrames: [CGRect?]) {
        let screenID = screenManager.identifier(for: screen)
        let screenFrame = screenManager.visibleFrame(for: screen)
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        layoutManager.setLayout(template: template, windows: [], forScreenID: screenID)
        
        var primaryWindows: [WindowInfo] = []
        for (slotIndex, zone) in sortedZones.enumerated() {
            let zoneFrame = screenManager.convertToCGCoordinates(
                frame: screenManager.calculateAbsoluteFrame(relativeFrame: zone.relativeFrame, in: screenFrame),
                for: screen
            )
            let frame = slotFrames.indices.contains(slotIndex) ? (slotFrames[slotIndex] ?? zoneFrame) : zoneFrame
            layoutManager.updateSlotFrame(slotIndex, frame: frame, forScreenID: screenID)
            
            let windows = slotAssignments.indices.contains(slotIndex) ? slotAssignments[slotIndex] : []
            for (windowIndex, window) in windows.enumerated() {
                _ = accessibilityService.setWindowFrame(window, frame: frame)
                if windowIndex == 0 {
                    primaryWindows.append(window)
                    layoutManager.assignWindow(window, to: slotIndex, forScreenID: screenID)
                } else if isGroupingEnabled {
                    layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: screenID)
                }
            }
        }
        
        for window in primaryWindows.reversed() {
            accessibilityService.raiseWindow(window)
        }
        
        finishTemplateApply(template: template, screen: screen)
        logger.info("Placed \(primaryWindows.count) windows into '\(template.name)' on screen \(screenID)")
    }
    
    func finishTemplateApply(template: GridTemplate, screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        oneTimeHints.hideIfShowing(.manualNeedsLayout)
        
        saveTemplateConfig(template: template, forScreen: screen)
        
        groupIndicatorManager?.updateIndicators()
        
        if mode(for: screen) == .manualAssignment && snapBackEnabled {
            snapBackService?.start(forScreenID: screenID)
        }
        
        if isGroupingEnabled && autoGroupSameApp {
            setupManualModeGroupingObservers()
        }
    }
    
    private func saveTemplateConfig(template: GridTemplate, forScreen screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        
        var screenConfig = ScreenConfigurationStorage.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        screenConfig.templateID = template.id
        ScreenConfigurationStorage.setConfiguration(
            screenConfig,
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: &screenConfigurations
        )
        
        debugLog("AppState", " saveTemplateConfig: screen=\(screenID), spaceID=\(screenSpaceID), templateID=\(template.id)")
        
        layoutManager.saveLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID)
    }

    // MARK: - Hotkey Preset Integration

    func applyHotkeyPreset(_ presetType: HotkeyPresetType) {
        let storage = HotkeyPresetStorage()
        let preset = presetType == .custom ? storage.loadCustomPreset() : HotkeyPreset.preset(for: presetType)
        
        activeHotkeyPreset = presetType
        
        debugLog("AppState", " Applying hotkey preset: \(presetType.rawValue)")
        
        hotkeyManager.unregisterResizeHotkeys()
        hotkeyManager.unregisterFocusDirectionHotkeys()
        hotkeyManager.unregisterModeCycleHotkey()
        hotkeyManager.unregisterFullscreenHotkey()
        hotkeyManager.unregisterRestoreLayoutHotkey()
        hotkeyManager.unregisterGenericHotkeys()
        hotkeyManager.unregisterAllActionHotkeys()
        
        var resizeBindings: [(keyCode: UInt32, modifiers: UInt32, direction: HotkeyManager.ResizeDirection)] = []
        if let shrinkWidth = preset.bindings[.resizeShrinkWidth] {
            resizeBindings.append((shrinkWidth.keyCode, shrinkWidth.modifiers, .shrinkWidth))
        }
        if let growWidth = preset.bindings[.resizeGrowWidth] {
            resizeBindings.append((growWidth.keyCode, growWidth.modifiers, .growWidth))
        }
        if let shrinkHeight = preset.bindings[.resizeShrinkHeight] {
            resizeBindings.append((shrinkHeight.keyCode, shrinkHeight.modifiers, .shrinkHeight))
        }
        if let growHeight = preset.bindings[.resizeGrowHeight] {
            resizeBindings.append((growHeight.keyCode, growHeight.modifiers, .growHeight))
        }
        
        if !resizeBindings.isEmpty {
            hotkeyManager.registerResizeHotkeys(bindings: resizeBindings) { [weak self] direction in
                Task { @MainActor in
                    self?.resizeActiveSlot(direction: direction)
                }
            }
        }
        
        var focusBindings: [(keyCode: UInt32, modifiers: UInt32, direction: HotkeyManager.SwapDirection)] = []
        if let left = preset.bindings[.focusLeft] {
            focusBindings.append((left.keyCode, left.modifiers, .left))
        }
        if let right = preset.bindings[.focusRight] {
            focusBindings.append((right.keyCode, right.modifiers, .right))
        }
        if let up = preset.bindings[.focusUp] {
            focusBindings.append((up.keyCode, up.modifiers, .up))
        }
        if let down = preset.bindings[.focusDown] {
            focusBindings.append((down.keyCode, down.modifiers, .down))
        }
        
        if !focusBindings.isEmpty {
            hotkeyManager.registerFocusDirectionHotkeys(bindings: focusBindings) { [weak self] direction in
                Task { @MainActor in
                    self?.focusWindowInDirection(direction)
                }
            }
        }
        
        if let cycleLayout = preset.bindings[.cycleLayout] {
            hotkeyManager.registerModeCycleHotkey(
                keyCode: cycleLayout.keyCode,
                modifiers: cycleLayout.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.cycleMode()
                }
            }
        }
        
        var modeHandlers: [HotkeyAction: () -> Void] = [:]
        modeHandlers[.switchToManual] = { [weak self] in
            Task { @MainActor in self?.switchToManualMode() }
        }
        modeHandlers[.switchToAuto] = { [weak self] in
            Task { @MainActor in self?.switchToAutoMode() }
        }
        modeHandlers[.switchToDragSnap] = { [weak self] in
            Task { @MainActor in self?.switchToDragSnapMode() }
        }
        
        for (action, handler) in modeHandlers {
            if let binding = preset.bindings[action] {
                hotkeyManager.registerFromPreset(
                    HotkeyPreset(type: presetType, bindings: [action: binding]),
                    handlers: [action: handler]
                )
            }
        }
        
        if let toggleFloat = preset.bindings[.toggleFloat] {
            hotkeyManager.registerTemplateHotkey(
                templateID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, // Reserved ID for floating
                keyCode: toggleFloat.keyCode,
                modifiers: toggleFloat.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.toggleFloatingWindow()
                }
            }
        } else {
            hotkeyManager.unregisterTemplateHotkey(templateID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        }
        
        if let fullscreen = preset.bindings[.toggleFullscreen] {
            hotkeyManager.registerFullscreenHotkey(
                keyCode: fullscreen.keyCode,
                modifiers: fullscreen.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.toggleFullscreen()
                }
            }
        }
        
        if let restoreLayout = preset.bindings[.restoreLayout] {
            hotkeyManager.registerRestoreLayoutHotkey(
                keyCode: restoreLayout.keyCode,
                modifiers: restoreLayout.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.restoreLayoutToOriginal()
                }
            }
        }
        
        if let openSwitcher = preset.bindings[.openWindowSwitcher] {
            hotkeyManager.registerAdditionalHotkeyWithID(
                keyCode: openSwitcher.keyCode,
                modifiers: openSwitcher.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.windowSwitcher.toggle()
                }
            }
        }

        activeWindowFlowBinding = preset.bindings[.openWindowFlow]
        spaceBarController.windowFlowShortcut = activeWindowFlowBinding?.displayString
        if let openFlow = preset.bindings[.openWindowFlow] {
            hotkeyManager.registerAdditionalHotkeyWithID(
                keyCode: openFlow.keyCode,
                modifiers: openFlow.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.windowFlow.toggle()
                }
            }
        }
        
        var desktopMoves: [(action: HotkeyAction, target: SpaceBarMoveTarget)] = [
            (.moveToPreviousDesktop, .previous),
            (.moveToNextDesktop, .next)
        ]
        for (index, action) in HotkeyAction.moveToDesktopNumbered.enumerated() {
            desktopMoves.append((action, .number(index + 1)))
        }
        for move in desktopMoves {
            guard let binding = preset.bindings[move.action] else { continue }
            let target = move.target
            hotkeyManager.registerAdditionalHotkeyWithID(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.spaceBarController.moveFrontWindow(to: target)
                }
            }
        }
        
        registerSwapHotkeys(from: preset)
        registerMoveHotkeys(from: preset)
        
        if let forward = preset.bindings[.cycleGroupForward] {
            hotkeyManager.registerGroupCyclingHotkey(
                keyCode: forward.keyCode,
                modifiers: forward.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.cycleActiveWindowGroup(direction: .backward) // backward logic works
                }
            }
        } else {
            // Also releases the default Control+Tab registered at launch
            hotkeyManager.unregisterGroupCyclingHotkeys()
        }
        
        if let toggleIndicators = preset.bindings[.toggleGroupIndicators] {
            hotkeyManager.registerAdditionalHotkeyWithID(
                keyCode: toggleIndicators.keyCode,
                modifiers: toggleIndicators.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.toggleGroupIndicatorsVisibility()
                }
            }
        }
        
        if let toggleGroup = preset.bindings[.toggleGroupWindows] {
            hotkeyManager.registerAdditionalHotkeyWithID(
                keyCode: toggleGroup.keyCode,
                modifiers: toggleGroup.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.toggleGroupForFrontmostWindow()
                }
            }
        }
        
        if let openOverlay = preset.bindings[.openOverlay] {
            hotkeyManager.registerHotkey(
                keyCode: openOverlay.keyCode,
                modifiers: openOverlay.modifiers
            ) { [weak self] in
                Task { @MainActor in
                    self?.toggleOverlay()
                }
            }
        } else {
            hotkeyManager.unregisterMainHotkey()
        }
        
        var moveToScreenBindings: [(keyCode: UInt32, modifiers: UInt32, direction: HotkeyManager.MoveToScreenDirection)] = []
        if screenManager.isMultiMonitor {
            if let moveLeft = preset.bindings[.moveToScreenLeft] {
                moveToScreenBindings.append((moveLeft.keyCode, moveLeft.modifiers, .left))
            }
            if let moveRight = preset.bindings[.moveToScreenRight] {
                moveToScreenBindings.append((moveRight.keyCode, moveRight.modifiers, .right))
            }
        }
        if moveToScreenBindings.isEmpty {
            hotkeyManager.unregisterWindowMoveHotkeys()
        } else {
            hotkeyManager.registerWindowMoveHotkeysWithBindings(moveToScreenBindings) { [weak self] direction in
                Task { @MainActor in
                    self?.moveWindowToScreen(direction: direction)
                }
            }
        }
        
        let slotActions: [HotkeyAction] = [
            .focusSlot1, .focusSlot2, .focusSlot3, .focusSlot4, .focusSlot5,
            .focusSlot6, .focusSlot7, .focusSlot8, .focusSlot9
        ]
        for (index, action) in slotActions.enumerated() {
            if let binding = preset.bindings[action] {
                let slotIndex = index  // 0-based
                hotkeyManager.registerAdditionalHotkeyWithID(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers
                ) { [weak self] in
                    Task { @MainActor in
                        self?.focusWindowInSlot(slotIndex)
                    }
                }
            }
        }
        
        logger.info("Applied hotkey preset: \(presetType.rawValue)")
    }
    
    /// Registers the swap shortcuts the preset has. With none left, the old ones are released.
    private func registerSwapHotkeys(from preset: HotkeyPreset) {
        let bindings = preset.directionBindings(left: .swapLeft, right: .swapRight, up: .swapUp, down: .swapDown)
        guard !bindings.isEmpty else {
            hotkeyManager.unregisterSwapHotkeys()
            return
        }
        hotkeyManager.registerSwapHotkeysWithBindings(bindings) { [weak self] direction in
            Task { @MainActor in
                self?.swapWithAdjacentSlot(direction: direction)
            }
        }
    }
    
    /// Registers the move-to-slot shortcuts the preset has. With none left, the old ones are released.
    private func registerMoveHotkeys(from preset: HotkeyPreset) {
        let bindings = preset.directionBindings(left: .moveLeft, right: .moveRight, up: .moveUp, down: .moveDown)
        guard !bindings.isEmpty else {
            hotkeyManager.unregisterMoveToSlotHotkeys()
            return
        }
        hotkeyManager.registerMoveToSlotHotkeysWithBindings(bindings) { [weak self] direction in
            Task { @MainActor in
                self?.moveToAdjacentSlot(direction: direction)
            }
        }
    }
    
    private func resizeActiveSlot(direction: HotkeyManager.ResizeDirection) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("AppState", " Resize ignored - no frontmost application")
            return
        }
        
        let windows = windowManager.enumerateWindows()
        guard let focusedWindow = windows.first(where: { $0.ownerPID == focusedApp.processIdentifier }) else {
            debugLog("AppState", " Resize ignored - no window found for frontmost app")
            return
        }
        
        let windowScreen = screenManager.screen(for: focusedWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            debugLog("AppState", " Resize ignored - no active layout on screen \(screenID)")
            return
        }
        
        // The slot of the focused window, not the first slot holding a window of its app
        let focusedPos = accessibilityService.getFocusedWindowPosition(for: focusedApp.processIdentifier)
        let slotAtFocus = focusedPos.flatMap { screenState.findSlotIndex(forPID: focusedApp.processIdentifier, windowOrigin: $0) }
        guard let slotIndex = slotAtFocus ?? screenState.findSlotIndex(forPID: focusedApp.processIdentifier) else {
            debugLog("AppState", " Resize ignored - focused window not in layout on screen \(screenID)")
            return
        }
        
        // The resize service moves the border the slot shares with its neighbours and saves the layout
        let step: CGFloat = 50 // points per keystroke
        guard windowResizeService?.resizeSlot(slotIndex, direction: direction, step: step, onScreen: screenID) == true else {
            debugLog("AppState", " Resize ignored - slot \(slotIndex) on screen \(screenID) can't be resized \(direction)")
            NSSound.beep()
            return
        }

        debugLog("AppState", " Resized slot \(slotIndex) on screen \(screenID) \(direction)")
    }
    
    private func focusWindowInDirection(_ direction: HotkeyManager.SwapDirection) {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            debugLog("AppState", " Focus ignored - no frontmost application")
            return
        }
        
        let windows = windowManager.enumerateWindows()
        guard let focusedWindow = windows.first(where: { $0.ownerPID == focusedApp.processIdentifier }) else {
            debugLog("AppState", " Focus ignored - no window found for frontmost app")
            return
        }
        
        let windowScreen = screenManager.screen(for: focusedWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            debugLog("AppState", " Focus ignored - no active layout on screen \(screenID)")
            return
        }
        
        let focusedPID = focusedApp.processIdentifier
        guard let currentSlotIndex = screenState.findSlotIndex(forPID: focusedPID) else {
            if let firstWindow = screenState.slots.first?.windows.first {
                let windowToFocus = windowManager.refreshWindowInfo(for: firstWindow.windowID) ?? firstWindow
                accessibilityService.raiseWindow(windowToFocus)
            }
            return
        }
        
        guard let adjacentSlotIndex = findAdjacentSlot(from: currentSlotIndex, direction: direction, screenID: screenID) else {
            debugLog("AppState", " No adjacent slot in direction \(direction) on screen \(screenID)")
            return
        }
        
        let slots = screenState.slots
        if adjacentSlotIndex < slots.count,
           let slotWindow = slots[adjacentSlotIndex].windows.first {
            let windowToFocus = windowManager.refreshWindowInfo(for: slotWindow.windowID) ?? slotWindow
            accessibilityService.raiseWindow(windowToFocus)
            debugLog("AppState", " Focused window in slot \(adjacentSlotIndex) on screen \(screenID)")
        }
    }
    
    /// Focus the window in a specific slot by index (0-based)
    /// Used by Focus Slot 1-9 hotkeys
    private func focusWindowInSlot(_ slotIndex: Int) {
        let activeScreen = screenManager.activeScreen()
        let screenID = screenManager.identifier(for: activeScreen)
        let screenState = layoutManager.state(forScreenID: screenID)
        
        guard screenState.isActive else {
            debugLog("AppState", " Focus slot ignored - no active layout on screen \(screenID)")
            return
        }
        
        let slots = screenState.slots
        guard slotIndex < slots.count else {
            debugLog("AppState", " Focus slot ignored - slot \(slotIndex) out of range (have \(slots.count) slots)")
            return
        }
        
        guard let slotWindow = slots[slotIndex].windows.first else {
            debugLog("AppState", " Focus slot ignored - slot \(slotIndex) is empty")
            return
        }
        
        let windowToFocus = windowManager.refreshWindowInfo(for: slotWindow.windowID) ?? slotWindow
        accessibilityService.raiseWindow(windowToFocus)
        debugLog("AppState", " Focused window in slot \(slotIndex + 1) on screen \(screenID)")
    }
    
    private func findAdjacentSlot(from slotIndex: Int, direction: HotkeyManager.SwapDirection, screenID: String? = nil) -> Int? {
        let slots: [Slot]
        if let screenID = screenID {
            slots = layoutManager.state(forScreenID: screenID).slots
        } else {
            slots = layoutManager.state.slots
        }
        guard slotIndex < slots.count else { return nil }
        
        // Use slot frame (not window frame) for consistent navigation
        let currentSlot = slots[slotIndex]
        let currentFrame = currentSlot.frame
        
        let currentCenter: CGPoint
        if currentFrame.width > 0 && currentFrame.height > 0 {
            currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        } else if let windowFrame = currentSlot.windows.first?.frame {
            currentCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        } else {
            return nil
        }
        
        var bestCandidate: (index: Int, distance: CGFloat)?
        
        for (index, slot) in slots.enumerated() {
            guard index != slotIndex else { continue }
            
            guard !slot.windows.isEmpty else { continue }
            
            let targetFrame = slot.frame
            let targetCenter: CGPoint
            if targetFrame.width > 0 && targetFrame.height > 0 {
                targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            } else if let windowFrame = slot.windows.first?.frame {
                targetCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            } else {
                continue
            }
            
            let isValidDirection: Bool
            switch direction {
            case .left:
                isValidDirection = targetCenter.x < currentCenter.x
            case .right:
                isValidDirection = targetCenter.x > currentCenter.x
            case .up:
                // Slot frames are in CG coordinates (top-left origin), so a lower Y is higher on screen
                isValidDirection = targetCenter.y < currentCenter.y
            case .down:
                isValidDirection = targetCenter.y > currentCenter.y
            }
            
            guard isValidDirection else { continue }
            
            let dx = abs(targetCenter.x - currentCenter.x)
            let dy = abs(targetCenter.y - currentCenter.y)
            
            let distance: CGFloat
            switch direction {
            case .left, .right:
                distance = dx + dy * 0.5  // Prefer horizontal alignment
            case .up, .down:
                distance = dy + dx * 0.5  // Prefer vertical alignment
            }
            
            if bestCandidate == nil || distance < bestCandidate!.distance {
                bestCandidate = (index, distance)
            }
        }
        
        if let candidate = bestCandidate {
            debugLog("AppState", " Found adjacent slot \(candidate.index) in direction \(direction)")
        }
        
        return bestCandidate?.index
    }
    
    /// Cycle through tiling modes (None → Manual → Auto → Drag → None)
    func cycleMode() {
        let screen = screenManager.activeScreen()
        let current = mode(for: screen)
        
        let nextMode: TilingMode
        switch current {
        case .none:
            nextMode = .manualAssignment
        case .manualAssignment:
            nextMode = .autoTiling
        case .autoTiling:
            nextMode = .dragSnap
        case .dragSnap:
            nextMode = .none
        }
        
        setMode(nextMode, for: screen)
        debugLog("AppState", " Cycled mode: \(current.displayName) → \(nextMode.displayName)")
    }
    
    func switchToManualMode() {
        let screen = screenManager.activeScreen()
        setMode(.manualAssignment, for: screen)
        debugLog("AppState", " Switched to Manual mode")
    }
    
    func switchToAutoMode() {
        let screen = screenManager.activeScreen()
        setMode(.autoTiling, for: screen)
        debugLog("AppState", " Switched to Auto-tiling mode")
    }
    
    func switchToDragSnapMode() {
        let screen = screenManager.activeScreen()
        setMode(.dragSnap, for: screen)
        debugLog("AppState", " Switched to Drag-to-Snap mode")
    }
    
    private func toggleFullscreen() {
        focusModeService?.toggleFocusMode()
    }
    
    /// Load and apply the saved hotkey preset on startup
    func loadSavedHotkeyPreset() {
        let storage = HotkeyPresetStorage()
        let savedPreset = storage.loadPresetType()
        applyHotkeyPreset(savedPreset)
    }
}
