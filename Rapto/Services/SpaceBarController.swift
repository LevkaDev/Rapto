//
//  SpaceBarController.swift
//  Rapto
//
//  Menu-bar pill that lists real macOS desktops and the apps
//  with windows on each one.
//

import AppKit
import ApplicationServices
import Combine
import Darwin
import os
import SwiftUI

extension Notification.Name {
    static let spaceBarMoveDidEnd = Notification.Name("SpaceBarMoveDidEnd")
}

private let logger = Logger(subsystem: "app.rapto.mac", category: "SpaceBar")

/// Electron apps such as HEY do not answer `_AXWindowID`, but this works for them.
@_silgen_name("_AXUIElementGetWindow")
private nonisolated func SpaceBarAXGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
private func SpaceBarGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Bring this window forward without moving it onto another desktop.
private let spaceBarFocusWindowOnly: UInt32 = 0x200

private let spaceBarSkyLight: UnsafeMutableRawPointer = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) ?? UnsafeMutableRawPointer(bitPattern: 1)!
}()

private typealias SpaceBarConnectionFn = @convention(c) () -> Int32
private typealias SpaceBarOrderedInFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Void
private typealias SpaceBarCopySpaceWindowsFn = @convention(c) (
    Int32, Int32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
) -> CFArray?
private typealias SpaceBarFrontProcess = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32
) -> OSStatus

// MARK: - Private CGS

// MARK: - Workaround:
// Cause: The public CGWindowList doesn't say which desktop a window is on,
//        and there is no public way to switch desktops.
// Context: Desktops Bar. Same class of private calls that already reads the list of desktops.
private typealias SpaceBarConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func SpaceBarMainConnectionID() -> SpaceBarConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func SpaceBarCopyManagedDisplaySpaces(_ connection: SpaceBarConnectionID) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func SpaceBarCopySpacesForWindows(_ connection: SpaceBarConnectionID, _ selector: Int32, _ windows: CFArray) -> CFArray?

private let spaceBarWindowSelector: Int32 = 7

@_silgen_name("CGSGetSymbolicHotKeyValue")
private func SpaceBarGetSymbolicHotKeyValue(
    _ hotKey: Int32,
    _ keyEquivalent: UnsafeMutablePointer<UInt16>,
    _ virtualKeyCode: UnsafeMutablePointer<UInt16>,
    _ modifiers: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("CGSIsSymbolicHotKeyEnabled")
private func SpaceBarIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func SpaceBarSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

/// "Switch to Desktop 1" in Keyboard Shortcuts → Mission Control. Desktop N is this plus N − 1.
private let spaceBarSwitchToDesktopOneHotKey: Int32 = 118

// MARK: - Model

struct SpaceBarWindowRef {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
    let ownerName: String
}

nonisolated struct SpaceBarGlyphKey: Hashable, Sendable {
    let spaceID: UInt64
    let pid: pid_t
}

struct SpaceBarGlyph: Identifiable {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let icon: NSImage
    let windows: [SpaceBarWindowRef]

    init(
        pid: pid_t,
        bundleIdentifier: String? = nil,
        appName: String,
        icon: NSImage,
        windows: [SpaceBarWindowRef]
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.icon = icon
        self.windows = windows
    }

    var id: String { "\(pid)" }
    var count: Int { windows.count }
}

struct SpaceBarSpace: Identifiable {
    let id: UInt64
    /// The key Rapto stores this desktop's mode and layout under.
    let key: String
    let number: Int
    let isCurrent: Bool
    /// The space macOS makes for an app in full screen. It has no number, mode or layout.
    let isFullScreen: Bool
    let glyphs: [SpaceBarGlyph]
}

struct SpaceBarDisplay: Identifiable {
    let id: String
    let spaces: [SpaceBarSpace]
}

/// Where a shortcut sends the front window.
enum SpaceBarMoveTarget: Equatable {
    /// The desktop with this number on the window's display
    case number(Int)
    case next
    case previous
}

/// When the pill is on screen.
enum SpaceBarPresentation: String, CaseIterable, Identifiable {
    case always
    case onHover
    /// On hover on screens with a notch, where the menu bar has no room. Always on the others.
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always On"
        case .onHover: return "Auto-Hide"
        case .automatic: return "Notched Screens"
        }
    }
}

enum SpaceBarStyle: String, CaseIterable, Identifiable {
    /// A dark pill whatever is behind the menu bar
    case dark
    /// A translucent pill that goes light or dark with the menu bar
    case glass
    /// No pill: the desktops sit in the menu bar like its own items
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .glass: return "Glass"
        case .plain: return "Plain"
        }
    }
}

// MARK: - Controller

/// Builds the desktop snapshot and keeps one pill on each screen's menu bar.
@MainActor
final class SpaceBarController: ObservableObject {

    @Published private(set) var displays: [SpaceBarDisplay] = []
    /// Whether macOS Accessibility permission is currently granted; when false, the bar shows a warning icon.
    @Published var hasAccessibilityPermission = true
    var onAccessibilityWarningClicked: (() -> Void)?
    /// Whether Window Flow is currently open (highlights the Flow button on the bar).
    @Published var isWindowFlowOpen = false
    /// Live shortcut string for Window Flow shown in the bar button tooltip, or nil when unbound.
    @Published var windowFlowShortcut: String?
    /// Fired when the user clicks the Window Flow button on a display's bar.
    var onWindowFlowClicked: ((String) -> Void)?
    /// Outline of the current desktop, the same color as the active window border
    @Published var currentDesktopColor: NSColor = .systemBlue
    @Published var style: SpaceBarStyle = .dark {
        didSet {
            guard style != oldValue else { return }
            applyStyle()
        }
    }
    /// Whether the menu bar draws light text. macOS picks that from the wallpaper behind the bar
    @Published private(set) var menuBarIsDark = true
    /// A zero-width status item: its button carries the menu bar's own appearance
    private var appearanceProbe: NSStatusItem?

    private var isEnabled = true
    private var started = false
    private var fingerprint = ""
    private struct CachedIcon {
        let image: NSImage
        let pixels: Data?
        let fetchedAt: Date
        let settled: Bool
    }
    private var icons: [pid_t: CachedIcon] = [:]
    private var iconRevision = 0
    /// Asking an app whether it is hidden is a round trip to LaunchServices, so answers are kept between refreshes.
    /// Cleared on every app launch/quit/activate/hide/unhide notification, and periodically as a safety net.
    private var hiddenByPID: [pid_t: Bool] = [:]
    private var hiddenByPIDResetDate = Date()
    private let hiddenByPIDLifetime: TimeInterval = 10
    private var cycleIndex: [String: Int] = [:]
    private var switchGeneration = 0
    private var didAskForSwitchPermission = false
    /// Work to do once a desktop is on screen. Returns false to try again later.
    private var pendingAction: (spaceID: UInt64, displayID: String, token: Int, settleDelay: TimeInterval, run: () -> Bool)?
    private var actionToken = 0
    /// Frames of each desktop segment in its pill, for finding the right-clicked desktop.
    private var segmentFrames: [String: [UInt64: CGRect]] = [:]
    /// Frames of each app icon in its pill, for finding a right-clicked app glyph.
    private var glyphFrames: [String: [SpaceBarGlyphKey: CGRect]] = [:]
    /// Proven title-bar grab anchors remembered per app for the current session.
    private var grabMemory = DesktopMoveGrabMemory()

    /// Builds the right-click menu for a desktop (and optional clicked app glyph) on a display.
    var menuBuilder: ((SpaceBarSpace, SpaceBarGlyph?, String) -> NSMenu?)?
    /// Fired when the user hovers the notch / top hover zone and reveals a hidden Desktops Bar.
    var onUserRevealedHoverBar: (() -> Void)?
    /// Fired when the user interacts with the Desktops Bar (switches desktops, focuses an app, or moves a window).
    var onUserUsedDesktopsBar: (() -> Void)?
    /// Whether a window moved from the pill takes the user along. Option on drop flips it.
    var movesFollowWindow = false
    /// Whether in-action hints (such as the live bar drag label) are shown.
    var showsHints = true {
        didSet {
            guard showsHints != oldValue else { return }
            if !showsHints {
                lastRenderedDragHintContent = nil
                dragHint.hide()
            } else if activeGlyphDrag != nil {
                refreshDragHint()
            }
        }
    }
    var presentation: SpaceBarPresentation = .automatic {
        didSet {
            guard presentation != oldValue else { return }
            revealed.removeAll()
            if started { layoutPanels() }
        }
    }
    /// Displays whose hover-only pill is showing right now.
    private var revealed = Set<String>()
    private var hideWork: [String: DispatchWorkItem] = [:]
    /// Shown after a desktop switch until this time, even without the pointer.
    private var flashUntil: [String: Date] = [:]
    private var isShowingMenu = false
    /// A window is about to leave this desktop (its key) on a display. The desktop is on screen.
    var onWillMoveWindow: ((CGWindowID, String, String) -> Void)?
    /// A window has landed on this desktop (its key) on a display.
    var onDidMoveWindow: ((CGWindowID, String, String) -> Void)?
    /// When the desktop id last changed. Focusing during the switch animation does nothing.
    private var spaceBecameCurrent: [String: (id: UInt64, at: Date)] = [:]
    private var isMovingWindow = false

    // MARK: - Workaround: Rapto's own drag watchers react to the mouse events of a move
    // Cause: A move presses, drags and releases the mouse by itself, sometimes several times.
    //        To the services that watch the user's drags these look like the user's own: a
    //        release scheduled a check for new windows that ran while the desktop was still
    //        switching, took the windows of the incoming desktop for new ones and put them
    //        into the layout of the desktop being left.
    // Context: While this is set, and for a moment after the last release, the drag watchers
    //          and the check for new windows stand down.
    private(set) static var isDrivingMouse = false
    /// The window being moved, while `isDrivingMouse` is set. Until it is let go it also goes
    /// where the user's hand moves the mouse, so its frame says nothing about its slot.
    private(set) static var movingWindowID: CGWindowID?

    private lazy var frontProcess: SpaceBarFrontProcess? = {
        guard let symbol = dlsym(spaceBarSkyLight, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: SpaceBarFrontProcess.self)
    }()

    private lazy var orderedIn: (connection: Int32, function: SpaceBarOrderedInFn)? = {
        guard let connectionSymbol = dlsym(spaceBarSkyLight, "SLSMainConnectionID"),
              let orderedSymbol = dlsym(spaceBarSkyLight, "SLSWindowIsOrderedIn") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: SpaceBarConnectionFn.self)()
        let function = unsafeBitCast(orderedSymbol, to: SpaceBarOrderedInFn.self)
        return (connection, function)
    }()

    private lazy var copySpaceWindows: (connection: Int32, function: SpaceBarCopySpaceWindowsFn)? = {
        guard let connectionSymbol = dlsym(spaceBarSkyLight, "SLSMainConnectionID"),
              let copySymbol = dlsym(spaceBarSkyLight, "SLSCopyWindowsWithOptionsAndTags") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: SpaceBarConnectionFn.self)()
        let function = unsafeBitCast(copySymbol, to: SpaceBarCopySpaceWindowsFn.self)
        return (connection, function)
    }()

    private var panels: [String: NSPanel] = [:]
    /// Screen of each display with a pill, kept from the last layout for the pointer handler
    private var screensByDisplay: [String: NSScreen] = [:]
    private var observers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var timer: Timer?
    /// Displays whose current space is a full-screen app.
    private var fullscreenDisplays = Set<String>()
    private var lastPointerCheck = Date.distantPast

    private let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "TextInputMenuAgent",
        "universalaccessd", "loginwindow", "WindowManager",
        "CursorUIViewService", "AirBuddyHelper"
    ]

    init() {}

    func start(enabled: Bool) {
        isEnabled = enabled
        guard !started else {
            applyVisibility()
            return
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        started = true
        applyStyle()
        observe()
        refresh()
        askForSwitchPermissionIfNeeded()
    }

    /// The style drawn on this display. On a screen with a notch the pill hangs
    /// below the menu bar, over windows, where only the dark pill stays readable.
    func look(displayID: String) -> SpaceBarStyle {
        guard style != .dark, let screen = screensByDisplay[displayID] ?? screen(forDisplayID: displayID) else { return style }
        return hasNotch(screen) ? .dark : style
    }

    /// App icon size in the pill, in step with the menu bar's own icons: 16 pt in a
    /// 24 pt bar, larger in the taller bars of bigger menu bar sizes and notched screens.
    func iconSize(displayID: String) -> CGFloat {
        guard let screen = screensByDisplay[displayID] ?? screen(forDisplayID: displayID) else { return 16 }
        // A hidden menu bar reports no height, so the status bar thickness stands in
        let height = max(menuBarHeight(of: screen), NSStatusBar.system.thickness)
        return min(max((height * 0.6).rounded(), 16), 20)
    }

    private func applyStyle() {
        guard started else { return }
        if style != .dark { watchMenuBarAppearance() }
        readMenuBarAppearance()
        for (displayID, panel) in panels {
            // A window shadow traces whatever is drawn, so only the opaque pill may have one
            panel.hasShadow = look(displayID: displayID) == .dark
            panel.invalidateShadow()
        }
    }

    private func watchMenuBarAppearance() {
        guard appearanceProbe == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 0)
        // Its own name: under a default one it inherits the saved "hidden" state of the
        // menu bar icon, and a hidden item never gets the bar's appearance
        item.autosaveName = "RaptoMenuBarAppearanceProbe"
        item.isVisible = true
        appearanceProbe = item
    }

    /// Read on every refresh: the status item reports no change when macOS repaints the bar,
    /// and until its window is placed in the bar it only has a default appearance.
    private func readMenuBarAppearance() {
        guard style != .dark else { return }
        let isDark: Bool
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            // In Dark mode the menu bar text is always light
            isDark = true
        } else if let window = appearanceProbe?.button?.window, window.frame.height > 0 {
            // In Light mode macOS picks the text colour from the wallpaper behind the bar
            isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            return
        }
        guard isDark != menuBarIsDark else { return }
        menuBarIsDark = isDark
        debugLog("[SpaceBar] menu bar is \(isDark ? "dark" : "light")")
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if started {
            applyVisibility()
        }
    }

    /// Switch to a desktop. A click on the number does not activate an app.
    func switchTo(spaceID: UInt64, displayID: String) {
        onUserUsedDesktopsBar?()
        pendingAction = nil
        askForSwitchPermissionIfNeeded()
        startSwitch(spaceID: spaceID, displayID: displayID)
    }

    /// Toggles Window Flow for the display owning this bar.
    func openWindowFlow(displayID: String) {
        onWindowFlowClicked?(displayID)
    }

    /// Open the app shown by this icon. If its desktop is hidden, switch there
    /// first and activate the window only after that desktop is on screen.
    func focus(_ glyph: SpaceBarGlyph, on spaceID: UInt64, displayID: String) {
        guard !glyph.windows.isEmpty else { return }
        onUserUsedDesktopsBar?()
        let key = "\(spaceID)-\(glyph.pid)"
        let index = cycleIndex[key] ?? 0
        let window = glyph.windows[index % glyph.windows.count]
        cycleIndex[key] = (index + 1) % glyph.windows.count
        if !AppResponsiveness.isResponding(glyph.pid), let screen = screen(forDisplayID: displayID) {
            showNotice(AppResponsiveness.notRespondingMessage(appName: glyph.appName), on: screen)
        }
        whenOnScreen(spaceID, displayID: displayID) { [weak self] in
            guard let self, self.window(window.windowID, isOn: spaceID) else { return false }
            self.performFocus(pid: window.pid, windowID: window.windowID)
            return true
        }
    }

    /// Run a menu action for a desktop. Switches to it first, so the result is on screen.
    func perform(on spaceID: UInt64, displayID: String, _ action: @escaping () -> Void) {
        if spaceIsCurrent(spaceID, on: displayID) {
            pendingAction = nil
            action()
            return
        }
        whenOnScreen(spaceID, displayID: displayID) {
            action()
            return true
        }
    }

    // MARK: - Moving windows

    /// Move the app's front window on one desktop to another desktop. With `follow`,
    /// the user ends up on the target desktop. Otherwise they stay where they were.
    func move(_ glyph: SpaceBarGlyph, from sourceID: UInt64, to targetID: UInt64, displayID: String, follow: Bool) {
        onUserUsedDesktopsBar?()
        let spaces = displays.first { $0.id == displayID }?.spaces ?? []
        move(glyph, from: sourceID, to: targetID, displayID: displayID, follow: follow, spaces: spaces)
    }

    /// Move the front window to another desktop of its display, the way a drag on the pill does.
    /// Works with the pill turned off too, so it reads the desktops itself.
    func moveFrontWindow(to target: SpaceBarMoveTarget) {
        guard !isMovingWindow,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let focusedID = focusedWindowID(pid: pid)
        // Windows come front to back, so without a focused window the app's first one is the front one
        var found: (display: SpaceBarDisplay, source: SpaceBarSpace, glyph: SpaceBarGlyph, window: SpaceBarWindowRef)?
        for display in makeSnapshot() {
            for space in display.spaces where space.isCurrent {
                guard let glyph = space.glyphs.first(where: { $0.pid == pid }),
                      let window = glyph.windows.first(where: { focusedID == nil || $0.windowID == focusedID }) else { continue }
                found = (display, space, glyph, window)
                break
            }
            if found != nil { break }
        }
        guard let found, !found.source.isFullScreen else {
            logger.notice("Move by shortcut: no front window on a desktop")
            NSSound.beep()
            return
        }
        let desktops = found.display.spaces.filter { !$0.isFullScreen }
        let destination: SpaceBarSpace?
        switch target {
        case .number(let number):
            destination = desktops.first { $0.number == number }
        case .next, .previous:
            let step = target == .next ? 1 : -1
            let index = desktops.firstIndex { $0.id == found.source.id }.map { $0 + step }
            destination = index.flatMap { desktops.indices.contains($0) ? desktops[$0] : nil }
        }
        guard let destination else {
            logger.notice("Move by shortcut: no such desktop on this display")
            NSSound.beep()
            return
        }
        let glyph = SpaceBarGlyph(pid: pid, appName: found.glyph.appName, icon: found.glyph.icon, windows: [found.window])
        move(glyph, from: found.source.id, to: destination.id, displayID: found.display.id,
             follow: movesFollowWindow, spaces: found.display.spaces)
    }

    /// Whether that desktop is the one shown on its display right now.
    func isCurrentSpace(_ spaceID: UInt64, on displayID: String) -> Bool {
        spaceIsCurrent(spaceID, on: displayID)
    }

    /// The window that has the keyboard, read from the app in front.
    func frontmostWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return focusedWindowID(pid: pid)
    }

    private func focusedWindowID(pid: pid_t) -> CGWindowID? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        return SpaceBarAXGetWindow(value as! AXUIElement, &id) == .success ? id : nil
    }

    private func move(
        _ glyph: SpaceBarGlyph, from sourceID: UInt64, to targetID: UInt64, displayID: String, follow: Bool,
        spaces: [SpaceBarSpace]
    ) {
        guard sourceID != targetID, !isMovingWindow, let window = glyph.windows.first else { return }
        guard AXIsProcessTrusted() else {
            logger.notice("Move: not trusted for accessibility")
            askForSwitchPermissionIfNeeded()
            return
        }
        logger.notice("Move: \(window.ownerName, privacy: .public) window \(window.windowID) from \(sourceID) to \(targetID), follow \(follow)")
        // A window assigned to All Desktops in the Dock is on both already and cannot be moved
        if refuseIfOnAllDesktops(glyph, displayID: displayID) { return }
        let current = desktopLayout(on: displayID).map { $0.ids[$0.currentIndex] }
        let home = follow ? targetID : current
        let keys = (
            source: spaces.first { $0.id == sourceID }?.key,
            target: spaces.first { $0.id == targetID }?.key
        )
        if current == sourceID, self.window(window.windowID, isOn: sourceID) {
            pendingAction = nil
            beginMove(window, to: targetID, displayID: displayID, home: home, keys: keys)
            return
        }
        // Pull an App-Napped app on the background desktop awake while macOS runs the desktop switch
        preWakeApp(pid: window.pid)
        whenOnScreen(sourceID, displayID: displayID) { [weak self] in
            guard let self else { return false }
            guard self.window(window.windowID, isOn: sourceID) else {
                logger.notice("Move: window \(window.windowID) is not on desktop \(sourceID) yet")
                return false
            }
            self.beginMove(window, to: targetID, displayID: displayID, home: home, keys: keys)
            return true
        }
    }

    private let hint = SpaceBarHint()
    private let dragHint = SpaceBarHint()

    private struct ActiveGlyphDrag: Equatable {
        let sourceSpaceID: UInt64
        var targetSpaceID: UInt64?
        let displayID: String
    }

    private var activeGlyphDrag: ActiveGlyphDrag?
    private var lastRenderedDragHintContent: HintCardContent?
    private var dragHintLocalMonitor: Any?
    private var dragHintGlobalMonitor: Any?

    /// Assigned to All Desktops in the Dock: one window with one frame on every desktop.
    func isOnAllDesktops(_ windowID: CGWindowID) -> Bool {
        spaceIDs(for: windowID, connection: SpaceBarMainConnectionID()).count > 1
    }

    /// A window assigned to All Desktops in the Dock is on every desktop and cannot be moved to one.
    /// Says so instead of acting out a move that changes nothing.
    private func refuseIfOnAllDesktops(_ glyph: SpaceBarGlyph, displayID: String) -> Bool {
        guard let window = glyph.windows.first,
              spaceIDs(for: window.windowID, connection: SpaceBarMainConnectionID()).count > 1 else { return false }
        logger.notice("Move: \(window.ownerName, privacy: .public) window \(window.windowID) is on all desktops")
        showOnAllDesktopsHint(appName: glyph.appName, displayID: displayID)
        return true
    }

    /// Frame of the visible Desktops Bar on `screen`, or top-center of `screen` when hidden.
    func barAnchor(on screen: NSScreen) -> NSRect {
        let bar = panels.first { $0.value.isVisible && $0.value.screen == screen }
        return bar?.value.frame ?? NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)
    }

    /// Visual style for hints shown on `screen`, matching its Desktops Bar.
    func lookForHint(on screen: NSScreen) -> SpaceBarHintLook {
        let bar = panels.first { $0.value.isVisible && $0.value.screen == screen }
        let displayID = bar?.key ?? displayUUID(for: screen)
        return hintLook(displayID: displayID.isEmpty ? nil : displayID)
    }

    /// A message from Rapto that belongs to no single control: under the bar when this display
    /// shows one, else at the top of the screen.
    func showNotice(_ text: String, on screen: NSScreen) {
        hint.show(text, below: barAnchor(on: screen), on: screen, look: lookForHint(on: screen))
    }

    // MARK: - Live Glyph Drag Hint

    func updateGlyphDrag(sourceSpaceID: UInt64, targetSpaceID: UInt64?, displayID: String) {
        activeGlyphDrag = ActiveGlyphDrag(
            sourceSpaceID: sourceSpaceID,
            targetSpaceID: targetSpaceID,
            displayID: displayID
        )
        installDragHintMonitorsIfNeeded()
        refreshDragHint()
    }

    func endGlyphDrag() {
        activeGlyphDrag = nil
        lastRenderedDragHintContent = nil
        removeDragHintMonitors()
        dragHint.hide()
    }

    private func refreshDragHint() {
        guard showsHints,
              let active = activeGlyphDrag,
              let targetID = active.targetSpaceID,
              targetID != active.sourceSpaceID else {
            lastRenderedDragHintContent = nil
            dragHint.hide()
            return
        }

        let targetDesktopNumber: Int?
        if targetID == Self.addDesktopSegmentID {
            targetDesktopNumber = nil
        } else {
            guard let targetSpace = displays
                .first(where: { $0.id == active.displayID })?
                .spaces
                .first(where: { $0.id == targetID }),
                !targetSpace.isFullScreen else {
                lastRenderedDragHintContent = nil
                dragHint.hide()
                return
            }
            targetDesktopNumber = targetSpace.number
        }

        let content = OneTimeHintCopy.spaceBarDrag(
            targetDesktopNumber: targetDesktopNumber,
            movesFollowWindow: movesFollowWindow,
            optionPressed: NSEvent.modifierFlags.contains(.option),
            learnedKeys: HintKeyStore.learnedKeys()
        )
        guard content != lastRenderedDragHintContent else { return }
        guard let screen = screensByDisplay[active.displayID] ?? screen(forDisplayID: active.displayID) else { return }
        let anchor = panels[active.displayID]?.frame ?? barAnchor(on: screen)
        lastRenderedDragHintContent = content
        dragHint.show(
            content,
            placement: .below(anchor),
            on: screen,
            look: hintLook(displayID: active.displayID),
            autoHideAfter: nil
        )
    }

    private func installDragHintMonitorsIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              dragHintGlobalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .leftMouseUp]
        let handleEvent: (NSEvent) -> Void = { [weak self] event in
            let eventType = event.type
            Task { @MainActor [weak self] in
                guard let self, self.activeGlyphDrag != nil else { return }
                if eventType == .flagsChanged {
                    self.refreshDragHint()
                } else if eventType == .leftMouseUp {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.activeGlyphDrag != nil,
                              (NSEvent.pressedMouseButtons & 1) == 0 else { return }
                        self.endGlyphDrag()
                    }
                }
            }
        }
        dragHintGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handleEvent)
        dragHintLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            handleEvent(event)
            return event
        }
    }

    private func removeDragHintMonitors() {
        if let dragHintGlobalMonitor {
            NSEvent.removeMonitor(dragHintGlobalMonitor)
            self.dragHintGlobalMonitor = nil
        }
        if let dragHintLocalMonitor {
            NSEvent.removeMonitor(dragHintLocalMonitor)
            self.dragHintLocalMonitor = nil
        }
    }

    func handleAccessibilityWarningTap(displayID: String) {
        if let screen = screen(forDisplayID: displayID) ?? NSScreen.main {
            showNotice(AppState.accessibilityOffMessage, on: screen)
        }
        onAccessibilityWarningClicked?()
    }

    /// A hint is drawn like the bar of its display; without a bar there, like the chosen style.
    private func hintLook(displayID: String?) -> SpaceBarHintLook {
        SpaceBarHintLook(style: displayID.map { look(displayID: $0) } ?? style, isDark: menuBarIsDark)
    }

    private func showOnAllDesktopsHint(appName: String, displayID: String) {
        NSSound.beep()
        guard let panel = panels[displayID], let screen = screen(forDisplayID: displayID) else { return }
        hint.show(
            "\(appName) is shown on all desktops, so it cannot be moved to one. "
                + "If it's assigned to All Desktops in the Dock, right-click \(appName) there and choose Options → Assign To → None.",
            below: panel.frame, on: screen, look: hintLook(displayID: displayID)
        )
    }

    func moveToNewDesktop(_ glyph: SpaceBarGlyph, from sourceID: UInt64, displayID: String, follow: Bool) {
        guard !isMovingWindow, !refuseIfOnAllDesktops(glyph, displayID: displayID) else { return }
        addDesktop(displayID: displayID) { [weak self] newID in
            self?.move(glyph, from: sourceID, to: newID, displayID: displayID, follow: follow)
        }
    }

    // MARK: - Adding desktops

    static let addDesktopSegmentID = UInt64.max
    private var isAddingDesktop = false

    // MARK: - Workaround:
    // Cause: With SIP enabled, a new desktop that the Dock knows about can only be
    //        created with the "+" button in Mission Control.
    // Context: The bar opens Mission Control for a moment, presses that button through
    //          Accessibility and closes it. Hammerspoon does the same.
    /// Adds a desktop at the end on this display. Calls `then` with its id once it exists.
    func addDesktop(displayID: String, then: ((UInt64) -> Void)? = nil) {
        guard !isAddingDesktop else { return }
        guard AXIsProcessTrusted() else {
            askForSwitchPermissionIfNeeded()
            return
        }
        guard let before = desktopLayout(on: displayID)?.ids else { return }
        isAddingDesktop = true
        logger.notice("Add desktop: opening Mission Control, \(before.count) desktops")
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        pressAddDesktop(displayID: displayID, before: before,
                        deadline: Date().addingTimeInterval(2.0), then: then)
    }

    private func pressAddDesktop(
        displayID: String, before: [UInt64],
        deadline: Date, then: ((UInt64) -> Void)?
    ) {
        guard let button = addDesktopButton(displayID: displayID) else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.pressAddDesktop(displayID: displayID, before: before, deadline: deadline, then: then)
                }
                return
            }
            logger.notice("Add desktop: no add button in Mission Control")
            isAddingDesktop = false
            closeMissionControl()
            NSSound.beep()
            return
        }
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        logger.notice("Add desktop: pressed (\(status.rawValue))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.closeMissionControl()
            self.waitForNewDesktop(displayID: displayID, before: before,
                                   deadline: Date().addingTimeInterval(2.0), then: then)
        }
    }

    private func waitForNewDesktop(displayID: String, before: [UInt64], deadline: Date, then: ((UInt64) -> Void)?) {
        let ids = desktopLayout(on: displayID)?.ids ?? []
        let newID = ids.last(where: { !before.contains($0) })
        let open = isMissionControlOpen
        // Mission Control has to be gone before a window can be grabbed.
        if let newID, !open {
            logger.notice("Add desktop: desktop \(newID) added")
            isAddingDesktop = false
            refresh()
            NotificationCenter.default.post(name: .raptoTourDidAddDesktop, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                then?(newID)
            }
            return
        }
        guard Date() < deadline else {
            logger.notice("Add desktop: timed out, new desktop \(newID ?? 0), \(ids.count) desktops, Mission Control open \(open)")
            isAddingDesktop = false
            closeMissionControl()
            NSSound.beep()
            return
        }
        // Escape is ignored while the new desktop slides in, so keep asking.
        if open, Date().timeIntervalSince(lastMissionControlClose) > 0.25 {
            closeMissionControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForNewDesktop(displayID: displayID, before: before, deadline: deadline, then: then)
        }
    }

    private var lastMissionControlClose = Date.distantPast

    private var isMissionControlOpen: Bool {
        !missionControlDisplays().isEmpty
    }

    private func closeMissionControl() {
        guard isMissionControlOpen else { return }
        lastMissionControlClose = Date()
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let escape = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: isDown)
            escape?.flags = []
            escape?.post(tap: .cghidEventTap)
        }
    }

    private func missionControlDisplays() -> [AXUIElement] {
        MissionControl.displays()
    }

    /// The "add desktop" button in the Spaces Bar of this display's Mission Control.
    private func addDesktopButton(displayID: String) -> AXUIElement? {
        let displays = missionControlDisplays()
        let screen = screen(forDisplayID: displayID)
        let screenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let display = displays.first { element in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXDisplayID" as CFString, &value) == .success,
                  let number = value as? NSNumber else { return false }
            return number.uint32Value == screenNumber
        } ?? displays.first { element in
            guard let screen, let frame = axFrame(of: element) else { return false }
            return frame == axRect(of: screen.frame)
        } ?? displays.first
        guard let display else { return nil }
        return descendant(of: display, identifier: "mc.spaces.add", depth: 3)
    }

    private func descendant(of element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        let kids = children(of: element)
        if let match = kids.first(where: { stringAttribute("AXIdentifier", of: $0) == identifier }) {
            return match
        }
        for kid in kids {
            if let match = descendant(of: kid, identifier: identifier, depth: depth - 1) { return match }
        }
        return nil
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// Converts an AppKit screen rect to Accessibility coordinates, which start at the top left.
    private func axRect(of rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Short per-element AX timeout used while starting a desktop move so an App-Napped app never
    /// blocks the move for a full second or falsely trips `AppResponsiveness`.
    private nonisolated static let quickAXTimeout: Float = 0.15
    private nonisolated static let wakeAXTimeout: Float = 0.35

    private nonisolated final class WakeProbeCancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private nonisolated struct SendableAXElement: @unchecked Sendable {
        let value: AXUIElement
    }

    private var moveWakeGeneration = 0
    private var wakeProbeCancel: WakeProbeCancelToken?
    private var wakingAXWindow: AXUIElement?
    private var isWaitingForAXWake = false

    private func cancelBackgroundAXWakeProbe() {
        moveWakeGeneration += 1
        wakeProbeCancel?.cancel()
        wakeProbeCancel = nil
        wakingAXWindow = nil
        isWaitingForAXWake = false
    }

    /// Polls Accessibility off the main thread for an app whose initial AX lookup timed out
    /// (such as a Mac Catalyst app finishing its background-to-foreground scene wake), raising
    /// the exact window as soon as the app answers without ever stalling Rapto's main thread.
    private func startBackgroundAXWakeProbe(
        window: SpaceBarWindowRef,
        started: Date,
        deadline: Date
    ) {
        let generation = moveWakeGeneration
        let cancelToken = WakeProbeCancelToken()
        wakeProbeCancel = cancelToken
        let pid = window.pid
        let windowID = window.windowID
        let ownerName = window.ownerName
        let probeTimeout = Self.wakeAXTimeout

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, probeTimeout)

            while !cancelToken.isCancelled && Date() < deadline {
                var windowsRef: CFTypeRef?
                let attemptStarted = CFAbsoluteTimeGetCurrent()
                let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
                let waited = CFAbsoluteTimeGetCurrent() - attemptStarted
                let matched = (result == .success)
                    ? (windowsRef as? [AXUIElement]).flatMap { Self.matchingAXWindow(windowID: windowID, in: $0) }
                    : nil
                let outcome = DesktopMoveGrabPlanner.classifyQuickAXProbe(
                    error: result,
                    waited: waited,
                    timeout: TimeInterval(probeTimeout),
                    foundWindow: matched != nil
                )
                if outcome != .waking {
                    let wrapped = matched.map(SendableAXElement.init)
                    let succeeded = (result == .success)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.moveWakeGeneration == generation else { return }
                        if succeeded {
                            AppResponsiveness.shared.noteResponded(pid)
                        }
                        self.isWaitingForAXWake = false
                        self.wakeProbeCancel = nil
                        if let axWin = wrapped?.value {
                            self.wakingAXWindow = axWin
                            let elapsed = Date().timeIntervalSince(started)
                            logger.notice("Move: \(ownerName, privacy: .public) window \(windowID) woke after \(String(format: "%.2f", elapsed), privacy: .public)s")
                            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                            let appElement = AXUIElementCreateApplication(pid)
                            AXUIElementSetMessagingTimeout(appElement, Self.quickAXTimeout)
                            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                        }
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.moveWakeGeneration == generation else { return }
                self.isWaitingForAXWake = false
                self.wakeProbeCancel = nil
            }
        }
    }

    /// Sends a lightweight off-main-thread Accessibility ping to wake an App-Napped process while
    /// macOS switches to its desktop, adding zero latency to already-awake apps.
    private func preWakeApp(pid: pid_t) {
        guard !AppResponsiveness.shared.notRespondingPIDs.contains(pid) else { return }
        let timeout = Self.wakeAXTimeout
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, timeout)
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role) == .success {
                AppResponsiveness.shared.noteResponded(pid)
            }
        }
    }

    // MARK: - Workaround:
    // Cause: Since macOS 15 the private calls that move another app's window to a different
    //        desktop do nothing while SIP is enabled.
    // Context: macOS carries a window held by its title bar along when the desktop
    //          switches. Press the mouse button on the title bar, switch the desktop
    //          and release. Amethyst and Raycast do the same.
    /// `home` is the desktop the user was on when the drag started. The move ends there.
    private func beginMove(
        _ window: SpaceBarWindowRef, to targetID: UInt64, displayID: String, home: UInt64?,
        keys: (source: String?, target: String?)
    ) {
        guard !AppResponsiveness.shared.notRespondingPIDs.contains(window.pid) else {
            logger.notice("Move: skipping \(window.ownerName, privacy: .public) window \(window.windowID) (app confirmed not responding)")
            NSSound.beep()
            return
        }
        cancelBackgroundAXWakeProbe()
        let cgFrame = cgWindowFrame(windowID: window.windowID)
        // Mark the move active BEFORE waking/focusing the target window so WindowHighlightService,
        // SettingsWindowDetector, WindowUsageTracker and drag watchers stand down and never block
        // the main thread querying an App-Napped app mid-move.
        isMovingWindow = true
        Self.isDrivingMouse = true
        Self.movingWindowID = window.windowID

        // Wake and bring the target window forward via LaunchServices + WindowServer BEFORE asking
        // Accessibility, so an App-Napped window (even buried behind a slot group) starts waking at once.
        focusViaWindowServer(pid: window.pid, windowID: window.windowID)

        let started = Date()
        let axProbe = quickAXWindowProbe(pid: window.pid, windowID: window.windowID, timeout: Self.quickAXTimeout)
        let axWin = axProbe.element
        let initialFrame = axWin.flatMap { frame(of: $0) } ?? cgFrame
        guard let initialFrame else {
            logger.notice("Move: no accessibility or Core Graphics window for \(window.windowID)")
            endDrivingMouse()
            NSSound.beep()
            return
        }
        if let source = keys.source {
            onWillMoveWindow?(window.windowID, source, displayID)
        }
        let raiseDuration = DesktopMoveGrabPlanner.raiseDeadlineDuration(axOutcome: axProbe.outcome)
        let raiseDeadline = Date().addingTimeInterval(raiseDuration)
        if let axWin {
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            let appElement = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(appElement, Self.quickAXTimeout)
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        } else if axProbe.outcome == .waking {
            isWaitingForAXWake = true
            logger.notice("Move: \(window.ownerName, privacy: .public) window \(window.windowID) AX not ready within \(Self.quickAXTimeout, privacy: .public)s, waiting up to \(raiseDuration, privacy: .public)s for app wake")
            startBackgroundAXWakeProbe(window: window, started: started, deadline: raiseDeadline)
        } else {
            logger.notice("Move: \(window.ownerName, privacy: .public) window \(window.windowID) has no AX window, using Core Graphics fallback")
        }
        grabWhenRaised(window, axWindow: axWin, frame: initialFrame, to: targetID, displayID: displayID, home: home,
                       targetKey: keys.target, deadline: raiseDeadline, started: started)
    }

    private func endDrivingMouse() {
        cancelBackgroundAXWakeProbe()
        isMovingWindow = false
        Self.isDrivingMouse = false
        Self.movingWindowID = nil
        NotificationCenter.default.post(name: .spaceBarMoveDidEnd, object: nil)
    }

    /// The title bar spot belongs to the window only once it is in front, so retry briefly.
    private func grabWhenRaised(
        _ window: SpaceBarWindowRef, axWindow: AXUIElement?, frame: CGRect,
        to targetID: UInt64, displayID: String, home: UInt64?, targetKey: String?,
        deadline: Date, started: Date = Date(), completedNudges: Int = 0, didRetrySlowAX: Bool = false
    ) {
        let effectiveAX = axWindow ?? wakingAXWindow
        let liveFrame = effectiveAX.flatMap { self.frame(of: $0) } ?? cgWindowFrame(windowID: window.windowID) ?? frame
        let windows = SpaceBarController.windowsFrontToBack()
        // Until the window is in front, spots are answered by whatever covers it. Checking three
        // points along the top strip avoids stalling when a small floating window sits over midX.
        let raisePoints = DesktopMoveGrabPlanner.raiseCheckPoints(for: liveFrame)
        let isOnTop = !raisePoints.isEmpty && raisePoints.contains {
            SpaceBarController.windowIsOnTop(pid: window.pid, at: $0, among: windows)
        }
        if DesktopMoveGrabPlanner.shouldWaitBeforeGrab(
            isOnTop: isOnTop,
            waitingForWake: isWaitingForAXWake,
            beforeDeadline: Date() < deadline
        ) {
            var nudges = completedNudges
            if !isOnTop,
               DesktopMoveGrabPlanner.nextRaiseNudgeIndex(
                   elapsed: Date().timeIntervalSince(started),
                   completedNudges: nudges
               ) != nil {
                nudges += 1
                focusViaWindowServer(pid: window.pid, windowID: window.windowID)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.grabWhenRaised(window, axWindow: effectiveAX, frame: liveFrame, to: targetID,
                                     displayID: displayID, home: home, targetKey: targetKey,
                                     deadline: deadline, started: started, completedNudges: nudges,
                                     didRetrySlowAX: didRetrySlowAX)
            }
            return
        }
        cancelBackgroundAXWakeProbe()
        // If AX wasn't ready at beginMove and the window is now on top, check once quickly.
        let resolvedAX = effectiveAX ?? (isOnTop ? quickAXWindow(pid: window.pid, windowID: window.windowID, timeout: Self.quickAXTimeout) : nil)
        let appKey = appIdentityKey(for: window)
        let button = resolvedAX.flatMap { titleBarButtonFrame(of: $0) }
        let outcome: GrabPlanOutcome
        if let resolvedAX {
            outcome = primaryGrabPlan(
                in: resolvedAX, frame: liveFrame, button: button, pid: window.pid,
                appKey: appKey, windows: windows, didRetrySlowAX: didRetrySlowAX
            )
        } else {
            outcome = cgFallbackGrabPlan(
                frame: liveFrame, pid: window.pid, appKey: appKey, windows: windows
            )
        }
        switch outcome {
        case .retrySlowAX:
            // MARK: - Workaround: Zen describes its page only a while after it is first asked
            // Retry once asynchronously so we never block the main thread with Thread.sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.grabWhenRaised(window, axWindow: resolvedAX, frame: liveFrame, to: targetID,
                                     displayID: displayID, home: home, targetKey: targetKey,
                                     deadline: max(deadline, Date().addingTimeInterval(0.2)),
                                     started: started, completedNudges: completedNudges,
                                     didRetrySlowAX: true)
            }
            return
        case .none:
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.grabWhenRaised(window, axWindow: resolvedAX, frame: liveFrame, to: targetID,
                                         displayID: displayID, home: home, targetKey: targetKey,
                                         deadline: deadline, started: started, completedNudges: completedNudges,
                                         didRetrySlowAX: didRetrySlowAX)
                }
                return
            }
            logger.notice("Move: no free title bar spot in \(window.ownerName, privacy: .public), frame \(String(describing: liveFrame), privacy: .public)")
            endDrivingMouse()
            NSSound.beep()
            return
        case .ready(let plan):
            let source = CGEventSource(stateID: .hidSystemState)
            let screenBounds = screen(forDisplayID: displayID).map { axRect(of: $0.frame) }
            let grab = Grab(
                window: window, appKey: appKey, axWindow: resolvedAX, frame: liveFrame,
                buttonFrame: button, screenBounds: screenBounds, targetID: targetID,
                targetKey: targetKey, displayID: displayID, home: home,
                cursor: CGEvent(source: nil)?.location ?? plan.points[0], source: source,
                usedCache: plan.usedCache, canDiscoverFallbacks: !plan.isGuess
            )
            if plan.isGuess {
                probe(plan.points, at: 0, grab: grab)
            } else {
                pressAndCarry(from: plan.points[0], grab: grab)
            }
        }
    }

    /// Pure Core Graphics fallback grab plan when an app waking from App Nap hasn't answered AX yet.
    private func cgFallbackGrabPlan(
        frame: CGRect, pid: pid_t, appKey: String, windows: [(pid: pid_t, frame: CGRect)]
    ) -> GrabPlanOutcome {
        if let cached = grabMemory.resolve(for: appKey, in: frame, buttonFrame: nil),
           SpaceBarController.windowIsOnTop(pid: pid, at: cached, among: windows) {
            return .ready(GrabPlan(points: [cached], isGuess: false, usedCache: true))
        }
        let spots = DesktopMoveGrabPlanner.cgFallbackSpots(in: frame, limit: Self.probeLimit)
            .filter { SpaceBarController.windowIsOnTop(pid: pid, at: $0, among: windows) }
        return spots.isEmpty ? .none : .ready(GrabPlan(points: spots, isGuess: true))
    }

    private func appIdentityKey(for window: SpaceBarWindowRef) -> String {
        AppBundleLookup.bundleIdentifier(for: NSRunningApplication(processIdentifier: window.pid)) ?? window.ownerName
    }

    /// What a move needs from the moment the mouse goes down until the desktop switches.
    private struct Grab {
        let window: SpaceBarWindowRef
        let appKey: String
        let axWindow: AXUIElement?
        let frame: CGRect
        let buttonFrame: CGRect?
        let screenBounds: CGRect?
        let targetID: UInt64
        let targetKey: String?
        let displayID: String
        let home: UInt64?
        /// Where the pointer was before the move, to put it back
        let cursor: CGPoint
        let source: CGEventSource?
        /// Whether the initial spot came from per-app session memory
        var usedCache: Bool = false
        /// Whether a non-moving primary/cached spot may lazily discover and probe fallback spots
        var canDiscoverFallbacks: Bool = false
        /// The confirmed spot the fallbacks stand in for; used when none of them drags either
        var lastResort: CGPoint?
        /// Whether the window visibly followed the synthetic drag before switching desktops
        var confirmedDrag: Bool = false
    }

    private struct OriginSnapshot {
        let ax: CGPoint?
        let cg: CGPoint?
    }

    private func originSnapshot(for grab: Grab) -> OriginSnapshot {
        OriginSnapshot(
            ax: grab.axWindow.flatMap { frame(of: $0)?.origin },
            cg: cgWindowOrigin(windowID: grab.window.windowID)
        )
    }

    /// Direct WindowServer bounds lookup works immediately even when an app is waking from App Nap.
    private func cgWindowFrame(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Direct WindowServer bounds lookup catches apps whose AX position lags or stays stale mid-drag.
    private func cgWindowOrigin(windowID: CGWindowID) -> CGPoint? {
        cgWindowFrame(windowID: windowID)?.origin
    }

    /// How far a spot is dragged to verify the window follows: first a small nudge for native
    /// windows, then a wider drag for Catalyst/Electron/Qt windows with an 8–12 pt drag threshold.
    private static let probeOffsets: [CGFloat] = [5, 14]

    private func press(at point: CGPoint, grab: Grab) {
        logger.notice("Move: grabbing at \(String(describing: point), privacy: .public)\(grab.usedCache ? " (cached)" : "", privacy: .public)")
        postMouse(.mouseMoved, at: point, source: grab.source)
        postMouse(.leftMouseDown, at: point, source: grab.source)
    }

    // MARK: - Workaround: A window that starts following the mouse late or needs a longer drag
    // Cause: macOS carries a window to the next desktop only once its drag has begun. Some
    //        apps (Hark) begin a few hundred milliseconds after the press, while Catalyst and
    //        Electron apps (WhatsApp) ignore a 5 pt drag until the pointer moves ~10–14 pt.
    // Context: After the press we drag 5 pt, escalate to 14 pt if the window has not moved
    //          within `escalateWait`, and wait up to `followWaitWithFallbacks` (or `followWait`
    //          on last resort) checking both Core Graphics and Accessibility positions.
    private static let escalateWait: TimeInterval = 0.12
    private static let followWaitWithFallbacks: TimeInterval = 0.36
    private static let followWait: TimeInterval = 0.45
    private static let followPoll: TimeInterval = 0.03

    private func pressAndCarry(from point: CGPoint, grab: Grab) {
        let before = originSnapshot(for: grab)
        press(at: point, grab: grab)
        let target = DesktopMoveGrabPlanner.probeDragTarget(from: point, windowFrame: grab.frame, offset: Self.probeOffsets[0])
        postMouse(.leftMouseDragged, at: target, source: grab.source)
        waitForFollow(from: point, grab: grab, before: before, started: Date(), stage: 0)
    }

    private func waitForFollow(from point: CGPoint, grab: Grab, before: OriginSnapshot, started: Date, stage: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followPoll) { [weak self] in
            guard let self else { return }
            let waited = Date().timeIntervalSince(started)
            let now = self.originSnapshot(for: grab)
            let followed = DesktopMoveGrabPlanner.didWindowFollow(
                beforeAX: before.ax, nowAX: now.ax,
                beforeCG: before.cg, nowCG: now.cg,
                dragOffset: Self.probeOffsets[stage]
            )
            if followed {
                logger.notice("Move: window follows after \(String(format: "%.2f", waited), privacy: .public)s (stage \(stage))")
                self.grabMemory.remember(point: point, in: grab.frame, buttonFrame: grab.buttonFrame, for: grab.appKey)
                var confirmed = grab
                confirmed.confirmedDrag = true
                self.carry(from: point, grab: confirmed)
                return
            }
            if stage == 0, waited >= Self.escalateWait, Self.probeOffsets.count > 1 {
                let target = DesktopMoveGrabPlanner.probeDragTarget(from: point, windowFrame: grab.frame, offset: Self.probeOffsets[1])
                self.postMouse(.leftMouseDragged, at: target, source: grab.source)
                self.waitForFollow(from: point, grab: grab, before: before, started: started, stage: 1)
                return
            }
            let maxWait = grab.canDiscoverFallbacks ? Self.followWaitWithFallbacks : Self.followWait
            if waited >= maxWait {
                logger.notice("Move: no move seen after \(String(format: "%.2f", waited), privacy: .public)s")
                if grab.canDiscoverFallbacks {
                    self.tryFallbacks(after: point, before: before, grab: grab)
                    return
                }
                self.carry(from: point, grab: grab)
                return
            }
            self.waitForFollow(from: point, grab: grab, before: before, started: started, stage: stage)
        }
    }

    // MARK: - Workaround: A spot Accessibility calls title bar (or a cached spot) may stop dragging
    // Cause: In Yab the middle of the top strip answers as a plain group of the window, or newly
    //        opened tabs can cover a previously learned spot.
    // Context: Release safely outside the window. If releasing itself moved the window (late
    //          follower like Hark), re-grab that same winning spot. Otherwise invalidate any stale
    //          cache entry and lazily probe structural empty gaps and multi-row candidates.
    private func tryFallbacks(after point: CGPoint, before: OriginSnapshot, grab: Grab) {
        let outside = DesktopMoveGrabPlanner.releasePoint(for: point, windowFrame: grab.frame, screenBounds: grab.screenBounds)
        postMouse(.leftMouseDragged, at: outside, source: grab.source)
        postMouse(.leftMouseUp, at: outside, source: grab.source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let after = self.originSnapshot(for: grab)
            let followedLate = DesktopMoveGrabPlanner.didWindowFollow(
                beforeAX: before.ax, nowAX: after.ax,
                beforeCG: before.cg, nowCG: after.cg,
                dragOffset: Self.probeOffsets[0]
            )
            self.putBack(grab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self else { return }
                if followedLate {
                    logger.notice("Move: window followed late at \(String(describing: point), privacy: .public)")
                    self.grabMemory.remember(point: point, in: grab.frame, buttonFrame: grab.buttonFrame, for: grab.appKey)
                    var next = grab
                    next.canDiscoverFallbacks = false
                    next.confirmedDrag = true
                    self.pressAndCarry(from: point, grab: next)
                    return
                }
                if grab.usedCache {
                    logger.notice("Move: invalidating cached grab spot for \(grab.appKey, privacy: .public)")
                    self.grabMemory.invalidate(for: grab.appKey)
                }
                let resolvedAX = grab.axWindow
                    ?? self.quickAXWindow(pid: grab.window.pid, windowID: grab.window.windowID, timeout: 0.05)
                let candidates: [CGPoint]
                if let resolvedAX {
                    candidates = self.fallbackSpots(
                        after: point, in: resolvedAX, frame: grab.frame,
                        button: grab.buttonFrame ?? self.titleBarButtonFrame(of: resolvedAX), pid: grab.window.pid
                    )
                } else {
                    let windows = SpaceBarController.windowsFrontToBack()
                    candidates = DesktopMoveGrabPlanner.cgFallbackSpots(
                        in: grab.frame, excluding: [point], limit: Self.fallbackLimit
                    ).filter { SpaceBarController.windowIsOnTop(pid: grab.window.pid, at: $0, among: windows) }
                }
                let next = Grab(
                    window: grab.window, appKey: grab.appKey, axWindow: resolvedAX, frame: grab.frame,
                    buttonFrame: grab.buttonFrame, screenBounds: grab.screenBounds, targetID: grab.targetID,
                    targetKey: grab.targetKey, displayID: grab.displayID, home: grab.home,
                    cursor: grab.cursor, source: grab.source, usedCache: false,
                    canDiscoverFallbacks: false, lastResort: point, confirmedDrag: grab.confirmedDrag
                )
                if candidates.isEmpty {
                    logger.notice("Move: no fallback spots available, carrying from \(String(describing: point), privacy: .public)")
                    self.pressAndCarry(from: point, grab: next)
                } else {
                    logger.notice("Move: letting go of \(String(describing: point), privacy: .public), probing \(candidates.count) other spots")
                    self.probe(candidates, at: 0, grab: next)
                }
            }
        }
    }

    // MARK: - Workaround: Some title bars drawn as a web page say nothing about where they drag
    // Cause: Antigravity, Orca and Electron apps answer "web page" or "group" across the title
    //        bar, and only parts of it drag the window. The rest holds controls.
    // Context: Guessed spots are tried one by one: press, drag inward, and see whether the
    //          window moved according to Core Graphics or Accessibility. One that did not is let
    //          go outside the window, so nothing under it is clicked. A window that moved only on
    //          that way out follows late (Hark): the spot does drag it, so we re-grab it.
    private func probe(_ points: [CGPoint], at index: Int, grab: Grab) {
        guard index < points.count else {
            // None followed within the wait. Moving from the first spot is what worked before
            // spots were probed, for windows that are only slow to follow.
            logger.notice("Move: no guessed spot dragged the window, using the first")
            var last = grab
            last.canDiscoverFallbacks = false
            pressAndCarry(from: grab.lastResort ?? points[0], grab: last)
            return
        }
        let point = points[index]
        let before = originSnapshot(for: grab)
        press(at: point, grab: grab)
        dragProbe(points, at: index, grab: grab, before: before, stage: 0)
    }

    private func dragProbe(_ points: [CGPoint], at index: Int, grab: Grab, before: OriginSnapshot, stage: Int) {
        let point = points[index]
        let target = DesktopMoveGrabPlanner.probeDragTarget(from: point, windowFrame: grab.frame, offset: Self.probeOffsets[stage])
        postMouse(.leftMouseDragged, at: target, source: grab.source)
        checkProbe(points, at: index, grab: grab, before: before, stage: stage, attempt: 0)
    }

    private func checkProbe(_ points: [CGPoint], at index: Int, grab: Grab, before: OriginSnapshot, stage: Int, attempt: Int) {
        // The app needs a moment to move its window after the drag event
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            let point = points[index]
            let now = self.originSnapshot(for: grab)
            if DesktopMoveGrabPlanner.didWindowFollow(
                beforeAX: before.ax, nowAX: now.ax,
                beforeCG: before.cg, nowCG: now.cg,
                dragOffset: Self.probeOffsets[stage]
            ) {
                logger.notice("Move: window followed at \(String(describing: point), privacy: .public), stage \(stage)")
                self.grabMemory.remember(point: point, in: grab.frame, buttonFrame: grab.buttonFrame, for: grab.appKey)
                var confirmed = grab
                confirmed.confirmedDrag = true
                self.carry(from: point, grab: confirmed)
                return
            }
            if attempt < 1 {
                self.checkProbe(points, at: index, grab: grab, before: before, stage: stage, attempt: attempt + 1)
                return
            }
            if stage + 1 < Self.probeOffsets.count {
                self.dragProbe(points, at: index, grab: grab, before: before, stage: stage + 1)
                return
            }
            logger.notice("Move: window did not follow at \(String(describing: point), privacy: .public)")
            // A button is pressed only when the mouse goes up over it
            let outside = DesktopMoveGrabPlanner.releasePoint(for: point, windowFrame: grab.frame, screenBounds: grab.screenBounds)
            self.postMouse(.leftMouseDragged, at: outside, source: grab.source)
            self.postMouse(.leftMouseUp, at: outside, source: grab.source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let after = self.originSnapshot(for: grab)
                let followedLate = DesktopMoveGrabPlanner.didWindowFollow(
                    beforeAX: before.ax, nowAX: after.ax,
                    beforeCG: before.cg, nowCG: after.cg,
                    dragOffset: Self.probeOffsets[0]
                )
                self.putBack(grab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self else { return }
                    if followedLate {
                        logger.notice("Move: window followed late at \(String(describing: point), privacy: .public)")
                        self.grabMemory.remember(point: point, in: grab.frame, buttonFrame: grab.buttonFrame, for: grab.appKey)
                        var confirmed = grab
                        confirmed.canDiscoverFallbacks = false
                        confirmed.confirmedDrag = true
                        self.pressAndCarry(from: point, grab: confirmed)
                    } else {
                        self.probe(points, at: index + 1, grab: grab)
                    }
                }
            }
        }
    }

    /// Where to let go of a spot that did not drag the window: just outside the window, so no
    /// control is pressed, but not at a screen edge, where macOS would tile a window that did follow.
    nonisolated static func releasePoint(for point: CGPoint, windowFrame: CGRect) -> CGPoint {
        DesktopMoveGrabPlanner.releasePoint(for: point, windowFrame: windowFrame, screenBounds: nil)
    }

    /// Returns the window to where it was when the move began, if a probe shifted it.
    private func putBack(_ grab: Grab) {
        let axWin = grab.axWindow ?? quickAXWindow(pid: grab.window.pid, windowID: grab.window.windowID, timeout: 0.08)
        let now = cgWindowOrigin(windowID: grab.window.windowID) ?? axWin.flatMap { frame(of: $0)?.origin }
        guard let now, now != grab.frame.origin, let axWin else { return }
        logger.notice("Move: putting the window back from \(String(describing: now), privacy: .public) to \(String(describing: grab.frame.origin), privacy: .public)")
        var origin = grab.frame.origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, value)
    }

    /// Whether a window dragged by `dragOffset` points came along. `start` is where it was just
    /// before the press, not when the move began: an earlier spot may have shifted it.
    nonisolated static func windowFollowed(from start: CGPoint, to now: CGPoint, dragOffset: CGFloat) -> Bool {
        DesktopMoveGrabPlanner.didWindowFollow(
            beforeAX: start, nowAX: now, beforeCG: nil, nowCG: nil, dragOffset: dragOffset
        )
    }

    /// The mouse is down on `point` and the window follows it: switch the desktop under it.
    private func carry(from point: CGPoint, grab: Grab) {
        var move = WindowMove(
            window: grab.window, appKey: grab.appKey, axWindow: grab.axWindow,
            origin: grab.frame.origin, frame: grab.frame, buttonFrame: grab.buttonFrame,
            targetID: grab.targetID, targetKey: grab.targetKey, displayID: grab.displayID,
            home: grab.home, grab: point, cursor: grab.cursor, source: grab.source,
            phaseStarted: Date(), confirmedDrag: grab.confirmedDrag
        )
        postMouse(.leftMouseDragged, at: CGPoint(x: point.x + 1, y: point.y), source: grab.source)
        postMouse(.leftMouseDragged, at: point, source: grab.source)

        // The Dock ignores the instant swipe while a mouse button is held, so this
        // uses the system shortcut, which macOS animates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.switchByHotKey(&move)
            move.phaseStarted = Date()
            self.waitForCarry(move)
        }
    }

    private struct WindowMove {
        let window: SpaceBarWindowRef
        let appKey: String
        let axWindow: AXUIElement?
        /// Where the window was before it was grabbed
        let origin: CGPoint
        let frame: CGRect
        let buttonFrame: CGRect?
        let targetID: UInt64
        let targetKey: String?
        let displayID: String
        let home: UInt64?
        let grab: CGPoint
        let cursor: CGPoint
        let source: CGEventSource?
        var phaseStarted: Date
        var restoreHotKey: (() -> Void)?
        var arrivedAt: Date?
        var confirmedDrag: Bool = false
    }

    private func switchByHotKey(_ move: inout WindowMove) {
        switchGeneration += 1
        move.restoreHotKey = pressSwitchHotKey(toward: move.targetID, displayID: move.displayID)
        if move.restoreHotKey == nil {
            logger.notice("Move: no desktop shortcut, falling back to the swipe")
            startSwitch(spaceID: move.targetID, displayID: move.displayID)
        }
    }

    /// Releases the window as soon as it is on the target desktop.
    private func waitForCarry(_ move: WindowMove) {
        var move = move
        let now = Date()
        let arrived = spaceIsCurrent(move.targetID, on: move.displayID)
        let carried = arrived && window(move.window.windowID, isOn: move.targetID)
        if arrived, move.arrivedAt == nil {
            move.arrivedAt = now
        }
        let elapsed = now.timeIntervalSince(move.phaseStarted)

        // Letting go while the desktop is still coming in can leave the window behind.
        if carried, now.timeIntervalSince(move.arrivedAt ?? now) >= 0.1 {
            logger.notice("Move: carried in \(String(format: "%.2f", elapsed), privacy: .public)s")
            release(move, moved: true)
            return
        }
        if elapsed > 2.5 {
            let spaces = spaceIDs(for: move.window.windowID, connection: SpaceBarMainConnectionID())
            logger.notice("Move: timed out, desktop switched \(arrived), window carried \(carried), window is on desktops \(spaces, privacy: .public), buttons down \(NSEvent.pressedMouseButtons)")
            release(move, moved: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.waitForCarry(move)
        }
    }

    /// Presses the system "Switch to Desktop N" shortcut, turning it on for the moment
    /// if the user has it off. Returns how to put the setting back, or nil if there is
    /// no such shortcut.
    private func pressSwitchHotKey(toward spaceID: UInt64, displayID: String) -> (() -> Void)? {
        guard let number = globalDesktopNumber(of: spaceID, displayID: displayID), number <= 16 else { return nil }
        let hotKey = spaceBarSwitchToDesktopOneHotKey + Int32(number - 1)
        var character: UInt16 = 0
        var keyCode: UInt16 = 0
        var modifiers: UInt32 = 0
        let status = SpaceBarGetSymbolicHotKeyValue(hotKey, &character, &keyCode, &modifiers)
        guard status == 0, keyCode != 0xFFFF else {
            logger.notice("Move: shortcut for desktop \(number) unavailable (\(status))")
            return nil
        }
        let wasEnabled = SpaceBarIsSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled {
            _ = SpaceBarSetSymbolicHotKeyEnabled(hotKey, true)
        }
        logger.notice("Move: pressing desktop \(number) shortcut key \(keyCode) modifiers \(modifiers), enabled \(wasEnabled)")
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return {
            if !wasEnabled {
                _ = SpaceBarSetSymbolicHotKeyEnabled(hotKey, false)
            }
        }
    }

    /// Mission Control numbers desktops across all displays.
    private func globalDesktopNumber(of spaceID: UInt64, displayID: String) -> Int? {
        let connection = SpaceBarMainConnectionID()
        guard let rawDisplays = SpaceBarCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return nil }
        var number = 0
        for display in rawDisplays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0, let sid = self.spaceID(from: space) else { continue }
                number += 1
                if sid == spaceID { return number }
            }
        }
        return nil
    }

    private func release(_ move: WindowMove, moved: Bool) {
        let window = move.window
        postMouse(.leftMouseUp, at: move.grab, source: move.source)
        CGWarpMouseCursorPosition(move.cursor)
        CGAssociateMouseAndMouseCursorPosition(1)
        move.restoreHotKey?()
        isMovingWindow = false
        // The release above reaches the watchers a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isMovingWindow else { return }
            Self.isDrivingMouse = false
            Self.movingWindowID = nil
            NotificationCenter.default.post(name: .spaceBarMoveDidEnd, object: nil)
        }

        // The user moved the window out of the way, so stay where they were.
        // The swipe must come after the mouse-up, or the window rides back.
        let returnHome = move.home.flatMap { $0 == move.targetID ? nil : $0 }
        if let returnHome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.startSwitch(spaceID: returnHome, displayID: move.displayID)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let done = moved && self.window(window.windowID, isOn: move.targetID)
            logger.notice("Move \(window.ownerName, privacy: .public) window \(window.windowID) to desktop \(move.targetID): \(done ? "done" : "failed", privacy: .public)")
            if done {
                self.grabMemory.remember(point: move.grab, in: move.frame, buttonFrame: move.buttonFrame, for: move.appKey)
                self.undoProbeShift(move)
                if let targetKey = move.targetKey {
                    self.onDidMoveWindow?(window.windowID, targetKey, move.displayID)
                }
                if returnHome == nil {
                    self.performFocus(pid: window.pid, windowID: window.windowID)
                }
            } else {
                self.grabMemory.invalidate(for: move.appKey)
                NSSound.beep()
            }
            self.refresh()
        }
    }

    /// A window that follows the mouse with a delay can arrive a few points off, by the length
    /// of the probe drag. It is put where it was; a window that is anywhere else was placed
    /// there on purpose and is left alone.
    private func undoProbeShift(_ move: WindowMove) {
        let axWin = move.axWindow ?? quickAXWindow(pid: move.window.pid, windowID: move.window.windowID, timeout: 0.1)
        guard let now = cgWindowOrigin(windowID: move.window.windowID) ?? axWin.flatMap({ frame(of: $0)?.origin }),
              SpaceBarController.isProbeShift(from: move.origin, to: now),
              let axWin else { return }
        logger.notice("Move: putting the window back from \(String(describing: now), privacy: .public) to \(String(describing: move.origin), privacy: .public)")
        var origin = move.origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, value)
    }

    /// Whether a window ended up off its place by no more than a probe drag and a little.
    nonisolated static func isProbeShift(from origin: CGPoint, to now: CGPoint) -> Bool {
        let dx = abs(now.x - origin.x)
        let dy = abs(now.y - origin.y)
        return (dx > 0 || dy > 0) && dx <= 18 && dy <= 18
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = []
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Where to press to drag the window. A spot Accessibility confirms (or a cached anchor) is
    /// tried immediately; guessed spots are probed one by one.
    private struct GrabPlan {
        let points: [CGPoint]
        let isGuess: Bool
        var usedCache: Bool = false
    }

    private enum GrabPlanOutcome {
        case ready(GrabPlan)
        case retrySlowAX
        case none
    }

    /// Maximum fallback spots probed lazily when a confirmed or cached spot does not drag.
    private static let fallbackLimit = 8
    /// Maximum spots probed when the window has no confirmed native chrome spot.
    private static let probeLimit = 10

    private func titleBarButtonFrame(of window: AXUIElement) -> CGRect? {
        buttonFrame(kAXZoomButtonAttribute, of: window)
            ?? buttonFrame(kAXFullScreenButtonAttribute, of: window)
            ?? buttonFrame(kAXCloseButtonAttribute, of: window)
    }

    /// Center of the window's native AXTitleUIElement when it sits inside the top title-bar strip.
    private func titleElementCenter(in window: AXUIElement, frame: CGRect) -> CGPoint? {
        guard let titleEl = elementAttribute(kAXTitleUIElementAttribute, of: window),
              let titleFrame = self.frame(of: titleEl),
              titleFrame.width >= 8, titleFrame.height >= 6,
              titleFrame.minY >= frame.minY,
              titleFrame.maxY <= frame.minY + DesktopMoveGrabPlanner.maxTitleBarHeight else {
            return nil
        }
        return CGPoint(x: titleFrame.midX, y: titleFrame.midY)
    }

    /// Bounded Accessibility walk of the top strip (max depth 4, max 80 nodes, skips web/scroll
    /// subtrees) that collects frames of interactive controls so we can compute empty gaps between them.
    private func topStripObstacles(in window: AXUIElement, frame: CGRect) -> [CGRect] {
        var obstacles: [CGRect] = []
        for attr in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute] {
            if let rect = buttonFrame(attr, of: window) {
                obstacles.append(rect)
            }
        }
        let stripMaxY = frame.minY + DesktopMoveGrabPlanner.maxTitleBarHeight
        var visited = 0
        let maxVisited = 80

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 4, visited < maxVisited else { return }
            for child in children(of: element) {
                visited += 1
                guard visited <= maxVisited else { return }
                let role = stringAttribute(kAXRoleAttribute, of: child) ?? ""
                let subrole = stringAttribute(kAXSubroleAttribute, of: child)

                // Never walk into web page content or scroll views
                if role == "AXWebArea" || role == "AXScrollArea" { continue }

                let childFrame = self.frame(of: child)
                if let childFrame, childFrame.minY > stripMaxY { continue }

                // A tab group often spans the full bar width with empty draggable space after the
                // last tab; record individual tab children as obstacles instead of the whole group.
                if role == "AXTabGroup" {
                    let tabChildren = children(of: child)
                    if !tabChildren.isEmpty {
                        walk(child, depth: depth + 1)
                        continue
                    }
                }

                let isControl = DesktopMoveGrabPlanner.controlRoles.contains(role)
                    || (subrole.map { DesktopMoveGrabPlanner.controlSubroles.contains($0) } ?? false)
                if isControl {
                    if let childFrame, childFrame.width > 0, childFrame.height > 0, childFrame.maxY >= frame.minY {
                        obstacles.append(childFrame)
                    }
                    continue
                }

                if depth < 4 {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(window, depth: 1)
        return obstacles
    }

    /// Fast, non-blocking primary grab plan. Computes fallback candidates lazily only if needed.
    private func primaryGrabPlan(
        in window: AXUIElement, frame: CGRect, button: CGRect?, pid: pid_t,
        appKey: String, windows: [(pid: pid_t, frame: CGRect)], didRetrySlowAX: Bool
    ) -> GrabPlanOutcome {
        let systemWide = AXUIElementCreateSystemWide()

        // 0. Per-app session anchor memory: re-verify it is still on top and not over a control.
        if let cached = grabMemory.resolve(for: appKey, in: frame, buttonFrame: button),
           SpaceBarController.windowIsOnTop(pid: pid, at: cached, among: windows),
           let info = classifySpot(at: cached, frame: frame, pid: pid, systemWide: systemWide),
           info.tier != .control {
            return .ready(GrabPlan(points: [cached], isGuess: false, usedCache: true))
        }

        // 1. Spots right next to the traffic lights (instant path for standard macOS apps).
        var firstWebOrContainer: CGPoint?
        if let button {
            let nextToButtons = [10.0, 28.0, 56.0].map { CGPoint(x: button.maxX + $0, y: button.midY) }
            for point in nextToButtons where frame.contains(point) {
                guard SpaceBarController.windowIsOnTop(pid: pid, at: point, among: windows),
                      let info = classifySpot(at: point, frame: frame, pid: pid, systemWide: systemWide) else { continue }
                if info.tier == .chrome {
                    return .ready(GrabPlan(points: [point], isGuess: false))
                }
                if info.tier == .webOrContainer && firstWebOrContainer == nil {
                    firstWebOrContainer = point
                }
            }
        }

        // 2. Native window title element (`AXTitleUIElement`), if unobstructed and outside controls.
        if let titlePoint = titleElementCenter(in: window, frame: frame),
           SpaceBarController.windowIsOnTop(pid: pid, at: titlePoint, among: windows),
           let info = classifySpot(at: titlePoint, frame: frame, pid: pid, systemWide: systemWide),
           info.tier == .chrome {
            return .ready(GrabPlan(points: [titlePoint], isGuess: false))
        }

        // 3. Structural empty gaps between top-strip controls (tabs, buttons, search fields).
        let obstacles = topStripObstacles(in: window, frame: frame)
        let rows = DesktopMoveGrabPlanner.titleBarRows(for: frame, buttonFrame: button)
        if let primaryRow = rows.first {
            let primaryGaps = DesktopMoveGrabPlanner.emptyGapMidpoints(in: frame, rowY: primaryRow, obstacles: obstacles)
            for point in primaryGaps.prefix(3) where frame.contains(point) {
                guard SpaceBarController.windowIsOnTop(pid: pid, at: point, among: windows),
                      let info = classifySpot(at: point, frame: frame, pid: pid, systemWide: systemWide) else { continue }
                if info.tier == .chrome {
                    return .ready(GrabPlan(points: [point], isGuess: false))
                }
            }
        }

        // 4. Sidebar-tab browsers (Zen, Arc) hide traffic lights and keep toolbar space along the top.
        let alongTop = [frame.midX, frame.minX + 90, frame.minX + 20, frame.minX + 50, frame.minX + 130, frame.maxX - 60, frame.maxX - 150]
            .map { CGPoint(x: $0, y: frame.minY + 10) }
        var firstChromeAlongTop: CGPoint?
        for point in alongTop where frame.contains(point) {
            guard SpaceBarController.windowIsOnTop(pid: pid, at: point, among: windows),
                  let info = classifySpot(at: point, frame: frame, pid: pid, systemWide: systemWide) else { continue }
            if info.tier == .chrome && info.inToolbar {
                return .ready(GrabPlan(points: [point], isGuess: false))
            }
            if info.tier == .chrome && firstChromeAlongTop == nil {
                firstChromeAlongTop = point
            }
        }
        if button == nil && !didRetrySlowAX && firstWebOrContainer == nil {
            return .retrySlowAX
        }
        if let point = firstChromeAlongTop {
            return .ready(GrabPlan(points: [point], isGuess: false))
        }

        // 5. Multi-row adaptive probe plan (Electron/web title bars, frameless and Wine windows).
        let probePoints = buildProbeCandidates(
            leading: firstWebOrContainer,
            excluding: [],
            frame: frame,
            button: button,
            obstacles: obstacles,
            pid: pid,
            windows: windows,
            systemWide: systemWide,
            limit: Self.probeLimit
        )
        return probePoints.isEmpty ? .none : .ready(GrabPlan(points: probePoints, isGuess: true))
    }

    /// Lazily built fallback candidates when a confirmed or cached spot did not drag the window.
    private func fallbackSpots(
        after failed: CGPoint, in window: AXUIElement, frame: CGRect, button: CGRect?, pid: pid_t
    ) -> [CGPoint] {
        let windows = SpaceBarController.windowsFrontToBack()
        let systemWide = AXUIElementCreateSystemWide()
        let obstacles = topStripObstacles(in: window, frame: frame)
        var extraLeading: [CGPoint] = []
        if let titlePoint = titleElementCenter(in: window, frame: frame) {
            extraLeading.append(titlePoint)
        }
        if let button {
            extraLeading += [10.0, 28.0, 56.0].map { CGPoint(x: button.maxX + $0, y: button.midY) }
        }
        return buildProbeCandidates(
            leading: nil,
            extraLeading: extraLeading,
            excluding: [failed],
            frame: frame,
            button: button,
            obstacles: obstacles,
            pid: pid,
            windows: windows,
            systemWide: systemWide,
            limit: Self.fallbackLimit
        )
    }

    /// Combines structural empty gaps and width-adaptive X sweeps across all title-bar rows,
    /// rejects any spot inside a control or covered by another window, and orders by hit tier.
    private func buildProbeCandidates(
        leading: CGPoint?,
        extraLeading: [CGPoint] = [],
        excluding: [CGPoint],
        frame: CGRect,
        button: CGRect?,
        obstacles: [CGRect],
        pid: pid_t,
        windows: [(pid: pid_t, frame: CGRect)],
        systemWide: AXUIElement,
        limit: Int
    ) -> [CGPoint] {
        var raw: [CGPoint] = []
        if let leading { raw.append(leading) }
        raw.append(contentsOf: extraLeading)

        let rows = DesktopMoveGrabPlanner.titleBarRows(for: frame, buttonFrame: button)
        for (rowIndex, rowY) in rows.enumerated() {
            raw.append(contentsOf: DesktopMoveGrabPlanner.emptyGapMidpoints(in: frame, rowY: rowY, obstacles: obstacles))
            let rowButtonsMaxX: CGFloat? = (rowIndex == 0) ? button?.maxX : nil
            let xs = DesktopMoveGrabPlanner.adaptiveXs(in: frame, buttonsMaxX: rowButtonsMaxX)
            raw.append(contentsOf: xs.map { CGPoint(x: $0, y: rowY) })
        }

        // Pre-deduplicate raw points so we issue minimal AX IPCs while keeping every row covered.
        var dedupedRaw: [CGPoint] = []
        for point in raw where frame.contains(point) {
            if excluding.contains(where: { abs($0.x - point.x) < 20 && abs($0.y - point.y) < 20 }) {
                continue
            }
            if dedupedRaw.contains(where: { abs($0.x - point.x) < 18 && abs($0.y - point.y) < 18 }) {
                continue
            }
            dedupedRaw.append(point)
            if dedupedRaw.count >= 24 { break }
        }

        var classified: [(point: CGPoint, tier: GrabHitTier)] = []
        for point in dedupedRaw {
            guard SpaceBarController.windowIsOnTop(pid: pid, at: point, among: windows),
                  let info = classifySpot(at: point, frame: frame, pid: pid, systemWide: systemWide),
                  info.tier != .control else { continue }
            classified.append((point, info.tier))
        }

        // Keep an explicit leading web/title-bar spot (e.g. Vivaldi next-to-buttons) first.
        if let leading, let idx = classified.firstIndex(where: { $0.point == leading }) {
            let lead = classified.remove(at: idx)
            let rest = DesktopMoveGrabPlanner.prioritizeCandidates(
                classified, excluding: excluding + [lead.point], limit: max(0, limit - 1)
            )
            return [lead.point] + rest
        }
        return DesktopMoveGrabPlanner.prioritizeCandidates(classified, excluding: excluding, limit: limit)
    }

    /// The spots to probe after `failed`: none close to it or to one another, at most `limit`.
    nonisolated static func fallbackOrder(after failed: CGPoint, candidates: [CGPoint], limit: Int) -> [CGPoint] {
        Array(probeOrder(first: failed, then: candidates).dropFirst().prefix(limit))
    }

    /// The spots to probe when the first one is itself a guess: it stays first, and guessed
    /// spots too close to it or to each other are left out, as they are the same part of the bar.
    nonisolated static func probeOrder(first: CGPoint, then guesses: [CGPoint]) -> [CGPoint] {
        var result = [first]
        for point in guesses where !result.contains(where: { abs($0.x - point.x) < 24 && abs($0.y - point.y) < 24 }) {
            result.append(point)
        }
        return result
    }

    /// Real app windows on screen, front to back, with their owner and frame (top-left origin).
    /// Excludes system overlay layers (such as Dock's full-screen layer-20 window and Window Server)
    /// and Rapto's own windows (the active-window border is click-through, and clickable Rapto
    /// windows such as the group indicator are still caught by AX hit-testing `hitPID == pid`).
    private static func windowsFrontToBack() -> [(pid: pid_t, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard DesktopMoveGrabPlanner.isBlockingWindow(
                layer: layer, owner: owner, alpha: alpha, pid: pid, ownPID: ownPID
            ) else { return nil }
            return (pid, CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// Whether the frontmost window at `point` belongs to the app: a press on a spot covered
    /// by something else, such as Rapto's own group indicator, would land on that instead.
    nonisolated static func windowIsOnTop(pid: pid_t, at point: CGPoint, among windows: [(pid: pid_t, frame: CGRect)]) -> Bool {
        windows.first { $0.frame.contains(point) }?.pid == pid
    }

    /// Where along a title bar to look for a spot that drags the window, in the order to try.
    nonisolated static func guessedGrabXs(buttonsMaxX: CGFloat, frameMinX: CGFloat, frameMaxX: CGFloat) -> [CGFloat] {
        let midX = (frameMinX + frameMaxX) / 2
        let candidates = [
            midX, buttonsMaxX + 120, buttonsMaxX + 200, frameMaxX - 150, frameMaxX - 60,
            buttonsMaxX + 280, midX - 220, midX + 220, buttonsMaxX + 60, frameMaxX - 260
        ]
        var result: [CGFloat] = []
        for x in candidates where x > buttonsMaxX + 4 && x < frameMaxX - 4 {
            // Spots closer than this are most likely the same part of the title bar
            if !result.contains(where: { abs($0 - x) < 24 }) {
                result.append(x)
            }
        }
        return result
    }

    nonisolated enum GuessKind { case page, other, control }

    nonisolated static func guessKind(forRole role: String) -> GuessKind {
        if role == "AXWebArea" { return .page }
        return DesktopMoveGrabPlanner.controlRoles.contains(role) ? .control : .other
    }

    /// Performs one Accessibility hit test and classifies its full ancestor chain up to `AXWindow`.
    private func classifySpot(
        at point: CGPoint, frame: CGRect, pid: pid_t, systemWide: AXUIElement
    ) -> (tier: GrabHitTier, inToolbar: Bool)? {
        guard frame.contains(point) else { return nil }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit else {
            logger.notice("Move: nothing at \(String(describing: point), privacy: .public) (\(status.rawValue))")
            return nil
        }
        var hitPID: pid_t = 0
        AXUIElementGetPid(hit, &hitPID)
        let chain = hitChain(of: hit)
        let summary = chain.prefix(5).map(\.role).joined(separator: " < ")
        logger.notice("Move: at \(String(describing: point), privacy: .public) pid \(hitPID) roles \(summary, privacy: .public)")
        guard hitPID == pid else { return nil }
        let tier = DesktopMoveGrabPlanner.classifyHitChain(chain)
        let inToolbar = chain.contains { $0.role == kAXToolbarRole }
        return (tier, inToolbar)
    }

    private func hitChain(of element: AXUIElement) -> [(role: String, subrole: String?)] {
        var result: [(role: String, subrole: String?)] = []
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let node = current else { break }
            let role = stringAttribute(kAXRoleAttribute, of: node) ?? "?"
            let subrole = stringAttribute(kAXSubroleAttribute, of: node)
            result.append((role, subrole))
            if role == kAXWindowRole { break }
            current = elementAttribute(kAXParentAttribute, of: node)
        }
        return result
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func buttonFrame(_ attribute: String, of window: AXUIElement) -> CGRect? {
        guard let button = elementAttribute(attribute, of: window),
              let frame = frame(of: button), frame.width > 0 else { return nil }
        return frame
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func whenOnScreen(_ spaceID: UInt64, displayID: String, fastSettle: Bool = false, run: @escaping () -> Bool) {
        askForSwitchPermissionIfNeeded()
        actionToken += 1
        let token = actionToken
        let settleDelay: TimeInterval = fastSettle ? 0.12 : 0.4
        pendingAction = (spaceID, displayID, token, settleDelay, run)
        if !spaceIsCurrent(spaceID, on: displayID) {
            startSwitch(spaceID: spaceID, displayID: displayID)
        }
        // Under Window Flow's curtain, poll frequently so the instant DockSpaceSwipe raises the
        // target window behind the curtain instead of 600 ms later in plain view.
        if fastSettle {
            for delay in stride(from: 0.025, through: 0.9, by: 0.025) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tryPendingAction(token: token)
                }
            }
            for delay in stride(from: 1.2, through: 4.8, by: 0.4) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tryPendingAction(token: token)
                }
            }
        } else {
            // The desktop id changes before the animation finishes. Act only on a
            // later attempt, once that desktop has stayed current.
            // A dropped swipe is sent again after a second, so keep trying for a while.
            for delay in stride(from: 0.2, through: 4.8, by: 0.4) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tryPendingAction(token: token)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.pendingAction?.token == token {
                self?.pendingAction = nil
            }
        }
    }

    // MARK: - Right-click menu

    func updateSegmentFrames(_ frames: [UInt64: CGRect], for displayID: String) {
        segmentFrames[displayID] = frames
    }

    func updateGlyphFrames(_ frames: [SpaceBarGlyphKey: CGRect], for displayID: String) {
        glyphFrames[displayID] = frames
    }

    nonisolated static func hitGlyphPID(
        at point: CGPoint,
        in spaceID: UInt64,
        glyphFrames: [SpaceBarGlyphKey: CGRect]
    ) -> pid_t? {
        glyphFrames.first { key, frame in
            key.spaceID == spaceID && frame.insetBy(dx: -1, dy: -2).contains(point)
        }?.key.pid
    }

    /// The desktop segment nearest to this x position in the pill.
    func spaceID(atX x: CGFloat, displayID: String) -> UInt64? {
        segmentFrames[displayID]?.min { distance(x, to: $0.value) < distance(x, to: $1.value) }?.key
    }

    fileprivate func showMenu(for event: NSEvent, in view: NSView, displayID: String) {
        let point = view.convert(event.locationInWindow, from: nil)
        let swiftUIPoint = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        guard let spaceID = spaceID(atX: point.x, displayID: displayID),
              let space = displays.first(where: { $0.id == displayID })?.spaces.first(where: { $0.id == spaceID }),
              !space.isFullScreen else { return }
        let hitGlyph = Self.hitGlyphPID(
            at: swiftUIPoint,
            in: spaceID,
            glyphFrames: glyphFrames[displayID] ?? [:]
        ).flatMap { pid in
            space.glyphs.first { $0.pid == pid }
        }
        guard let menu = menuBuilder?(space, hitGlyph, displayID) else { return }
        // A hover-only pill would hide while the pointer is over the menu.
        isShowingMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        isShowingMenu = false
        handlePointer(NSEvent.mouseLocation)
    }

    private func distance(_ x: CGFloat, to frame: CGRect) -> CGFloat {
        if x < frame.minX { return frame.minX - x }
        if x > frame.maxX { return x - frame.maxX }
        return 0
    }

    private func startSwitch(spaceID: UInt64, displayID: String) {
        switchGeneration += 1
        let generation = switchGeneration
        // The click is still the current mouse event. Posting the swipe on the
        // next turn lets that event finish first.
        DispatchQueue.main.async { [weak self] in
            self?.step(toward: spaceID, on: displayID, generation: generation, remaining: 8)
        }
    }

    /// macOS drops the desktop swipe unless this app is allowed to control the computer.
    private func askForSwitchPermissionIfNeeded() {
        guard !AXIsProcessTrusted(), !didAskForSwitchPermission else { return }
        didAskForSwitchPermission = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Sends every swipe to the target desktop at once. If some were dropped,
    /// sends the rest once the Dock has settled. Retrying sooner reads a
    /// half-finished switch and overshoots, which on macOS 27 freezes the Dock.
    private func step(
        toward spaceID: UInt64, on displayID: String, generation: Int, remaining: Int, resentDropped: Bool = false
    ) {
        guard generation == switchGeneration, remaining > 0 else { return }
        guard let layout = desktopLayout(on: displayID),
              let target = layout.ids.firstIndex(of: spaceID) else { return }
        if layout.currentIndex == target {
            return
        }
        let before = layout.currentIndex
        DockSpaceSwipe.post(towardHigherIndex: target > before, count: abs(target - before))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, generation == self.switchGeneration,
                  let latest = self.desktopLayout(on: displayID), latest.currentIndex != target else { return }
            // Right after Mission Control closes the Dock can drop the whole swipe. Send it
            // once more, never in a loop: a Dock that keeps ignoring swipes must be left alone.
            var resent = resentDropped
            if latest.currentIndex == before {
                guard !resentDropped, !self.isMissionControlOpen else {
                    debugLog("SpaceBar", "Switch to desktop \(spaceID): swipe was dropped again, giving up")
                    return
                }
                debugLog("SpaceBar", "Switch to desktop \(spaceID): swipe was dropped, sending it again")
                resent = true
            }
            self.step(toward: spaceID, on: displayID, generation: generation, remaining: remaining - 1, resentDropped: resent)
        }
    }

    private func spaceIsCurrent(_ spaceID: UInt64, on displayID: String) -> Bool {
        guard let layout = desktopLayout(on: displayID),
              let index = layout.ids.firstIndex(of: spaceID) else { return false }
        return layout.currentIndex == index
    }

    // MARK: - Workaround:
    // Cause: Activating a window while its desktop is hidden or still animating either does
    //        nothing or moves the window to the visible desktop.
    // Context: The icon and the menu act only once the target desktop has settled on screen.
    private func tryPendingAction(token: Int) {
        noteCurrentSpaces()
        guard let pending = pendingAction, pending.token == token else { return }
        guard spaceHasSettled(pending.spaceID, on: pending.displayID, minAge: pending.settleDelay) else { return }
        guard pending.run() else { return }
        if pendingAction?.token == token {
            pendingAction = nil
        }
    }

    private func spaceHasSettled(_ spaceID: UInt64, on displayID: String, minAge: TimeInterval = 0.4) -> Bool {
        guard let known = spaceBecameCurrent[displayID], known.id == spaceID else { return false }
        return Date().timeIntervalSince(known.at) >= minAge
    }

    private func noteCurrentSpaces() {
        let connection = SpaceBarMainConnectionID()
        guard let rawDisplays = SpaceBarCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return }
        let now = Date()
        for display in rawDisplays {
            guard let displayID = display["Display Identifier"] as? String,
                  let currentID = (display["Current Space"] as? [String: Any]).flatMap({ spaceID(from: $0) }) else { continue }
            if spaceBecameCurrent[displayID]?.id != currentID {
                spaceBecameCurrent[displayID] = (currentID, now)
            }
        }
    }

    private func window(_ windowID: CGWindowID, isOn spaceID: UInt64) -> Bool {
        spaceIDs(for: windowID, connection: SpaceBarMainConnectionID()).contains(spaceID)
    }

    private func focusViaWindowServer(pid: pid_t, windowID: UInt32) {
        // LaunchServices activation pulls App-Napped Catalyst/background apps awake immediately,
        // then `_SLPSSetFrontProcessWithOptions` raises the specific window above slot neighbors.
        NSRunningApplication(processIdentifier: pid)?.activate()
        var psn = ProcessSerialNumber()
        if let frontProcess, SpaceBarGetProcessForPID(pid, &psn) == 0 {
            let status = frontProcess(&psn, windowID, spaceBarFocusWindowOnly)
            if status != 0 {
                debugLog("SpaceBar", "Focus window \(windowID) failed: \(status)")
            }
        }
    }

    private func performFocus(pid: pid_t, windowID: UInt32) {
        focusViaWindowServer(pid: pid, windowID: windowID)
        // The window server call above still brings a hung app's window to the front
        guard AppResponsiveness.isResponding(pid) else { return }
        let application = AXUIElementCreateApplication(pid)
        if let axWindow = axWindow(pid: pid, windowID: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        guard AppResponsiveness.isResponding(pid) else { return }
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Non-banning AX window lookup with a short per-element timeout so an App-Napped app waking up
    /// on another desktop does not stall the move for 1 s or get flagged as hung.
    private func quickAXWindowProbe(
        pid: pid_t, windowID: UInt32, timeout: Float = quickAXTimeout
    ) -> (element: AXUIElement?, outcome: DesktopMoveAXProbeOutcome) {
        guard !AppResponsiveness.shared.notRespondingPIDs.contains(pid) else {
            return (nil, .unavailable)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var windowsRef: CFTypeRef?
        let started = CFAbsoluteTimeGetCurrent()
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
        let waited = CFAbsoluteTimeGetCurrent() - started
        let matched = (result == .success)
            ? (windowsRef as? [AXUIElement]).flatMap { Self.matchingAXWindow(windowID: windowID, in: $0) }
            : nil
        if result == .success {
            AppResponsiveness.shared.noteResponded(pid)
        }
        let outcome = DesktopMoveGrabPlanner.classifyQuickAXProbe(
            error: result,
            waited: waited,
            timeout: TimeInterval(timeout),
            foundWindow: matched != nil
        )
        return (matched, outcome)
    }

    private func quickAXWindow(pid: pid_t, windowID: UInt32, timeout: Float = quickAXTimeout) -> AXUIElement? {
        quickAXWindowProbe(pid: pid, windowID: windowID, timeout: timeout).element
    }

    private func axWindow(pid: pid_t, windowID: UInt32) -> AXUIElement? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(pid) {
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
        }
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return nil }
        return Self.matchingAXWindow(windowID: windowID, in: windows)
    }

    private nonisolated static func matchingAXWindow(windowID: UInt32, in windows: [AXUIElement]) -> AXUIElement? {
        for window in windows {
            var id: CGWindowID = 0
            if SpaceBarAXGetWindow(window, &id) == .success {
                if id == windowID { return window }
                continue
            }
            var idRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "_AXWindowID" as CFString, &idRef) == .success,
                  let number = idRef as? NSNumber,
                  number.uint32Value == windowID else { continue }
            return window
        }
        return nil
    }

    func currentDesktopID(on displayID: String) -> UInt64? {
        desktopLayout(on: displayID).map { $0.ids[$0.currentIndex] }
    }

    private func desktopLayout(on displayID: String) -> (currentIndex: Int, ids: [UInt64])? {
        let connection = SpaceBarMainConnectionID()
        guard let rawDisplays = SpaceBarCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return nil }
        for display in rawDisplays {
            guard let id = display["Display Identifier"] as? String, id == displayID,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let currentID = (display["Current Space"] as? [String: Any]).flatMap { spaceID(from: $0) }
            var ids: [UInt64] = []
            var currentIndex: Int?
            // Swipes go through full screen apps too, so they count here.
            for space in spaces {
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0 || type == fullScreenSpaceType, let sid = spaceID(from: space) else { continue }
                if sid == currentID { currentIndex = ids.count }
                ids.append(sid)
            }
            guard let currentIndex else { return nil }
            return (currentIndex, ids)
        }
        return nil
    }

    func updateSize(_ size: CGSize, for displayID: String) {
        guard size.width > 1, size.height > 1, let panel = panels[displayID] else { return }
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        guard let screen = screen(forDisplayID: displayID) else { return }
        place(panel, on: screen, size: size)
    }

    // MARK: - Refresh

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in names {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    controller.hiddenByPID.removeAll()
                    controller.refresh()
                }
            }
            observers.append(observer)
        }
        let flashObserver = workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.flashHoverPanels() }
        }
        observers.append(flashObserver)
        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.refresh() }
        }
        observers.append(screenObserver)

        updateTimer()
    }

    // MARK: - Pointer Tracking

    // Every pointer move wakes the app while a monitor is installed, which costs CPU
    // all the time the mouse moves. Install it only while a pill has to react to
    // the pointer: hover-only pills, and pills hidden along with the menu bar.
    private func updatePointerTracking(needed: Bool) {
        if needed, globalMouseMonitor == nil {
            let handler: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let controller = self else { return }
                    controller.revealIfPointerAtTop()
                    controller.handlePointer(NSEvent.mouseLocation)
                }
            }
            let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents, handler: handler)
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { event in
                handler(event)
                return event
            }
        } else if !needed, let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
            if let local = localMouseMonitor {
                NSEvent.removeMonitor(local)
                localMouseMonitor = nil
            }
        }
    }

    // MARK: - Hover

    // MARK: - Workaround:
    // Cause: On a full-screen desktop macOS hides the menu bar, but the screen size
    //        (visibleFrame) doesn't show that, and the bar stayed on top of video.
    // Context: A display's current desktop is full screen if its type in the desktop list is not 0.
    //          The bar then behaves as in "on hover" mode and slides out together with
    //          the menu bar when the pointer is at the top edge.
    private func isHoverOnly(_ screen: NSScreen, displayID: String) -> Bool {
        if fullscreenDisplays.contains(displayID) { return true }
        switch presentation {
        case .always: return false
        case .onHover: return true
        case .automatic: return hasNotch(screen)
        }
    }

    private func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// The pointer opens the pill here: the notch, or the middle of the menu bar.
    private func hoverZone(on screen: NSScreen, panel: NSPanel) -> CGRect {
        let menuBar = max(menuBarHeight(of: screen), screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        var width = max(panel.frame.width, 200)
        if hasNotch(screen), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = screen.frame.width - left.width - right.width
        }
        // One point taller: at the very top edge the pointer sits on maxY, which a rect does not contain.
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - menuBar, width: width, height: menuBar + 1)
    }

    /// The notch rectangle in AppKit coordinates when `screen` hides its Desktops Bar
    /// until the pointer hovers the notch; nil on non-notched screens or when always shown.
    func notchAnchor(on screen: NSScreen) -> NSRect? {
        guard isEnabled, hasNotch(screen) else { return nil }
        let displayID = displayUUID(for: screen)
        guard !displayID.isEmpty, isHoverOnly(screen, displayID: displayID) else { return nil }
        let menuBar = max(menuBarHeight(of: screen), screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        var width: CGFloat = 200
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max(120, screen.frame.width - left.width - right.width)
        }
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - menuBar, width: width, height: menuBar)
    }

    private func handlePointer(_ mouse: NSPoint) {
        for (displayID, panel) in panels {
            guard let screen = screensByDisplay[displayID], isHoverOnly(screen, displayID: displayID) else { continue }
            if pointer(mouse, keeps: panel, on: screen, displayID: displayID) {
                let wasRevealed = revealed.contains(displayID)
                reveal(displayID)
                if !wasRevealed && revealed.contains(displayID) {
                    onUserRevealedHoverBar?()
                    NotificationCenter.default.post(name: .raptoTourDidRevealNotchBar, object: nil)
                }
            } else if revealed.contains(displayID) {
                scheduleHide(displayID)
            }
        }
    }

    private func pointer(_ mouse: NSPoint, keeps panel: NSPanel, on screen: NSScreen, displayID: String) -> Bool {
        if hoverZone(on: screen, panel: panel).contains(mouse) { return true }
        // The gap between the notch and the pill must not close it.
        return revealed.contains(displayID) && panel.frame.insetBy(dx: -12, dy: -12).contains(mouse)
    }

    private func reveal(_ displayID: String) {
        hideWork[displayID]?.cancel()
        hideWork[displayID] = nil
        guard !revealed.contains(displayID), let panel = panels[displayID] else { return }
        revealed.insert(displayID)
        refresh()
        panel.ignoresMouseEvents = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleHide(_ displayID: String) {
        guard hideWork[displayID] == nil else { return }
        let flashLeft = flashUntil[displayID].map { $0.timeIntervalSinceNow } ?? 0
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork[displayID] = nil
            guard let panel = self.panels[displayID], let screen = self.screen(forDisplayID: displayID) else { return }
            guard self.isHoverOnly(screen, displayID: displayID) else {
                self.revealed.remove(displayID)
                return
            }
            let keep = self.isShowingMenu || self.isMovingWindow || self.isAddingDesktop || self.activeGlyphDrag != nil
                || self.pointer(NSEvent.mouseLocation, keeps: panel, on: screen, displayID: displayID)
            if keep {
                self.scheduleHide(displayID)
                return
            }
            self.revealed.remove(displayID)
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
        }
        hideWork[displayID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.35, flashLeft), execute: work)
    }

    /// Show a hover-only pill for a moment after a desktop switch, so the new desktop is visible.
    private func flashHoverPanels() {
        refresh()
        for (displayID, _) in panels {
            guard let screen = screen(forDisplayID: displayID), isHoverOnly(screen, displayID: displayID),
                  !fullscreenDisplays.contains(displayID) else { continue }
            flashUntil[displayID] = Date().addingTimeInterval(1.2)
            reveal(displayID)
            hideWork[displayID]?.cancel()
            hideWork[displayID] = nil
            scheduleHide(displayID)
        }
    }

    /// A hover-only pill stays ordered in, but is clear and lets clicks through until revealed.
    private func applyPresentation(to panel: NSPanel, displayID: String, on screen: NSScreen) {
        let visible = !isHoverOnly(screen, displayID: displayID) || revealed.contains(displayID)
        panel.ignoresMouseEvents = !visible
        if !visible {
            panel.alphaValue = 0
        } else if !revealed.contains(displayID) {
            panel.alphaValue = 1
        }
    }

    private func refresh() {
        guard isEnabled else {
            for panel in panels.values { panel.orderOut(nil) }
            return
        }
        readMenuBarAppearance()
        let snapshot = makeSnapshot()
        let nextFingerprint = fingerprint(of: snapshot)
        if nextFingerprint != fingerprint {
            fingerprint = nextFingerprint
            displays = snapshot
        }
        noteCurrentSpaces()
        layoutPanels()
    }

    private func applyVisibility() {
        updateTimer()
        if isEnabled {
            refresh()
        } else {
            endGlyphDrag()
            for panel in panels.values {
                panel.orderOut(nil)
            }
            updatePointerTracking(needed: false)
        }
    }

    private func updateTimer() {
        if isEnabled, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in controller.refresh() }
            }
        } else if !isEnabled {
            timer?.invalidate()
            timer = nil
        }
    }

    private func revealIfPointerAtTop() {
        let now = Date()
        guard now.timeIntervalSince(lastPointerCheck) > 0.25 else { return }
        guard panels.values.contains(where: { !$0.isVisible }) else { return }
        let mouse = NSEvent.mouseLocation
        let nearTop = NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX && screen.frame.maxY - mouse.y < 8
        }
        guard nearTop else { return }
        lastPointerCheck = now
        refresh()
    }

    // MARK: - Snapshot

    private let fullScreenSpaceType = 4

    private struct Desktop {
        let id: UInt64
        let key: String
        let number: Int
        let isCurrent: Bool
        /// Set for a full screen app's space: the app it belongs to.
        let fullScreenPID: pid_t?

        var isFullScreen: Bool { fullScreenPID != nil }
    }

    private struct DesktopMap {
        var desktopsByDisplay: [String: [Desktop]] = [:]
        var knownIDs = Set<UInt64>()
        var currentIDs = Set<UInt64>()
        var displayBySpace: [UInt64: String] = [:]
    }

    private func makeSnapshot() -> [SpaceBarDisplay] {
        let connection = SpaceBarMainConnectionID()
        guard let map = readDesktops(connection: connection) else { return [] }

        var windowsBySpace: [UInt64: [pid_t: [SpaceBarWindowRef]]] = [:]
        var appOrder: [UInt64: [pid_t]] = [:]

        for (window, ids) in placedWindows(in: map, connection: connection) {
            for spaceID in ids {
                var order = appOrder[spaceID] ?? []
                if !order.contains(window.pid) {
                    order.append(window.pid)
                }
                appOrder[spaceID] = order

                var grouped = windowsBySpace[spaceID] ?? [:]
                var windows = grouped[window.pid] ?? []
                windows.append(window.ref)
                grouped[window.pid] = windows
                windowsBySpace[spaceID] = grouped
            }
        }

        return map.desktopsByDisplay.map { displayID, desktops in
            let spaces = desktops.map { desktop -> SpaceBarSpace in
                var order = appOrder[desktop.id] ?? []
                let grouped = windowsBySpace[desktop.id] ?? [:]
                if let pid = desktop.fullScreenPID, order.isEmpty {
                    order = [pid]
                }
                let glyphs = order.map { pid in
                    let windows = grouped[pid] ?? []
                    let runningApp = NSRunningApplication(processIdentifier: pid)
                    return SpaceBarGlyph(
                        pid: pid,
                        bundleIdentifier: AppBundleLookup.bundleIdentifier(for: runningApp),
                        appName: windows.first?.ownerName ?? runningApp?.localizedName ?? "App",
                        icon: icon(for: pid),
                        windows: windows
                    )
                }
                return SpaceBarSpace(
                    id: desktop.id,
                    key: desktop.key,
                    number: desktop.number,
                    isCurrent: desktop.isCurrent,
                    isFullScreen: desktop.isFullScreen,
                    glyphs: glyphs
                )
            }
            return SpaceBarDisplay(id: displayID, spaces: spaces)
        }
        .sorted { $0.id < $1.id }
    }

    private func readDesktops(connection: SpaceBarConnectionID) -> DesktopMap? {
        guard let rawDisplays = SpaceBarCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
            return nil
        }
        var map = DesktopMap()

        for display in rawDisplays {
            guard let displayID = display["Display Identifier"] as? String, !displayID.isEmpty,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let current = display["Current Space"] as? [String: Any]
            let currentID = current.flatMap { spaceID(from: $0) }
            if let currentID { map.currentIDs.insert(currentID) }
            if ((current?["type"] as? NSNumber)?.intValue ?? 0) != 0 {
                fullscreenDisplays.insert(displayID)
            } else {
                fullscreenDisplays.remove(displayID)
            }

            var desktops: [Desktop] = []
            var number = 0
            for space in spaces {
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0 || type == fullScreenSpaceType, let id = spaceID(from: space) else { continue }
                map.knownIDs.insert(id)
                map.displayBySpace[id] = displayID
                let fullScreenPID = type == fullScreenSpaceType ? (space["pid"] as? NSNumber)?.int32Value ?? 0 : nil
                if fullScreenPID == nil { number += 1 }
                desktops.append(Desktop(
                    id: id,
                    key: SpaceManager.spaceKey(from: space) ?? "space-\(id)",
                    number: fullScreenPID == nil ? number : 0,
                    isCurrent: id == currentID,
                    fullScreenPID: fullScreenPID
                ))
            }
            map.desktopsByDisplay[displayID] = desktops
        }
        return map
    }

    /// Open, visible windows front to back, each with the desktops it is shown on.
    private func placedWindows(in map: DesktopMap, connection: SpaceBarConnectionID) -> [(window: ParsedWindow, spaceIDs: [UInt64])] {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if Date().timeIntervalSince(hiddenByPIDResetDate) > hiddenByPIDLifetime {
            hiddenByPID.removeAll()
            hiddenByPIDResetDate = Date()
        }
        var placed: [(window: ParsedWindow, spaceIDs: [UInt64])] = []
        for info in list {
            guard let window = windowRef(from: info, ownPID: ownPID) else { continue }
            let isHidden: Bool
            if let known = hiddenByPID[window.pid] {
                isHidden = known
            } else {
                isHidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden == true
                hiddenByPID[window.pid] = isHidden
            }
            if isHidden { continue }
            guard isOrderedIn(window.windowID) else { continue }
            var ids = spaceIDs(for: window.windowID, connection: connection).filter { map.knownIDs.contains($0) }
            if ids.count > 1 {
                // A window assigned to All Desktops is listed on every desktop but is only seen on the current one
                ids = ids.filter { map.currentIDs.contains($0) }
                if ids.count > 1, let windowDisplay = displayUUID(containing: window.cgFrame) {
                    ids = ids.filter { map.displayBySpace[$0] == windowDisplay }
                }
            }
            guard !ids.isEmpty else { continue }
            placed.append((window, ids))
        }
        return placed
    }

    /// A desktop on this display other than the current one with no open windows,
    /// the nearest one after the current desktop first. Minimized windows and those of
    /// hidden apps don't count: when they come back, Rapto fits them into the desktop's mode.
    func emptyDesktop(on displayID: String) -> (id: UInt64, number: Int)? {
        let connection = SpaceBarMainConnectionID()
        guard let map = readDesktops(connection: connection),
              let desktops = map.desktopsByDisplay[displayID],
              let current = desktops.firstIndex(where: \.isCurrent) else { return nil }
        let occupied = Set(placedWindows(in: map, connection: connection).flatMap(\.spaceIDs))
        let candidates = desktops[(current + 1)...] + desktops[..<current]
        return candidates.first { !$0.isFullScreen && !occupied.contains($0.id) }.map { ($0.id, $0.number) }
    }

    // MARK: - Window switcher

    /// Every open window on every desktop, most recently used first.
    func switcherWindows() -> [WindowSwitcherEntry] {
        let connection = SpaceBarMainConnectionID()
        guard let map = readDesktops(connection: connection) else { return [] }
        let showsDisplay = map.desktopsByDisplay.count > 1
        var entries: [WindowSwitcherEntry] = []
        for (window, ids) in placedWindows(in: map, connection: connection) {
            guard let spaceID = ids.first,
                  let displayID = map.displayBySpace[spaceID],
                  let desktop = map.desktopsByDisplay[displayID]?.first(where: { $0.id == spaceID }) else { continue }
            entries.append(WindowSwitcherEntry(
                window: window.ref,
                appName: NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? window.ref.ownerName,
                spaceID: spaceID,
                displayID: displayID,
                desktopNumber: desktop.number,
                isFullScreen: desktop.isFullScreen,
                isOnCurrentDesktop: desktop.isCurrent,
                displayName: showsDisplay ? screen(forDisplayID: displayID)?.localizedName : nil
            ))
        }
        return entries
    }

    /// Bring one window to the front, switching to its desktop first if that desktop is hidden.
    func focusWindow(
        _ window: SpaceBarWindowRef,
        on spaceID: UInt64,
        displayID: String,
        fastSettle: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if spaceIsCurrent(spaceID, on: displayID) {
            pendingAction = nil
            performFocus(pid: window.pid, windowID: window.windowID)
            completion?()
            return
        }
        whenOnScreen(spaceID, displayID: displayID, fastSettle: fastSettle) { [weak self] in
            guard let self, self.window(window.windowID, isOn: spaceID) else { return false }
            self.performFocus(pid: window.pid, windowID: window.windowID)
            completion?()
            return true
        }
    }

    private struct ParsedWindow {
        let ref: SpaceBarWindowRef
        let pid: pid_t
        let windowID: CGWindowID
        let cgFrame: CGRect
    }

    private func windowRef(from info: [String: Any], ownPID: Int32) -> ParsedWindow? {
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        guard layer == 0 else { return nil }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard pid != 0, pid != ownPID else { return nil }
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard !owner.isEmpty, !ignoredOwners.contains(owner) else { return nil }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0 else { return nil }
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let width = bounds["Width"] ?? 0
        let height = bounds["Height"] ?? 0
        guard width >= 80, height >= 48 else { return nil }
        let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        guard windowID != 0 else { return nil }
        let title = info[kCGWindowName as String] as? String ?? ""
        let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
        let ref = SpaceBarWindowRef(
            windowID: windowID,
            pid: pid,
            title: title.isEmpty ? owner : title,
            ownerName: owner
        )
        return ParsedWindow(ref: ref, pid: pid, windowID: windowID, cgFrame: cgFrame)
    }

    /// Minimized windows are ordered out. Open windows stay ordered in even on another desktop.
    private func isOrderedIn(_ windowID: CGWindowID) -> Bool {
        guard let orderedIn else { return false }
        var ordered: UInt8 = 0
        orderedIn.function(orderedIn.connection, windowID, &ordered)
        return ordered != 0
    }

    private func spaceID(from info: [String: Any]) -> UInt64? {
        (info["id64"] as? NSNumber)?.uint64Value
    }

    func windowSpaceIDs(_ windowID: CGWindowID) -> [UInt64] {
        spaceIDs(for: windowID, connection: SpaceBarMainConnectionID())
    }

    // MARK: - Workaround: Per-space window stacking order
    // Cause: CGWindowListCopyWindowInfo sorts off-screen desktops by global background app activity
    //        rather than the desktop's actual front-to-back window stacking.
    // Context: Window Flow queries SLSCopyWindowsWithOptionsAndTags for the target space so its
    //          pre-composited desktop preview matches the exact top window in every slot.
    func orderedWindowIDs(on spaceID: UInt64) -> [CGWindowID] {
        guard let copySpaceWindows else { return [] }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaces = [NSNumber(value: spaceID)] as CFArray
        let raw = copySpaceWindows.function(copySpaceWindows.connection, 0, spaces, 0x2, &setTags, &clearTags) as? [NSNumber]
        return raw?.map(\.uint32Value) ?? []
    }

    private func spaceIDs(for windowID: CGWindowID, connection: SpaceBarConnectionID) -> [UInt64] {
        let windows = [NSNumber(value: windowID)] as CFArray
        let spaces = SpaceBarCopySpacesForWindows(connection, spaceBarWindowSelector, windows) as? [NSNumber]
        return spaces?.map(\.uint64Value) ?? []
    }

    // MARK: - Workaround: apps like Arc set their own icon a while after launching
    // Until then macOS hands out a placeholder, so icons of freshly launched apps are read again.
    private func icon(for pid: pid_t) -> NSImage {
        let now = Date()
        if let cached = icons[pid], cached.settled || now.timeIntervalSince(cached.fetchedAt) < 3 {
            return cached.image
        }
        let app = NSRunningApplication(processIdentifier: pid)
        let image = app?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.size = NSSize(width: 16, height: 16)
        let settled = app?.launchDate.map { now.timeIntervalSince($0) > 120 } ?? true
        let pixels = smallPixels(of: image)
        if let previous = icons[pid], previous.pixels != pixels {
            iconRevision += 1
        }
        icons[pid] = CachedIcon(image: image, pixels: pixels, fetchedAt: now, settled: settled)
        if icons.count > 300 { icons.removeAll() }
        return image
    }

    private func smallPixels(of image: NSImage) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)?.dataProvider?.data as Data?
    }

    private func fingerprint(of displays: [SpaceBarDisplay]) -> String {
        displays.map { display in
            let spaces = display.spaces.map { space in
                let glyphs = space.glyphs.map { "\($0.pid)x\($0.count)" }.joined(separator: ",")
                return "\(space.id):\(space.number):\(space.isCurrent ? 1 : 0):\(space.isFullScreen ? 1 : 0):\(glyphs)"
            }.joined(separator: "|")
            return "\(display.id)#\(spaces)"
        }.joined(separator: ";") + "@\(iconRevision)"
    }

    // MARK: - Panels

    private func layoutPanels() {
        guard isEnabled else {
            for panel in panels.values { panel.orderOut(nil) }
            screensByDisplay.removeAll()
            updatePointerTracking(needed: false)
            return
        }

        var seen = Set<String>()
        var needsPointer = false
        for screen in NSScreen.screens {
            let displayID = displayUUID(for: screen)
            guard !displayID.isEmpty, displays.contains(where: { $0.id == displayID }) else { continue }
            seen.insert(displayID)
            screensByDisplay[displayID] = screen
            let panel = panel(for: displayID)
            if menuBarHeight(of: screen) < 8, !fullscreenDisplays.contains(displayID) {
                panel.orderOut(nil)
                needsPointer = true
                continue
            }
            if isHoverOnly(screen, displayID: displayID) {
                needsPointer = true
            }
            let wasVisible = panel.isVisible
            place(panel, on: screen, size: panel.frame.size)
            applyPresentation(to: panel, displayID: displayID, on: screen)
            if !wasVisible {
                panel.orderFrontRegardless()
            }
        }

        for displayID in panels.keys where !seen.contains(displayID) {
            panels[displayID]?.orderOut(nil)
            panels[displayID] = nil
        }
        for displayID in screensByDisplay.keys where !seen.contains(displayID) {
            screensByDisplay[displayID] = nil
        }
        updatePointerTracking(needed: needsPointer)
    }

    private func panel(for displayID: String) -> NSPanel {
        if let panel = panels[displayID] { return panel }
        let panel = SpaceBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = look(displayID: displayID) == .dark
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let host = SpaceBarHostingView(rootView: SpaceBarView(displayID: displayID, controller: self))
        host.onRightClick = { [weak self, weak host] event in
            guard let self, let host else { return }
            self.showMenu(for: event, in: host, displayID: displayID)
        }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panels[displayID] = panel
        return panel
    }

    private func place(_ panel: NSPanel, on screen: NSScreen, size: CGSize) {
        let width = max(size.width, 24)
        let height = max(size.height, 22)
        let menuBar = menuBarHeight(of: screen)
        let x = screen.frame.midX - width / 2
        let y: CGFloat
        if screen.safeAreaInsets.top > 0 {
            y = screen.visibleFrame.maxY - height - 2
        } else {
            y = screen.frame.maxY - menuBar + (menuBar - height) / 2
        }
        let frame = NSRect(x: x, y: y, width: width, height: height).integral
        // The hosting view sizes the panel to its fractional ideal width, which `.integral` rounds,
        // so an exact comparison never matches and would re-lay out the panel on every refresh
        let current = panel.frame
        let tolerance: CGFloat = 1
        let isSameFrame = current.width >= width && current.height >= height
            && abs(current.minX - frame.minX) <= tolerance
            && abs(current.minY - frame.minY) <= tolerance
            && abs(current.width - frame.width) <= tolerance
            && abs(current.height - frame.height) <= tolerance
        if !isSameFrame {
            panel.setFrame(frame, display: true)
        }
    }

    private func menuBarHeight(of screen: NSScreen) -> CGFloat {
        screen.frame.maxY - screen.visibleFrame.maxY
    }

    private func displayUUID(for screen: NSScreen) -> String {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return ""
        }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    private func displayUUID(containing cgFrame: CGRect) -> String? {
        let center = CGPoint(x: cgFrame.midX, y: cgFrame.midY)
        return NSScreen.screens.first { axRect(of: $0.frame).contains(center) }.map(displayUUID(for:))
    }

    private func screen(forDisplayID displayID: String) -> NSScreen? {
        NSScreen.screens.first { displayUUID(for: $0) == displayID }
    }
}

/// A pill that must not become key. Becoming key makes Rapto active and
/// leaves two apps drawing their menus into the menu bar at once.
private final class SpaceBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI has no right-click gesture, so the pill catches it here.
private final class SpaceBarHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
            return
        }
        super.mouseDown(with: event)
    }
}
