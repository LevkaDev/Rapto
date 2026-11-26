//
//  WindowLayoutManager.swift
//  Rapto
//
//  Unified state manager for window layouts using Slot-based architecture.
//  Single source of truth to prevent race conditions between services.
//

import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "WindowLayoutManager")

nonisolated enum LayoutOperationMode: Equatable, Sendable {
    case idle               // Normal state, all services can operate
    case resizing          // User is resizing windows, snap-back disabled
    case applyingLayout    // Applying new layout, all interference disabled
    case snappingBack      // Snap-back in progress, resize detection disabled
    case swapping
    case redistributing
    
    var description: String {
        switch self {
        case .idle: return "idle"
        case .resizing: return "resizing"
        case .applyingLayout: return "applyingLayout"
        case .snappingBack: return "snappingBack"
        case .swapping: return "swapping"
        case .redistributing: return "redistributing"
        }
    }
}

enum CycleDirection: CustomStringConvertible, Sendable {
    case forward
    case backward
    
    var description: String {
        switch self {
        case .forward: return "forward"
        case .backward: return "backward"
        }
    }
}

// MARK: - Saved Layout Info (for persistence)

/// Saved layout info for persistence (without PIDs since they change on restart)
/// Groups are restored by position, not by saved app info
struct SavedLayoutInfo: Codable {
    var templateID: UUID
    var slots: [SavedSlotInfo]
    /// Visible area of the screen (CG coordinates) the frames were saved for
    var visibleFrame: CGRect?
    
    struct SavedSlotInfo: Codable {
        let slotID: UUID
        let index: Int
        let ownerName: String?
        let bundleIdentifier: String?
        /// Saved frame (preserves resized positions)
        var frame: CGRect?
        let groupBundleIDs: [String]?
        /// All PIDs in this slot's group (for proper group restoration after fullscreen)
        let groupPIDs: [Int32]?
    }
}

/// A desktop's Manual layout, kept while the desktop is in another mode so Manual comes back as it was
struct ManualLayoutSnapshot: Codable {
    var templateID: UUID
    var slots: [SlotSnapshot]
    /// Visible area of the screen (CG coordinates) the frames were saved for
    var visibleFrame: CGRect?

    struct SlotSnapshot: Codable {
        let index: Int
        var frame: CGRect
        /// Front window first. Empty when the layout was saved for a desktop that wasn't on screen
        let windowIDs: [CGWindowID]
        let bundleIDs: [String]
    }
}

// MARK: - Layout State

struct LayoutState {
    var template: GridTemplate?
    
    /// Array of slots in fill order (index matches fillOrder)
    var slots: [Slot] = []
    
    /// Flag indicating user has manually resized windows (prevents auto-redistribute on Space return)
    /// Reset when window count changes (window added/removed)
    var hasManualModifications: Bool = false
    
    // MARK: - Computed Properties
    
    var isActive: Bool {
        template != nil && !slots.isEmpty
    }
    
    var slotCount: Int {
        slots.count
    }
    
    var managedWindowIDs: Set<CGWindowID> {
        Set(slots.flatMap { $0.windows.map(\.windowID) })
    }
    
    /// Get all managed windows (primary windows from all slots)
    var allWindows: [WindowInfo] {
        slots.compactMap { $0.primaryWindow }
    }
    
    var hasGroups: Bool {
        slots.contains { $0.hasGroup }
    }
    
    var emptySlots: [Slot] {
        slots.filter { $0.isEmpty }
    }
    
    // MARK: - Queries
    
    func slot(for windowID: CGWindowID) -> Slot? {
        slots.first { $0.contains(windowID: windowID) }
    }
    
    func slotIndex(for windowID: CGWindowID) -> Int? {
        slots.firstIndex { $0.contains(windowID: windowID) }
    }
    
    func slotIndex(byID id: UUID) -> Int? {
        slots.firstIndex { $0.id == id }
    }
    
    func slot(at index: Int) -> Slot? {
        guard index >= 0 && index < slots.count else { return nil }
        return slots[index]
    }
    
    func findSlotIndex(forPID pid: pid_t) -> Int? {
        slots.firstIndex { slot in
            slot.windows.contains { $0.ownerPID == pid }
        }
    }
    
    /// The slot of the app's window whose top left corner is at `origin`.
    /// A window rarely sits exactly on its slot, hence the tolerance. With it, the corner of a
    /// window can also fall inside the slot to its left or above, and when that slot holds
    /// another window of the same app, the first match is the wrong slot. The nearest one is right.
    func findSlotIndex(forPID pid: pid_t, windowOrigin origin: CGPoint, tolerance: CGFloat = 50) -> Int? {
        slots.indices
            .filter { index in
                slots[index].frame.insetBy(dx: -tolerance, dy: -tolerance).contains(origin)
                    && slots[index].windows.contains { $0.ownerPID == pid }
            }
            .min { first, second in
                distance(from: slots[first].frame.origin, to: origin) < distance(from: slots[second].frame.origin, to: origin)
            }
    }
    
    private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
    
    func findSlotIndex(forBundleID bundleID: String) -> Int? {
        slots.firstIndex { slot in
            slot.bundleIdentifier == bundleID
        }
    }
    
    func findSlotIndex(forOwnerName ownerName: String) -> Int? {
        slots.firstIndex { slot in
            slot.ownerName == ownerName
        }
    }
    
    func firstEmptySlot() -> (index: Int, slot: Slot)? {
        guard let index = slots.firstIndex(where: { $0.isEmpty }) else { return nil }
        return (index, slots[index])
    }
    
    func findSlotForGrouping(window: WindowInfo) -> (index: Int, slot: Slot)? {
        if let bundleID = window.bundleIdentifier,
           let index = findSlotIndex(forBundleID: bundleID) {
            return (index, slots[index])
        }
        
        if let index = findSlotIndex(forPID: window.ownerPID) {
            return (index, slots[index])
        }
        
        if let index = findSlotIndex(forOwnerName: window.ownerName) {
            return (index, slots[index])
        }
        
        return nil
    }
}

// MARK: - WindowLayoutManager

/// Prevents race conditions by centralizing all state management
/// Supports per-screen layouts for multi-monitor setups
@MainActor
class WindowLayoutManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Current layout state (for active/main screen - backward compatibility)
    @Published private(set) var state = LayoutState()
    
    /// Per-screen layout states (key: screenID from ScreenIdentifier)
    @Published private(set) var screenStates: [String: LayoutState] = [:]
    
    @Published private(set) var activeScreenID: String = ""

    /// Per screen: the slot each window stood in before the group shortcut pulled it into a group
    private var slotsBeforeGrouping: [String: [CGWindowID: Int]] = [:]
    
    @Published private(set) var operationMode: LayoutOperationMode = .idle
    
    // MARK: - Publishers for Events
    
    let layoutChanged = PassthroughSubject<LayoutState, Never>()
    
    let slotUpdated = PassthroughSubject<(index: Int, slot: Slot), Never>()
    
    let framesRecalculated = PassthroughSubject<Void, Never>()
    
    let modeChanged = PassthroughSubject<LayoutOperationMode, Never>()
    
    let groupCycled = PassthroughSubject<(slotIndex: Int, newActiveWindow: WindowInfo), Never>()
    
    /// Published when a window needs to be repositioned (moved from group to empty slot)
    let windowNeedsRepositioning = PassthroughSubject<(slotIndex: Int, window: WindowInfo), Never>()
    
    // MARK: - Dependencies
    
    private let screenManager: ScreenManager
    
    // MARK: - Initialization
    
    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        self.activeScreenID = ScreenIdentifier.mainScreenID
        logger.info("WindowLayoutManager initialized with Slot-based architecture and multi-screen support")
    }
    
    // MARK: - Per-Screen State Access
    
    /// - Returns: The layout state for that screen, or empty state if none
    func state(forScreenID screenID: String) -> LayoutState {
        return screenStates[screenID] ?? LayoutState()
    }
    
    func hasActiveLayout(forScreenID screenID: String) -> Bool {
        return screenStates[screenID]?.isActive ?? false
    }
    
    /// Set the active screen (updates `state` to match)
    func setActiveScreen(_ screenID: String) {
        activeScreenID = screenID
        if let screenState = screenStates[screenID] {
            state = screenState
        } else {
            state = LayoutState()
        }
        logger.info("Active screen set to: \(screenID)")
    }
    
    func setActiveScreen(_ screen: NSScreen) {
        setActiveScreen(screenManager.identifier(for: screen))
    }
    
    var screensWithActiveLayouts: [String] {
        return screenStates.filter { $0.value.isActive }.map { $0.key }
    }
    
    var allWindows: [WindowInfo] {
        return screenStates.values.flatMap { $0.allWindows }
    }
    
    // MARK: - State Queries (Convenience)
    
    /// Frame of the window's slot in the active screen's layout (`state`)
    func expectedFrame(for windowID: CGWindowID) -> CGRect? {
        state.slot(for: windowID)?.frame
    }
    
    // MARK: - Operation Mode Control
    
    func setMode(_ mode: LayoutOperationMode) {
        guard operationMode != mode else { return }
        
        operationMode = mode
        logger.info("Operation mode changed to: \(mode.description)")
        modeChanged.send(mode)
    }
    
    func canPerform(operation: LayoutOperationMode) -> Bool {
        switch (operationMode, operation) {
        case (.idle, _):
            return true
        case (.resizing, .snappingBack):
            return false
        case (.snappingBack, .resizing):
            return false
        case (.applyingLayout, _):
            return false
        case (.swapping, .snappingBack):
            return false
        case (.redistributing, .snappingBack):
            return false
        case (.redistributing, .resizing):
            return false
        case (_, .redistributing) where operationMode != .idle:
            return false
        default:
            return true
        }
    }
    
    // MARK: - Layout Management
    
    /// Set active layout with template and windows (on active screen)
    /// - Parameters:
    ///   - windows: Windows to assign (in fill order)
    func setLayout(template: GridTemplate, windows: [WindowInfo]) {
        setLayout(template: template, windows: windows, forScreenID: activeScreenID)
    }
    
    /// - Parameters:
    ///   - windows: Windows to assign (in fill order)
    func setLayout(template: GridTemplate, windows: [WindowInfo], forScreenID screenID: String) {
        setMode(.applyingLayout)
        
        let screen = screenManager.screen(for: screenID) ?? screenManager.activeScreen()
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        let screenFrame = screenManager.visibleFrame(for: screen)
        
        var newSlots: [Slot] = []
        for (index, zone) in sortedZones.enumerated() {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            
            var slotWindows: [WindowInfo] = []
            if index < windows.count {
                slotWindows = [windows[index]]
            }
            
            let slot = Slot(
                id: zone.id,
                index: index,
                frame: cgFrame,
                windows: slotWindows
            )
            newSlots.append(slot)
        }
        
        var newState = LayoutState()
        newState.template = template
        newState.slots = newSlots
        
        screenStates[screenID] = newState
        
        if screenID == activeScreenID {
            state = newState
        }
        
        logger.info("Layout set for screen \(screenID): \(windows.count) windows in \(template.zones.count) slots")
        layoutChanged.send(newState)
        
        // Return to idle after a short delay, so other services ignore the window moves this causes
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setMode(.idle)
        }
    }
    
    func setLayoutWithSlots(template: GridTemplate, slots: [Slot], forScreenID screenID: String) {
        setMode(.applyingLayout)
        
        var newState = LayoutState()
        newState.template = template
        newState.slots = slots
        
        screenStates[screenID] = newState
        
        if screenID == activeScreenID {
            state = newState
        }
        
        logger.info("Layout set for screen \(screenID) with \(slots.count) pre-built slots")
        layoutChanged.send(newState)
        
        // Return to idle after a short delay, so other services ignore the window moves this causes
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setMode(.idle)
        }
    }
    
    func clearLayout(forScreenID screenID: String) {
        screenStates.removeValue(forKey: screenID)
        
        if screenID == activeScreenID {
            state = LayoutState()
        }
        
        logger.info("Layout cleared for screen \(screenID)")
        layoutChanged.send(LayoutState())
    }
    
    // MARK: - State Synchronization
    
    /// Sync the main `state` back to `screenStates[activeScreenID]`
    /// Must be called after ANY mutation to `state` to keep them in sync
    /// Swift value types mean `state` and `screenStates[activeScreenID]` are separate copies
    private func syncStateToScreenStates() {
        // Drop windows that no longer exist before syncing.
        // The IDs come from CGWindowList with optionOnScreenOnly: minimized windows, windows of
        // hidden apps and windows on other Spaces are not in it and are dropped as well.
        let existingWindowIDs = getExistingWindowIDs()
        
        var cleanedSlotCount = 0
        for i in state.slots.indices {
            let originalCount = state.slots[i].windows.count
            state.slots[i].windows.removeAll { window in
                let exists = existingWindowIDs.contains(window.windowID)
                if !exists {
                    debugLog("WindowLayoutManager", "⚠️ Removing closed window \(window.windowID) from slot \(i)")
                }
                return !exists
            }
            if state.slots[i].windows.count != originalCount {
                cleanedSlotCount += 1
            }
        }
        
        if cleanedSlotCount > 0 {
            debugLog("WindowLayoutManager", "🧹 Cleaned \(cleanedSlotCount) slots of closed windows")
        }
        
        screenStates[activeScreenID] = state
    }
    
    /// On-screen window IDs from CGWindowList.
    /// Tests replace this: their windows don't exist on screen and would be dropped as closed
    var existingWindowIDs: () -> Set<CGWindowID> = WindowLayoutManager.allWindowIDs
    
    private func getExistingWindowIDs() -> Set<CGWindowID> {
        existingWindowIDs()
    }
    
    /// Every window that exists, also minimized ones, windows of hidden apps and windows on other
    /// desktops: those stay in their groups, only closed windows leave.
    private static func allWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var windowIDs = Set<CGWindowID>()
        for dict in windowList {
            if let windowID = dict[kCGWindowNumber as String] as? CGWindowID {
                windowIDs.insert(windowID)
            }
        }
        return windowIDs
    }
    
    // MARK: - Slot Operations
    
    /// Assign a window to a specific slot (replaces existing windows)
    func assignWindow(_ window: WindowInfo, to slotIndex: Int) {
        guard slotIndex >= 0 && slotIndex < state.slots.count else {
            logger.warning("Invalid slot index: \(slotIndex)")
            return
        }
        
        removeWindow(window.windowID)
        
        state.slots[slotIndex].windows = [window]
        state.slots[slotIndex].originalBundleID = window.bundleIdentifier
        state.slots[slotIndex].originalOwnerName = window.ownerName
        
        syncStateToScreenStates()
        
        logger.info("Assigned '\(window.title)' to slot \(slotIndex)")
        slotUpdated.send((slotIndex, state.slots[slotIndex]))
    }
    
    /// Assign a window to a specific slot on a specific screen (replaces existing windows)
    func assignWindow(_ window: WindowInfo, to slotIndex: Int, forScreenID screenID: String) {
        let initialState = state(forScreenID: screenID)
        guard slotIndex >= 0 && slotIndex < initialState.slots.count else {
            logger.warning("Invalid slot index: \(slotIndex) for screen \(screenID)")
            return
        }
        
        // Remove window from ALL screens first to prevent ghost indicators
        // A window moved cross-screen must be removed from the old screen's slots
        removeWindowFromAllScreens(window.windowID)
        
        // Re-fetch state AFTER removal to get the updated slots
        // Otherwise the removal is lost when we overwrite screenStates[screenID]
        var screenState = state(forScreenID: screenID)
        
        screenState.slots[slotIndex].windows = [window]
        screenState.slots[slotIndex].originalBundleID = window.bundleIdentifier
        screenState.slots[slotIndex].originalOwnerName = window.ownerName
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        logger.info("Assigned '\(window.title)' to slot \(slotIndex) on screen \(screenID)")
        slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
    }
    
    func addWindowToSlot(_ window: WindowInfo, slotIndex: Int, forScreenID screenID: String) {
        let initialState = state(forScreenID: screenID)
        guard slotIndex >= 0 && slotIndex < initialState.slots.count else {
            logger.warning("Invalid slot index: \(slotIndex) for screen \(screenID)")
            return
        }
        
        // Remove from ALL screens first to prevent ghost indicators on other monitors
        removeWindowFromAllScreens(window.windowID)
        
        // Re-fetch state AFTER removal to get the updated slots
        // Otherwise the removal is lost when we overwrite screenStates[screenID]
        var screenState = state(forScreenID: screenID)
        
        screenState.slots[slotIndex].addWindow(window)
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        let windowCount = screenState.slots[slotIndex].windowCount
        logger.info("Added '\(window.title)' to slot \(slotIndex) group on screen \(screenID) (now \(windowCount) windows)")
        slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
    }
    
    @discardableResult
    func removeWindow(_ windowID: CGWindowID, forScreenID screenID: String) -> (slotIndex: Int, window: WindowInfo)? {
        var screenState = state(forScreenID: screenID)
        
        for (index, slot) in screenState.slots.enumerated() {
            if slot.windows.contains(where: { $0.windowID == windowID }) {
                if let window = screenState.slots[index].removeWindow(withID: windowID) {
                    screenStates[screenID] = screenState
                    
                    if screenID == activeScreenID {
                        state = screenState
                    }
                    
                    logger.info("Removed window \(windowID) from slot \(index) on screen \(screenID)")
                    slotUpdated.send((index, screenState.slots[index]))
                    return (index, window)
                }
            }
        }
        return nil
    }
    
    func updateWindowInSlot(slotIndex: Int, oldWindowID: CGWindowID, newWindow: WindowInfo, forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        
        guard slotIndex >= 0 && slotIndex < screenState.slots.count else {
            logger.warning("Invalid slot index for update: \(slotIndex) on screen \(screenID)")
            return
        }
        
        if let windowIndex = screenState.slots[slotIndex].windows.firstIndex(where: { $0.windowID == oldWindowID }) {
            screenState.slots[slotIndex].windows[windowIndex] = newWindow
            
            screenStates[screenID] = screenState
            
            if screenID == activeScreenID {
                state = screenState
            }
            
            logger.info("Updated window ID in slot \(slotIndex) on screen \(screenID): \(oldWindowID) -> \(newWindow.windowID)")
            slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
        } else {
            logger.warning("Window \(oldWindowID) not found in slot \(slotIndex) on screen \(screenID) for update")
        }
    }
    
    /// Update just the frame of a window in a slot (after physical repositioning)
    /// This is critical for keeping WindowInfo.frame in sync with actual window position
    func updateWindowFrame(_ windowID: CGWindowID, newFrame: CGRect, forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        
        for (slotIndex, slot) in screenState.slots.enumerated() {
            if let windowIndex = slot.windows.firstIndex(where: { $0.windowID == windowID }) {
                var updatedWindow = screenState.slots[slotIndex].windows[windowIndex]
                updatedWindow = WindowInfo(
                    id: updatedWindow.id,
                    windowID: updatedWindow.windowID,
                    ownerPID: updatedWindow.ownerPID,
                    title: updatedWindow.title,
                    ownerName: updatedWindow.ownerName,
                    bundleIdentifier: updatedWindow.bundleIdentifier,
                    frame: newFrame,
                    thumbnail: updatedWindow.thumbnail
                )
                screenState.slots[slotIndex].windows[windowIndex] = updatedWindow
                
                screenStates[screenID] = screenState
                
                if screenID == activeScreenID {
                    state = screenState
                }
                
                return
            }
        }
        
        logger.warning("updateWindowFrame: Window \(windowID) not found on screen \(screenID)")
    }
    
    @discardableResult
    func removeWindow(_ windowID: CGWindowID) -> (slotIndex: Int, window: WindowInfo)? {
        guard let slotIndex = state.slotIndex(for: windowID) else {
            return nil
        }
        
        if let window = state.slots[slotIndex].removeWindow(withID: windowID) {
            syncStateToScreenStates()
            
            logger.info("Removed window \(windowID) from slot \(slotIndex)")
            slotUpdated.send((slotIndex, state.slots[slotIndex]))
            return (slotIndex, window)
        }
        return nil
    }
    
    /// Used when moving windows between monitors to ensure no duplicate tracking
    @discardableResult
    func removeWindowFromAllScreens(_ windowID: CGWindowID) -> Bool {
        var removed = false
        
        for screenID in screenStates.keys {
            var screenState = screenStates[screenID]!
            
            for (index, slot) in screenState.slots.enumerated() {
                if slot.windows.contains(where: { $0.windowID == windowID }) {
                    _ = screenState.slots[index].removeWindow(withID: windowID)
                    screenStates[screenID] = screenState
                    
                    if screenID == activeScreenID {
                        state = screenState
                    }
                    
                    logger.info("Removed window \(windowID) from screen \(screenID) slot \(index)")
                    slotUpdated.send((index, screenState.slots[index]))
                    removed = true
                }
            }
        }
        
        return removed
    }
    
    func cycleWindowsSkippingMinimized(in slotIndex: Int, direction: CycleDirection, visibleWindowIDs: Set<CGWindowID>, forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        
        guard slotIndex >= 0 && slotIndex < screenState.slots.count else {
            logger.warning("Invalid slot index: \(slotIndex) on screen \(screenID)")
            return
        }
        
        let slot = screenState.slots[slotIndex]
        
        let visibleWindows = slot.windows.filter { visibleWindowIDs.contains($0.windowID) }
        
        guard visibleWindows.count > 1 else {
            logger.debug("Slot \(slotIndex) on screen \(screenID) has \(visibleWindows.count) visible windows, no cycling needed")
            return
        }
        
        guard let currentActive = slot.primaryWindow,
              let currentVisibleIndex = visibleWindows.firstIndex(where: { $0.windowID == currentActive.windowID }) else {
            // Current active is minimized, just pick first visible
            if let firstVisible = visibleWindows.first {
                screenState.slots[slotIndex].setActiveWindow(firstVisible.windowID)
                screenStates[screenID] = screenState
                if screenID == activeScreenID {
                    state = screenState
                }
                logger.info("Slot \(slotIndex) on screen \(screenID): active was minimized, switching to '\(firstVisible.title)'")
                groupCycled.send((slotIndex, firstVisible))
                slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
            }
            return
        }
        
        let nextVisibleIndex: Int
        switch direction {
        case .forward:
            nextVisibleIndex = (currentVisibleIndex + 1) % visibleWindows.count
        case .backward:
            nextVisibleIndex = (currentVisibleIndex - 1 + visibleWindows.count) % visibleWindows.count
        }
        
        let nextWindow = visibleWindows[nextVisibleIndex]
        
        screenState.slots[slotIndex].setActiveWindow(nextWindow.windowID)
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        logger.info("Cycled slot \(slotIndex) on screen \(screenID) \(direction) (skipping minimized): new active = '\(nextWindow.title)'")
        groupCycled.send((slotIndex, nextWindow))
        slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
    }
    
    func setActiveWindow(_ windowID: CGWindowID, in slotIndex: Int, forScreenID screenID: String) {
        var layoutState = state(forScreenID: screenID)
        guard slotIndex >= 0 && slotIndex < layoutState.slots.count else { return }
        
        layoutState.slots[slotIndex].setActiveWindow(windowID)
        screenStates[screenID] = layoutState
        
        if screenID == activeScreenID {
            state = layoutState
        }
        
        slotUpdated.send((slotIndex, layoutState.slots[slotIndex]))
    }
    
    // MARK: - Swap Operations
    
    /// Swaps the contents of two slots in the active screen's layout (`state`)
    func swapSlotContents(slot1Index: Int, slot2Index: Int) {
        guard slot1Index >= 0 && slot1Index < state.slots.count,
              slot2Index >= 0 && slot2Index < state.slots.count,
              slot1Index != slot2Index else {
            logger.warning("Invalid slot indices for swap: \(slot1Index), \(slot2Index)")
            return
        }
        
        setMode(.swapping)
        
        let temp = state.slots[slot1Index].windows
        state.slots[slot1Index].windows = state.slots[slot2Index].windows
        state.slots[slot2Index].windows = temp
        
        let tempBundle = state.slots[slot1Index].originalBundleID
        let tempOwner = state.slots[slot1Index].originalOwnerName
        state.slots[slot1Index].originalBundleID = state.slots[slot2Index].originalBundleID
        state.slots[slot1Index].originalOwnerName = state.slots[slot2Index].originalOwnerName
        state.slots[slot2Index].originalBundleID = tempBundle
        state.slots[slot2Index].originalOwnerName = tempOwner
        
        logger.info("Swapped slot \(slot1Index) <-> slot \(slot2Index)")
        
        syncStateToScreenStates()
        
        slotUpdated.send((slot1Index, state.slots[slot1Index]))
        slotUpdated.send((slot2Index, state.slots[slot2Index]))
        
        // Return to idle after a short delay, so other services ignore the window moves this causes
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setMode(.idle)
        }
    }
    
    /// Swap individual windows by their IDs on the screen whose layout holds both of them
    /// (only swaps the specific windows, not entire slot contents)
    func swapWindows(_ window1ID: CGWindowID, _ window2ID: CGWindowID) {
        guard let first = findWindowAcrossScreens(window1ID),
              let second = findWindowAcrossScreens(window2ID),
              first.screenID == second.screenID else {
            logger.warning("Cannot swap - windows not found on one screen")
            debugLog("WindowLayoutManager", "⚠️ Cannot swap - window1ID=\(window1ID) on \(findWindowAcrossScreens(window1ID)?.screenID ?? "none"), window2ID=\(window2ID) on \(findWindowAcrossScreens(window2ID)?.screenID ?? "none")")
            return
        }
        swapWindows(window1ID, window2ID, forScreenID: first.screenID)
    }
    
    func swapWindows(_ window1ID: CGWindowID, _ window2ID: CGWindowID, forScreenID screenID: String) {
        debugLog("WindowLayoutManager", "🔄 swapWindows(\(window1ID), \(window2ID)) on screen \(screenID)")
        var screenState = state(forScreenID: screenID)
        
        guard let slot1Index = screenState.slotIndex(for: window1ID),
              let slot2Index = screenState.slotIndex(for: window2ID) else {
            logger.warning("Cannot swap - one or both windows not found")
            debugLog("WindowLayoutManager", "⚠️ Cannot swap - window not found on \(screenID). window1ID=\(window1ID) found: \(screenState.slotIndex(for: window1ID) != nil), window2ID=\(window2ID) found: \(screenState.slotIndex(for: window2ID) != nil)")
            return
        }
        
        guard slot1Index != slot2Index else {
            logger.warning("Cannot swap windows in the same slot")
            return
        }
        
        guard let window1Index = screenState.slots[slot1Index].windows.firstIndex(where: { $0.windowID == window1ID }),
              let window2Index = screenState.slots[slot2Index].windows.firstIndex(where: { $0.windowID == window2ID }) else {
            logger.warning("Cannot find windows in their slots")
            return
        }
        
        setMode(.swapping)
        
        let window1 = screenState.slots[slot1Index].windows.remove(at: window1Index)
        let window2 = screenState.slots[slot2Index].windows.remove(at: window2Index)
        
        screenState.slots[slot1Index].windows.insert(window2, at: 0)
        screenState.slots[slot2Index].windows.insert(window1, at: 0)
        
        if screenState.slots[slot1Index].windows.count == 1 {
            screenState.slots[slot1Index].originalBundleID = window2.bundleIdentifier
            screenState.slots[slot1Index].originalOwnerName = window2.ownerName
        }
        if screenState.slots[slot2Index].windows.count == 1 {
            screenState.slots[slot2Index].originalBundleID = window1.bundleIdentifier
            screenState.slots[slot2Index].originalOwnerName = window1.ownerName
        }
        
        debugLog("WindowLayoutManager", " ✅ Swapped individual windows on \(screenID): '\(window1.title)' (slot \(slot1Index) → \(slot2Index)) <-> '\(window2.title)' (slot \(slot2Index) → \(slot1Index))")
        logger.info("Swapped slot \(slot1Index) <-> slot \(slot2Index) on screen \(screenID)")
        
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        
        slotUpdated.send((slot1Index, screenState.slots[slot1Index]))
        slotUpdated.send((slot2Index, screenState.slots[slot2Index]))
        
        // Return to idle after a short delay, so other services ignore the window moves this causes
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setMode(.idle)
        }
    }
    
    // MARK: - Drops Across Screens

    /// Put a window in front of a slot on a screen, leaving any other layout it was in
    private func insertAtFront(_ window: WindowInfo, slotIndex: Int, forScreenID screenID: String) {
        removeWindowFromAllScreens(window.windowID)
        var screenState = state(forScreenID: screenID)
        guard slotIndex >= 0 && slotIndex < screenState.slots.count else { return }
        let placed = WindowInfo(
            id: window.id,
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            title: window.title,
            ownerName: window.ownerName,
            bundleIdentifier: window.bundleIdentifier,
            frame: screenState.slots[slotIndex].frame,
            thumbnail: window.thumbnail
        )
        screenState.slots[slotIndex].windows.insert(placed, at: 0)
        if screenState.slots[slotIndex].windows.count == 1 {
            screenState.slots[slotIndex].originalBundleID = window.bundleIdentifier
            screenState.slots[slotIndex].originalOwnerName = window.ownerName
        }
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
    }

    /// A window dropped onto a window of another screen joins that window's slot
    /// - Returns: The screens whose layouts changed
    @discardableResult
    func moveWindowAcrossScreens(_ window: WindowInfo, toSlotOf targetWindowID: CGWindowID) -> [String] {
        guard let target = findWindowAcrossScreens(targetWindowID) else { return [] }
        let source = findWindowAcrossScreens(window.windowID)?.screenID
        insertAtFront(window, slotIndex: target.slotIndex, forScreenID: target.screenID)
        debugLog("WindowLayoutManager", " Moved '\(window.ownerName)' from \(source ?? "no layout") to slot \(target.slotIndex) on \(target.screenID)")
        return [source, target.screenID].compactMap { $0 }
    }

    @discardableResult
    func moveWindowAcrossScreens(_ window: WindowInfo, toEmptySlot slotIndex: Int, forScreenID screenID: String) -> [String] {
        let source = findWindowAcrossScreens(window.windowID)?.screenID
        insertAtFront(window, slotIndex: slotIndex, forScreenID: screenID)
        debugLog("WindowLayoutManager", " Moved '\(window.ownerName)' from \(source ?? "no layout") to empty slot \(slotIndex) on \(screenID)")
        return [source, screenID].compactMap { $0 }
    }

    /// Swap of windows on different screens: each takes the other's slot. A dragged window from
    /// a screen without a layout leaves the target outside any layout
    /// - Returns: The screens whose layouts changed
    @discardableResult
    func swapWindowsAcrossScreens(dragged: WindowInfo, target: WindowInfo) -> [String] {
        guard let targetPlace = findWindowAcrossScreens(target.windowID) else { return [] }
        let draggedPlace = findWindowAcrossScreens(dragged.windowID)
        insertAtFront(dragged, slotIndex: targetPlace.slotIndex, forScreenID: targetPlace.screenID)
        if let draggedPlace {
            insertAtFront(target, slotIndex: draggedPlace.slotIndex, forScreenID: draggedPlace.screenID)
        } else {
            removeWindow(target.windowID, forScreenID: targetPlace.screenID)
        }
        debugLog("WindowLayoutManager", " Swapped '\(dragged.ownerName)' (\(draggedPlace?.screenID ?? "no layout")) with '\(target.ownerName)' (\(targetPlace.screenID))")
        return [draggedPlace?.screenID, targetPlace.screenID].compactMap { $0 }
    }

    // MARK: - Move Window to Slot
    
    /// Move a window to another slot (without swapping)
    /// The window is removed from its current slot and added to the target slot (grouping with existing windows)
    func moveWindowToSlot(windowID: CGWindowID, targetWindowID: CGWindowID, forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        
        guard let sourceSlotIndex = screenState.slotIndex(for: windowID),
              let targetSlotIndex = screenState.slotIndex(for: targetWindowID) else {
            debugLog("WindowLayoutManager", " ❌ moveWindowToSlot: could not find slots for windows")
            return
        }
        
        guard sourceSlotIndex != targetSlotIndex else {
            debugLog("WindowLayoutManager", " ⚠️ moveWindowToSlot: source and target are the same slot")
            return
        }
        
        guard let windowIndex = screenState.slots[sourceSlotIndex].windows.firstIndex(where: { $0.windowID == windowID }) else {
            debugLog("WindowLayoutManager", " ❌ moveWindowToSlot: window not found in source slot")
            return
        }
        
        let movedWindow = screenState.slots[sourceSlotIndex].windows.remove(at: windowIndex)
        
        screenState.slots[targetSlotIndex].windows.insert(movedWindow, at: 0)
        
        debugLog("WindowLayoutManager", " ✅ Moved window '\(movedWindow.title)' from slot \(sourceSlotIndex) to slot \(targetSlotIndex)")
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state.slots = screenState.slots
        }
        
        slotUpdated.send((sourceSlotIndex, screenState.slots[sourceSlotIndex]))
        slotUpdated.send((targetSlotIndex, screenState.slots[targetSlotIndex]))
        
        logger.info("Moved window to slot \(targetSlotIndex) on screen \(screenID)")
    }
    
    func moveWindowToEmptySlot(windowID: CGWindowID, slotIndex: Int, forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        
        guard slotIndex >= 0 && slotIndex < screenState.slots.count else {
            debugLog("WindowLayoutManager", " ❌ moveWindowToEmptySlot: invalid slot index \(slotIndex)")
            return
        }
        
        guard screenState.slots[slotIndex].isEmpty else {
            debugLog("WindowLayoutManager", " ⚠️ moveWindowToEmptySlot: slot \(slotIndex) is not empty, has \(screenState.slots[slotIndex].windows.count) windows")
            return
        }
        
        guard let sourceSlotIndex = screenState.slotIndex(for: windowID) else {
            debugLog("WindowLayoutManager", " ❌ moveWindowToEmptySlot: could not find source slot for window \(windowID)")
            return
        }
        
        guard sourceSlotIndex != slotIndex else {
            debugLog("WindowLayoutManager", " ⚠️ moveWindowToEmptySlot: source and target are the same slot")
            return
        }
        
        guard let windowIndex = screenState.slots[sourceSlotIndex].windows.firstIndex(where: { $0.windowID == windowID }) else {
            debugLog("WindowLayoutManager", " ❌ moveWindowToEmptySlot: window not found in source slot")
            return
        }
        
        var movedWindow = screenState.slots[sourceSlotIndex].windows.remove(at: windowIndex)
        
        movedWindow = WindowInfo(
            id: movedWindow.id,
            windowID: movedWindow.windowID,
            ownerPID: movedWindow.ownerPID,
            title: movedWindow.title,
            ownerName: movedWindow.ownerName,
            bundleIdentifier: movedWindow.bundleIdentifier,
            frame: screenState.slots[slotIndex].frame,
            thumbnail: movedWindow.thumbnail
        )
        
        screenState.slots[slotIndex].windows.append(movedWindow)
        
        debugLog("WindowLayoutManager", " ✅ Moved window '\(movedWindow.title)' from slot \(sourceSlotIndex) to empty slot \(slotIndex)")
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state.slots = screenState.slots
        }
        
        slotUpdated.send((sourceSlotIndex, screenState.slots[sourceSlotIndex]))
        slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
        
        logger.info("Moved window to empty slot \(slotIndex) on screen \(screenID)")
    }
    
    func swapActiveWindowsOnly(slot1Index: Int, slot2Index: Int, forScreenID screenID: String) -> (window1: WindowInfo?, window2: WindowInfo?) {
        var screenState = state(forScreenID: screenID)
        
        guard slot1Index >= 0 && slot1Index < screenState.slots.count,
              slot2Index >= 0 && slot2Index < screenState.slots.count,
              slot1Index != slot2Index else {
            logger.warning("Invalid slot indices for swap: \(slot1Index), \(slot2Index) on screen \(screenID)")
            return (nil, nil)
        }
        
        setMode(.swapping)
        
        let window1 = screenState.slots[slot1Index].primaryWindow
        let window2 = screenState.slots[slot2Index].primaryWindow
        
        if let w1 = window1 {
            screenState.slots[slot1Index].removeWindow(withID: w1.windowID)
        }
        if let w2 = window2 {
            screenState.slots[slot2Index].removeWindow(withID: w2.windowID)
        }
        
        if let w2 = window2 {
            screenState.slots[slot1Index].windows.insert(w2, at: 0)
            if screenState.slots[slot1Index].windows.count == 1 {
                screenState.slots[slot1Index].originalBundleID = w2.bundleIdentifier
                screenState.slots[slot1Index].originalOwnerName = w2.ownerName
            }
        }
        if let w1 = window1 {
            screenState.slots[slot2Index].windows.insert(w1, at: 0)
            if screenState.slots[slot2Index].windows.count == 1 {
                screenState.slots[slot2Index].originalBundleID = w1.bundleIdentifier
                screenState.slots[slot2Index].originalOwnerName = w1.ownerName
            }
        }
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        logger.info("Swapped active windows on screen \(screenID): slot \(slot1Index) <-> slot \(slot2Index)")
        
        slotUpdated.send((slot1Index, screenState.slots[slot1Index]))
        slotUpdated.send((slot2Index, screenState.slots[slot2Index]))
        
        // Return to idle after a short delay, so other services ignore the window moves this causes
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.setMode(.idle)
        }
        
        validateSlotIntegrity(forScreenID: screenID)
        
        return (window1, window2)
    }
    
    // MARK: - Slot Integrity Validation
    
    /// Validates that no window appears in multiple slots (detects data corruption)
    /// Logs errors if duplicates found and attempts to fix them
    func validateSlotIntegrity(forScreenID screenID: String? = nil) {
        let targetScreenIDs = screenID.map { [$0] } ?? Array(screenStates.keys)
        
        for sid in targetScreenIDs {
            guard let screenState = screenStates[sid] else { continue }
            
            var seenWindowIDs: [CGWindowID: Int] = [:] // windowID -> slotIndex
            var duplicates: [(windowID: CGWindowID, slots: [Int])] = []
            
            for (slotIndex, slot) in screenState.slots.enumerated() {
                for window in slot.windows {
                    if let existingSlot = seenWindowIDs[window.windowID] {
                        duplicates.append((window.windowID, [existingSlot, slotIndex]))
                        debugLog("WindowLayoutManager", "🚨 INTEGRITY ERROR: windowID \(window.windowID) in BOTH slot \(existingSlot) AND slot \(slotIndex) on screen \(sid)")
                    } else {
                        seenWindowIDs[window.windowID] = slotIndex
                    }
                }
            }
            
            if !duplicates.isEmpty {
                var fixedState = screenState
                for (windowID, slots) in duplicates {
                    for slotIndex in slots.dropFirst() {
                        fixedState.slots[slotIndex].windows.removeAll { $0.windowID == windowID }
                        debugLog("WindowLayoutManager", "🔧 Fixed: removed windowID \(windowID) from slot \(slotIndex)")
                    }
                }
                screenStates[sid] = fixedState
                if sid == activeScreenID {
                    state = fixedState
                }
                logger.error("Fixed \(duplicates.count) duplicate window(s) on screen \(sid)")
            }
        }
    }
    
    // MARK: - Frame Operations
    
    /// - Parameters:
    ///   - isManualResize: If true, marks layout as manually modified (preserves on Space return)
    func updateSlotFrame(_ index: Int, frame: CGRect, forScreenID screenID: String, isManualResize: Bool = false) {
        var screenState = state(forScreenID: screenID)
        guard index >= 0 && index < screenState.slots.count else { return }
        
        screenState.slots[index].frame = frame
        
        if isManualResize {
            screenState.hasManualModifications = true
            logger.debug("Layout marked as manually modified for screen \(screenID) (slot \(index) resized)")
        }
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        slotUpdated.send((index, screenState.slots[index]))
    }
    
    func recalculateAllFrames() {
        // Recalculate for all active screens; this also updates `state` for the active screen
        for screenID in screensWithActiveLayouts {
            recalculateFrames(forScreenID: screenID)
        }
        
        framesRecalculated.send()
    }
    
    /// Moves a screen's slot frames to where they belong after its visible area changed.
    /// Unlike `recalculateFrames`, slots the user resized keep their share of the screen.
    func rescaleFrames(forScreenID screenID: String, from old: CGRect, to new: CGRect) {
        guard var screenState = screenStates[screenID], screenState.template != nil else { return }
        for index in screenState.slots.indices {
            screenState.slots[index].frame = screenManager.rescale(screenState.slots[index].frame, from: old, to: new)
        }
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        debugLog("WindowLayoutManager", "Moved \(screenState.slots.count) slot frames of screen '\(screenID)' from visible area \(old) to \(new)")
    }
    
    func recalculateFrames(forScreenID screenID: String) {
        guard var screenState = screenStates[screenID],
              let template = screenState.template else {
            return
        }
        
        guard let screen = screenManager.screen(for: screenID) else {
            logger.warning("Screen not found for ID: \(screenID)")
            return
        }
        
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        let screenFrame = screenManager.visibleFrame(for: screen)
        
        for (index, zone) in sortedZones.enumerated() {
            guard index < screenState.slots.count else { break }
            
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            screenState.slots[index].frame = cgFrame
        }
        
        screenStates[screenID] = screenState
        
        if screenID == activeScreenID {
            state = screenState
        }
        
        logger.debug("Recalculated \(screenState.slots.count) slot frames for screen \(screenID)")
    }
    
    // MARK: - Manual Modification Tracking
    
    /// Clear manual modifications flag (call when window count changes)
    func clearManualModifications(forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        if screenState.hasManualModifications {
            screenState.hasManualModifications = false
            screenStates[screenID] = screenState
            if screenID == activeScreenID {
                state = screenState
            }
            logger.debug("Cleared manual modifications flag for screen \(screenID)")
        }
    }
    
    /// Mark layout as manually modified (call after user resize)
    func markAsManuallyModified(forScreenID screenID: String) {
        var screenState = state(forScreenID: screenID)
        screenState.hasManualModifications = true
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        logger.debug("Marked layout as manually modified for screen \(screenID)")
    }
    
    // MARK: - Multi-Monitor Window Transfer
    
    func findWindowAcrossScreens(_ windowID: CGWindowID) -> (screenID: String, slotIndex: Int)? {
        for (screenID, screenState) in screenStates {
            if let slotIndex = screenState.slotIndex(for: windowID) {
                return (screenID, slotIndex)
            }
        }
        // Also check the active state (in case it's not synced)
        if let slotIndex = state.slotIndex(for: windowID) {
            return (activeScreenID, slotIndex)
        }
        return nil
    }
    
    func areInSameSlot(_ window1ID: CGWindowID, _ window2ID: CGWindowID) -> Bool {
        guard let first = findWindowAcrossScreens(window1ID),
              let second = findWindowAcrossScreens(window2ID) else { return false }
        return first.screenID == second.screenID && first.slotIndex == second.slotIndex
    }
    
    @discardableResult
    func removeWindowFromAnyScreen(_ windowID: CGWindowID) -> (screenID: String, slotIndex: Int, window: WindowInfo)? {
        for (screenID, var screenState) in screenStates {
            if let slotIndex = screenState.slotIndex(for: windowID),
               let window = screenState.slots[slotIndex].removeWindow(withID: windowID) {
                screenStates[screenID] = screenState
                
                if screenID == activeScreenID {
                    state = screenState
                }
                
                logger.info("Removed window \(windowID) from screen \(screenID), slot \(slotIndex)")
                slotUpdated.send((slotIndex, screenState.slots[slotIndex]))
                return (screenID, slotIndex, window)
            }
        }
        return nil
    }
    
    /// - Parameters:
    ///   - toSlotIndex: Optional specific slot index (if nil, finds best slot)
    /// - Returns: New slot index if successful, nil if failed
    @discardableResult
    func transferWindow(_ windowID: CGWindowID, toScreenID: String, toSlotIndex: Int? = nil) -> Int? {
        guard let (fromScreenID, _, window) = removeWindowFromAnyScreen(windowID) else {
            logger.warning("Cannot transfer - window \(windowID) not found in any layout")
            return nil
        }
        
        debugLog("WindowLayoutManager"," transferWindow: '\(window.title)' from \(fromScreenID) to \(toScreenID)")
        
        guard var targetState = screenStates[toScreenID] else {
            // Target screen has no layout - window becomes unmanaged
            debugLog("WindowLayoutManager"," transferWindow: target screen \(toScreenID) has no active layout")
            return nil
        }
        
        debugLog("WindowLayoutManager"," transferWindow: target state has \(targetState.slots.count) slots")
        
        let finalSlotIndex: Int
        
        if let specificSlot = toSlotIndex, specificSlot >= 0 && specificSlot < targetState.slots.count {
            finalSlotIndex = specificSlot
        } else {
            if let emptyIndex = targetState.slots.firstIndex(where: { $0.isEmpty }) {
                finalSlotIndex = emptyIndex
            } else if let groupIndex = targetState.findSlotForGrouping(window: window)?.index {
                finalSlotIndex = groupIndex
            } else {
                finalSlotIndex = targetState.slots.count - 1
            }
        }
        
        if targetState.slots[finalSlotIndex].isEmpty {
            targetState.slots[finalSlotIndex].windows = [window]
            targetState.slots[finalSlotIndex].originalBundleID = window.bundleIdentifier
            targetState.slots[finalSlotIndex].originalOwnerName = window.ownerName
        } else {
            targetState.slots[finalSlotIndex].addWindow(window)
        }
        
        screenStates[toScreenID] = targetState
        
        if toScreenID == activeScreenID {
            state = targetState
        }
        
        let slotFrame = targetState.slots[finalSlotIndex].frame
        debugLog("WindowLayoutManager"," transferWindow: slot \(finalSlotIndex) frame = \(slotFrame)")
        logger.info("Window '\(window.title)' transferred to screen \(toScreenID), slot \(finalSlotIndex)")
        slotUpdated.send((finalSlotIndex, targetState.slots[finalSlotIndex]))
        
        return finalSlotIndex
    }
    
    /// Handle window moving between screens (detected by position change)
    /// - Returns: New slot index if integrated into layout
    @discardableResult
    func handleWindowMovedToScreen(_ window: WindowInfo, newScreenID: String) -> Int? {
        if let (oldScreenID, _) = findWindowAcrossScreens(window.windowID) {
            if oldScreenID != newScreenID {
                return transferWindow(window.windowID, toScreenID: newScreenID)
            }
        }
        
        // Window wasn't managed, or stayed on same screen
        return nil
    }
    
    // MARK: - Persistence
    
    private static let savedLayoutKeyPrefix = "savedLayoutInfo_v4_"  // Per-Space-Screen key prefix
    private static let legacyV3KeyPrefix = "savedLayoutInfo_v3_"     // Legacy per-Space key
    
    private static func storageKey(forSpaceID spaceID: String, screenID: String) -> String {
        return "\(savedLayoutKeyPrefix)\(spaceID)_\(screenID)"
    }
    
    private static func legacyStorageKey(forSpaceID spaceID: String) -> String {
        return "\(legacyV3KeyPrefix)\(spaceID)"
    }
    
    func saveLayoutInfo(forSpaceID spaceID: String, screenID: String) {
        let key = Self.storageKey(forSpaceID: spaceID, screenID: screenID)
        let layoutState = screenStates[screenID] ?? state
        
        guard let template = layoutState.template else {
            UserDefaults.standard.removeObject(forKey: key)
            logger.info("Cleared saved layout info for space \(spaceID), screen \(screenID)")
            return
        }
        
        let savedSlots = layoutState.slots.map { slot in
            let groupBundleIDs = slot.windows.compactMap { $0.bundleIdentifier }
            let groupPIDs = slot.windows.map { $0.ownerPID }
            
            // Use PRIMARY window's info for restoration (not original owner)
            // This ensures we restore the currently active window, not a window that may have been removed
            let primaryWindow = slot.primaryWindow
            let ownerNameToSave = primaryWindow?.ownerName ?? slot.originalOwnerName
            let bundleIDToSave = primaryWindow?.bundleIdentifier ?? slot.originalBundleID
            
            return SavedLayoutInfo.SavedSlotInfo(
                slotID: slot.id,
                index: slot.index,
                ownerName: ownerNameToSave,
                bundleIdentifier: bundleIDToSave,
                frame: slot.frame,
                groupBundleIDs: groupBundleIDs.isEmpty ? nil : groupBundleIDs,
                groupPIDs: groupPIDs.isEmpty ? nil : groupPIDs.map { Int32($0) }
            )
        }
        
        let savedInfo = SavedLayoutInfo(
            templateID: template.id,
            slots: savedSlots,
            visibleFrame: visibleFrame(forScreenID: screenID)
        )
        
        do {
            let data = try JSONEncoder().encode(savedInfo)
            UserDefaults.standard.set(data, forKey: key)
            logger.info("Saved layout for space \(spaceID), screen \(screenID): template=\(template.name), slots=\(savedSlots.count)")
            debugLog("WindowLayoutManager"," Saved layout for space '\(spaceID)', screen '\(screenID)': \(template.name)")
        } catch {
            logger.error("Failed to save layout info: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Saved Frames and Screen Size
    // Saved slot frames are in points of the visible area they were saved for.
    // When the screen's resolution has changed since, they are moved to the same place on the current one.

    private func visibleFrame(forScreenID screenID: String) -> CGRect? {
        screenManager.screen(for: screenID).map(screenManager.visibleCGFrame(for:))
    }

    private func fitted(_ info: SavedLayoutInfo, toScreenID screenID: String) -> SavedLayoutInfo {
        guard let old = info.visibleFrame, let new = visibleFrame(forScreenID: screenID), old != new else { return info }
        var info = info
        for index in info.slots.indices {
            info.slots[index].frame = info.slots[index].frame.map { screenManager.rescale($0, from: old, to: new) }
        }
        info.visibleFrame = new
        return info
    }

    private func fitted(_ snapshot: ManualLayoutSnapshot, toScreenID screenID: String) -> ManualLayoutSnapshot {
        guard let old = snapshot.visibleFrame, let new = visibleFrame(forScreenID: screenID), old != new else { return snapshot }
        var snapshot = snapshot
        for index in snapshot.slots.indices {
            snapshot.slots[index].frame = screenManager.rescale(snapshot.slots[index].frame, from: old, to: new)
        }
        snapshot.visibleFrame = new
        return snapshot
    }

    /// Layouts saved before the visible area was kept with them are taken to be for the current one.
    func stampSavedFramesWithVisibleArea() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Self.savedLayoutKeyPrefix) || $0.hasPrefix("manualLayout_v1_")
        }
        for screen in screenManager.allScreens() {
            let screenID = screenManager.identifier(for: screen)
            let visible = screenManager.visibleCGFrame(for: screen)
            // Same shape as an encoded CGRect
            let encoded = [[visible.minX, visible.minY], [visible.width, visible.height]]
            for key in keys where key.hasSuffix("_\(screenID)") || key.contains("_\(screenID)_") {
                guard let data = defaults.data(forKey: key),
                      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["visibleFrame"] == nil else { continue }
                object["visibleFrame"] = encoded
                if let stamped = try? JSONSerialization.data(withJSONObject: object) {
                    defaults.set(stamped, forKey: key)
                }
            }
        }
    }

    // MARK: - Manual Layout Snapshot

    /// Without `templateID`: the layout kept for coming back to Manual. With it: how that template was arranged.
    private static func manualLayoutKey(forSpaceID spaceID: String, screenID: String, templateID: UUID? = nil) -> String {
        let key = "manualLayout_v1_\(spaceID)_\(screenID)"
        return templateID.map { "\(key)_\($0.uuidString)" } ?? key
    }

    /// Keeps the screen's current Manual layout for when the desktop comes back to Manual
    func saveManualLayout(forSpaceID spaceID: String, screenID: String) {
        guard let snapshot = currentManualSnapshot(forScreenID: screenID) else { return }
        storeManualLayout(snapshot, forSpaceID: spaceID, screenID: screenID)
        storeManualLayout(snapshot, forSpaceID: spaceID, screenID: screenID, templateID: snapshot.templateID)
    }

    /// Keeps how the screen's current template is arranged, for when the user picks this template again
    func saveTemplateArrangement(forSpaceID spaceID: String, screenID: String) {
        guard let snapshot = currentManualSnapshot(forScreenID: screenID) else { return }
        storeManualLayout(snapshot, forSpaceID: spaceID, screenID: screenID, templateID: snapshot.templateID)
    }

    func loadTemplateArrangement(_ templateID: UUID, forSpaceID spaceID: String, screenID: String) -> ManualLayoutSnapshot? {
        let canonical = PredefinedTemplates.canonicalID(for: templateID)
        let primaryKey = Self.manualLayoutKey(forSpaceID: spaceID, screenID: screenID, templateID: canonical)
        let fallbackKey = canonical == PredefinedTemplates.centerSplitSidebars.id
            ? Self.manualLayoutKey(forSpaceID: spaceID, screenID: screenID, templateID: PredefinedTemplates.retiredTwoOneTwoID)
            : nil
        guard let data = UserDefaults.standard.data(forKey: primaryKey)
            ?? fallbackKey.flatMap({ UserDefaults.standard.data(forKey: $0) }),
              var snapshot = try? JSONDecoder().decode(ManualLayoutSnapshot.self, from: data) else { return nil }
        snapshot.templateID = PredefinedTemplates.canonicalID(for: snapshot.templateID)
        return fitted(snapshot, toScreenID: screenID)
    }

    private func currentManualSnapshot(forScreenID screenID: String) -> ManualLayoutSnapshot? {
        let layoutState = screenStates[screenID] ?? state
        guard let template = layoutState.template, layoutState.slots.contains(where: { !$0.isEmpty }) else { return nil }
        return ManualLayoutSnapshot(
            templateID: template.id,
            slots: layoutState.slots.map { slot in
                ManualLayoutSnapshot.SlotSnapshot(
                    index: slot.index,
                    frame: slot.frame,
                    windowIDs: slot.windows.map(\.windowID),
                    bundleIDs: slot.windows.compactMap(\.bundleIdentifier)
                )
            },
            visibleFrame: visibleFrame(forScreenID: screenID)
        )
    }

    /// Same as `saveManualLayout`, for a desktop that isn't on screen: only its saved layout is known
    func saveManualLayoutFromSavedInfo(forSpaceID spaceID: String, screenID: String) {
        guard let savedInfo = loadSavedLayoutInfo(forSpaceID: spaceID, screenID: screenID) else { return }
        let snapshot = ManualLayoutSnapshot(
            templateID: savedInfo.templateID,
            slots: savedInfo.slots.compactMap { slot in
                guard let frame = slot.frame else { return nil }
                let bundleIDs = slot.groupBundleIDs ?? slot.bundleIdentifier.map { [$0] } ?? []
                return ManualLayoutSnapshot.SlotSnapshot(index: slot.index, frame: frame, windowIDs: [], bundleIDs: bundleIDs)
            },
            visibleFrame: savedInfo.visibleFrame
        )
        storeManualLayout(snapshot, forSpaceID: spaceID, screenID: screenID)
    }

    private func storeManualLayout(_ snapshot: ManualLayoutSnapshot, forSpaceID spaceID: String, screenID: String, templateID: UUID? = nil) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.manualLayoutKey(forSpaceID: spaceID, screenID: screenID, templateID: templateID))
        let windowCount = snapshot.slots.reduce(0) { $0 + max($1.windowIDs.count, $1.bundleIDs.count) }
        let kind = templateID == nil ? "Manual layout" : "arrangement of template \(snapshot.templateID)"
        debugLog("WindowLayoutManager", "Kept the \(kind) of desktop '\(spaceID)', screen '\(screenID)': \(snapshot.slots.count) slots, \(windowCount) windows")
    }

    func loadManualLayout(forSpaceID spaceID: String, screenID: String) -> ManualLayoutSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.manualLayoutKey(forSpaceID: spaceID, screenID: screenID)),
              var snapshot = try? JSONDecoder().decode(ManualLayoutSnapshot.self, from: data) else { return nil }
        snapshot.templateID = PredefinedTemplates.canonicalID(for: snapshot.templateID)
        return fitted(snapshot, toScreenID: screenID)
    }

    func removeManualLayout(forSpaceID spaceID: String, screenID: String) {
        UserDefaults.standard.removeObject(forKey: Self.manualLayoutKey(forSpaceID: spaceID, screenID: screenID))
    }

    /// Puts the kept windows back into their slots in the layout state (windows are not moved here).
    /// Windows are found by id, or else by app. Returns false when none of them is around any more.
    func restoreManualLayout(_ snapshot: ManualLayoutSnapshot, template: GridTemplate, currentWindows: [WindowInfo], forScreenID screenID: String) -> Bool {
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        let snapshotIDs = Set(snapshot.slots.flatMap(\.windowIDs))
        var claimed = Set<CGWindowID>()

        func take(_ window: WindowInfo?) -> WindowInfo? {
            guard let window, !claimed.contains(window.windowID) else { return nil }
            claimed.insert(window.windowID)
            return window
        }

        var slotWindows: [Int: [WindowInfo]] = [:]
        for saved in snapshot.slots {
            slotWindows[saved.index] = saved.windowIDs.compactMap { id in
                take(currentWindows.first { $0.windowID == id })
            }
        }
        // Windows of apps that were restarted get new ids; match them by app
        for saved in snapshot.slots {
            var missing = saved.bundleIDs
            for window in slotWindows[saved.index] ?? [] {
                if let i = missing.firstIndex(of: window.bundleIdentifier ?? "") { missing.remove(at: i) }
            }
            for bundleID in missing {
                let match = currentWindows.first {
                    $0.bundleIdentifier == bundleID && !claimed.contains($0.windowID) && !snapshotIDs.contains($0.windowID)
                }
                if let window = take(match) {
                    slotWindows[saved.index, default: []].append(window)
                }
            }
        }

        guard slotWindows.values.contains(where: { !$0.isEmpty }) else {
            debugLog("WindowLayoutManager", "None of the kept Manual windows are around for screen '\(screenID)'")
            return false
        }

        let screen = screenManager.screen(for: screenID) ?? screenManager.activeScreen()
        let screenFrame = screenManager.visibleFrame(for: screen)
        let slots = sortedZones.enumerated().map { index, zone -> Slot in
            let saved = snapshot.slots.first { $0.index == index }
            let frame = saved?.frame ?? screenManager.convertToCGCoordinates(
                frame: screenManager.calculateAbsoluteFrame(relativeFrame: zone.relativeFrame, in: screenFrame),
                for: screen
            )
            let windows = slotWindows[index] ?? []
            return Slot(
                id: zone.id,
                index: index,
                frame: frame,
                windows: windows,
                originalBundleID: windows.first?.bundleIdentifier ?? saved?.bundleIDs.first,
                originalOwnerName: windows.first?.ownerName
            )
        }
        setLayoutWithSlots(template: template, slots: slots, forScreenID: screenID)
        debugLog("WindowLayoutManager", "Brought back the Manual layout for screen '\(screenID)': \(claimed.count) windows in \(slots.filter { !$0.isEmpty }.count) slots")
        return true
    }
    
    func loadSavedLayoutInfo(forSpaceID spaceID: String, screenID: String) -> SavedLayoutInfo? {
        let key = Self.storageKey(forSpaceID: spaceID, screenID: screenID)
        
        if let data = UserDefaults.standard.data(forKey: key) {
            do {
                var savedInfo = try JSONDecoder().decode(SavedLayoutInfo.self, from: data)
                savedInfo.templateID = PredefinedTemplates.canonicalID(for: savedInfo.templateID)
                logger.info("Loaded layout for space \(spaceID), screen \(screenID): templateID=\(savedInfo.templateID)")
                return fitted(savedInfo, toScreenID: screenID)
            } catch {
                logger.error("Failed to load saved layout info: \(error.localizedDescription)")
            }
        }
        
        let legacyKey = Self.legacyStorageKey(forSpaceID: spaceID)
        if let data = UserDefaults.standard.data(forKey: legacyKey) {
            do {
                var savedInfo = try JSONDecoder().decode(SavedLayoutInfo.self, from: data)
                savedInfo.templateID = PredefinedTemplates.canonicalID(for: savedInfo.templateID)
                logger.info("Loaded legacy v3 layout for space \(spaceID)")
                return savedInfo
            } catch {
                logger.error("Failed to load legacy v3 layout: \(error.localizedDescription)")
            }
        }
        
        return nil
    }
    
    func restoreLayout(from savedInfo: SavedLayoutInfo, template: GridTemplate, currentWindows: [WindowInfo], forScreenID screenID: String) -> Bool {
        let screen = screenManager.screen(for: screenID) ?? screenManager.activeScreen()
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        let screenFrame = screenManager.visibleFrame(for: screen)
        
        var newSlots: [Slot] = []
        var matchedWindowIDs = Set<CGWindowID>()
        
        struct SlotInfo {
            let index: Int
            let zone: Zone
            let cgFrame: CGRect
            let savedSlot: SavedLayoutInfo.SavedSlotInfo?
        }
        
        var slotInfos: [SlotInfo] = []
        
        let screenArea = screenFrame.width * screenFrame.height
        
        for (index, zone) in sortedZones.enumerated() {
            let savedSlot = savedInfo.slots.first { $0.slotID == zone.id || $0.index == index }
            
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            let defaultFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: screen)
            
            // Use saved frame if available and valid (preserves user resize modifications)
            var cgFrame = defaultFrame
            if let savedFrame = savedSlot?.frame {
                // Validate saved frame - reject if it covers almost entire screen (likely corrupted)
                let savedArea = savedFrame.width * savedFrame.height
                let screenCoverage = savedArea / screenArea
                
                let templateArea = defaultFrame.width * defaultFrame.height
                let sizeRatio = templateArea > 0 ? savedArea / templateArea : 1.0
                
                if screenCoverage > 0.85 {
                    logger.warning("Ignoring corrupted saved frame for slot \(index) - covers \(Int(screenCoverage * 100))% of screen")
                } else if sizeRatio > 1.5 {
                    logger.warning("Ignoring corrupted saved frame for slot \(index) - \(Int(sizeRatio * 100))% of template size")
                } else {
                    cgFrame = savedFrame
                    logger.debug("Using saved frame for slot \(index)")
                }
            }
            
            slotInfos.append(SlotInfo(index: index, zone: zone, cgFrame: cgFrame, savedSlot: savedSlot))
        }
        
        for slotInfo in slotInfos {
            var windowForSlot: WindowInfo? = nil
            
            if let savedSlot = slotInfo.savedSlot {
                let matchFrame = slotInfo.savedSlot?.frame ?? slotInfo.cgFrame
                
                let identityMatchedWindow = currentWindows
                    .filter { window in
                        guard !matchedWindowIDs.contains(window.windowID) else { return false }
                        let overlap = overlapRatio(windowFrame: window.frame, slotFrame: matchFrame)
                        guard overlap >= 0.3 else { return false }
                        
                        if let savedBundle = savedSlot.bundleIdentifier,
                           let windowBundle = window.bundleIdentifier,
                           savedBundle == windowBundle {
                            return true
                        }
                        if let savedOwner = savedSlot.ownerName, window.ownerName == savedOwner {
                            return true
                        }
                        return false
                    }
                    .sorted { w1, w2 in
                        let overlap1 = overlapRatio(windowFrame: w1.frame, slotFrame: matchFrame)
                        let overlap2 = overlapRatio(windowFrame: w2.frame, slotFrame: matchFrame)
                        return overlap1 > overlap2
                    }
                    .first
                
                if let window = identityMatchedWindow {
                    windowForSlot = window
                    matchedWindowIDs.insert(window.windowID)
                }
            }
            
            if windowForSlot == nil {
                let matchFrame = slotInfo.savedSlot?.frame ?? slotInfo.cgFrame
                if let positionMatch = currentWindows.first(where: { window in
                    guard !matchedWindowIDs.contains(window.windowID) else { return false }
                    return windowOverlapsSlot(windowFrame: window.frame, slotFrame: matchFrame)
                }) {
                    windowForSlot = positionMatch
                    matchedWindowIDs.insert(positionMatch.windowID)
                }
            }
            
            let windowsForSlot = windowForSlot.map { [$0] } ?? []
            
            if let window = windowForSlot {
                debugLog("WindowLayoutManager"," Screen \(screenID) Slot \(slotInfo.index): restored '\(window.ownerName)'")
            }
            
            let slot = Slot(
                id: slotInfo.zone.id,
                index: slotInfo.index,
                frame: slotInfo.cgFrame,
                windows: windowsForSlot,
                originalBundleID: slotInfo.savedSlot?.bundleIdentifier,
                originalOwnerName: slotInfo.savedSlot?.ownerName
            )
            newSlots.append(slot)
        }
        
        let matchedCount = newSlots.filter { !$0.isEmpty }.count
        guard matchedCount > 0 else {
            logger.info("No matching windows found for saved layout on screen \(screenID)")
            return false
        }
        
        let unmatchedWindows = currentWindows.filter { !matchedWindowIDs.contains($0.windowID) }
        debugLog("WindowLayoutManager"," Screen \(screenID): Checking \(unmatchedWindows.count) unmatched windows for grouping")
        
        for unmatchedWindow in unmatchedWindows {
            var foundSlot = false
            
            for (slotIndex, slotInfo) in slotInfos.enumerated() {
                if let groupPIDs = slotInfo.savedSlot?.groupPIDs,
                   groupPIDs.contains(Int32(unmatchedWindow.ownerPID)) {
                    let overlap = overlapRatio(windowFrame: unmatchedWindow.frame, slotFrame: slotInfo.cgFrame)
                    if overlap >= 0.3 {
                        newSlots[slotIndex].windows.append(unmatchedWindow)
                        debugLog("WindowLayoutManager"," Screen \(screenID) Slot \(slotIndex): added '\(unmatchedWindow.ownerName)' to group (matched by saved PID, overlap: \(Int(overlap * 100))%)")
                        foundSlot = true
                        break
                    }
                }
            }
            
            if !foundSlot, let windowBundleID = unmatchedWindow.bundleIdentifier {
                for (slotIndex, slotInfo) in slotInfos.enumerated() {
                    if let groupBundleIDs = slotInfo.savedSlot?.groupBundleIDs,
                       groupBundleIDs.contains(windowBundleID) {
                        let overlap = overlapRatio(windowFrame: unmatchedWindow.frame, slotFrame: slotInfo.cgFrame)
                        if overlap >= 0.3 {
                            newSlots[slotIndex].windows.append(unmatchedWindow)
                            debugLog("WindowLayoutManager"," Screen \(screenID) Slot \(slotIndex): added '\(unmatchedWindow.ownerName)' to group (matched by saved bundleID, overlap: \(Int(overlap * 100))%)")
                            foundSlot = true
                            break
                        }
                    }
                }
            }
            
            // Strategy 3: Fall back to overlap-based matching for EMPTY slots only
            // Don't add to existing groups unless explicitly saved as group member
            if !foundSlot {
                let windowArea = unmatchedWindow.frame.width * unmatchedWindow.frame.height
                let screenCoverage = windowArea / screenArea
                if screenCoverage > 0.8 {
                    debugLog("WindowLayoutManager"," Screen \(screenID): Skipping '\(unmatchedWindow.ownerName)' - appears to be exiting fullscreen")
                    continue
                }
                
                for slotIndex in 0..<newSlots.count {
                    guard newSlots[slotIndex].isEmpty else { continue }
                    let overlap = overlapRatio(windowFrame: unmatchedWindow.frame, slotFrame: newSlots[slotIndex].frame)
                    if overlap >= 0.5 {
                        newSlots[slotIndex].windows.append(unmatchedWindow)
                        debugLog("WindowLayoutManager"," Screen \(screenID) Slot \(slotIndex): assigned '\(unmatchedWindow.ownerName)' to empty slot (overlap: \(Int(overlap * 100))%)")
                        foundSlot = true
                        break
                    }
                }
            }
            
            if !foundSlot {
                debugLog("WindowLayoutManager"," Screen \(screenID): Window '\(unmatchedWindow.ownerName)' not matched to any slot")
            }
        }
        
        var newState = LayoutState()
        newState.template = template
        newState.slots = newSlots
        
        screenStates[screenID] = newState
        
        if screenID == activeScreenID {
            state = newState
        }
        
        let totalWindows = newSlots.reduce(0) { $0 + $1.windowCount }
        let groupCount = newSlots.filter { $0.hasGroup }.count
        logger.info("Restored layout for screen \(screenID): \(matchedCount) slots, \(totalWindows) windows, \(groupCount) groups")
        debugLog("WindowLayoutManager"," Restored for screen '\(screenID)': \(matchedCount) slots, \(totalWindows) windows, \(groupCount) groups")
        
        return true
    }
    
    private func overlapRatio(windowFrame: CGRect, slotFrame: CGRect) -> CGFloat {
        let intersection = windowFrame.intersection(slotFrame)
        guard !intersection.isNull else { return 0 }
        
        let windowArea = windowFrame.width * windowFrame.height
        guard windowArea > 0 else { return 0 }
        
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / windowArea
    }
    
    /// Check if a window's frame overlaps significantly with a slot frame
    /// Uses 50% overlap threshold to handle grouped windows with slight differences
    private func windowOverlapsSlot(windowFrame: CGRect, slotFrame: CGRect) -> Bool {
        let intersection = windowFrame.intersection(slotFrame)
        guard !intersection.isNull else { return false }
        
        let windowArea = windowFrame.width * windowFrame.height
        guard windowArea > 0 else { return false }
        
        let intersectionArea = intersection.width * intersection.height
        let overlapRatio = intersectionArea / windowArea
        
        // Window is considered in slot if 50%+ of its area overlaps
        // Lower threshold to catch grouped windows that may have slight size/position differences
        return overlapRatio >= 0.5
    }
    
    // MARK: - Helper Methods
    
    /// Removes windows that are no longer visible and redistributes grouped windows to empty slots
    func syncWithVisibleWindows(_ visibleWindowIDs: Set<CGWindowID>, forScreenID screenID: String, skipRedistribution: Bool = false) {
        guard UserSession.isActive, var screenState = screenStates[screenID] else { return }
        
        var updated = false
        var windowsToReposition: [(Int, WindowInfo)] = []
        
        for i in 0..<screenState.slots.count {
            let originalCount = screenState.slots[i].windows.count
            screenState.slots[i].windows.removeAll { !visibleWindowIDs.contains($0.windowID) }
            
            if screenState.slots[i].windows.count != originalCount {
                updated = true
            }
        }
        
        if !skipRedistribution {
            var emptySlotIndices: [Int] = []
            var groupSlotIndices: [Int] = []
            
            for (index, slot) in screenState.slots.enumerated() {
                if slot.isEmpty {
                    emptySlotIndices.append(index)
                } else if slot.hasGroup {
                    groupSlotIndices.append(index)
                }
            }
            
            for emptySlotIndex in emptySlotIndices {
                guard let groupIndex = groupSlotIndices.first(where: { screenState.slots[$0].hasGroup }) else {
                    break
                }
                
                guard screenState.slots[groupIndex].windows.count > 1 else { continue }
                
                let windowToMove = screenState.slots[groupIndex].windows.removeLast()
                screenState.slots[emptySlotIndex].windows = [windowToMove]
                screenState.slots[emptySlotIndex].originalBundleID = windowToMove.bundleIdentifier
                screenState.slots[emptySlotIndex].originalOwnerName = windowToMove.ownerName
                
                windowsToReposition.append((emptySlotIndex, windowToMove))
                logger.info("Moved '\(windowToMove.title)' from slot \(groupIndex) to empty slot \(emptySlotIndex) on screen \(screenID)")
                
                debugLog("WindowLayoutManager", " 📊 After move: slot \(groupIndex) now has \(screenState.slots[groupIndex].windows.count) windows, slot \(emptySlotIndex) now has \(screenState.slots[emptySlotIndex].windows.count) windows")
            }
        }
        
        screenStates[screenID] = screenState

        if screenID == activeScreenID {
            state = screenState
        }
        
        pendingRepositioningWindows[screenID] = windowsToReposition
        
        if updated {
            logger.debug("Synced slots with visible windows for screen \(screenID)")
        }
    }
    
    /// Storage for windows that need repositioning after sync (per-screen)
    private(set) var pendingRepositioningWindows: [String: [(Int, WindowInfo)]] = [:]
    
    /// Get and clear windows needing repositioning for a screen
    func windowsNeedingRepositioning(forScreenID screenID: String) -> [(Int, WindowInfo)] {
        let windows = pendingRepositioningWindows[screenID] ?? []
        pendingRepositioningWindows[screenID] = nil
        return windows
    }
    
}

// MARK: - Smart Window Assignment (Centralized)

extension WindowLayoutManager {
    
    /// Assigns windows to slots with app-aware distribution.
    /// This is the single source of truth for window-to-slot assignment logic.
    /// - Each app gets at least one slot while there are enough slots
    /// - Apps with more windows get more slots (proportionally)
    /// - Overflow windows from the same app group together
    /// - Different apps share a slot only when there are more apps than slots:
    ///   the apps that do not get a slot join the last assigned slot
    /// - Parameters:
    ///   - windows: Sorted list of windows to assign
    ///   - frontmostPID: PID of frontmost app (for prioritization)
    func assignWindowsToSlots(
        windows: [WindowInfo],
        slotCount: Int,
        frontmostPID: pid_t? = nil
    ) -> [[WindowInfo]] {
        debugLog("WindowLayoutManager"," START: \(windows.count) windows -> \(slotCount) slots")
        
        guard slotCount > 0 else { return [] }
        guard !windows.isEmpty else { return Array(repeating: [], count: slotCount) }
        
        var slotAssignments: [[WindowInfo]] = Array(repeating: [], count: slotCount)
        
        var appGroups: [String: [WindowInfo]] = [:]
        var appOrder: [String] = []
        for window in windows {
            let appKey = window.bundleIdentifier ?? window.ownerName
            if appGroups[appKey] == nil {
                appGroups[appKey] = []
                appOrder.append(appKey)
            }
            appGroups[appKey]?.append(window)
        }
        
        let appCount = appGroups.count
        debugLog("WindowLayoutManager"," Grouped into \(appCount) apps")
        
        // Sort apps by window count (descending), with frontmost app first.
        // Apps with as many windows keep the order of the window list, not the dictionary's
        var sortedAppKeys = appOrder.enumerated()
            .sorted { a, b in
                let countA = appGroups[a.element]!.count, countB = appGroups[b.element]!.count
                return countA != countB ? countA > countB : a.offset < b.offset
            }
            .map(\.element)
        
        if let frontPID = frontmostPID {
            if let frontAppIndex = sortedAppKeys.firstIndex(where: { appGroups[$0]?.first?.ownerPID == frontPID }) {
                let frontApp = sortedAppKeys.remove(at: frontAppIndex)
                sortedAppKeys.insert(frontApp, at: 0)
            }
        }
        
        // Each app gets at least 1 slot, remaining slots go to apps with most windows
        var slotsPerApp: [String: Int] = [:]
        
        if appCount >= slotCount {
            debugLog("WindowLayoutManager"," Mode: Apps >= Slots (\(appCount) apps, \(slotCount) slots)")
            for (index, appKey) in sortedAppKeys.enumerated() {
                if index < slotCount {
                    slotsPerApp[appKey] = 1
                } else {
                    slotsPerApp[appKey] = 0 // Will share with another app
                }
            }
        } else {
            debugLog("WindowLayoutManager"," Mode: Apps < Slots (\(appCount) apps, \(slotCount) slots)")
            
            for appKey in sortedAppKeys {
                slotsPerApp[appKey] = 1
            }
            
            var remainingSlots = slotCount - appCount
            var appIndex = 0
            while remainingSlots > 0 {
                let appKey = sortedAppKeys[appIndex % appCount]
                let appWindowCount = appGroups[appKey]?.count ?? 0
                let currentSlots = slotsPerApp[appKey] ?? 1
                
                if appWindowCount > currentSlots {
                    slotsPerApp[appKey] = currentSlots + 1
                    remainingSlots -= 1
                }
                
                appIndex += 1
                // Prevent infinite loop if all apps have enough slots
                if appIndex >= appCount * 10 {
                    for i in 0..<remainingSlots {
                        let key = sortedAppKeys[i % appCount]
                        slotsPerApp[key] = (slotsPerApp[key] ?? 1) + 1
                    }
                    break
                }
            }
        }

        var currentSlotIndex = 0
        
        for appKey in sortedAppKeys {
            guard var appWindows = appGroups[appKey] else { continue }
            let appSlotCount = slotsPerApp[appKey] ?? 1
            
            if appSlotCount == 0 {
                if currentSlotIndex > 0 {
                    slotAssignments[currentSlotIndex - 1].append(contentsOf: appWindows)
                    debugLog("WindowLayoutManager"," ⚠️ App '\(appKey)' has no slot, grouping with previous")
                }
                continue
            }
            
            let windowsPerSlot = appWindows.count / appSlotCount
            let extraWindows = appWindows.count % appSlotCount
            
            for slotOffset in 0..<appSlotCount {
                guard currentSlotIndex < slotCount else { break }
                
                let windowsForThisSlot = windowsPerSlot + (slotOffset < extraWindows ? 1 : 0)
                
                for _ in 0..<windowsForThisSlot {
                    if !appWindows.isEmpty {
                        slotAssignments[currentSlotIndex].append(appWindows.removeFirst())
                    }
                }
                
                let slotWindowCount = slotAssignments[currentSlotIndex].count
                if slotWindowCount > 0 {
                    debugLog("WindowLayoutManager"," Slot \(currentSlotIndex + 1): '\(appKey)' (\(slotWindowCount) windows)")
                }
                
                currentSlotIndex += 1
            }
        }
        
        let totalAssigned = slotAssignments.reduce(0) { $0 + $1.count }
        debugLog("WindowLayoutManager"," END: \(totalAssigned)/\(windows.count) windows assigned")
        
        return slotAssignments
    }
    
}

extension WindowLayoutManager {
    
}

// MARK: - Manual Grouping (GROUP Hotkey)

extension WindowLayoutManager {
    
    struct GroupToggleResult {
        let didPerformAction: Bool
        /// Whether the action was grouping (true) or ungrouping (false)
        let wasGrouping: Bool
        /// Windows that need to be repositioned (slotIndex, window)
        let windowsToReposition: [(Int, WindowInfo)]
        /// The new number of logical windows (for template sizing)
        let logicalWindowCount: Int
    }
    
    /// Toggle grouping of same-app windows for the frontmost window's app.
    /// - If windows are spread across multiple slots → GROUP into current slot
    /// - If windows are already grouped in current slot → UNGROUP into separate slots
    func toggleGroupSameApp(
        frontmostWindowID: CGWindowID,
        forScreenID screenID: String
    ) -> GroupToggleResult? {
        guard var screenState = screenStates[screenID] else {
            logger.warning("toggleGroupSameApp: no state for screen \(screenID)")
            return nil
        }
        
        guard let currentSlotIndex = screenState.slots.firstIndex(where: { slot in
            slot.windows.contains(where: { $0.windowID == frontmostWindowID })
        }) else {
            logger.warning("toggleGroupSameApp: window \(frontmostWindowID) not found in any slot")
            return nil
        }
        
        guard let frontmostWindow = screenState.slots[currentSlotIndex].windows.first(where: { $0.windowID == frontmostWindowID }) else {
            return nil
        }
        
        let appBundleID = frontmostWindow.bundleIdentifier ?? frontmostWindow.ownerName
        
        var sameAppWindows: [WindowInfo] = []
        var sameAppSlotIndices: Set<Int> = []
        
        for (slotIndex, slot) in screenState.slots.enumerated() {
            for window in slot.windows {
                let windowAppID = window.bundleIdentifier ?? window.ownerName
                if windowAppID == appBundleID {
                    sameAppWindows.append(window)
                    sameAppSlotIndices.insert(slotIndex)
                }
            }
        }
        
        logger.debug("toggleGroupSameApp: app=\(appBundleID), windows=\(sameAppWindows.count), slots=\(sameAppSlotIndices)")
        
        guard sameAppWindows.count > 1 else {
            logger.debug("toggleGroupSameApp: only 1 window of this app, nothing to do")
            return GroupToggleResult(
                didPerformAction: false,
                wasGrouping: false,
                windowsToReposition: [],
                logicalWindowCount: countLogicalWindows(in: screenState)
            )
        }
        
        let alreadyGrouped = sameAppSlotIndices.count == 1
        
        if alreadyGrouped {
            return ungroupWindows(
                windows: sameAppWindows,
                fromSlotIndex: currentSlotIndex,
                screenState: &screenState,
                screenID: screenID
            )
        } else {
            return groupWindows(
                windows: sameAppWindows,
                toSlotIndex: currentSlotIndex,
                screenState: &screenState,
                screenID: screenID
            )
        }
    }
    
    private func groupWindows(
        windows: [WindowInfo],
        toSlotIndex targetSlotIndex: Int,
        screenState: inout LayoutState,
        screenID: String
    ) -> GroupToggleResult {
        var windowsToReposition: [(Int, WindowInfo)] = []
        var slotsFreed: Set<Int> = []
        
        for (slotIndex, slot) in screenState.slots.enumerated() {
            guard slotIndex != targetSlotIndex else { continue }
            
            let windowsToMove = slot.windows.filter { slotWindow in
                windows.contains(where: { $0.windowID == slotWindow.windowID })
            }
            
            if !windowsToMove.isEmpty {
                screenState.slots[slotIndex].windows.removeAll { slotWindow in
                    windows.contains(where: { $0.windowID == slotWindow.windowID })
                }
                
                for window in windowsToMove {
                    slotsBeforeGrouping[screenID, default: [:]][window.windowID] = slotIndex
                    if !screenState.slots[targetSlotIndex].windows.contains(where: { $0.windowID == window.windowID }) {
                        screenState.slots[targetSlotIndex].windows.append(window)
                        windowsToReposition.append((targetSlotIndex, window))
                    }
                }
                
                if screenState.slots[slotIndex].isEmpty {
                    slotsFreed.insert(slotIndex)
                }
            }
        }
        
        logger.debug("groupWindows: grouped \(windows.count) windows into slot \(targetSlotIndex), freed \(slotsFreed.count) slots")
        
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        
        return GroupToggleResult(
            didPerformAction: true,
            wasGrouping: true,
            windowsToReposition: windowsToReposition,
            logicalWindowCount: countLogicalWindows(in: screenState)
        )
    }
    
    private func ungroupWindows(
        windows: [WindowInfo],
        fromSlotIndex sourceSlotIndex: Int,
        screenState: inout LayoutState,
        screenID: String
    ) -> GroupToggleResult {
        var windowsToReposition: [(Int, WindowInfo)] = []

        // Windows grouped by the shortcut go back to the slots they came from
        var origins = slotsBeforeGrouping[screenID] ?? [:]
        for window in windows {
            guard let origin = origins.removeValue(forKey: window.windowID),
                  origin != sourceSlotIndex, origin < screenState.slots.count else { continue }
            screenState.slots[sourceSlotIndex].windows.removeAll { $0.windowID == window.windowID }
            screenState.slots[origin].windows.append(window)
            windowsToReposition.append((origin, window))
        }
        slotsBeforeGrouping[screenID] = origins
        if !windowsToReposition.isEmpty {
            logger.debug("ungroupWindows: returned \(windowsToReposition.count) windows to the slots they came from")
            screenStates[screenID] = screenState
            if screenID == activeScreenID {
                state = screenState
            }
            return GroupToggleResult(
                didPerformAction: true,
                wasGrouping: false,
                windowsToReposition: windowsToReposition,
                logicalWindowCount: countLogicalWindows(in: screenState)
            )
        }
        
        var emptySlotIndices: [Int] = []
        for (index, slot) in screenState.slots.enumerated() {
            if slot.isEmpty && index != sourceSlotIndex {
                emptySlotIndices.append(index)
            }
        }
        
        let windowsToMove = Array(windows.dropFirst()) // Keep first window in place
        
        var movedCount = 0
        for (moveIndex, window) in windowsToMove.enumerated() {
            if moveIndex < emptySlotIndices.count {
                let targetSlotIndex = emptySlotIndices[moveIndex]
                
                screenState.slots[sourceSlotIndex].windows.removeAll { $0.windowID == window.windowID }
                
                screenState.slots[targetSlotIndex].windows = [window]
                screenState.slots[targetSlotIndex].originalBundleID = window.bundleIdentifier
                screenState.slots[targetSlotIndex].originalOwnerName = window.ownerName
                
                windowsToReposition.append((targetSlotIndex, window))
                movedCount += 1
            }
        }
        
        logger.debug("ungroupWindows: moved \(movedCount) windows out of slot \(sourceSlotIndex)")
        
        screenStates[screenID] = screenState
        if screenID == activeScreenID {
            state = screenState
        }
        
        return GroupToggleResult(
            didPerformAction: movedCount > 0,
            wasGrouping: false,
            windowsToReposition: windowsToReposition,
            logicalWindowCount: countLogicalWindows(in: screenState)
        )
    }
    
    /// Count logical windows (groups count as 1)
    func countLogicalWindows(in screenState: LayoutState) -> Int {
        var count = 0
        for slot in screenState.slots {
            if !slot.isEmpty {
                count += 1
            }
        }
        return count
    }
    
}
