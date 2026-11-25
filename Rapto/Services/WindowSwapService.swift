//
//  WindowSwapService.swift
//  Rapto
//
//  Service for swapping window positions when dragging one window onto another.
//  Works in Auto-tiling and Manual modes (not in Drag-snap mode).
//

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "WindowSwapService")

@MainActor
class WindowSwapService: ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isActive: Bool = false
    
    /// When true, mouse events are ignored (e.g., during overlay mode)
    var suppressMouseEvents: Bool = false
    
    /// The window currently under the cursor (potential swap target)
    @Published private(set) var targetWindow: WindowInfo?
    
    @Published private(set) var isSwapPending: Bool = false
    
    @Published private(set) var isMovePending: Bool = false
    
    private var targetEmptySlotIndex: Int?
    
    private var targetEmptySlotFrame: CGRect?
    
    private var targetEmptySlotScreenID: String?
    
    /// Cached AXUIElement for the target window (obtained when target is detected)
    /// Critical for same-app swaps where position-based lookup would fail
    private var targetWindowAXElement: AXUIElement?
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let windowManager: WindowManager
    
    // MARK: - Event Monitors
    
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    
    // MARK: - Drag State
    
    private var draggedWindow: WindowInfo?
    
    /// Cached AXUIElement for the dragged window (obtained at drag start before position changes)
    /// This is critical because position-based matching fails once the window is moved
    private var draggedWindowAXElement: AXUIElement?
    
    private var draggedWindowOriginalFrame: CGRect?
    
    private var targetCandidates: [WindowInfo]?
    
    private var dragStartPosition: CGPoint?
    
    private var isDragging: Bool = false
    
    /// The current drag doesn't move a window, so stop checking until mouse up
    private var isNotWindowDrag = false
    
    // MARK: - Configuration
    
    /// Minimum drag distance before checking for swap
    private let minimumDragDistance: CGFloat = 20
    
    /// Whether Control key must be held for swap to activate
    var requiresModifierKey: Bool = true
    
    var moveRequiresShift: Bool = true

    /// Whether in-action hint labels are drawn inside the preview highlight
    var showsHints: Bool = true

    /// Whether window grouping is enabled (controls the "Groups with …" detail phrase)
    var isGroupingEnabled: Bool = true
    
    /// Callback when a swap is about to be performed (to disable snap-back)
    var onSwapStarting: (() -> Void)?
    
    /// Callback when a swap is performed (window1ID, window2ID)
    var onSwapPerformed: ((CGWindowID, CGWindowID) -> Void)?
    
    /// Callback when a move is performed (movedWindowID, targetSlotWindowID)
    var onMovePerformed: ((CGWindowID, CGWindowID) -> Void)?
    
    /// Callback when a move to empty slot is performed (movedWindowID, targetSlotIndex, screenID)
    var onMoveToEmptySlot: ((CGWindowID, Int, String) -> Void)?

    /// A locked window is neither dragged into another slot nor a drop target
    var isWindowLocked: ((CGWindowID) -> Bool)?

    /// Drops on this window's screen always swap. Auto Tiling keeps one window per slot,
    /// so a move would leave a slot empty. Drops on another screen follow the modifier settings.
    var swapsOnly: ((WindowInfo) -> Bool)?

    /// Windows of another Auto Tiling screen are no target for a move: the dragged window joins that screen.
    /// A swap still swaps with them
    var joinsScreenOf: ((_ dragged: WindowInfo, _ target: WindowInfo) -> Bool)?

    /// Frame of the slot that holds this window, when swaps should land exactly on slots
    var slotFrame: ((CGWindowID) -> CGRect?)?
    private var dragSwapsOnly = false
    
    private weak var layoutManager: WindowLayoutManager?
    private weak var screenManager: ScreenManager?
    
    private var swapPreviewWindow: SwapPreviewWindow?
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, windowManager: WindowManager) {
        self.accessibilityService = accessibilityService
        self.windowManager = windowManager
    }
    
    func setLayoutManager(_ manager: WindowLayoutManager) {
        self.layoutManager = manager
    }
    
    /// Set the screen manager reference (needed for empty slot detection)
    func setScreenManager(_ manager: ScreenManager) {
        self.screenManager = manager
    }
    
    // MARK: - Public Methods
    
    func start() {
        guard !isActive else {
            logger.debug("WindowSwapService already active")
            return
        }
        
        logger.info("Starting WindowSwapService")
        
        setupEventMonitors()
        isActive = true
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping WindowSwapService")
        
        removeEventMonitors()
        hidePreview()
        resetState()
        isActive = false
    }
    
    // MARK: - Event Monitor Setup
    
    private func setupEventMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
        }
        
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
            return event
        }
        
        logger.debug("Event monitors set up")
    }
    
    private func removeEventMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        
        logger.debug("Event monitors removed")
    }
    
    // MARK: - Mouse Event Handling
    
    private func handleMouseEvent(_ event: NSEvent) {
        // Skip event handling when overlay is visible (to prevent accidental window dragging)
        if suppressMouseEvents { return }
        // The Desktops Bar is moving a window with the mouse; this is not the user's drag
        if SpaceBarController.isDrivingMouse { return }
        
        switch event.type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        case .flagsChanged:
            if isDragging {
                checkForSwapTarget(at: NSEvent.mouseLocation)
            }
        default:
            break
        }
    }
    
    private func handleMouseDown(_ event: NSEvent) {
        dragStartPosition = NSEvent.mouseLocation
        isNotWindowDrag = false
        
        identifyDraggedWindow()
        if let dragged = draggedWindow, isWindowLocked?(dragged.windowID) == true {
            debugLog("WindowSwapService", "'\(dragged.title)' is locked, no swap or move")
            draggedWindow = nil
            draggedWindowAXElement = nil
        }
    }
    
    private func handleMouseDragged(_ event: NSEvent) {
        guard let startPos = dragStartPosition,
              let dragged = draggedWindow else { 
            return 
        }
        
        let currentPos = NSEvent.mouseLocation
        let dragDistance = hypot(currentPos.x - startPos.x, currentPos.y - startPos.y)
        
        if dragDistance > minimumDragDistance && !isDragging && !isNotWindowDrag {
            if isWindowBeingDragged() {
                isDragging = true
                draggedWindowOriginalFrame = dragged.frame
                dragSwapsOnly = swapsOnly?(dragged) == true
                debugLog("WindowSwapService", "✅ Window drag detected for swap: '\(dragged.title)', swapsOnly=\(dragSwapsOnly)")
            } else if WindowManager.pointerMovedPastGiveUpDistance(from: startPos) {
                isNotWindowDrag = true
            }
        }
        
        if isDragging {
            checkForSwapTarget(at: currentPos)
        }
    }
    
    private func handleMouseUp(_ event: NSEvent) {
        guard isDragging,
              let dragged = draggedWindow,
              let originalFrame = draggedWindowOriginalFrame else {
            hidePreview()
            resetState()
            return
        }
        
        if isMovePending,
           let emptySlotIndex = targetEmptySlotIndex,
           let emptySlotFrame = targetEmptySlotFrame,
           let screenID = targetEmptySlotScreenID {
            logger.info("Move to empty slot: '\(dragged.title, privacy: .public)' to slot \(emptySlotIndex)")
            performMoveToEmptySlot(dragged: dragged, slotIndex: emptySlotIndex, slotFrame: emptySlotFrame, screenID: screenID)
            if moveRequiresShift && NSEvent.modifierFlags.contains(.shift) {
                HintKeyStore.recordCompletedUse(of: .moveKey)
            }
            hidePreview()
            resetState()
            return
        }
        
        guard let target = targetWindow else {
            hidePreview()
            resetState()
            return
        }
        
        if isMovePending {
            logger.info("Move operation: '\(dragged.title, privacy: .public)' to slot of '\(target.title, privacy: .public)'")
            performMove(dragged: dragged, target: target, draggedOriginalFrame: originalFrame)
            if moveRequiresShift && NSEvent.modifierFlags.contains(.shift) {
                HintKeyStore.recordCompletedUse(of: .moveKey)
            }
        } else if isSwapPending {
            logger.info("Swap operation: '\(dragged.title, privacy: .public)' with '\(target.title, privacy: .public)'")
            performSwap(dragged: dragged, target: target, draggedOriginalFrame: originalFrame)
            let onDragStartScreen = dragStartPosition.map { start in
                NSScreen.screens.first { $0.frame.contains(start) } == NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            } ?? true
            if !(dragSwapsOnly && onDragStartScreen) && requiresModifierKey && NSEvent.modifierFlags.contains(.control) {
                HintKeyStore.recordCompletedUse(of: .swapKey)
            }
        }
        
        hidePreview()
        resetState()
    }
    
    // MARK: - Window Detection
    
    private func identifyDraggedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let mousePos = dragStartPosition else {
            return
        }
        
        let windows = windowManager.enumerateWindows()
        
        // Find the window under the cursor at mouse down position
        // This correctly identifies which window in a group is being dragged
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        
        for window in windows {
            guard window.ownerPID == frontApp.processIdentifier else { continue }
            
            let windowFrameAppKit = CGRect(
                x: window.frame.origin.x,
                y: screenHeight - window.frame.origin.y - window.frame.height,
                width: window.frame.width,
                height: window.frame.height
            )
            
            if windowFrameAppKit.contains(mousePos) {
                draggedWindow = window
                draggedWindowOriginalFrame = window.frame
                // Cache AXUIElement NOW while window is still at original position
                // This prevents position-based matching failures during drag
                draggedWindowAXElement = accessibilityService.getAXWindow(for: window)
                debugLog("WindowSwapService", "Identified dragged window: '\(window.title)' (windowID=\(window.windowID)) at \(mousePos), AXElement cached: \(draggedWindowAXElement != nil)")
                return
            }
        }
        
        draggedWindow = windows.first { $0.ownerPID == frontApp.processIdentifier }
        if let window = draggedWindow {
            draggedWindowOriginalFrame = window.frame
            draggedWindowAXElement = accessibilityService.getAXWindow(for: window)
            debugLog("WindowSwapService", "Fallback: using first window '\(window.title)' (windowID=\(window.windowID)), AXElement cached: \(draggedWindowAXElement != nil)")
        }
    }
    
    private func isWindowBeingDragged() -> Bool {
        guard let originalWindow = draggedWindow else { 
            debugLog("WindowSwapService", "isWindowBeingDragged: no originalWindow")
            return false 
        }
        
        guard let layoutManager = layoutManager else {
            debugLog("WindowSwapService", "isWindowBeingDragged: no layoutManager")
            return false
        }
        
        let isManaged = layoutManager.screenStates.values.contains { screenState in
            screenState.slots.contains { slot in
                slot.windows.contains { $0.windowID == originalWindow.windowID }
            }
        }
        
        guard isManaged else {
            return false
        }
        
        // Now check if the window actually moved (CGWindow position changed)
        // Runs on every drag event until the window moves or the pointer passes the give-up distance
        guard let currentFrame = windowManager.frame(of: originalWindow.windowID) else {
            debugLog("WindowSwapService", "isWindowBeingDragged: window not found")
            return false
        }
        let currentWindow = originalWindow.with(frame: currentFrame)
        
        let positionChanged = currentWindow.frame.origin != originalWindow.frame.origin
        let sizeChanged = currentWindow.frame.size != originalWindow.frame.size

        // If size changed, it's a resize operation, not a drag
        if sizeChanged {
            return false
        }
        
        if positionChanged {
            draggedWindow = currentWindow
            return true
        }
        
        // FALLBACK: Use AX position for faster/more reliable movement detection
        if let axElement = draggedWindowAXElement {
            var positionRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionRef) == .success,
               let posValue = positionRef {
                var axPosition = CGPoint.zero
                if AXValueGetValue(posValue as! AXValue, .cgPoint, &axPosition) {
                    let baseOrigin = draggedWindowOriginalFrame?.origin ?? originalWindow.frame.origin
                    let positionDeltaX = abs(axPosition.x - baseOrigin.x)
                    let positionDeltaY = abs(axPosition.y - baseOrigin.y)
                    let positionThreshold: CGFloat = 5
                    
                    if positionDeltaX > positionThreshold || positionDeltaY > positionThreshold {
                        debugLog("WindowSwapService", "isWindowBeingDragged: AX position changed (\(positionDeltaX), \(positionDeltaY))")
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    // MARK: - Swap Target Detection
    
    private func checkForSwapTarget(at mousePosition: CGPoint) {
        guard let dragged = draggedWindow else {
            targetWindow = nil
            isSwapPending = false
            isMovePending = false
            hidePreview()
            return
        }
        
        let onDragStartScreen = dragStartPosition.map { start in
            NSScreen.screens.first { $0.frame.contains(start) } == NSScreen.screens.first { $0.frame.contains(mousePosition) }
        } ?? true

        // Check if this is actually a resize operation, not a drag
        // If the window size has changed since drag started, cancel the swap/move detection.
        // On another screen macOS itself shrinks a window that doesn't fit, so that is still a drag
        if onDragStartScreen, let originalFrame = draggedWindowOriginalFrame {
            if let currentFrame = windowManager.frame(of: dragged.windowID) {
                let sizeChanged = currentFrame.size != originalFrame.size
                if sizeChanged {
                    debugLog("WindowSwapService", "checkForSwapTarget: size changed (resize detected), cancelling swap/move")
                    targetWindow = nil
                    isSwapPending = false
                    isMovePending = false
                    targetEmptySlotIndex = nil
                    targetEmptySlotFrame = nil
                    targetEmptySlotScreenID = nil
                    hidePreview()
                    isDragging = false
                    return
                }
            }
        }
        
        let controlPressed = NSEvent.modifierFlags.contains(.control)
        let shiftPressed = NSEvent.modifierFlags.contains(.shift)
        
        // At least one of requiresModifierKey or moveRequiresShift is always true (enforced by AppState)
        var swapActive = false
        var moveActive = false
        
        if requiresModifierKey && moveRequiresShift {
            swapActive = controlPressed
            moveActive = shiftPressed && !controlPressed
        } else if requiresModifierKey && !moveRequiresShift {
            swapActive = controlPressed
            moveActive = !controlPressed
        } else if !requiresModifierKey && moveRequiresShift {
            swapActive = !shiftPressed
            moveActive = shiftPressed
        }
        if dragSwapsOnly && moveActive && onDragStartScreen {
            swapActive = true
            moveActive = false
        }

        if !swapActive && !moveActive {
            if targetWindow != nil || targetEmptySlotIndex != nil {
                targetWindow = nil
                targetWindowAXElement = nil
                targetEmptySlotIndex = nil
                targetEmptySlotFrame = nil
                targetEmptySlotScreenID = nil
                isSwapPending = false
                isMovePending = false
                hidePreview()
            }
            return
        }
        
        // Other windows stay put during a drag, so list them once per drag
        let windows = targetCandidates ?? windowManager.enumerateWindows().filter { isWindowLocked?($0.windowID) != true }
        targetCandidates = windows
        
        // Find window under cursor (excluding the dragged window and same-slot windows)
        // Mouse position is in AppKit coordinates (bottom-left origin)
        // Window frames from CGWindowList are in CG coordinates (top-left origin)
        // Use PRIMARY screen height for coordinate conversion (CG coords are relative to primary)
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        
        var foundTarget: WindowInfo? = nil
        
        for window in windows {
            guard window.windowID != dragged.windowID else { continue }
            
            if layoutManager?.areInSameSlot(dragged.windowID, window.windowID) == true {
                continue
            }
            
            let windowFrameAppKit = CGRect(
                x: window.frame.origin.x,
                y: screenHeight - window.frame.origin.y - window.frame.height,
                width: window.frame.width,
                height: window.frame.height
            )
            
            if windowFrameAppKit.contains(mousePosition) {
                if swapActive || joinsScreenOf?(dragged, window) != true {
                    foundTarget = window
                }
                break
            }
        }
        
        let operationChanged = (moveActive && isSwapPending) || (swapActive && isMovePending)
        if foundTarget?.windowID != targetWindow?.windowID || operationChanged {
            targetWindow = foundTarget
            isSwapPending = swapActive && foundTarget != nil
            isMovePending = moveActive && foundTarget != nil
            
            // Cache AXUIElement for target window NOW while it's still at its original position
            // This is essential for same-app swaps (e.g., two Cursor windows) where:
            // 1. _AXWindowID is not available (Electron apps)
            // 2. Window titles may be empty
            // 3. Position-based matching would fail after dragged window moves
            if let target = foundTarget {
                targetWindowAXElement = accessibilityService.getAXWindow(for: target)
                if targetWindowAXElement != nil {
                    debugLog("WindowSwapService", "Cached AXElement for target window '\(target.title)' (windowID=\(target.windowID))")
                } else {
                    debugLog("WindowSwapService", "⚠️ Failed to cache AXElement for target window '\(target.title)'")
                }
            } else {
                targetWindowAXElement = nil
            }
            
            if foundTarget != nil {
                targetEmptySlotIndex = nil
                targetEmptySlotFrame = nil
                targetEmptySlotScreenID = nil
            }
            
            if let target = foundTarget {
                let isSwapOnlyTarget = dragSwapsOnly && onDragStartScreen
                let sameApp = target.ownerPID == dragged.ownerPID ||
                    (target.bundleIdentifier != nil && target.bundleIdentifier == dragged.bundleIdentifier)
                let hint = DragHint.swapOrMove(
                    showsHints: showsHints,
                    target: isSwapOnlyTarget
                        ? .swapOnlyWindow
                        : .window(ownerName: target.ownerName, sameApp: sameApp),
                    requiresControlForSwap: requiresModifierKey,
                    moveRequiresShift: moveRequiresShift,
                    controlPressed: controlPressed,
                    shiftPressed: shiftPressed,
                    isGroupingEnabled: isGroupingEnabled,
                    learnedKeys: HintKeyStore.learnedKeys()
                )
                showPreview(for: target, isMove: moveActive, hint: hint)
            } else {
                hidePreview()
            }
        }
        
        if foundTarget == nil && moveActive {
            checkForEmptySlotTarget(at: mousePosition, dragged: dragged)
        } else if foundTarget != nil || !moveActive {
            if targetEmptySlotIndex != nil {
                targetEmptySlotIndex = nil
                targetEmptySlotFrame = nil
                targetEmptySlotScreenID = nil
                hidePreview()
            }
        }
    }
    
    // MARK: - Empty Slot Detection
    
    private func checkForEmptySlotTarget(at mousePosition: CGPoint, dragged: WindowInfo) {
        guard let layoutManager = layoutManager,
              screenManager != nil else {
            return
        }
        
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mousePosition) }) else {
            return
        }
        
        let screenID = ScreenIdentifier.identifier(for: mouseScreen)
        let screenState = layoutManager.state(forScreenID: screenID)
        
        guard screenState.isActive else {
            if targetEmptySlotIndex != nil {
                targetEmptySlotIndex = nil
                targetEmptySlotFrame = nil
                targetEmptySlotScreenID = nil
                hidePreview()
            }
            return
        }
        
        let draggedSlotIndex = screenState.slotIndex(for: dragged.windowID)
        
        let screenHeight = NSScreen.screens.first?.frame.height ?? mouseScreen.frame.height
        
        var foundEmptySlotIndex: Int? = nil
        var foundEmptySlotFrame: CGRect? = nil
        
        for (index, slot) in screenState.slots.enumerated() {
            guard slot.isEmpty else { continue }
            
            if let draggedSlot = draggedSlotIndex, draggedSlot == index {
                continue
            }
            
            let slotFrameAppKit = CGRect(
                x: slot.frame.origin.x,
                y: screenHeight - slot.frame.origin.y - slot.frame.height,
                width: slot.frame.width,
                height: slot.frame.height
            )
            
            if slotFrameAppKit.contains(mousePosition) {
                foundEmptySlotIndex = index
                foundEmptySlotFrame = slotFrameAppKit
                break
            }
        }
        
        if foundEmptySlotIndex != targetEmptySlotIndex {
            targetEmptySlotIndex = foundEmptySlotIndex
            targetEmptySlotFrame = foundEmptySlotFrame
            targetEmptySlotScreenID = foundEmptySlotIndex != nil ? screenID : nil
            
            if let frame = foundEmptySlotFrame {
                let hint = DragHint.swapOrMove(
                    showsHints: showsHints,
                    target: .emptySlot,
                    requiresControlForSwap: requiresModifierKey,
                    moveRequiresShift: moveRequiresShift,
                    controlPressed: NSEvent.modifierFlags.contains(.control),
                    shiftPressed: NSEvent.modifierFlags.contains(.shift),
                    isGroupingEnabled: isGroupingEnabled,
                    learnedKeys: HintKeyStore.learnedKeys()
                )
                showPreviewForFrame(frame, isMove: true, hint: hint)
                isMovePending = true
                debugLog("WindowSwapService", "Found empty slot \(foundEmptySlotIndex ?? -1) at \(mousePosition)")
            } else {
                hidePreview()
                // Don't set isMovePending to false here - it might be set for a window target
            }
        }
    }
    
    // MARK: - Swap Execution
    
    private func performSwap(dragged: WindowInfo, target: WindowInfo, draggedOriginalFrame: CGRect) {
        logger.info("Swapping '\(dragged.title, privacy: .public)' with '\(target.title, privacy: .public)'")
        
        onSwapStarting?()
        
        let targetFrame = slotFrame?(target.windowID) ?? target.frame
        let draggedOriginalFrame = slotFrame?(dragged.windowID) ?? draggedOriginalFrame
        
        // Use cached AXUIElement for dragged window (obtained at drag start)
        // This prevents position-based matching failures since window has moved during drag
        var draggedSuccess = false
        if let cachedDraggedAX = draggedWindowAXElement {
            debugLog("WindowSwapService", "Using cached AXElement for dragged window")
            draggedSuccess = accessibilityService.setWindowFrame(axWindow: cachedDraggedAX, frame: targetFrame, windowTitle: dragged.title)
        } else {
            debugLog("WindowSwapService", "⚠️ No cached AXElement for dragged, falling back to lookup")
            let result = accessibilityService.setWindowPositionAndSize(dragged, position: targetFrame.origin, size: targetFrame.size)
            draggedSuccess = result.position && result.size
        }
        
        // Use cached AXUIElement for target window (obtained when target was detected)
        // This is essential for same-app swaps where dragged window has moved to target's position
        // and position-based lookup would find the dragged window instead of the target
        var targetSuccess = false
        if let cachedTargetAX = targetWindowAXElement {
            debugLog("WindowSwapService", "Using cached AXElement for target window")
            targetSuccess = accessibilityService.setWindowFrame(axWindow: cachedTargetAX, frame: draggedOriginalFrame, windowTitle: target.title)
        } else {
            debugLog("WindowSwapService", "⚠️ No cached AXElement for target, falling back to lookup")
            let result = accessibilityService.setWindowPositionAndSize(target, position: draggedOriginalFrame.origin, size: draggedOriginalFrame.size)
            targetSuccess = result.position && result.size
        }
        
        if draggedSuccess && targetSuccess {
            logger.info("Successfully swapped windows")
            onSwapPerformed?(dragged.windowID, target.windowID)
        } else if draggedSuccess, !AppResponsiveness.isResponding(target.ownerPID) {
            // The other window belongs to an app that is not answering and cannot be moved now.
            // The swap still counts: the dragged window is in its new slot already, and the
            // other one is put into its slot when its app answers again. Left uncounted, the
            // dragged window would sit in a slot the layout says is someone else's.
            logger.info("Swapped with a window of an app that is not responding; it moves when the app answers")
            debugLog("WindowSwapService", "Swap counted: '\(target.ownerName)' is not responding and moves to its slot when it answers")
            onSwapPerformed?(dragged.windowID, target.windowID)
        } else {
            logger.warning("Swap partially failed: dragged=\(draggedSuccess), target=\(targetSuccess)")
        }
    }
    
    /// Where a window dropped on another window goes, or nil when the drop is not a move.
    /// On a screen that keeps windows in slots it is the target's slot, not the target window's
    /// own frame: a window that does not fit its slot (an app that refuses the size) sits
    /// elsewhere, and the dragged window would follow it out of the layout. A target outside
    /// every slot is no place for a window that has one. Without slots it is the target's frame.
    static func moveTargetFrame(draggedSlot: CGRect?, targetSlot: CGRect?, targetWindowFrame: CGRect) -> CGRect? {
        if let targetSlot { return targetSlot }
        return draggedSlot == nil ? targetWindowFrame : nil
    }

    private func performMove(dragged: WindowInfo, target: WindowInfo, draggedOriginalFrame: CGRect) {
        logger.info("Moving '\(dragged.title, privacy: .public)' to slot of '\(target.title, privacy: .public)'")
        
        guard let targetFrame = Self.moveTargetFrame(
            draggedSlot: slotFrame?(dragged.windowID),
            targetSlot: slotFrame?(target.windowID),
            targetWindowFrame: target.frame
        ) else {
            // Snap-back returns the dragged window to its slot
            debugLog("WindowSwapService", "Move skipped: '\(target.title)' is not in a slot")
            return
        }
        
        onSwapStarting?()
        
        // Use cached AXUIElement for dragged window (obtained at drag start)
        // This prevents position-based matching failures since window has moved during drag
        var success = false
        if let cachedAXElement = draggedWindowAXElement {
            debugLog("WindowSwapService", "Using cached AXElement for move operation")
            success = accessibilityService.setWindowFrame(axWindow: cachedAXElement, frame: targetFrame, windowTitle: dragged.title)
        } else {
            debugLog("WindowSwapService", "No cached AXElement for move, falling back to lookup")
            let result = accessibilityService.setWindowPositionAndSize(dragged, position: targetFrame.origin, size: targetFrame.size)
            success = result.position && result.size
        }
        
        if success {
            logger.info("Successfully moved window to new slot")
            onMovePerformed?(dragged.windowID, target.windowID)
        } else {
            logger.warning("Move failed")
            // Even on failure, try to update slots to avoid indicator desync
            // The window may have been partially moved - check if it's at target position
            if let refreshedWindow = windowManager.refreshWindowInfo(for: dragged.windowID) {
                let tolerance: CGFloat = 50
                let atTargetPosition = abs(refreshedWindow.frame.origin.x - targetFrame.origin.x) < tolerance &&
                                       abs(refreshedWindow.frame.origin.y - targetFrame.origin.y) < tolerance
                if atTargetPosition {
                    debugLog("WindowSwapService", "Window moved but resize may have failed - updating slot tracking")
                    onMovePerformed?(dragged.windowID, target.windowID)
                }
            }
        }
    }
    
    private func performMoveToEmptySlot(dragged: WindowInfo, slotIndex: Int, slotFrame: CGRect, screenID: String) {
        logger.info("Moving '\(dragged.title, privacy: .public)' to empty slot \(slotIndex) on screen \(screenID)")
        
        onSwapStarting?()
        
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgFrame = CGRect(
            x: slotFrame.origin.x,
            y: screenHeight - slotFrame.origin.y - slotFrame.height,
            width: slotFrame.width,
            height: slotFrame.height
        )
        
        var success = false
        if let cachedAXElement = draggedWindowAXElement {
            debugLog("WindowSwapService", "Using cached AXElement for move to empty slot")
            success = accessibilityService.setWindowFrame(axWindow: cachedAXElement, frame: cgFrame, windowTitle: dragged.title)
        } else {
            debugLog("WindowSwapService", "No cached AXElement, falling back to lookup")
            let result = accessibilityService.setWindowPositionAndSize(dragged, position: cgFrame.origin, size: cgFrame.size)
            success = result.position && result.size
        }
        
        if success {
            logger.info("Successfully moved window to empty slot \(slotIndex)")
            onMoveToEmptySlot?(dragged.windowID, slotIndex, screenID)
        } else {
            logger.warning("Move to empty slot failed")
            if let refreshedWindow = windowManager.refreshWindowInfo(for: dragged.windowID) {
                let tolerance: CGFloat = 50
                let atTargetPosition = abs(refreshedWindow.frame.origin.x - cgFrame.origin.x) < tolerance &&
                                       abs(refreshedWindow.frame.origin.y - cgFrame.origin.y) < tolerance
                if atTargetPosition {
                    debugLog("WindowSwapService", "Window moved to empty slot but resize may have failed - updating slot tracking")
                    onMoveToEmptySlot?(dragged.windowID, slotIndex, screenID)
                }
            }
        }
    }
    
    // MARK: - Preview
    
    private func showPreview(for window: WindowInfo, isMove: Bool = false, hint: DragHint? = nil) {
        // Convert to AppKit coordinates for preview
        // Use PRIMARY screen height for coordinate conversion (CG coords are relative to primary)
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let frameAppKit = CGRect(
            x: window.frame.origin.x,
            y: screenHeight - window.frame.origin.y - window.frame.height,
            width: window.frame.width,
            height: window.frame.height
        )
        
        if swapPreviewWindow == nil {
            swapPreviewWindow = SwapPreviewWindow()
        }
        
        swapPreviewWindow?.showPreview(frame: frameAppKit, isMove: isMove, hint: hint)
    }
    
    /// Show preview for a frame (used for empty slots where frame is already in AppKit coordinates)
    private func showPreviewForFrame(_ frame: CGRect, isMove: Bool = false, hint: DragHint? = nil) {
        if swapPreviewWindow == nil {
            swapPreviewWindow = SwapPreviewWindow()
        }
        
        swapPreviewWindow?.showPreview(frame: frame, isMove: isMove, hint: hint)
    }
    
    private func hidePreview() {
        swapPreviewWindow?.hidePreview()
    }
    
    // MARK: - State Reset
    
    private func resetState() {
        isDragging = false
        draggedWindow = nil
        draggedWindowAXElement = nil
        draggedWindowOriginalFrame = nil
        dragStartPosition = nil
        targetWindow = nil
        targetWindowAXElement = nil
        targetEmptySlotIndex = nil
        targetEmptySlotFrame = nil
        targetEmptySlotScreenID = nil
        isSwapPending = false
        isMovePending = false
        targetCandidates = nil
        isNotWindowDrag = false
        dragSwapsOnly = false
    }
}

// MARK: - Swap Preview Window

@MainActor
class SwapPreviewWindow {
    
    private var window: NSWindow?
    private var isVisible: Bool = false
    private var currentIsMove: Bool = false
    
    private let swapPreviewColor = NSColor.systemOrange.withAlphaComponent(0.3)
    private let swapBorderColor = NSColor.systemOrange.withAlphaComponent(0.8)
    
    private let movePreviewColor = NSColor.systemTeal.withAlphaComponent(0.3)
    private let moveBorderColor = NSColor.systemTeal.withAlphaComponent(0.8)
    
    private let borderWidth: CGFloat = 4
    private let cornerRadius: CGFloat = 8
    private let animationDuration: TimeInterval = 0.1
    
    // MARK: - Workaround: a hidden .canJoinAllSpaces window ends up on one desktop
    // Same as DragSnapLayoutPicker: when a temporary space goes away, macOS leaves a hidden all-desktops
    // window on one desktop, and the preview then shows only there. So every show creates a new window
    // and the end of the fade-out drops it.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        
        let contentView = SwapPreviewContentView()
        contentView.previewColor = swapPreviewColor
        contentView.borderColor = swapBorderColor
        contentView.borderWidth = borderWidth
        contentView.cornerRadius = cornerRadius
        
        window.contentView = contentView
        
        return window
    }
    
    func showPreview(frame: CGRect, isMove: Bool = false, hint: DragHint? = nil) {
        if !isVisible {
            // A window that is still fading out finishes on its own
            window = makeWindow()
        }
        guard let window = window,
              let contentView = window.contentView as? SwapPreviewContentView else { return }
        
        var needsRedraw = false

        if isMove != currentIsMove || !isVisible {
            currentIsMove = isMove
            contentView.previewColor = isMove ? movePreviewColor : swapPreviewColor
            contentView.borderColor = isMove ? moveBorderColor : swapBorderColor
            needsRedraw = true
        }

        if contentView.hint != hint {
            contentView.hint = hint
            needsRedraw = true
        }

        if needsRedraw {
            contentView.needsDisplay = true
        }
        
        window.setFrame(frame, display: true)
        
        if !isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                window.animator().alphaValue = 1
            }
            
            isVisible = true
        }
    }
    
    func hidePreview() {
        guard let window = window, isVisible else { return }
        
        isVisible = false
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                if let self, self.window === window {
                    self.window = nil
                }
            }
        }
    }
}

private class SwapPreviewContentView: NSView {
    var previewColor: NSColor = .systemOrange.withAlphaComponent(0.3)
    var borderColor: NSColor = .systemOrange.withAlphaComponent(0.8)
    var borderWidth: CGFloat = 4
    var cornerRadius: CGFloat = 8
    var hint: DragHint?
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        
        previewColor.setFill()
        path.fill()
        
        borderColor.setStroke()
        path.lineWidth = borderWidth
        path.stroke()

        if let hint {
            HintLabel.draw(hint, in: bounds)
        }
    }
}
