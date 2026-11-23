//
//  WindowResizeService.swift
//  Rapto
//
//  Service for auto-resizing adjacent slots when one slot is resized.
//  Works with slot-based architecture: resize affects all windows in affected slots.
//  Detects resizes from mouse events; a timer runs only while a resize is in progress.
//

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "WindowResizeService")

@MainActor
class WindowResizeService: ObservableObject {
    
    @Published private(set) var isActive: Bool = false
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let windowManager: WindowManager
    private weak var screenManager: ScreenManager?
    private weak var layoutManager: WindowLayoutManager?
    
    // MARK: - Resize State
    
    private var slotFramesOnMouseDown: [Int: CGRect] = [:]
    
    /// Snapshot of window frame at mouse down (to detect actual resize)
    private var windowFrameOnMouseDown: CGRect?
    
    private var resizingSlotIndex: Int?
    
    private var resizingWindowID: CGWindowID?

    /// That window's AX element, found by its exact frame on mouse down. A later lookup can land on
    /// another window of the app once this one is closed (Finder matches its desktop by empty title).
    private var resizingAXWindow: AXUIElement?
    
    private var resizingScreenID: String?
    
    // MARK: - Event Monitoring
    
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    
    private(set) var resizeInProgress: Bool = false
    
    /// Pointer location at mouse down; nil once the drag is known not to be a resize
    private var mouseDownLocation: CGPoint?
    
    /// Window in front in each slot at mouse down
    private var frontWindows: [Int: WindowInfo] = [:]

    /// Windows of each slot at mouse down, front window first
    private var slotWindows: [Int: [WindowInfo]] = [:]

    /// Frames the slots were given while following the drag
    private var liveFrames: [Int: CGRect] = [:]

    /// Drives the neighbours while a resize is in progress. Mouse events arrive before the app has
    /// resized its window and stop when the pointer stops, which left the neighbours a step behind.
    private var liveFollowTimer: DispatchSourceTimer?

    /// The dragged window's frame the neighbours were last lined up with
    private var lastFollowedFrame: CGRect?

    /// Frames the hidden group windows of each slot were given while following the drag
    private var hiddenFrames: [Int: CGRect] = [:]

    private let mover = WindowMover()

    /// Accessibility elements of the windows moved during this drag
    private var axElements: [CGWindowID: AXUIElement] = [:]

    /// Smallest sizes windows turned out to accept; apps don't tell this in advance
    private var minimumSizes: [CGWindowID: CGSize] = [:]
    
    // MARK: - Configuration
    
    /// Minimum slot size (pixels)
    private let minimumSlotSize: CGFloat = 100
    
    /// Minimum size change to trigger adjacent resize (pixels)
    private let minimumSizeChange: CGFloat = 8

    /// How often the dragged window's frame is checked while neighbours follow it (seconds)
    private let liveFollowInterval: TimeInterval = 1.0 / 120

    /// Hidden group windows are kept this far (pixels) inside a border that moves towards them, so
    /// they are out of the way long before the slot's front window gets there
    private let hiddenWindowMargin: CGFloat = 240

    /// A hidden window closer than this to such a border is pulled in again
    private let hiddenWindowGuard: CGFloat = 60
    
    // MARK: - Callbacks
    
    /// Called when mouse down on a managed window (to disable snap-back early)
    var onManagedWindowMouseDown: (() -> Void)?
    
    /// Called when a resize operation is detected (before adjustments)
    var onResizeStarted: (() -> Void)?

    /// A locked window doesn't resize its neighbouring slots
    var isWindowLocked: ((CGWindowID) -> Bool)?
    
    var onResizeCompleted: ((_ updatedSlotFrames: [Int: CGRect], _ screenID: String) -> Void)?
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, windowManager: WindowManager, screenManager: ScreenManager? = nil) {
        self.accessibilityService = accessibilityService
        self.windowManager = windowManager
        self.screenManager = screenManager
    }
    
    // MARK: - Public Methods
    
    func setLayoutManager(_ manager: WindowLayoutManager) {
        self.layoutManager = manager
    }
    
    func start() {
        guard !isActive else {
            logger.debug("WindowResizeService already active")
            return
        }
        
        debugLog("WindowResizeService"," Started (Option+drag to sync slots)")
        logger.info("Starting WindowResizeService (slot-based)")
        setupEventMonitors()
        isActive = true
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping WindowResizeService")
        removeEventMonitors()
        resetResizeState()
        isActive = false
    }
    
    /// Does nothing: the service reads slots from layoutManager. Kept for existing callers
    func setManagedLayout(windows: [WindowInfo]) {
        logger.debug("setManagedLayout called (ignored in slot-based mode)")
    }
    
    func swapManagedWindows(window1ID: CGWindowID, window2ID: CGWindowID) {
        // Handled by layoutManager
    }
    
    // MARK: - Event Monitoring
    
    private func setupEventMonitors() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard !SpaceBarController.isDrivingMouse else { return }
                self?.captureStateOnMouseDown()
            }
        }
        
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in
                guard !SpaceBarController.isDrivingMouse else { return }
                self?.checkForResizeDuringDrag()
            }
        }
        
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard !SpaceBarController.isDrivingMouse else { return }
                self?.checkForResizeAndAdjust()
            }
        }
        
        logger.debug("Event monitors set up")
    }
    
    private func removeEventMonitors() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }
    
    // MARK: - Resize Detection
    
    private func captureStateOnMouseDown() {
        resetResizeState()
        
        guard let layoutManager = layoutManager,
              let screenManager = screenManager else {
            debugLog("WindowResizeService"," Mouse down - no layout manager")
            return
        }
        
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return
        }
        
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        
        let windows = windowManager.enumerateWindows()
        let frontWindows = windows.filter { $0.ownerPID == frontApp.processIdentifier }

        // Right after a desktop switch the app of the previous desktop is still frontmost, while the
        // pointer is on a window of this one. The edge a resize starts from is just outside the window.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        let pointer = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let underPointer = windows.first { $0.frame.contains(pointer) }
            ?? windows.first { $0.frame.insetBy(dx: -6, dy: -6).contains(pointer) }

        guard let frontWindow = underPointer ?? frontWindows.first else {
            debugLog("WindowResizeService"," Mouse down - no front window")
            return
        }
        if isWindowLocked?(frontWindow.windowID) == true {
            debugLog("WindowResizeService"," Mouse down - '\(frontWindow.title)' is locked")
            return
        }
        
        let windowScreen = screenManager.screen(for: frontWindow)
        let screenID = screenManager.identifier(for: windowScreen)
        
        let screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else {
            debugLog("WindowResizeService"," Mouse down - no active layout on screen \(screenID)")
            return
        }
        
        guard let slotIndex = screenState.slotIndex(for: frontWindow.windowID) else {
            debugLog("WindowResizeService"," Mouse down - not on managed window")
            return
        }
        
        resizingScreenID = screenID
        
        for (index, slot) in screenState.slots.enumerated() {
            slotFramesOnMouseDown[index] = slot.frame
            let slotIDs = Set(slot.windows.map(\.windowID))
            let inFrontOrder = windows.filter { slotIDs.contains($0.windowID) }
            self.frontWindows[index] = inFrontOrder.first
            slotWindows[index] = inFrontOrder
        }
        
        windowFrameOnMouseDown = frontWindow.frame
        
        resizingSlotIndex = slotIndex
        resizingWindowID = frontWindow.windowID
        resizingAXWindow = accessibilityService.getAXWindow(for: frontWindow, overrideFrame: frontWindow.frame)
        resizeInProgress = false
        mouseDownLocation = NSEvent.mouseLocation
        
        debugLog("WindowResizeService"," Captured slot \(slotIndex) '\(frontWindow.title)' frame=\(Int(frontWindow.frame.width))x\(Int(frontWindow.frame.height))")
        onManagedWindowMouseDown?()
    }
    
    private func checkForResizeDuringDrag() {
        guard let windowID = resizingWindowID,
              let originalWindowFrame = windowFrameOnMouseDown else {
            return
        }
        // Once a resize is known, the timer follows it
        if resizeInProgress { return }
        guard let mouseDown = mouseDownLocation, resizingSlotIndex != nil else { return }
        
        // Runs on every drag event, so read only this window
        guard let currentFrame = windowManager.frame(of: windowID) else { return }
        
        // Compare current window frame with WINDOW frame on mouse down
        // This correctly detects resize even after previous resize operations
        func sizeChanged(_ frame: CGRect) -> Bool {
            abs(frame.width - originalWindowFrame.width) > minimumSizeChange
                || abs(frame.height - originalWindowFrame.height) > minimumSizeChange
        }
        var resized = sizeChanged(currentFrame)
        let givingUp = !resized && WindowManager.pointerMovedPastGiveUpDistance(from: mouseDown)
        // On a quick drag the window list still has the old size when the pointer is past the give-up
        // distance; the app already knows the new one
        if givingUp, let element = resizingAXWindow, let axFrame = accessibilityService.getWindowFrame(axWindow: element) {
            resized = sizeChanged(axFrame)
        }

        if resized {
            resizeInProgress = true
            ResizeEchoGate.shared.isClosed = true
            debugLog("WindowResizeService"," Resize detected: \(Int(originalWindowFrame.width))x\(Int(originalWindowFrame.height)) -> \(Int(currentFrame.width))x\(Int(currentFrame.height))")
            onResizeStarted?()
            followResizeLive(windowID: windowID)
            startLiveFollowTimer()
        } else if givingUp {
            // Not a resize (moving the window or selecting text); mouse up still checks
            mouseDownLocation = nil
        }
    }
    
    private func startLiveFollowTimer() {
        liveFollowTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + liveFollowInterval, repeating: liveFollowInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // After the button is released the mouse-up handler places everything
                guard let self, self.resizeInProgress, let windowID = self.resizingWindowID,
                      NSEvent.pressedMouseButtons & 1 == 1 else { return }
                self.followResizeLive(windowID: windowID)
            }
        }
        timer.resume()
        liveFollowTimer = timer
    }

    private func checkForResizeAndAdjust() {
        // The final frames are placed below; a tick in between would race with them
        liveFollowTimer?.cancel()
        liveFollowTimer = nil

        guard let slotIndex = resizingSlotIndex,
              let originalSlotFrame = slotFramesOnMouseDown[slotIndex],
              let originalWindowFrame = windowFrameOnMouseDown,
              let windowID = resizingWindowID else {
            debugLog("WindowResizeService"," Mouse up - no tracked resize (slot=\(resizingSlotIndex as Any), frames=\(slotFramesOnMouseDown.count))")
            resetResizeState()
            return
        }
        
        let windows = windowManager.enumerateWindows()
        guard let currentWindow = windows.first(where: { $0.windowID == windowID }) else {
            debugLog("WindowResizeService"," Mouse up - window not found")
            resetResizeState()
            return
        }
        
        let newSlotFrame: CGRect
        if let element = resizingAXWindow {
            // The element stops answering once the window is closed, e.g. by its close button
            guard let frame = accessibilityService.getWindowFrame(axWindow: element) else {
                debugLog("WindowResizeService"," Mouse up - window closed")
                resetResizeState()
                return
            }
            newSlotFrame = frame
        } else {
            newSlotFrame = accessibilityService.getWindowFrame(currentWindow) ?? currentWindow.frame
        }
        
        // An element matched to the wrong window (Firefox's 16x16 tab drag image after a tab was torn off)
        // reports a size the window doesn't have and would squeeze every slot
        if abs(newSlotFrame.width - currentWindow.frame.width) > 100 || abs(newSlotFrame.height - currentWindow.frame.height) > 100 {
            debugLog("WindowResizeService", "Mouse up - AX frame \(newSlotFrame) doesn't match window \(windowID) at \(currentWindow.frame), ignored")
            accessibilityService.clearAXCache(for: windowID)
            placeSlotWindows(slotFramesOnMouseDown.filter { liveFrames[$0.key] != nil }, except: windowID)
            resetResizeState()
            return
        }

        // No window of a slot reaches past the screen's working area, over the menu bar or the Dock
        if let screenManager, let screenID = resizingScreenID, let screen = screenManager.screen(for: screenID) {
            let workArea = screenManager.convertToCGCoordinates(frame: screenManager.visibleFrame(for: screen), for: screen)
            if !workArea.insetBy(dx: -20, dy: -20).contains(newSlotFrame) {
                debugLog("WindowResizeService"," Mouse up - frame \(newSlotFrame) is outside the screen's working area, ignored")
                placeSlotWindows(slotFramesOnMouseDown.filter { liveFrames[$0.key] != nil }, except: windowID)
                resetResizeState()
                return
            }
        }
        
        // Compare with WINDOW frame on mouse down (not slot frame) to detect actual resize
        let widthChange = abs(newSlotFrame.width - originalWindowFrame.width)
        let heightChange = abs(newSlotFrame.height - originalWindowFrame.height)
        let positionChange = hypot(newSlotFrame.origin.x - originalWindowFrame.origin.x,
                                   newSlotFrame.origin.y - originalWindowFrame.origin.y)
        
        let isResize = (widthChange > minimumSizeChange || heightChange > minimumSizeChange)
        let isPureMove = widthChange < minimumSizeChange && heightChange < minimumSizeChange && positionChange > 20
        
        debugLog("WindowResizeService"," Mouse up - slot \(slotIndex): resize=\(isResize), move=\(isPureMove), dW=\(Int(widthChange)), dH=\(Int(heightChange))")
        
        if isResize && !isPureMove {
            logger.info("Slot resize detected for slot \(slotIndex): \(Int(originalSlotFrame.width))x\(Int(originalSlotFrame.height)) -> \(Int(newSlotFrame.width))x\(Int(newSlotFrame.height))")
            
            if !resizeInProgress {
                onResizeStarted?()
            }
            
            // Apply immediately on mouse up - no debounce needed since resize is complete
            // Pass slot frames (original and new) for proper adjacent slot calculation
            applyResizeAdjustment(
                resizedSlotIndex: slotIndex,
                originalSlotFrame: originalSlotFrame,
                newSlotFrame: newSlotFrame,
                windowID: windowID,
                savedSlotSnapshots: slotFramesOnMouseDown
            )
        } else {
            // Dragged back to where it was: slots that followed go back too
            placeSlotWindows(slotFramesOnMouseDown.filter { liveFrames[$0.key] != nil }, except: windowID)
        }
        
        resetResizeState()
    }
    
    // MARK: - Slot-Based Adjacent Adjustment

    /// A border between slots that moves with the resized window. Slots on its near side end at
    /// `position`, slots on its far side start `gap` after it.
    private struct Divider {
        let isVertical: Bool
        var position: CGFloat
        /// The space the border had before the drag; layouts can have their own on top of the gap setting
        let gap: CGFloat
        let nearSlots: [Int]
        let farSlots: [Int]
    }

    /// The widest space between two slots still taken as one border
    private let maximumBorderGap: CGFloat = 60

    /// Borders of the resized slot that moved and have slots on both sides.
    /// Every slot on the border moves with it, so the grid stays lined up.
    private func movedDividers(originalSlotFrame original: CGRect, newSlotFrame new: CGRect, slotFrames: [Int: CGRect]) -> [Divider] {
        func minEdge(_ frame: CGRect, _ isVertical: Bool) -> CGFloat { isVertical ? frame.minX : frame.minY }
        func maxEdge(_ frame: CGRect, _ isVertical: Bool) -> CGFloat { isVertical ? frame.maxX : frame.maxY }

        /// The resized slot's edge moved from `from` to `to`; `resizedIsNear` when it's the slot's right (or bottom) edge
        func divider(isVertical: Bool, from: CGFloat, to: CGFloat, resizedIsNear: Bool) -> Divider? {
            // Slots on one border can drift apart (a layout rebuilt for one slot only); taking them all
            // as one border moves them together, which lines the border up again
            let sameSide = slotFrames.filter {
                abs((resizedIsNear ? maxEdge($0.value, isVertical) : minEdge($0.value, isVertical)) - from) < maximumBorderGap
            }
            func space(_ frame: CGRect) -> CGFloat {
                resizedIsNear ? minEdge(frame, isVertical) - from : from - maxEdge(frame, isVertical)
            }
            let otherSide = slotFrames.filter {
                space($0.value) > -maximumBorderGap && space($0.value) < maximumBorderGap
            }
            guard !sameSide.isEmpty, !otherSide.isEmpty else { return nil }
            let gap = otherSide.values.map(space).filter { $0 >= 0 }.min() ?? 0
            let near = resizedIsNear ? sameSide : otherSide
            let far = resizedIsNear ? otherSide : sameSide
            var result = Divider(
                isVertical: isVertical,
                position: resizedIsNear ? to : to - gap,
                gap: gap,
                nearSlots: Array(near.keys),
                farSlots: Array(far.keys)
            )
            for (index, frame) in near {
                result.position = max(result.position, minEdge(frame, isVertical) + minimumLength(ofSlot: index, isVertical: isVertical))
            }
            for (index, frame) in far {
                result.position = min(result.position, maxEdge(frame, isVertical) - gap - minimumLength(ofSlot: index, isVertical: isVertical))
            }
            return result
        }

        var dividers: [Divider?] = []
        if abs(new.maxX - original.maxX) > minimumSizeChange {
            dividers.append(divider(isVertical: true, from: original.maxX, to: new.maxX, resizedIsNear: true))
        }
        if abs(new.minX - original.minX) > minimumSizeChange {
            dividers.append(divider(isVertical: true, from: original.minX, to: new.minX, resizedIsNear: false))
        }
        if abs(new.maxY - original.maxY) > minimumSizeChange {
            dividers.append(divider(isVertical: false, from: original.maxY, to: new.maxY, resizedIsNear: true))
        }
        if abs(new.minY - original.minY) > minimumSizeChange {
            dividers.append(divider(isVertical: false, from: original.minY, to: new.minY, resizedIsNear: false))
        }
        return dividers.compactMap { $0 }
    }

    /// The smallest width (or height) a slot can get: what the biggest of its windows allows, as far as we've seen
    private func minimumLength(ofSlot index: Int, isVertical: Bool) -> CGFloat {
        let windowMinimums = (slotWindows[index] ?? []).compactMap { minimumSizes[$0.windowID] }
            .map { isVertical ? $0.width : $0.height }
        return max(minimumSlotSize, windowMinimums.max() ?? 0)
    }

    /// Where the slots go once the dividers moved: the resized slot and every slot that changed
    private func targetFrames(dividers: [Divider], resizedSlotIndex: Int, newSlotFrame: CGRect, slotFrames: [Int: CGRect]) -> [Int: CGRect] {
        var frames = slotFrames
        frames[resizedSlotIndex] = newSlotFrame
        for divider in dividers {
            for index in divider.nearSlots {
                guard var frame = frames[index] else { continue }
                if divider.isVertical {
                    frame.size.width = divider.position - frame.minX
                } else {
                    frame.size.height = divider.position - frame.minY
                }
                frames[index] = frame
            }
            for index in divider.farSlots {
                guard var frame = frames[index] else { continue }
                let start = divider.position + divider.gap
                if divider.isVertical {
                    frame.size.width = frame.maxX - start
                    frame.origin.x = start
                } else {
                    frame.size.height = frame.maxY - start
                    frame.origin.y = start
                }
                frames[index] = frame
            }
        }
        return frames.filter { index, frame in index == resizedSlotIndex || frame != slotFrames[index] }
    }

    /// Moves the front windows of neighbouring slots while the user drags
    private func followResizeLive(windowID: CGWindowID) {
        guard let slotIndex = resizingSlotIndex,
              let original = slotFramesOnMouseDown[slotIndex],
              let current = windowManager.frame(of: windowID) else { return }

        guard current != lastFollowedFrame else { return }
        lastFollowedFrame = current
        let dividers = movedDividers(originalSlotFrame: original, newSlotFrame: current, slotFrames: slotFramesOnMouseDown)
        let targets = targetFrames(dividers: dividers, resizedSlotIndex: slotIndex, newSlotFrame: current, slotFrames: slotFramesOnMouseDown)
        // Slots that followed earlier but no longer move go back to where they were
        for index in Set(targets.keys).union(liveFrames.keys) {
            guard let frame = targets[index] ?? slotFramesOnMouseDown[index] else { continue }
            let previous = liveFrames[index] ?? slotFramesOnMouseDown[index]
            guard previous != frame else { continue }
            liveFrames[index] = frame
            keepHiddenWindowsInside(slot: index, frame: frame, except: windowID)
            // Only the window the user sees follows the border exactly
            if let front = slotWindows[index]?.first, front.windowID != windowID {
                move(front, to: frame, from: previous)
            }
        }
        // The slots take this step together
        mover.flush()
    }

    /// Hidden group windows of a slot that gets smaller would show next to its front window: each app
    /// resizes at its own pace, and a hidden window slower than the front one is seen for a moment.
    /// Nobody sees their size, so they are shrunk well ahead of the border and then left alone until
    /// it gets close again. On mouse up they get the slot's frame.
    private func keepHiddenWindowsInside(slot index: Int, frame: CGRect, except skippedID: CGWindowID) {
        guard let windows = slotWindows[index], windows.count > 1,
              let start = slotFramesOnMouseDown[index] else { return }
        let hidden = hiddenFrames[index] ?? start
        let marginX = min(hiddenWindowMargin, frame.width / 4)
        let marginY = min(hiddenWindowMargin, frame.height / 4)
        var minX = hidden.minX, maxX = hidden.maxX, minY = hidden.minY, maxY = hidden.maxY

        /// `space` is how far the hidden windows are inside the border
        func needsPull(space: CGFloat, borderMovedIn: Bool) -> Bool {
            space < 0 || (borderMovedIn && space < hiddenWindowGuard)
        }
        if needsPull(space: frame.maxX - maxX, borderMovedIn: frame.maxX < start.maxX) { maxX = frame.maxX - marginX }
        if needsPull(space: minX - frame.minX, borderMovedIn: frame.minX > start.minX) { minX = frame.minX + marginX }
        if needsPull(space: frame.maxY - maxY, borderMovedIn: frame.maxY < start.maxY) { maxY = frame.maxY - marginY }
        if needsPull(space: minY - frame.minY, borderMovedIn: frame.minY > start.minY) { minY = frame.minY + marginY }

        let pulled = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard pulled != hidden, pulled.width > 0, pulled.height > 0 else { return }
        hiddenFrames[index] = pulled
        for window in windows.dropFirst() where window.windowID != skippedID {
            move(window, to: pulled, from: hidden, first: true)
        }
    }

    /// `from` is the frame the window is taken to have now; without it both position and size are set
    /// The move starts with the next `mover.flush()`. `first` puts it before the app's other windows.
    private func move(_ window: WindowInfo, to frame: CGRect, from previous: CGRect? = nil, first: Bool = false) {
        guard let element = axElements[window.windowID] ?? accessibilityService.getAXWindow(for: window) else { return }
        axElements[window.windowID] = element
        mover.move(element, windowID: window.windowID, app: window.ownerPID, to: frame, from: previous, first: first)
    }

    /// Moves every window of the given slots, hidden group windows too
    private func placeSlotWindows(_ frames: [Int: CGRect], except skippedID: CGWindowID, visibleWindowIDs: Set<CGWindowID>? = nil) {
        for (index, frame) in frames {
            guard let windows = slotWindows[index] else { continue }
            for window in windows where window.windowID != skippedID && (visibleWindowIDs?.contains(window.windowID) ?? true) {
                move(window, to: frame)
            }
        }
        mover.flush()
    }

    /// Apps with a minimum size don't shrink as far as asked. Moves the dividers so every window
    /// of the slots on them fits, hidden group windows too, and remembers those sizes.
    /// Returns whether any divider moved.
    private func fitDividersToWindows(_ dividers: inout [Divider], targets: [Int: CGRect], resizedWindowID: CGWindowID) -> Bool {
        var moved = false

        /// The size the window kept when it was asked to fit `target`, or nil when it fits
        func refusedSize(_ window: WindowInfo, target: CGRect) -> CGSize? {
            guard window.windowID != resizedWindowID,
                  let actual = accessibilityService.getWindowFrame(window),
                  actual.width > target.width + 1 || actual.height > target.height + 1 else { return nil }
            let known = minimumSizes[window.windowID] ?? .zero
            minimumSizes[window.windowID] = CGSize(
                width: actual.width > target.width + 1 ? max(known.width, actual.width) : known.width,
                height: actual.height > target.height + 1 ? max(known.height, actual.height) : known.height
            )
            debugLog("WindowResizeService", " Window \(window.windowID) keeps \(Int(actual.width))x\(Int(actual.height)) instead of \(Int(target.width))x\(Int(target.height))")
            return actual.size
        }

        for i in dividers.indices {
            let isVertical = dividers[i].isVertical
            for index in dividers[i].nearSlots {
                guard let target = targets[index] else { continue }
                for window in slotWindows[index] ?? [] {
                    guard let size = refusedSize(window, target: target) else { continue }
                    let end = isVertical ? target.minX + size.width : target.minY + size.height
                    if end > dividers[i].position + 1 {
                        dividers[i].position = end
                        moved = true
                    }
                }
            }
            for index in dividers[i].farSlots {
                guard let target = targets[index] else { continue }
                for window in slotWindows[index] ?? [] {
                    guard let size = refusedSize(window, target: target) else { continue }
                    let start = isVertical ? target.maxX - size.width : target.maxY - size.height
                    if start - dividers[i].gap < dividers[i].position - 1 {
                        dividers[i].position = start - dividers[i].gap
                        moved = true
                    }
                }
            }
        }
        return moved
    }

    /// Apply resize adjustment using slot frames (not individual window frames)
    private func applyResizeAdjustment(
        resizedSlotIndex: Int,
        originalSlotFrame: CGRect,
        newSlotFrame: CGRect,
        windowID: CGWindowID,
        savedSlotSnapshots: [Int: CGRect]
    ) {
        guard let layoutManager = layoutManager,
              let screenID = resizingScreenID else { return }

        var dividers = movedDividers(originalSlotFrame: originalSlotFrame, newSlotFrame: newSlotFrame, slotFrames: savedSlotSnapshots)
        var targets = targetFrames(dividers: dividers, resizedSlotIndex: resizedSlotIndex, newSlotFrame: newSlotFrame, slotFrames: savedSlotSnapshots)
        debugLog("WindowResizeService", " Slot \(resizedSlotIndex) resized: \(dividers.count) borders moved, \(targets.count - 1) neighbouring slots follow")

        let visibleWindowIDs = Set(windowManager.enumerateWindows().map(\.windowID))
        func place() {
            var frames = targets
            frames[resizedSlotIndex] = nil
            // Slots that followed the drag but don't move in the end go back
            for (index, _) in liveFrames where targets[index] == nil {
                frames[index] = savedSlotSnapshots[index]
            }
            placeSlotWindows(frames, except: windowID, visibleWindowIDs: visibleWindowIDs)
            // The resized slot's other windows, and the dragged window when its border was held back
            if let resizedFrame = targets[resizedSlotIndex] {
                placeSlotWindows([resizedSlotIndex: resizedFrame], except: resizedFrame == newSlotFrame ? windowID : 0, visibleWindowIDs: visibleWindowIDs)
            }
            mover.waitUntilDone()
        }
        place()
        // Some apps finish resizing a moment after they answer
        usleep(50_000)
        if fitDividersToWindows(&dividers, targets: targets, resizedWindowID: windowID) {
            targets = targetFrames(dividers: dividers, resizedSlotIndex: resizedSlotIndex, newSlotFrame: newSlotFrame, slotFrames: savedSlotSnapshots)
            debugLog("WindowResizeService", " A window can't get that small, moved the border to fit it")
            place()
        }

        for (index, frame) in targets {
            layoutManager.updateSlotFrame(index, frame: frame, forScreenID: screenID)
            debugLog("WindowResizeService", " Updated slot \(index): pos=(\(Int(frame.origin.x)),\(Int(frame.origin.y))) size=\(Int(frame.width))x\(Int(frame.height))")
        }

        // Mark layout as manually modified to preserve on Space return
        layoutManager.markAsManuallyModified(forScreenID: screenID)

        onResizeCompleted?(targets, screenID)

        logger.info("Slot-based resize adjustment completed, updated \(targets.count) slots, marked as manually modified")
    }

    // MARK: - State Reset
    
    private func resetResizeState() {
        mouseDownLocation = nil
        slotFramesOnMouseDown.removeAll()
        windowFrameOnMouseDown = nil
        resizingSlotIndex = nil
        resizingWindowID = nil
        resizingAXWindow = nil
        resizingScreenID = nil
        resizeInProgress = false
        liveFollowTimer?.cancel()
        liveFollowTimer = nil
        lastFollowedFrame = nil
        frontWindows.removeAll()
        slotWindows.removeAll()
        axElements.removeAll()
        liveFrames.removeAll()
        hiddenFrames.removeAll()
        mover.finish()
        ResizeEchoGate.shared.isClosed = false
    }
}

/// Moves windows off the main thread with one queue per app, so a hung app doesn't hold up the others.
///
/// Windows move in rounds: a round gives every window its latest frame and the next one starts when
/// all apps have answered. Left to themselves a quick app takes sixty steps a second and a slow one
/// ten, and two slots on the same border visibly resize at different speeds; in rounds they take the
/// same steps. An app that doesn't answer in time is left out until it does.
private final class WindowMover: @unchecked Sendable {
    private struct Job {
        let element: AXUIElement
        let windowID: CGWindowID
        let app: pid_t
        let frame: CGRect
        /// The frame the window is taken to have; nil sets both position and size
        let from: CGRect?
        let first: Bool
    }

    /// Guards everything below; signalled when an app is done with its windows
    private let state = NSCondition()
    /// The latest frame asked for each window, until a round takes it
    private var waiting: [CGWindowID: Job] = [:]
    private var queues: [pid_t: DispatchQueue] = [:]
    /// Apps still moving their windows
    private var busyApps: Set<pid_t> = []
    /// Apps the running round waits for
    private var roundApps: Set<pid_t> = []
    private var roundRunning = false
    private var round = 0
    /// Frames the windows were last given, to tell what the next frame changes
    private var applied: [CGWindowID: CGRect] = [:]
    /// Goes up with every `finish`, so a move still queued from the drag before doesn't leave its frame in `applied`
    private var generation = 0
    /// Apps asked about AXEnhancedUserInterface since the last `finish`
    private var preparedApps: Set<pid_t> = []
    /// Apps it was turned off for
    private var enhancedApps: Set<pid_t> = []

    private let rounds = DispatchQueue(label: "app.rapto.resize.rounds", qos: .userInteractive)

    /// How long a round waits for a slow app before the others go on without it (seconds)
    private let roundTimeout: TimeInterval = 0.08

    private static let enhancedAttribute = "AXEnhancedUserInterface" as CFString

    /// Asks for a window's frame; nothing moves until `flush`
    func move(_ element: AXUIElement, windowID: CGWindowID, app pid: pid_t, to frame: CGRect, from: CGRect? = nil, first: Bool = false) {
        state.lock()
        waiting[windowID] = Job(element: element, windowID: windowID, app: pid, frame: frame, from: from, first: first)
        state.unlock()
    }

    /// Starts moving the windows asked for, unless a round is running; then they go with the next one
    func flush() {
        state.lock()
        startRound()
        state.unlock()
    }

    /// Call with `state` locked
    private func startRound() {
        guard !roundRunning else { return }
        let jobs = waiting.values.filter { !busyApps.contains($0.app) }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            waiting[job.windowID] = nil
        }
        roundRunning = true
        round += 1
        let round = round
        let generation = generation
        let byApp = Dictionary(grouping: jobs, by: \.app)
        roundApps = Set(byApp.keys)
        busyApps.formUnion(byApp.keys)

        for (pid, appJobs) in byApp {
            let queue = queues[pid] ?? DispatchQueue(label: "app.rapto.resize.\(pid)", qos: .userInteractive)
            queues[pid] = queue
            let prepare = preparedApps.insert(pid).inserted
            queue.async { [self] in
                if prepare {
                    turnOffEnhancedUserInterface(of: pid)
                }
                for job in appJobs.sorted(by: { $0.first && !$1.first }) {
                    apply(job, generation: generation)
                }
                state.lock()
                busyApps.remove(pid)
                roundApps.remove(pid)
                if roundRunning, self.round == round, roundApps.isEmpty {
                    roundRunning = false
                }
                startRound()
                state.broadcast()
                state.unlock()
            }
        }
        rounds.asyncAfter(deadline: .now() + roundTimeout) { [self] in
            state.lock()
            if roundRunning, self.round == round {
                roundRunning = false
                startRound()
            }
            state.unlock()
        }
    }

    /// While it is on (turned on by assistive apps), the app animates every frame change and its
    /// windows trail behind the drag
    private func turnOffEnhancedUserInterface(of pid: pid_t) {
        guard AppResponsiveness.isResponding(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, Self.enhancedAttribute, &value) == .success,
              (value as? Bool) == true else { return }
        AXUIElementSetAttributeValue(app, Self.enhancedAttribute, kCFBooleanFalse)
        state.lock()
        enhancedApps.insert(pid)
        state.unlock()
    }

    private func apply(_ job: Job, generation: Int) {
        state.lock()
        let known = job.from == nil ? nil : (applied[job.windowID] ?? job.from)
        state.unlock()

        var origin = job.frame.origin
        var size = job.frame.size
        func setPosition() {
            guard known?.origin != origin, let value = AXValueCreate(.cgPoint, &origin) else { return }
            AXUIElementSetAttributeValue(job.element, kAXPositionAttribute as CFString, value)
        }
        func setSize() {
            guard known?.size != size, let value = AXValueCreate(.cgSize, &size) else { return }
            AXUIElementSetAttributeValue(job.element, kAXSizeAttribute as CFString, value)
        }
        // The step in between is on screen for a moment. A window that gets smaller shrinks first, so
        // it never reaches over the border; one that grows moves first and never leaves its slot.
        if let known, size.width < known.width || size.height < known.height {
            setSize()
            setPosition()
        } else {
            setPosition()
            setSize()
        }

        state.lock()
        if generation == self.generation {
            applied[job.windowID] = job.frame
        }
        state.unlock()
    }

    /// Ends a drag: turns AXEnhancedUserInterface back on once the moves still asked for are done
    func finish() {
        state.lock()
        generation += 1
        applied.removeAll()
        let apps = preparedApps
        preparedApps.removeAll()
        state.unlock()
        guard !apps.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            waitUntilDone()
            state.lock()
            let enhanced = enhancedApps.intersection(apps)
            enhancedApps.subtract(apps)
            state.unlock()
            for pid in enhanced {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), Self.enhancedAttribute, kCFBooleanTrue)
            }
        }
    }

    /// Blocks until every window got its latest frame, or an app has not answered for two seconds
    func waitUntilDone() {
        let deadline = Date().addingTimeInterval(2)
        state.lock()
        startRound()
        while !(waiting.isEmpty && busyApps.isEmpty) {
            if !state.wait(until: deadline) { break }
        }
        state.unlock()
    }
}

/// Closed while neighbours follow a resize. Every window Rapto moves answers with a moved and a resized
/// notification, some ninety a second; the AX observer drops them before they reach the main actor.
final class ResizeEchoGate: @unchecked Sendable {
    static let shared = ResizeEchoGate()

    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        get { lock.withLock { closed } }
        set { lock.withLock { closed = newValue } }
    }
}
