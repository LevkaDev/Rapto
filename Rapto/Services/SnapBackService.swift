//
//  SnapBackService.swift
//  Rapto
//
//  Service for snapping windows back to their assigned slots after accidental dragging.
//  Works in both Manual and Auto-tiling modes.
//  Slot assignments and frames are read from WindowLayoutManager, the single source of truth.
//

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "SnapBackService")

@MainActor
class SnapBackService: ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isActive: Bool = false
    
    private var activeScreens: Set<String> = []
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let screenManager: ScreenManager
    private let windowManager: WindowManager
    private weak var layoutManager: WindowLayoutManager?
    
    /// Reference to floating window service to skip floating windows
    weak var floatingWindowService: FloatingWindowService?

    /// The focused window is held in place by focus mode, not snapped into its slot
    weak var focusModeService: FocusModeService?
    
    // MARK: - Event Monitoring
    
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    
    private var windowFramesOnMouseDown: [CGWindowID: CGRect] = [:]
    
    // MARK: - Configuration
    
    /// Threshold (in pixels) for considering a window as "moved"
    private let snapBackThreshold: CGFloat = 50
    
    /// When the last drag ended in a swap. Only that mouse up skips the snap-back
    private var lastSwapDropAt: Date?
    
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
    
    // MARK: - Public Methods
    
    func start() {
        for screen in NSScreen.screens {
            let screenID = screenManager.identifier(for: screen)
            start(forScreenID: screenID)
        }
    }
    
    func start(forScreenID screenID: String) {
        guard !activeScreens.contains(screenID) else { return }
        
        logger.info("Starting SnapBackService for screen \(screenID)")
        activeScreens.insert(screenID)
        
        if !isActive {
            setupMouseMonitor()
            isActive = true
        }
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping SnapBackService for all screens")
        removeMouseMonitor()
        activeScreens.removeAll()
        isActive = false
    }
    
    func stop(forScreenID screenID: String) {
        guard activeScreens.contains(screenID) else { return }
        
        logger.info("Stopping SnapBackService for screen \(screenID)")
        activeScreens.remove(screenID)
        
        if activeScreens.isEmpty {
            stop()
        }
    }
    
    /// Check if snap-back is configured (layout is active in layoutManager) - any screen
    var hasActiveLayout: Bool {
        guard let layoutManager = layoutManager else { return false }
        return layoutManager.screensWithActiveLayouts.count > 0
    }
    
    /// The drag that is ending swaps windows, so its mouse up must not snap them back.
    /// The next drag snaps back as usual, however soon it comes.
    func skipSnapBackForCurrentDrop() {
        lastSwapDropAt = Date()
    }
    
    /// Reapply the current layout (e.g., when gap settings change) - all active screens
    func reapplyLayout(excludingScreenIDs: Set<String> = []) {
        guard let layoutManager = layoutManager else {
            logger.debug("No layoutManager")
            return
        }
        
        let activeScreenIDs = layoutManager.screensWithActiveLayouts.filter { !excludingScreenIDs.contains($0) }
        guard !activeScreenIDs.isEmpty else {
            logger.debug("No active layouts to reapply")
            return
        }
        
        logger.info("Reapplying layouts for \(activeScreenIDs.count) screens")
        
        layoutManager.recalculateAllFrames()

        let currentWindows = windowManager.enumerateWindows()

        for screenID in activeScreenIDs {
            let state = layoutManager.state(forScreenID: screenID)
            
            for slot in state.slots {
                let slotFrame = slot.frame
                
                for slotWindow in slot.windows {
                    guard let window = currentWindows.first(where: { $0.windowID == slotWindow.windowID }) else {
                        continue
                    }
                    
                    logger.debug("Repositioning '\(window.title)' to slot \(slot.index + 1) on screen \(screenID)")
                    // Use atomic method to avoid race condition
                    _ = accessibilityService.setWindowPositionAndSize(window, position: slotFrame.origin, size: slotFrame.size)
                }
            }
        }
    }
    
    /// Puts the windows of a screen's layout into their slot frames as they are now
    func moveWindowsToSlots(forScreenID screenID: String) {
        guard let layoutManager = layoutManager else { return }
        let currentWindows = windowManager.enumerateWindows()
        let refreshedState = layoutManager.state(forScreenID: screenID)
        
        for slot in refreshedState.slots {
            let slotFrame = slot.frame
            
            for slotWindow in slot.windows {
                guard let window = currentWindows.first(where: { $0.windowID == slotWindow.windowID }) else {
                    continue
                }
                
                logger.debug("Repositioning '\(window.title)' to slot \(slot.index + 1)")
                // Use atomic method to avoid race condition
                _ = accessibilityService.setWindowPositionAndSize(window, position: slotFrame.origin, size: slotFrame.size)
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupMouseMonitor() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard !SpaceBarController.isDrivingMouse else { return }
                self?.captureWindowFrames()
            }
        }
        
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            let releasedAt = Date()
            Task { @MainActor in
                guard !SpaceBarController.isDrivingMouse else { return }
                // Minimal delay - resize service runs on same mouse up event
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                self?.snapBackWindows(releasedAt: releasedAt)
            }
        }
        logger.debug("Mouse monitors set up for snap-back")
        debugLog("SnapBackService"," Mouse monitors active")
    }
    
    /// Capture current window frames at mouse down, on every screen with snap-back
    private func captureWindowFrames() {
        windowFramesOnMouseDown.removeAll()
        guard let layoutManager = layoutManager else { return }
        
        let states = layoutManager.screensWithActiveLayouts
            .filter { activeScreens.contains($0) }
            .map { layoutManager.state(forScreenID: $0) }
        guard !states.isEmpty else { return }
        
        windowFramesOnMouseDown = Self.framesOfSlotWindows(in: states, windows: windowManager.enumerateWindows())
        logger.debug("Captured frames of \(self.windowFramesOnMouseDown.count) windows on mouse down")
    }
    
    /// The current frame of every window that stands in a slot of these layouts
    static func framesOfSlotWindows(in states: [LayoutState], windows: [WindowInfo]) -> [CGWindowID: CGRect] {
        let framesByID = Dictionary(windows.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var frames: [CGWindowID: CGRect] = [:]
        for state in states {
            for slot in state.slots {
                for slotWindow in slot.windows {
                    if let frame = framesByID[slotWindow.windowID] {
                        frames[slotWindow.windowID] = frame
                    }
                }
            }
        }
        return frames
    }
    
    private func removeMouseMonitor() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        windowFramesOnMouseDown.removeAll()
        logger.debug("Mouse monitors removed")
    }
    
    private func snapBackWindows(releasedAt: Date) {
        if let swapDrop = lastSwapDropAt, abs(swapDrop.timeIntervalSince(releasedAt)) < 0.25 {
            debugLog("SnapBackService", " Skipped (this drop swapped windows)")
            return
        }
        
        guard let layoutManager = layoutManager else {
            debugLog("SnapBackService"," No layoutManager")
            return
        }
        
        let activeScreenIDs = layoutManager.screensWithActiveLayouts
        guard !activeScreenIDs.isEmpty else {
            debugLog("SnapBackService"," No active layouts")
            return
        }
        
        guard layoutManager.canPerform(operation: .snappingBack) else {
            debugLog("SnapBackService"," Blocked by operation mode: \(layoutManager.operationMode.description)")
            return
        }
        
        layoutManager.setMode(.snappingBack)

        let currentWindows = windowManager.enumerateWindows()

        let sizeChangeThreshold: CGFloat = 5
        let positionChangeThreshold: CGFloat = 10
        
        var crossScreenMoves: [(window: WindowInfo, fromScreenID: String, toScreenID: String)] = []
        var firstSnappedSlot: (frame: CGRect, screenID: String)?
        
        for screenID in activeScreenIDs {
            // Snap-back may be enabled for only some screens
            guard activeScreens.contains(screenID) else { continue }
            
            let state = layoutManager.state(forScreenID: screenID)
            debugLog("SnapBackService"," Checking \(state.slots.count) slots on screen \(screenID)...")
            
            for slot in state.slots {
                guard let primaryWindow = slot.primaryWindow,
                      let window = currentWindows.first(where: { $0.windowID == primaryWindow.windowID }) else {
                    continue
                }
                
                if floatingWindowService?.isFloating(windowID: window.windowID) == true {
                    continue
                }
                // Verify the window is still in this slot with a fresh lookup, so a stale
                // windowID in a slot never snaps a window back to the wrong slot
                let freshSlotIndex = state.slotIndex(for: window.windowID)
                guard freshSlotIndex == slot.index else {
                    debugLog("SnapBackService", "⚠️ Slot mismatch for '\(window.title)': expected slot \(freshSlotIndex ?? -1), got \(slot.index)")
                    continue
                }
                
                guard let originalFrame = windowFramesOnMouseDown[primaryWindow.windowID] else {
                    continue
                }

                let currentFrame = window.frame
                let slotFrame = slot.frame

                let movedSinceMouseDown = hypot(
                    currentFrame.origin.x - originalFrame.origin.x,
                    currentFrame.origin.y - originalFrame.origin.y
                )
                
                if movedSinceMouseDown < positionChangeThreshold {
                    continue
                }

                if focusModeService?.isFocusedWindow(window.windowID) == true {
                    focusModeService?.putBackFocusedWindow(window)
                    continue
                }
                
                // Step 2: Check if window moved to a DIFFERENT screen. Checked before the size:
                // macOS shrinks a window that doesn't fit the other screen
                let currentScreenID = screenManager.identifier(for: screenManager.screen(for: window))

                if currentScreenID != screenID {
                    debugLog("SnapBackService"," '\(window.title)' MOVED to different screen (\(screenID) -> \(currentScreenID))")
                    crossScreenMoves.append((window, screenID, currentScreenID))
                    continue
                }
                
                let widthChanged = abs(currentFrame.width - originalFrame.width) > sizeChangeThreshold
                let heightChanged = abs(currentFrame.height - originalFrame.height) > sizeChangeThreshold
                let sizeChanged = widthChanged || heightChanged
                
                if sizeChanged {
                    debugLog("SnapBackService"," '\(window.title)' was RESIZED - skip")
                    continue
                }
                
                let distanceFromSlot = hypot(
                    currentFrame.origin.x - slotFrame.origin.x,
                    currentFrame.origin.y - slotFrame.origin.y
                )

                let sizeDiffersFromSlot = abs(currentFrame.width - slotFrame.width) > 5 ||
                                          abs(currentFrame.height - slotFrame.height) > 5

                let windowOverlapsSlot = currentFrame.intersects(slotFrame)
                
                // Snap back if:
                // 1. Window is far from slot origin (classic case), OR
                // 2. Window overlaps slot but position/size is off (user tried to return it)
                let needsSnapBack = distanceFromSlot > snapBackThreshold ||
                                    (windowOverlapsSlot && (distanceFromSlot > 5 || sizeDiffersFromSlot))
                
                if needsSnapBack {
                    debugLog("SnapBackService"," Snapping '\(window.title)' back to slot \(slot.index + 1) on screen \(screenID) (dist=\(Int(distanceFromSlot)), overlap=\(windowOverlapsSlot), sizeDiff=\(sizeDiffersFromSlot))")
                    
                    // Restore BOTH position AND size using atomic method to avoid race condition
                    let result = accessibilityService.setWindowPositionAndSize(window, position: slotFrame.origin, size: slotFrame.size)
                    
                    // Update WindowInfo.frame to prevent repeated snap-back attempts
                    if result.position && result.size {
                        layoutManager.updateWindowFrame(window.windowID, newFrame: slotFrame, forScreenID: screenID)
                        if firstSnappedSlot == nil {
                            firstSnappedSlot = (slotFrame, screenID)
                        }
                    }
                }
            }
        }
        
        layoutManager.setMode(.idle)

        if let snapped = firstSnappedSlot {
            onWindowSnappedBack?(snapped.frame, snapped.screenID)
        }
        
        for (window, fromScreenID, toScreenID) in crossScreenMoves {
            if screenTilesItself?(toScreenID) == true {
                layoutManager.removeWindowFromAnyScreen(window.windowID)
                debugLog("SnapBackService"," '\(window.ownerName)' moved from \(fromScreenID) to Auto Tiling screen \(toScreenID), which lays it out")
                continue
            }
            debugLog("SnapBackService"," Transferring '\(window.title)' from \(fromScreenID) to \(toScreenID)")
            if let newSlotIndex = layoutManager.handleWindowMovedToScreen(window, newScreenID: toScreenID) {
                let newState = layoutManager.state(forScreenID: toScreenID)
                if let newSlot = newState.slot(at: newSlotIndex) {
                    debugLog("SnapBackService"," Positioning '\(window.title)' in slot \(newSlotIndex + 1) on screen \(toScreenID), frame=\(newSlot.frame)")
                    // Use atomic method to avoid race condition
                    let result = accessibilityService.setWindowPositionAndSize(window, position: newSlot.frame.origin, size: newSlot.frame.size)
                    if result.position && result.size {
                        layoutManager.updateWindowFrame(window.windowID, newFrame: newSlot.frame, forScreenID: toScreenID)
                    }
                } else {
                    debugLog("SnapBackService"," ERROR: newSlot is nil for index \(newSlotIndex)")
                }
            } else {
                debugLog("SnapBackService"," Window '\(window.title)' removed from layout (target screen has no layout or transfer failed)")
            }
        }
        
        if !crossScreenMoves.isEmpty {
            onCrossScreenMoveWithScreenInfo?(crossScreenMoves)
            // Also call legacy callback for backward compatibility
            onCrossScreenMove?(crossScreenMoves.map { $0.window })
        }
    }
    
    // MARK: - Callbacks
    
    /// Auto Tiling screens place windows that arrive there themselves, one per slot
    var screenTilesItself: ((String) -> Bool)?
    
    /// Called when windows are moved between screens (for UI update) - legacy
    var onCrossScreenMove: (([WindowInfo]) -> Void)?
    
    var onCrossScreenMoveWithScreenInfo: (([(window: WindowInfo, fromScreenID: String, toScreenID: String)]) -> Void)?

    /// Called after one or more windows were snapped back into their slots (CG slot frame, screenID).
    var onWindowSnappedBack: ((CGRect, String) -> Void)?
}
