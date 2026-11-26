//
//  AppState+Layouts.swift
//  Rapto
//
//  Applying, restoring and editing layouts; the overlay's actions; gaps.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")
/// Readiness state of the Custom Layout editor's Save button, explaining why saving is unavailable.
nonisolated enum CustomLayoutSaveRequirement: Equatable, Sendable {
    case needsZones
    case needsName
    case ready(trimmedName: String)

    static func evaluate(zoneCount: Int, layoutName: String) -> CustomLayoutSaveRequirement {
        guard zoneCount > 0 else { return .needsZones }
        let trimmed = layoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .needsName }
        return .ready(trimmedName: trimmed)
    }

    var statusText: String? {
        switch self {
        case .needsZones:
            return "Click + inside the frame to add Zone 1"
        case .needsName:
            return "Name your layout on the left to save"
        case .ready:
            return nil
        }
    }

    var statusIcon: String? {
        switch self {
        case .needsZones:
            return "plus.circle"
        case .needsName:
            return "character.cursor.ibeam"
        case .ready:
            return nil
        }
    }
}

extension AppState {
    // MARK: - Restore Layout
    
    /// Rebuild layout state for restore using the saved snapshot and current open windows.
    /// This repairs corrupted slot assignments before windows are repositioned.
    func rebuildLayoutStateForRestore(
        savedInfo: SavedLayoutInfo,
        template: GridTemplate,
        currentWindows: [WindowInfo],
        screenID: String
    ) -> Bool {
        guard layoutManager.restoreLayout(
            from: savedInfo,
            template: template,
            currentWindows: currentWindows,
            forScreenID: screenID
        ) else {
            return false
        }
        
        let restoredWindows = layoutManager.state(forScreenID: screenID).allWindows
        processUnassignedWindowsAfterRestore(
            allWindowsOnScreen: currentWindows,
            restoredWindows: restoredWindows,
            forScreenID: screenID
        )
        
        return true
    }
    
    /// Restore all windows to their original template positions
    /// This recalculates zone frames from the template and repositions all windows,
    /// undoing any manual moves or resizes the user has made
    /// Only affects the screen where the focused window is located
    func restoreLayoutToOriginal() {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("No frontmost application for restore")
            return
        }
        
        let windows = windowManager.enumerateWindows()
        guard let focusedWindow = windows.first(where: { $0.ownerPID == focusedApp.processIdentifier }) else {
            logger.warning("No window found for frontmost app")
            return
        }
        
        let screen = screenManager.screen(for: focusedWindow)
        let screenID = screenManager.identifier(for: screen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            logger.warning("No active layout on screen \(screenID) to restore")
            debugLog("AppState", " restoreLayoutToOriginal: No active layout on screen \(screenID)")
            return
        }
        
        guard let template = screenState.template else {
            logger.warning("No template in active layout on screen \(screenID)")
            debugLog("AppState", " restoreLayoutToOriginal: No template on screen \(screenID)")
            return
        }
        
        let screenSpaceID = spaceID(for: screen)
        let currentWindows = windowManager.enumerateWindows()
        let windowsOnScreen = filterWindowsOnScreen(currentWindows, screen: screen)
        var layoutStateToRestore = screenState
        
        if let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID) {
            // Clear stale AX handles before rebuilding slot assignments from live windows.
            accessibilityService.clearAllAXCache()
            
            if rebuildLayoutStateForRestore(
                savedInfo: savedInfo,
                template: template,
                currentWindows: windowsOnScreen,
                screenID: screenID
            ) {
                layoutStateToRestore = layoutManager.state(forScreenID: screenID)
                debugLog("AppState", " restoreLayoutToOriginal: Rebuilt slot assignments from saved layout for screen \(screenID)")
            } else {
                debugLog("AppState", " restoreLayoutToOriginal: Saved layout rebuild failed, using current slot assignments for screen \(screenID)")
            }
        } else {
            debugLog("AppState", " restoreLayoutToOriginal: No saved layout snapshot for screen \(screenID), using current slot assignments")
        }
        
        debugLog("AppState", " restoreLayoutToOriginal: Restoring windows on screen \(screenID) to template '\(template.name)'")
        
        let screenFrame = screenManager.visibleFrame(for: screen)
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        var originalFrames: [CGRect] = []
        for zone in sortedZones {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            originalFrames.append(cgFrame)
        }
        
        let allWindowsToRestore = layoutStateToRestore.slots.enumerated().flatMap { slotIndex, slot in
            slotIndex < originalFrames.count ? slot.windows : []
        }
        let axCache = accessibilityService.batchGetAXWindows(for: allWindowsToRestore)
        var batchTargets: [AccessibilityService.BatchFrameTarget] = []
        batchTargets.reserveCapacity(allWindowsToRestore.count)

        for (slotIndex, slot) in layoutStateToRestore.slots.enumerated() {
            guard slotIndex < originalFrames.count else { continue }
            let originalFrame = originalFrames[slotIndex]

            layoutManager.updateSlotFrame(slotIndex, frame: originalFrame, forScreenID: screenID)

            for window in slot.windows.reversed() {
                batchTargets.append(
                    AccessibilityService.BatchFrameTarget(
                        window: window,
                        axWindow: axCache[window.windowID],
                        frame: originalFrame
                    )
                )
            }
        }

        var startedTransition = false
        let results = accessibilityService.batchSetWindowFrames(batchTargets) { [weak self] in
            startedTransition = true
            self?.windowHighlightService?.beginLayoutTransition()
            self?.groupIndicatorManager?.hideAll()
        }
        for slot in layoutStateToRestore.slots where slot.windows.count >= 2 {
            if let primary = slot.primaryWindow, let axWin = axCache[primary.windowID] {
                _ = accessibilityService.raiseWindow(axWindow: axWin)
            }
        }
        let restoredCount = results.values.filter { $0 }.count

        groupIndicatorManager?.updateIndicators()
        if startedTransition {
            windowHighlightService?.endLayoutTransition()
        }
        
        let updatedScreenState = layoutManager.state(forScreenID: screenID)
        let managedIDs = updatedScreenState.managedWindowIDs
        let freshWindows = windowManager.enumerateWindows()
        let managedWindows = freshWindows.filter { managedIDs.contains($0.windowID) }
        windowResizeService?.setManagedLayout(windows: managedWindows)
        
        layoutManager.saveLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID)
        
        logger.info("Restored \(restoredCount) windows on screen \(screenID) to original template positions")
        debugLog("AppState", " restoreLayoutToOriginal: Restored \(restoredCount) windows on screen \(screenID)")
    }

    // MARK: - Permission Methods

    nonisolated static let accessibilityOffMessage =
        "Rapto can't move windows: Accessibility is turned off. Turn on Rapto in System Settings → Privacy & Security → Accessibility."

    nonisolated static let autoTilingOverlayNotice =
        "Auto-tiling arranges this desktop automatically. Switch to Manual to pick a layout."

    nonisolated enum OverlayToggleDecision: Equatable, Sendable {
        case toggleVisibility
        case showAutoTilingNotice(String)
    }

    nonisolated static func overlayToggleDecision(
        isOverlayVisible: Bool,
        screenMode: TilingMode
    ) -> OverlayToggleDecision {
        if !isOverlayVisible && screenMode == .autoTiling {
            return .showAutoTilingNotice(autoTilingOverlayNotice)
        }
        return .toggleVisibility
    }

    func checkAccessibilityPermission() {
        refreshAccessibilityPermission(reapplyModesOnGrant: false)
    }

    /// Re-reads `AXIsProcessTrusted()`, starts/stops the rare recovery poll while permission is off,
    /// and re-activates screen modes immediately when permission returns.
    func refreshAccessibilityPermission(reapplyModesOnGrant: Bool = true) {
        let wasGranted = hasAccessibilityPermission
        let isGranted = AXIsProcessTrusted()
        if hasAccessibilityPermission != isGranted {
            hasAccessibilityPermission = isGranted
            debugLog("AppState", " Accessibility permission changed: \(isGranted)")
            if isGranted && !wasGranted && reapplyModesOnGrant {
                applyInitialModesToAllScreens()
            }
        }
        updateAccessibilityPollTask()
    }

    /// Observes app activation and runs a rare recovery poll while permission is off so revoked or
    /// newly granted Accessibility permission is reflected without restarting Rapto.
    func startAccessibilityMonitoring() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        let appActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityPermission()
            }
        }

        let workspaceActive = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityPermission()
            }
        }

        accessibilityObservers = [appActive, workspaceActive]
        updateAccessibilityPollTask()
    }

    private func updateAccessibilityPollTask() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        if hasAccessibilityPermission {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
        } else if accessibilityPollTask == nil {
            accessibilityPollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !Task.isCancelled else { return }
                    self.refreshAccessibilityPermission()
                }
            }
        }
    }

    // MARK: - Public Methods
    
    /// Fill the overlay's lists: windows of the active screen, then those on the other displays
    func loadOverlayWindows() {
        let screenID = screenManager.identifier(for: screenManager.activeScreen())
        let all = windowManager.enumerateWindows()
        let isHere = { (window: WindowInfo) in
            self.screenManager.identifier(for: self.screenManager.screen(for: window)) == screenID
        }
        windows = all.filter(isHere)
        windowsOnOtherDisplays = all.filter { !isHere($0) }
    }
    
    func toggleOverlay() {
        refreshAccessibilityPermission()
        let screen = screenManager.activeScreen()
        switch Self.overlayToggleDecision(isOverlayVisible: isOverlayVisible, screenMode: mode(for: screen)) {
        case .showAutoTilingNotice(let message):
            debugLog("AppState", " Not opening the overlay: Auto-tiling picks the layout on this screen")
            spaceBarController.showNotice(message, on: screen)
        case .toggleVisibility:
            isOverlayVisible.toggle()
        }
    }
    
    /// Select a grid template and enter zone assignment mode
    func selectTemplate(_ template: GridTemplate) {
        selectedTemplate = template
        assignedWindows = []
        currentZoneIndex = 0
    }
    
    /// Assign a window to the next available zone, or unassign if already assigned
    /// During overlay assignment, grouping is tracked in pendingGroups dictionary
    /// Groups are committed to layoutManager.slots when applyLayout() is called
    func assignWindow(_ window: WindowInfo) {
        debugLog("AppState"," ========== assignWindow CALLED ==========")
        debugLog("AppState"," Window: \(window.title), Owner: \(window.ownerName), PID: \(window.ownerPID)")
        
        guard let template = selectedTemplate else {
            logger.warning("assignWindow called but no template selected")
            return
        }
        
        if let existingIndex = assignedWindows.firstIndex(where: { $0.windowID == window.windowID }) {
            debugLog("AppState"," Window already assigned at index \(existingIndex), removing")
            assignedWindows.remove(at: existingIndex)
            currentZoneIndex = assignedWindows.count
            
            for (zoneID, var groupWindows) in pendingGroups {
                if let groupIndex = groupWindows.firstIndex(where: { $0.windowID == window.windowID }) {
                    groupWindows.remove(at: groupIndex)
                    if groupWindows.count <= 1 {
                        pendingGroups.removeValue(forKey: zoneID)
                    } else {
                        pendingGroups[zoneID] = groupWindows
                    }
                    debugLog("AppState"," Removed from pending group")
                    break
                }
            }
            
            logger.info("Unassigned window '\(window.title, privacy: .public)'")
            return
        }
        
        debugLog("AppState"," assignWindow: '\(window.title)' grouping=\(self.isGroupingEnabled), autoGroup=\(self.autoGroupSameApp), PID=\(window.ownerPID)")
        logger.debug("assignWindow: grouping=\(self.isGroupingEnabled), autoGroup=\(self.autoGroupSameApp), bundleID=\(window.bundleIdentifier ?? "nil")")
        
        if isGroupingEnabled && autoGroupSameApp {
            debugLog("AppState"," Grouping enabled - checking \(self.assignedWindows.count) assigned windows")
            debugLog("AppState"," Assigned window PIDs: \(self.assignedWindows.map { "\($0.ownerName):\($0.ownerPID)" })")
            debugLog("AppState"," New window PID: \(window.ownerName):\(window.ownerPID)")
            logger.debug("Checking for groupable windows among \(self.assignedWindows.count) assigned windows")
            
            if let existingWindow = assignedWindows.first(where: { 
                let samePID = $0.ownerPID == window.ownerPID
                debugLog("AppState"," Comparing with '\($0.title)' PID \($0.ownerPID) vs \(window.ownerPID): samePID=\(samePID)")
                return samePID
            }) {
                if let existingIndex = assignedWindows.firstIndex(where: { $0.windowID == existingWindow.windowID }) {
                    let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
                    guard existingIndex < sortedZones.count else { return }
                    
                    let zoneID = sortedZones[existingIndex].id
                    
                    if pendingGroups[zoneID] == nil {
                        pendingGroups[zoneID] = [existingWindow]
                    }
                    pendingGroups[zoneID]?.append(window)
                    
                    let groupSize = pendingGroups[zoneID]?.count ?? 0
                    debugLog("AppState"," ✅ Added '\(window.title)' to pending group (now \(groupSize) windows)")
                    logger.info("Added window '\(window.title, privacy: .public)' to pending group in zone")
                    return
                }
            }
        }
        
        let zoneNum = currentZoneIndex + 1
        logger.info("Assigning window '\(window.title, privacy: .public)' (PID: \(window.ownerPID)) to zone \(zoneNum)")
        
        assignedWindows.append(window)
        currentZoneIndex += 1
        
        let assignedCount = assignedWindows.count
        let totalZones = template.zones.count
        logger.info("Assigned \(assignedCount) of \(totalZones) zones")
        
        if assignedWindows.count == template.zones.count {
            logger.info("All zones filled, applying layout...")
            applyLayout()
        }
    }

    func applyLayout() {
        debugLog("AppState"," ===== APPLYLAYOUT v3 (slot-based) =====")
        let windowCount = assignedWindows.count
        debugLog("AppState"," applyLayout: \(windowCount) windows, groupingEnabled=\(isGroupingEnabled)")
        logger.info("applyLayout called with \(windowCount) windows")
        
        guard let template = selectedTemplate else {
            logger.warning("No template selected, dismissing overlay")
            isOverlayVisible = false
            reset()
            return
        }
        
        if !accessibilityService.checkPermission() {
            logger.error("Accessibility permission not granted!")
            accessibilityService.requestPermission()
            isOverlayVisible = false
            reset()
            return
        }
        
        // One screen for placing the windows and for the layout that records them
        let activeScreen = screenManager.activeScreen()
        let activeScreenID = screenManager.identifier(for: activeScreen)
        
        // Frames are from when the overlay opened, so this is where each window came from
        let takenFromOtherDisplays = (assignedWindows + pendingGroups.values.flatMap { $0 }).filter { window in
            screenManager.identifier(for: screenManager.screen(for: window)) != activeScreenID
        }
        
        let screenFrame = screenManager.visibleFrame(for: activeScreen)
        logger.info("Screen frame: origin=(\(screenFrame.origin.x), \(screenFrame.origin.y)), size=(\(screenFrame.width) x \(screenFrame.height))")
        
        // Sort zones by fill order to ensure correct pairing with assigned windows
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        for (index, window) in assignedWindows.enumerated() {
            guard index < sortedZones.count else { break }
            
            let zone = sortedZones[index]
            
            // Calculate absolute frame from relative zone frame (in AppKit coordinates)
            debugLog("AppState"," Calculating frame for window \(index + 1): \(window.title)")
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            debugLog("AppState"," Absolute frame: \(absoluteFrame)")
            
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: activeScreen)
            
            // setWindowFrame looks up the AX window once, which matters for apps such as Xcode
            // that expose several AX windows
            let success = accessibilityService.setWindowFrame(window, frame: cgFrame)
            
            if !success {
                logger.error("Failed to set frame for window '\(window.title, privacy: .public)' (owner: \(window.ownerName, privacy: .public), windowID: \(window.windowID))")
            } else {
                logger.debug("Successfully positioned window '\(window.title, privacy: .public)' to zone \(index + 1)")
            }
        }
        
        // Raise all windows to front (in reverse order so first window ends up on top)
        for window in assignedWindows.reversed() {
            accessibilityService.raiseWindow(window)
        }
        
        if minimizeOthersOnApply {
            minimizeNonAssignedWindows()
        }
        
        var sourceScreens: [String: NSScreen] = [:]
        for window in takenFromOtherDisplays {
            let source = screenManager.screen(for: window)
            sourceScreens[screenManager.identifier(for: source)] = source
            layoutManager.removeWindowFromAllScreens(window.windowID)
        }
        for (sourceID, source) in sourceScreens {
            layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: source), screenID: sourceID)
            debugLog("AppState", " The overlay took windows from screen \(sourceID) to \(activeScreenID)")
        }
        
        layoutManager.setLayout(template: template, windows: assignedWindows, forScreenID: activeScreenID)
        
        if isGroupingEnabled && !pendingGroups.isEmpty {
            for (zoneID, groupWindows) in pendingGroups {
                if let slotIndex = layoutManager.state(forScreenID: activeScreenID).slotIndex(byID: zoneID), groupWindows.count > 1 {
                    for window in groupWindows.dropFirst() {
                        layoutManager.addWindowToSlot(window, slotIndex: slotIndex, forScreenID: activeScreenID)
                        debugLog("AppState"," Committed grouped window '\(window.title)' to slot \(slotIndex)")
                    }
                    
                    if let primaryWindow = layoutManager.state(forScreenID: activeScreenID).slots[slotIndex].primaryWindow {
                        raiseWindowViaAccessibility(primaryWindow)
                    }
                } else {
                    debugLog("AppState"," Warning: Could not find slot for zoneID \(zoneID), skipping group")
                }
            }
            pendingGroups.removeAll()
            debugLog("AppState"," Cleared pendingGroups after commit")
        }
        
        enterManualKeepingLayout(on: activeScreen)
        
        let currentSpaceID = spaceID(for: activeScreen)
        layoutManager.saveLayoutInfo(forSpaceID: currentSpaceID, screenID: activeScreenID)
        debugLog("AppState"," Saved layout for space '\(currentSpaceID)' screen '\(activeScreenID)'")
        
        var config = spaceConfigurations[currentSpaceID] ?? .default
        config.templateID = template.id
        spaceConfigurations[currentSpaceID] = config
        SpaceConfigurationStorage.save(spaceConfigurations)
        debugLog("AppState"," Updated space config with templateID=\(template.id)")
        
        // Capture window IDs before reset clears assignedWindows
        let assignedWindowIDs = Set(assignedWindows.map { $0.windowID })
        
        // Save ALL visible window IDs at layout apply time
        // Windows that existed but weren't assigned should NOT be auto-grouped later
        let allCurrentWindows = windowManager.enumerateWindows()
        windowIDsAtLayoutApply = Set(allCurrentWindows.map { $0.windowID })
        debugLog("AppState"," Saved \(windowIDsAtLayoutApply.count) window IDs at layout apply")
        
        isOverlayVisible = false
        reset()
        
        // Set up resize service to track these windows for adjacent resize
        // after a short delay that lets the windows settle
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
            guard let self else { return }
            let updatedWindows = self.windowManager.enumerateWindows().filter { window in
                assignedWindowIDs.contains(window.windowID)
            }
            logger.info("Setting up resize tracking for \(updatedWindows.count) windows")
            self.windowResizeService?.setManagedLayout(windows: updatedWindows)
            
            debugLog("AppState"," Post-layout check: isGroupingEnabled=\(self.isGroupingEnabled), autoGroupSameApp=\(self.autoGroupSameApp), mode=\(self.currentMode.rawValue)")
            if self.isGroupingEnabled && self.autoGroupSameApp && self.currentMode == .manualAssignment {
                debugLog("AppState"," Calling setupManualModeGroupingObservers...")
                self.setupManualModeGroupingObservers()
            } else {
                debugLog("AppState"," NOT setting up grouping observers - conditions not met")
            }
            
            self.setupSwapHotkeys()
        }
    }
    
    private func minimizeNonAssignedWindows() {
        let assignedWindowIDs = Set(assignedWindows.map { $0.windowID })
        
        for window in windows {
            if !assignedWindowIDs.contains(window.windowID) {
                let success = accessibilityService.minimizeWindow(window)
                if success {
                    logger.debug("Minimized window '\(window.title, privacy: .public)'")
                } else {
                    logger.warning("Failed to minimize window '\(window.title, privacy: .public)'")
                }
            }
        }
    }
    
    /// Close the overlay (ESC or its close button), cancelling a grid or focus zone being drawn
    func dismissOverlay() {
        if isCreatingCustomGrid {
            cancelCustomGridCreation()
        } else if isSelectingFocusZone || isCreatingFocusZone {
            cancelFocusZoneSelection()
        }
        isOverlayVisible = false
        reset()
    }
    
    func reset() {
        selectedTemplate = nil
        assignedWindows = []
        currentZoneIndex = 0
        pendingGroups = [:]
    }

    // MARK: - Gap Settings Methods
    
    func setWindowGap(_ gap: CGFloat) {
        windowGap = gap
        screenManager.windowGap = gap
        UserDefaults.standard.set(gap, forKey: "windowGap")
        logger.info("Window gap set to \(gap)px")
        
        reapplyLayoutWithNewGaps()
    }
    
    func setScreenEdgeGap(_ gap: CGFloat) {
        screenEdgeGap = gap
        screenManager.screenEdgeGap = gap
        UserDefaults.standard.set(gap, forKey: "screenEdgeGap")
        logger.info("Screen edge gap set to \(gap)px")
        
        reapplyLayoutWithNewGaps()
    }
    
    nonisolated struct GapReapplyPlan: Equatable {
        let manualScreens: [String]
        let autoTilingScreens: [String]
        let dragSnapScreens: [String]
    }

    nonisolated static func gapReapplyPlan(screenModes: [(screenID: String, mode: TilingMode)]) -> GapReapplyPlan {
        var manual: [String] = []
        var autoTiling: [String] = []
        var dragSnap: [String] = []
        for (screenID, mode) in screenModes {
            switch mode {
            case .none:
                break
            case .manualAssignment:
                manual.append(screenID)
            case .autoTiling:
                autoTiling.append(screenID)
            case .dragSnap:
                dragSnap.append(screenID)
            }
        }
        return GapReapplyPlan(manualScreens: manual, autoTilingScreens: autoTiling, dragSnapScreens: dragSnap)
    }

    private func reapplyLayoutWithNewGaps() {
        let screenModes = screenManager.allScreens().map { screen in
            (screenID: screenManager.identifier(for: screen), mode: mode(for: screen))
        }
        let plan = Self.gapReapplyPlan(screenModes: screenModes)

        if !plan.manualScreens.isEmpty, let snapBackService = snapBackService {
            if snapBackService.hasActiveLayout {
                logger.info("Reapplying manual layout with new gaps (snapBack=\(self.snapBackEnabled))")
                snapBackService.reapplyLayout(excludingScreenIDs: Set(plan.autoTilingScreens))
            } else {
                logger.debug("No active layout to reapply in manual mode")
            }
        }

        if !plan.autoTilingScreens.isEmpty, let autoTilingService = autoTilingService {
            logger.info("Redistributing auto-tiling layout with new gaps")
            for screenID in plan.autoTilingScreens {
                autoTilingService.redistributeNow(forScreenID: screenID)
            }
        }

        if !plan.dragSnapScreens.isEmpty, let dragSnapService = dragSnapService {
            logger.info("Reapplying drag-snap windows with new gaps")
            for screenID in plan.dragSnapScreens {
                dragSnapService.reapplyGaps(forScreenID: screenID)
            }
        }

        windowHighlightService?.refresh()
        groupIndicatorManager?.updateIndicators()
    }

    // MARK: - Custom Grid Creation Methods
    
    func startCustomGridCreation() {
        isCreatingCustomGrid = true
        tempZones = []
        customTemplateName = ""
        selectedTemplate = nil
    }
    
    func cancelCustomGridCreation() {
        isCreatingCustomGrid = false
        tempZones = []
        customTemplateName = ""
    }
    
    func addTempZone(_ zone: Zone) {
        tempZones.append(zone)
        logger.info("Added temp zone \(self.tempZones.count)")
    }
    
    func removeTempZone(_ zone: Zone) {
        tempZones.removeAll { $0.id == zone.id }
        for i in 0..<tempZones.count {
            tempZones[i] = Zone(
                id: tempZones[i].id,
                relativeFrame: tempZones[i].relativeFrame,
                fillOrder: i
            )
        }
        logger.info("Removed temp zone, \(self.tempZones.count) remaining")
    }

    /// Replace a zone's frame while drawing a layout, keeping its place in the order
    func updateTempZone(_ zone: Zone) {
        guard let index = tempZones.firstIndex(where: { $0.id == zone.id }) else { return }
        tempZones[index] = zone
        logger.info("Updated temp zone \(index + 1)")
    }

    /// Replace a placed zone with two adjacent halves, keeping fill order sequential
    func splitTempZone(_ zone: Zone, into first: Zone, and second: Zone) {
        guard let index = tempZones.firstIndex(where: { $0.id == zone.id }) else { return }
        tempZones[index] = first
        tempZones.insert(second, at: index + 1)
        for i in 0..<tempZones.count {
            tempZones[i] = Zone(
                id: tempZones[i].id,
                relativeFrame: tempZones[i].relativeFrame,
                fillOrder: i
            )
        }
        logger.info("Split temp zone \(index + 1), now \(self.tempZones.count) zones")
    }
    
    func clearTempZones() {
        tempZones = []
        logger.info("Cleared all temp zones")
    }
    
    func saveCustomTemplate(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tempZones.isEmpty, !trimmedName.isEmpty else {
            logger.warning("Cannot save empty or unnamed template")
            return
        }
        
        let template = GridTemplate(
            name: trimmedName,
            icon: "square.grid.3x3",
            zones: tempZones
        )
        
        customTemplates = customTemplateStorage.addTemplate(template, to: customTemplates)
        logger.info("Saved custom template '\(trimmedName)' with \(self.tempZones.count) zones")
        
        isCreatingCustomGrid = false
        tempZones = []
        customTemplateName = ""
    }
    
    func deleteCustomTemplate(_ template: GridTemplate) {
        customTemplates = customTemplateStorage.deleteTemplate(withID: template.id, from: customTemplates)
        // Its shortcut would stay taken with no row in Settings to clear it
        if hotkey(for: template) != nil {
            removeHotkey(from: template)
        }
        logger.info("Deleted custom template '\(template.name)'")
    }
    
    func renameCustomTemplate(_ template: GridTemplate, newName: String) {
        guard let index = customTemplates.firstIndex(where: { $0.id == template.id }) else {
            logger.warning("Template not found for rename")
            return
        }
        
        let renamedTemplate = GridTemplate(
            id: template.id,
            name: newName,
            icon: template.icon,
            zones: template.zones
        )
        
        customTemplates[index] = renamedTemplate
        customTemplateStorage.saveTemplates(customTemplates)
        logger.info("Renamed template to '\(newName)'")
    }
    
    var allTemplates: [GridTemplate] {
        return PredefinedTemplates.all + customTemplates
    }

    /// Finds a layout by ID, resolving retired built-in IDs to their active replacement.
    func template(withID id: UUID) -> GridTemplate? {
        let canonical = PredefinedTemplates.canonicalID(for: id)
        return allTemplates.first { $0.id == canonical }
    }

    // MARK: - Removing Standard Layouts From the Lists
    
    static let hiddenStandardTemplatesKey = "hiddenStandardTemplateIDs"

    /// Templates offered in menus and pickers. Look templates up by id in `allTemplates` instead.
    var listedTemplates: [GridTemplate] {
        allTemplates.filter { !hiddenStandardTemplateIDs.contains($0.id) }
    }

    /// Splits listed layouts for `screen`: ultrawide screens see all layouts flat, while
    /// laptops and regular monitors tuck ultrawide layouts into a secondary group.
    func partitionedTemplates(for screen: NSScreen?) -> (primary: [GridTemplate], ultrawide: [GridTemplate]) {
        let profile = screen.map(DisplayProfile.forScreen) ?? DisplayProfile.dominant(for: screenManager.allScreens())
        guard !profile.prefersUltrawideLayouts else {
            return (listedTemplates, [])
        }
        let primary = listedTemplates.filter { !PredefinedTemplates.ultrawideIDs.contains($0.id) }
        let wide = listedTemplates.filter { PredefinedTemplates.ultrawideIDs.contains($0.id) }
        return (primary, wide)
    }
    
    func hideStandardTemplate(_ template: GridTemplate) {
        guard PredefinedTemplates.all.contains(where: { $0.id == template.id }) else { return }
        hiddenStandardTemplateIDs.insert(template.id)
        saveHiddenStandardTemplates()
    }
    
    func unhideStandardTemplate(_ template: GridTemplate) {
        hiddenStandardTemplateIDs.remove(template.id)
        saveHiddenStandardTemplates()
    }
    
    /// Standard layouts removed from the lists, in their usual order
    var hiddenStandardTemplates: [GridTemplate] {
        PredefinedTemplates.all.filter { hiddenStandardTemplateIDs.contains($0.id) }
    }
    
    private func saveHiddenStandardTemplates() {
        UserDefaults.standard.set(hiddenStandardTemplateIDs.map(\.uuidString), forKey: Self.hiddenStandardTemplatesKey)
        logger.info("Standard layouts removed from the lists: \(self.hiddenStandardTemplateIDs.count)")
    }

    // MARK: - Layout from Windows
    
    /// Save where the windows of a screen are now as a custom layout (only their places, not the windows)
    /// - Parameters:
    ///   - screen: The screen to read, the active one if nil
    @discardableResult
    func createLayoutFromWindows(name: String, on screen: NSScreen? = nil) -> Bool {
        let screen = screen ?? screenManager.activeScreen()
        let currentWindows = windowsForNewLayout(on: screen)
        
        guard !currentWindows.isEmpty else {
            logger.warning("No windows to make a layout from")
            return false
        }
        
        let screenFrame = screenManager.visibleFrame(for: screen)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        
        let zones = currentWindows.enumerated().map { index, window in
            Zone(
                relativeFrame: Self.snapshotRelativeFrame(of: window.frame, in: screenFrame, primaryScreenHeight: primaryScreenHeight),
                fillOrder: index
            )
        }
        
        let template = GridTemplate(
            name: name,
            icon: "square.grid.2x2",
            zones: zones
        )
        
        customTemplates = customTemplateStorage.addTemplate(template, to: customTemplates)
        logger.info("Created layout '\(name)' from \(zones.count) windows")
        
        return true
    }
    
    /// A window frame in CG coordinates (top-left origin of the primary display) as a zone frame
    /// (0.0-1.0, bottom-left origin) inside `visibleFrame` (AppKit coordinates), kept inside it.
    nonisolated static func snapshotRelativeFrame(of cgFrame: CGRect, in visibleFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let appKitY = primaryScreenHeight - cgFrame.origin.y - cgFrame.height
        
        let relativeX = (cgFrame.origin.x - visibleFrame.origin.x) / visibleFrame.width
        let relativeY = (appKitY - visibleFrame.origin.y) / visibleFrame.height
        let relativeWidth = cgFrame.width / visibleFrame.width
        let relativeHeight = cgFrame.height / visibleFrame.height
        
        return CGRect(
            x: max(0, min(relativeX, 1.0 - relativeWidth)),
            y: max(0, min(relativeY, 1.0 - relativeHeight)),
            width: min(relativeWidth, 1.0),
            height: min(relativeHeight, 1.0)
        )
    }
    
    /// Ask for a name, then save where the windows of a screen are as a new layout
    /// - Parameter screen: The screen to read, the active one if nil
    func createLayoutFromWindowsAskingName(on screen: NSScreen? = nil) {
        // Before the prompt: it becomes the key window and can move the active screen
        let screen = screen ?? screenManager.activeScreen()
        guard !windowsForNewLayout(on: screen).isEmpty else {
            NSSound.beep()
            showInfoAlert(title: "No Windows Here", message: "Open and arrange windows on this display first")
            return
        }
        guard let name = askName(
            title: "Create Layout from Windows",
            message: "Saves where the windows on this display are as a new layout. Only their places are kept, not the apps",
            button: "Create",
            initial: newLayoutFromWindowsName()
        ) else { return }
        createLayoutFromWindows(name: name, on: screen)
    }
    
    func canPopulateTempZonesFromWindows(on screen: NSScreen? = nil) -> Bool {
        let targetScreen = screen ?? screenManager.activeScreen()
        return !windowsForNewLayout(on: targetScreen).isEmpty
    }

    @discardableResult
    func populateTempZonesFromOpenWindows(on screen: NSScreen? = nil) -> Int {
        let targetScreen = screen ?? screenManager.activeScreen()
        let currentWindows = windowsForNewLayout(on: targetScreen)
        guard !currentWindows.isEmpty else { return 0 }

        let screenFrame = screenManager.visibleFrame(for: targetScreen)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height

        tempZones = currentWindows.enumerated().map { index, window in
            Zone(
                relativeFrame: Self.snapshotRelativeFrame(
                    of: window.frame,
                    in: screenFrame,
                    primaryScreenHeight: primaryScreenHeight
                ),
                fillOrder: index
            )
        }
        logger.info("Populated \(self.tempZones.count) temp zones from open windows")
        return tempZones.count
    }

    private func windowsForNewLayout(on screen: NSScreen) -> [WindowInfo] {
        let screenID = screenManager.identifier(for: screen)
        return windowManager.enumerateWindows().filter { window in
            screenManager.identifier(for: screenManager.screen(for: window)) == screenID
        }
    }
    
    /// A default name for a layout made from windows, with the time
    func newLayoutFromWindowsName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "Layout \(formatter.string(from: Date()))"
    }
}
