//
//  DragSnapService.swift
//  Rapto
//
//  Handles drag-to-snap functionality for window management.
//  Detects when windows are dragged to screen edges and snaps them to predefined zones.
//

import Foundation
import AppKit
import CoreGraphics
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "DragSnapService")

extension Notification.Name {
    static let dragSnapDidSnap = Notification.Name("RaptoDragSnapDidSnap")
    static let dragSnapGroupsDidChange = Notification.Name("RaptoDragSnapGroupsDidChange")
}

/// Windows snapped to the same zone that are still where they were put
struct SnapGroup {
    /// Stable while the zone stays the same
    let key: String
    let screenID: String
    /// Zone frame (CG coordinates)
    let frame: CGRect
    let windowIDs: Set<CGWindowID>
}

enum SnapEdge: Equatable {
    case left
    case right
    case top
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case bottomLeftThird
    case bottomCenterThird
    case bottomRightThird
    /// A zone of the layout chosen for Drag to Snap on the desktop
    case layoutZone(Int)
    /// A zone of a small layout in the picker at the top of the screen
    case pickerZone(layout: Int, zone: Int)
    case none
}

struct SnapZone {
    let edge: SnapEdge
    
    /// The resulting frame as relative coordinates (0.0-1.0)
    let resultFrame: CGRect
    
    var displayName: String {
        switch edge {
        case .left: return "Left Half"
        case .right: return "Right Half"
        case .top: return "Full Screen"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .bottomLeftThird: return "Left Third"
        case .bottomCenterThird: return "Center Third"
        case .bottomRightThird: return "Right Third"
        case .layoutZone(let index): return "Layout Zone \(index + 1)"
        case .pickerZone(let layout, let zone): return "Picker Layout \(layout + 1) Zone \(zone + 1)"
        case .none: return "None"
        }
    }
}

@MainActor
class DragSnapService: ObservableObject {
    
    // MARK: - Properties
    
    @Published private(set) var isActive: Bool = false
    
    /// When true, mouse events are ignored (e.g., during overlay mode)
    var suppressMouseEvents: Bool = false

    /// Whether in-action hint labels are drawn inside snap previews and above the layout picker
    var showsHints: Bool = true
    
    /// Zones (relative frames) of the layout chosen for the desktop on this screen; empty for the standard zones
    var layoutZones: ((NSScreen) -> [CGRect])?
    
    private var activeScreens: Set<String> = []
    
    @Published private(set) var currentSnapZone: SnapZone?
    
    private var currentDragScreenID: String?
    
    @Published private(set) var isDragging: Bool = false
    
    /// The current drag doesn't move a window, so stop checking until mouse up
    private var isNotWindowDrag = false
    
    // MARK: - Dependencies
    
    private let accessibilityService: AccessibilityService
    private let screenManager: ScreenManager
    private let windowManager: WindowManager
    
    // MARK: - Event Monitors
    
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    
    // MARK: - Drag State
    
    /// Window under the cursor when the button went down, with its frame at that moment (CG coordinates)
    private var pressedWindow: (windowID: CGWindowID, pid: pid_t, frame: CGRect)?
    
    /// Size the dragged window had before it was snapped, when the drag gave that size back
    private var sizeBeforeSnap: CGSize?
    
    private var dragStartPosition: CGPoint?
    
    /// A window this service snapped (frames in CG coordinates)
    private struct SnappedWindow {
        /// Frame the window actually took
        var snappedFrame: CGRect
        let sizeBefore: CGSize
        let axWindow: AXUIElement
        let pid: pid_t
        /// Frame of the zone it was snapped to: windows with the same zone form a group
        var zoneFrame: CGRect
        let screenID: String
    }
    
    private var snappedWindows: [CGWindowID: SnappedWindow] = [:]
    
    private var isResizingWindow = false
    
    /// Window frames may differ from the requested ones by a point or two after rounding
    private let frameTolerance: CGFloat = 4
    
    // MARK: - Configuration
    
    /// Distance from a screen edge that triggers a snap. Holding a window right at the edge
    /// makes macOS move it to the next desktop, so the zone has to show up before the edge.
    private let edgeTriggerDistance: CGFloat = 40
    
    /// Length of the corner part of each edge, measured from the corner
    private let cornerLength: CGFloat = 100
    
    /// On the left and right edges the corner parts take this share of the screen height
    private let sideCornerFraction: CGFloat = 0.2
    
    /// Minimum drag distance before checking for snap zones
    private let minimumDragDistance: CGFloat = 10
    
    // MARK: - Predefined Snap Zones
    
    private let snapZones: [SnapZone] = [
        SnapZone(edge: .left, resultFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1.0)),
        SnapZone(edge: .right, resultFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0)),
        SnapZone(edge: .top, resultFrame: CGRect(x: 0, y: 0, width: 1.0, height: 1.0)),
        
        SnapZone(edge: .topLeft, resultFrame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        SnapZone(edge: .topRight, resultFrame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        SnapZone(edge: .bottomLeft, resultFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        SnapZone(edge: .bottomRight, resultFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        
        SnapZone(edge: .bottomLeftThird, resultFrame: CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1.0)),
        SnapZone(edge: .bottomCenterThird, resultFrame: CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1.0)),
        SnapZone(edge: .bottomRightThird, resultFrame: CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1.0)),
    ]
    
    // MARK: - Preview Window
    
    private var previewWindow: DragSnapPreviewWindow?
    
    /// Outlines of all layout zones during a drag
    private var zonesWindow: DragSnapZonesWindow?
    
    private var spaceChangeObserver: NSObjectProtocol?

    /// Small layouts to drop the window on, while no layout is chosen for the desktop
    private lazy var layoutPicker = DragSnapLayoutPicker()
    
    // MARK: - Initialization
    
    init(accessibilityService: AccessibilityService, screenManager: ScreenManager, windowManager: WindowManager) {
        self.accessibilityService = accessibilityService
        self.screenManager = screenManager
        self.windowManager = windowManager
    }
    
    // MARK: - Public Methods
    
    func start(forScreenID screenID: String) {
        guard !activeScreens.contains(screenID) else {
            logger.debug("DragSnapService already active for screen \(screenID)")
            return
        }
        
        logger.info("Starting DragSnapService for screen \(screenID)")
        
        activeScreens.insert(screenID)
        
        if !isActive {
            setupEventMonitors()
            isActive = true
        }
    }
    
    func stop() {
        guard isActive else { return }
        
        logger.info("Stopping DragSnapService for all screens")
        
        removeEventMonitors()
        hidePreview()
        discardOverlayWindows()
        layoutPicker.hide()
        resetDragState()
        activeScreens.removeAll()
        snappedWindows.removeAll()
        isActive = false
    }
    
    func stop(forScreenID screenID: String) {
        guard activeScreens.contains(screenID) else { return }
        
        logger.info("Stopping DragSnapService for screen \(screenID)")
        activeScreens.remove(screenID)
        snappedWindows = snappedWindows.filter { $0.value.screenID != screenID }
        
        if activeScreens.isEmpty {
            stop()
        }
    }
    
    func isActive(forScreenID screenID: String) -> Bool {
        return activeScreens.contains(screenID)
    }
    
    // MARK: - Groups
    
    /// Groups of 2+ windows snapped to one zone. A window that was moved or resized since is not counted.
    /// - Parameter windowFrames: current frames of the windows on screen (CG coordinates)
    func snapGroups(windowFrames: [CGWindowID: CGRect]) -> [SnapGroup] {
        let inPlace = snappedWindows.filter { windowID, snapped in
            guard activeScreens.contains(snapped.screenID), let frame = windowFrames[windowID] else { return false }
            return isClose(frame, snapped.snappedFrame)
        }
        let byZone = Dictionary(grouping: inPlace) { groupKey(of: $0.value) }
        return byZone.compactMap { key, members in
            guard members.count >= 2, let first = members.first?.value else { return nil }
            return SnapGroup(key: key, screenID: first.screenID, frame: first.zoneFrame, windowIDs: Set(members.map(\.key)))
        }
    }
    
    private func groupKey(of snapped: SnappedWindow) -> String {
        let zone = snapped.zoneFrame.integral
        return "\(snapped.screenID)|\(Int(zone.minX)),\(Int(zone.minY)),\(Int(zone.width)),\(Int(zone.height))"
    }
    
    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
    
    /// Resizing a window of a group gives the same frame to the other windows of the group
    private func resizeGroup(ofResized pressed: (windowID: CGWindowID, pid: pid_t, frame: CGRect)) {
        guard let resized = snappedWindows[pressed.windowID],
              isClose(pressed.frame, resized.snappedFrame),
              let newFrame = windowManager.frame(of: pressed.windowID) else { return }
        
        let key = groupKey(of: resized)
        let mates = snappedWindows.filter { windowID, snapped in
            guard windowID != pressed.windowID, groupKey(of: snapped) == key,
                  let frame = windowManager.frame(of: windowID) else { return false }
            return isClose(frame, snapped.snappedFrame)
        }
        guard !mates.isEmpty else { return }
        
        debugLog("DragSnapService", "Resizing group of \(mates.count + 1) windows to \(newFrame)")
        snappedWindows[pressed.windowID]?.snappedFrame = newFrame
        snappedWindows[pressed.windowID]?.zoneFrame = newFrame
        for (windowID, mate) in mates {
            setFrame(newFrame, of: mate.axWindow, pid: mate.pid)
            snappedWindows[windowID]?.snappedFrame = frame(of: mate.axWindow) ?? newFrame
            snappedWindows[windowID]?.zoneFrame = newFrame
        }
        NotificationCenter.default.post(name: .dragSnapGroupsDidChange, object: nil)
    }
    
    /// Moves the windows snapped on a screen to the same zones after its visible area changed (CG coordinates)
    func rescaleSnappedWindows(forScreenID screenID: String, from old: CGRect, to new: CGRect) {
        let onScreen = snappedWindows.filter { $0.value.screenID == screenID }
        guard !onScreen.isEmpty else { return }
        for (windowID, snapped) in onScreen {
            let zone = screenManager.rescale(snapped.zoneFrame, from: old, to: new)
            setFrame(zone, of: snapped.axWindow, pid: snapped.pid)
            snappedWindows[windowID]?.zoneFrame = zone
            snappedWindows[windowID]?.snappedFrame = frame(of: snapped.axWindow) ?? zone
        }
        debugLog("DragSnapService", "Moved \(onScreen.count) snapped window(s) on \(screenID) from visible area \(old) to \(new)")
        NotificationCenter.default.post(name: .dragSnapGroupsDidChange, object: nil)
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
        
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.discardOverlayWindows()
            }
        }
        
        logger.debug("Event monitors set up")
    }
    
    // MARK: - Workaround: the preview and zone outlines stay on the desktop where they were first shown
    // Their windows are .stationary without .canJoinAllSpaces, so macOS keeps them on that desktop:
    // hiding and showing them again on another desktop leaves them invisible there.
    // WindowHighlightService.recreateForNewSpace() does the same for the active window border.
    /// Drops the windows on a desktop change. The next drag creates new ones on the current desktop.
    private func discardOverlayWindows() {
        previewWindow?.remove()
        previewWindow = nil
        zonesWindow?.hide()
        zonesWindow = nil
    }
    
    private func removeEventMonitors() {
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
        
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
            // Pressing or releasing ⌥ without moving the mouse turns the zones off or on right away
            if isDragging {
                updateSnapZone(for: NSEvent.mouseLocation)
            }
        default:
            break
        }
    }
    
    private func handleMouseDown(_ event: NSEvent) {
        dragStartPosition = NSEvent.mouseLocation
        isNotWindowDrag = false
        pressedWindow = windowUnderCursor()
    }
    
    private func handleMouseDragged(_ event: NSEvent) {
        guard let startPos = dragStartPosition else { return }
        
        let currentPos = NSEvent.mouseLocation
        let dragDistance = hypot(currentPos.x - startPos.x, currentPos.y - startPos.y)
        
        if dragDistance > minimumDragDistance && !isDragging && !isNotWindowDrag {
            switch windowDragState() {
            case .moved(let frame):
                beginDrag(currentFrame: frame)
            case .resized:
                isNotWindowDrag = true
                isResizingWindow = true
            case .still:
                if pressedWindow == nil || WindowManager.pointerMovedPastGiveUpDistance(from: startPos) {
                    isNotWindowDrag = true
                }
            }
        }
        
        if isDragging {
            updateSnapZone(for: currentPos)
        }
    }
    
    private func handleMouseUp(_ event: NSEvent) {
        if isDragging, let zone = currentSnapZone, let pressed = pressedWindow,
           let window = windowManager.enumerateWindows().first(where: { $0.windowID == pressed.windowID }) {
            applySnap(window: window, to: zone)
            if case .pickerZone = zone.edge {
                var shown = Set(UserDefaults.standard.stringArray(forKey: "shownHints") ?? [])
                if shown.insert(DragSnapLayoutPicker.pickerHintID).inserted {
                    UserDefaults.standard.set(Array(shown).sorted(), forKey: "shownHints")
                }
            }
        } else if isDragging, currentSnapZone == nil, NSEvent.modifierFlags.contains(.option) {
            HintKeyStore.recordCompletedUse(of: .snapFreeKey)
        } else if isResizingWindow, let pressed = pressedWindow {
            resizeGroup(ofResized: pressed)
        }
        
        hidePreview()
        layoutPicker.hide()
        resetDragState()
    }
    
    // MARK: - Window Detection
    
    /// The topmost normal window under the cursor. Works for inactive windows too:
    /// when the button goes down on them, their app is not frontmost yet.
    private func windowUnderCursor() -> (windowID: CGWindowID, pid: pid_t, frame: CGRect)? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(point) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            return (windowID, pid, frame)
        }
        return nil
    }
    
    private enum WindowDragState {
        case still
        case moved(CGRect)
        case resized
    }
    
    /// Compares the pressed window with its frame at mouse down.
    /// Dragging a window edge moves its origin too, so a changed size means a resize, not a drag.
    private func windowDragState() -> WindowDragState {
        guard let pressed = pressedWindow,
              let currentFrame = windowManager.frame(of: pressed.windowID) else { return .still }
        
        let sizeChanged = abs(currentFrame.width - pressed.frame.width) > 1
            || abs(currentFrame.height - pressed.frame.height) > 1
        if sizeChanged { return .resized }
        if currentFrame.origin != pressed.frame.origin { return .moved(currentFrame) }
        return .still
    }
    
    /// Kept cheap: it runs in the middle of the drag, and the preview must follow right away.
    /// The window details and its AX element are looked up only when the window is dropped.
    private func beginDrag(currentFrame: CGRect) {
        guard let pressed = pressedWindow else { return }
        if let bundleID = NSRunningApplication(processIdentifier: pressed.pid)?.bundleIdentifier,
           windowManager.ignoredBundleIdentifiers.contains(bundleID) {
            isNotWindowDrag = true
            return
        }
        
        isDragging = true
        logger.debug("Window drag detected: windowID=\(pressed.windowID)")
        
        restoreSizeIfSnapped(windowID: pressed.windowID, currentFrame: currentFrame)
    }
    
    /// A snapped window that is dragged away gets back the size it had before the snap.
    /// The point under the cursor stays at the same place in the title bar.
    private func restoreSizeIfSnapped(windowID: CGWindowID, currentFrame: CGRect) {
        guard let snapped = snappedWindows.removeValue(forKey: windowID) else { return }
        NotificationCenter.default.post(name: .dragSnapGroupsDidChange, object: nil)
        let stillSnapped = abs(currentFrame.width - snapped.snappedFrame.width) <= 2
            && abs(currentFrame.height - snapped.snappedFrame.height) <= 2
        guard stillSnapped,
              let pid = pressedWindow?.pid,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let axWindow = snapped.axWindow
        
        let mouse = NSEvent.mouseLocation
        let cursor = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        let fraction = currentFrame.width > 0 ? (cursor.x - currentFrame.minX) / currentFrame.width : 0.5
        let size = snapped.sizeBefore
        let origin = CGPoint(x: cursor.x - fraction * size.width, y: currentFrame.minY)
        
        logger.debug("Restoring size \(size.width)x\(size.height) after unsnap")
        sizeBeforeSnap = size
        setFrame(CGRect(origin: origin, size: size), of: axWindow, pid: pid)
    }
    
    // MARK: - Snap Zone Detection
    
    private func updateSnapZone(for mousePosition: CGPoint) {
        // NSEvent.mouseLocation returns AppKit coordinates (bottom-left origin)
        guard let screen = screenManager.screenAppKit(at: mousePosition) else {
            currentSnapZone = nil
            hidePreview()
            layoutPicker.hide()
            return
        }
        
        let screenID = screenManager.identifier(for: screen)
        
        guard activeScreens.contains(screenID) else {
            currentSnapZone = nil
            currentDragScreenID = nil
            hidePreview()
            layoutPicker.hide()
            return
        }
        
        currentDragScreenID = screenID
        
        // ⌥ moves the window freely. With a layout chosen, the zone under the cursor takes the window, as in Manual.
        let newZone: SnapZone?
        if NSEvent.modifierFlags.contains(.option) {
            zonesWindow?.hide()
            layoutPicker.hide()
            newZone = nil
        } else if let zones = layoutZones?(screen), !zones.isEmpty {
            layoutPicker.hide()
            newZone = layoutZone(at: mousePosition, zones: zones, on: screen)
        } else {
            zonesWindow?.hide()
            let showsPickerCaption = showsHints &&
                !(UserDefaults.standard.stringArray(forKey: "shownHints") ?? []).contains(DragSnapLayoutPicker.pickerHintID)
            layoutPicker.show(in: screenManager.visibleFrame(for: screen), showsCaption: showsPickerCaption)
            if layoutPicker.contains(mousePosition) {
                newZone = layoutPicker.pick(at: mousePosition).map {
                    SnapZone(edge: .pickerZone(layout: $0.layout, zone: $0.zone), resultFrame: $0.relativeFrame)
                }
            } else {
                _ = layoutPicker.pick(at: mousePosition)
                let detectedEdge = detectEdge(mousePosition: mousePosition, screen: screen)
                newZone = snapZones.first { $0.edge == detectedEdge }
            }
        }
        
        if let zone = newZone {
            if zone.edge != currentSnapZone?.edge {
                logger.debug("Snap zone detected on screen \(screenID): \(zone.displayName)")
                currentSnapZone = zone
            }
            showPreview(for: zone, on: screen)
        } else {
            if currentSnapZone != nil {
                logger.debug("Left snap zone on screen \(screenID)")
                hidePreview()
            }
            currentSnapZone = nil
        }
    }
    
    /// The layout zone under the cursor, or the nearest one when the cursor is in a gap.
    /// Shows the outlines of all zones, so it is clear where the window can go.
    private func layoutZone(at mousePosition: CGPoint, zones: [CGRect], on screen: NSScreen) -> SnapZone? {
        let visible = screenManager.visibleFrame(for: screen)
        let frames = zones.map { screenManager.calculateAbsoluteFrame(relativeFrame: $0, in: visible) }
        
        let zonesWindow = self.zonesWindow ?? DragSnapZonesWindow()
        self.zonesWindow = zonesWindow
        zonesWindow.show(zones: frames, on: screen.frame)
        
        let containing = frames.indices.filter { frames[$0].contains(mousePosition) }
        let index = containing.min { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }
            ?? frames.indices.min {
                hypot(frames[$0].midX - mousePosition.x, frames[$0].midY - mousePosition.y)
                    < hypot(frames[$1].midX - mousePosition.x, frames[$1].midY - mousePosition.y)
            }
        guard let index else { return nil }
        return SnapZone(edge: .layoutZone(index), resultFrame: zones[index])
    }
    
    /// Uses the full screen frame: the pointer can reach the menu bar and the Dock,
    /// while the snapped window still goes into the visible frame.
    private func detectEdge(mousePosition: CGPoint, screen: NSScreen) -> SnapEdge {
        let frame = screen.frame
        let x = mousePosition.x
        let y = mousePosition.y
        
        let fromLeft = x - frame.minX
        let fromRight = frame.maxX - x
        let fromTop = frame.maxY - y
        let fromBottom = y - frame.minY
        
        let nearLeft = fromLeft <= edgeTriggerDistance
        let nearRight = fromRight <= edgeTriggerDistance
        let nearTop = fromTop <= edgeTriggerDistance
        let nearBottom = fromBottom <= edgeTriggerDistance
        
        // Corners on the side edges are measured from the visible frame: the Dock and the menu bar
        // would otherwise eat most of them, and the bottom corner could only be hit at the very bottom
        if nearLeft || nearRight {
            let visible = screenManager.visibleFrame(for: screen)
            let sideCorner = max(cornerLength, visible.height * sideCornerFraction)
            if visible.maxY - y <= sideCorner { return nearLeft ? .topLeft : .topRight }
            if y - visible.minY <= sideCorner { return nearLeft ? .bottomLeft : .bottomRight }
            return nearLeft ? .left : .right
        }
        
        if nearTop {
            if fromLeft <= cornerLength { return .topLeft }
            if fromRight <= cornerLength { return .topRight }
            return .top
        }
        
        if nearBottom {
            if fromLeft <= cornerLength { return .bottomLeft }
            if fromRight <= cornerLength { return .bottomRight }
            let third = frame.width / 3
            if fromLeft < third { return .bottomLeftThird }
            if fromLeft < 2 * third { return .bottomCenterThird }
            return .bottomRightThird
        }
        
        return .none
    }
    
    // MARK: - Preview Window
    
    private func showPreview(for zone: SnapZone, on screen: NSScreen) {
        let screenFrame = screenManager.visibleFrame(for: screen)
        let absoluteFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: zone.resultFrame,
            in: screenFrame
        )
        
        let preview = previewWindow ?? DragSnapPreviewWindow()
        previewWindow = preview
        let hint = DragHint.dragSnap(showsHints: showsHints, learnedKeys: HintKeyStore.learnedKeys())
        preview.showPreview(
            frame: absoluteFrame,
            growingFrom: preview.isShowing ? nil : draggedWindowFrameAppKit(),
            hint: hint
        )
    }
    
    private func draggedWindowFrameAppKit() -> CGRect? {
        guard let windowID = pressedWindow?.windowID,
              let frame = windowManager.frame(of: windowID),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
    
    private func hidePreview() {
        previewWindow?.hidePreview()
        zonesWindow?.hide()
    }
    
    // MARK: - Snap Application
    
    private func applySnap(window: WindowInfo, to zone: SnapZone) {
        let targetScreen: NSScreen
        if let screenID = currentDragScreenID,
           let screen = screenManager.screen(for: screenID) {
            targetScreen = screen
        } else {
            targetScreen = screenManager.activeScreen()
        }
        
        let screenID = screenManager.identifier(for: targetScreen)
        logger.info("Applying snap: '\(window.title, privacy: .public)' to \(zone.displayName) on screen \(screenID)")
        
        let screenFrame = screenManager.visibleFrame(for: targetScreen)
        let absoluteFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: zone.resultFrame,
            in: screenFrame
        )
        let cgFrame = screenManager.convertToCGCoordinates(frame: absoluteFrame, for: targetScreen)
        
        guard let axWindow = accessibilityService.getAXWindow(for: window) else {
            logger.warning("Failed to snap window: no AX element")
            return
        }
        
        let sizeBefore = sizeBeforeSnap ?? pressedWindow?.frame.size ?? window.frame.size
        setFrame(cgFrame, of: axWindow, pid: window.ownerPID)
        
        let actualFrame = frame(of: axWindow) ?? cgFrame
        let snapped = SnappedWindow(
            snappedFrame: actualFrame, sizeBefore: sizeBefore, axWindow: axWindow,
            pid: window.ownerPID, zoneFrame: cgFrame, screenID: screenID
        )
        snappedWindows[window.windowID] = snapped
        if snappedWindows.count > 200 {
            snappedWindows = snappedWindows.filter { windowManager.frame(of: $0.key) != nil }
        }
        let sameZone = snappedWindows.values.filter { groupKey(of: $0) == groupKey(of: snapped) }.count
        debugLog("DragSnapService", "Snapped window \(window.windowID) (\(window.ownerName)) to \(zone.displayName) \(cgFrame) on \(screenID), got \(actualFrame); \(sameZone) snapped window(s) in this zone")
        NotificationCenter.default.post(name: .dragSnapDidSnap, object: nil)
        NotificationCenter.default.post(name: .dragSnapGroupsDidChange, object: nil)
    }
    
    /// Right after a frame change the window list still reports the old frame; the window itself answers at once
    private func frame(of axWindow: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    
    // MARK: - Workaround: apps with AXEnhancedUserInterface animate every frame change
    // While it is on (turned on by assistive apps), the window slides to its new frame slowly and
    // can stop short. Size, then position, then size again: the first size can be clamped by the
    // screen edge at the old position, and some apps resize only after they were moved.
    private func setFrame(_ frame: CGRect, of axWindow: AXUIElement, pid: pid_t) {
        guard AppResponsiveness.isResponding(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        let enhancedAttribute = "AXEnhancedUserInterface" as CFString
        var enhancedValue: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(app, enhancedAttribute, &enhancedValue) == .success
            && (enhancedValue as? Bool) == true
        if wasEnhanced {
            AXUIElementSetAttributeValue(app, enhancedAttribute, kCFBooleanFalse)
        }
        defer {
            if wasEnhanced {
                AXUIElementSetAttributeValue(app, enhancedAttribute, kCFBooleanTrue)
            }
        }
        
        var size = frame.size
        var origin = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &origin) else { return }
        
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        
        if positionResult != .success || sizeResult != .success {
            logger.warning("Failed to set frame: position=\(positionResult.rawValue), size=\(sizeResult.rawValue)")
        }
    }
    
    // MARK: - State Reset
    
    private func resetDragState() {
        isDragging = false
        isNotWindowDrag = false
        isResizingWindow = false
        pressedWindow = nil
        sizeBeforeSnap = nil
        dragStartPosition = nil
        currentSnapZone = nil
        currentDragScreenID = nil
    }
}
