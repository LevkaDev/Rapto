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

private let logger = Logger(subsystem: "app.rapto.mac", category: "SpaceBar")

/// Electron apps such as HEY do not answer `_AXWindowID`, but this works for them.
@_silgen_name("_AXUIElementGetWindow")
private func SpaceBarAXGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    /// Builds the right-click menu for a desktop (and optional clicked app glyph) on a display.
    var menuBuilder: ((SpaceBarSpace, SpaceBarGlyph?, String) -> NSMenu?)?
    /// Fired when the user hovers the notch / top hover zone and reveals a hidden Desktops Bar.
    var onUserRevealedHoverBar: (() -> Void)?
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
        pendingAction = nil
        askForSwitchPermissionIfNeeded()
        startSwitch(spaceID: spaceID, displayID: displayID)
    }

    /// Open the app shown by this icon. If its desktop is hidden, switch there
    /// first and activate the window only after that desktop is on screen.
    func focus(_ glyph: SpaceBarGlyph, on spaceID: UInt64, displayID: String) {
        guard !glyph.windows.isEmpty else { return }
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
        guard let axWindow = axWindow(pid: window.pid, windowID: window.windowID),
              let frame = frame(of: axWindow) else {
            logger.notice("Move: no accessibility window for \(window.windowID)")
            NSSound.beep()
            return
        }
        isMovingWindow = true
        Self.isDrivingMouse = true
        Self.movingWindowID = window.windowID
        if let source = keys.source {
            onWillMoveWindow?(window.windowID, source, displayID)
        }
        performFocus(pid: window.pid, windowID: window.windowID)
        grabWhenRaised(window, axWindow: axWindow, frame: frame, to: targetID, displayID: displayID, home: home,
                       targetKey: keys.target, deadline: Date().addingTimeInterval(0.4))
    }

    /// The title bar spot belongs to the window only once it is in front, so retry briefly.
    private func grabWhenRaised(
        _ window: SpaceBarWindowRef, axWindow: AXUIElement, frame: CGRect,
        to targetID: UInt64, displayID: String, home: UInt64?, targetKey: String?, deadline: Date
    ) {
        // Until the window is in front, the spots are answered by the window still covering it
        // (Yab raised behind Orca: the spots next to its buttons were taken for Orca's and skipped)
        let top = CGPoint(x: frame.midX, y: frame.minY + 10)
        if Date() < deadline, !SpaceBarController.windowIsOnTop(pid: window.pid, at: top, among: SpaceBarController.windowsFrontToBack()) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.grabWhenRaised(window, axWindow: axWindow, frame: frame, to: targetID,
                                     displayID: displayID, home: home, targetKey: targetKey, deadline: deadline)
            }
            return
        }
        guard let plan = grabPlan(in: axWindow, frame: frame, pid: window.pid) else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.grabWhenRaised(window, axWindow: axWindow, frame: frame, to: targetID,
                                         displayID: displayID, home: home, targetKey: targetKey, deadline: deadline)
                }
                return
            }
            logger.notice("Move: no free title bar spot in \(window.ownerName, privacy: .public), frame \(String(describing: frame), privacy: .public)")
            isMovingWindow = false
            Self.isDrivingMouse = false
            Self.movingWindowID = nil
            NSSound.beep()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let grab = Grab(
            window: window, axWindow: axWindow, frame: frame, targetID: targetID, targetKey: targetKey,
            displayID: displayID, home: home, cursor: CGEvent(source: nil)?.location ?? plan.points[0], source: source,
            fallbacks: plan.fallbacks
        )
        if plan.isGuess {
            probe(plan.points, at: 0, grab: grab)
        } else {
            pressAndCarry(from: plan.points[0], grab: grab)
        }
    }

    /// What a move needs from the moment the mouse goes down until the desktop switches.
    private struct Grab {
        let window: SpaceBarWindowRef
        let axWindow: AXUIElement
        let frame: CGRect
        let targetID: UInt64
        let targetKey: String?
        let displayID: String
        let home: UInt64?
        /// Where the pointer was before the move, to put it back
        let cursor: CGPoint
        let source: CGEventSource?
        /// Other spots to probe when the confirmed one does not drag the window
        var fallbacks: [CGPoint] = []
        /// The confirmed spot the fallbacks stand in for; used when none of them drags either
        var lastResort: CGPoint?
    }

    /// How far a guessed spot is dragged to see whether the window follows: first a little, then
    /// more for title bar parts that are also buttons and wait for a longer drag.
    private static let probeOffsets: [CGPoint] = [CGPoint(x: 5, y: 5), CGPoint(x: 12, y: 12)]

    private func press(at point: CGPoint, grab: Grab) {
        logger.notice("Move: grabbing at \(String(describing: point), privacy: .public)")
        postMouse(.mouseMoved, at: point, source: grab.source)
        postMouse(.leftMouseDown, at: point, source: grab.source)
    }

    // MARK: - Workaround: A window that starts following the mouse late is left behind
    // Cause: macOS carries a window to the next desktop only once its drag has begun. Some
    //        apps (Hark) begin it a few hundred milliseconds after the press, and the desktop
    //        switched before that about one time in four.
    // Context: After the press the window is dragged a few points and the switch waits until
    //          it has moved, or for `followWait` at most; a window that never reports a move
    //          is carried anyway, as it was before.
    private static let followWait: TimeInterval = 0.45
    private static let followPoll: TimeInterval = 0.03

    private func pressAndCarry(from point: CGPoint, grab: Grab) {
        let before = frame(of: grab.axWindow)?.origin ?? grab.frame.origin
        press(at: point, grab: grab)
        let offset = Self.probeOffsets[0]
        postMouse(.leftMouseDragged, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y), source: grab.source)
        waitForFollow(from: point, grab: grab, before: before, started: Date())
    }

    private func waitForFollow(from point: CGPoint, grab: Grab, before: CGPoint, started: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followPoll) { [weak self] in
            guard let self else { return }
            let waited = Date().timeIntervalSince(started)
            let now = self.frame(of: grab.axWindow)?.origin
            let followed = now.map { SpaceBarController.windowFollowed(from: before, to: $0, dragOffset: Self.probeOffsets[0].x) } ?? false
            if followed || waited >= Self.followWait {
                logger.notice("Move: \(followed ? "window follows" : "no move seen", privacy: .public) after \(String(format: "%.2f", waited), privacy: .public)s")
                if !followed, !grab.fallbacks.isEmpty {
                    self.tryFallbacks(after: point, grab: grab)
                    return
                }
                self.carry(from: point, grab: grab)
                return
            }
            self.waitForFollow(from: point, grab: grab, before: before, started: started)
        }
    }

    // MARK: - Workaround: A spot Accessibility calls title bar does not always drag the window
    // Cause: In Yab the middle of the top strip answers as a plain group of the window, like
    //        empty toolbar space does, but it is the tab strip: a press there drags nothing,
    //        and the desktop switched without the window.
    // Context: When a confirmed spot does not move the window within `followWait`, it is let go
    //          outside the window and a few other spots are probed. If none drags either, the
    //          move goes on from the confirmed spot as before, for windows that never report
    //          that they moved.
    private func tryFallbacks(after point: CGPoint, grab: Grab) {
        logger.notice("Move: letting go of \(String(describing: point), privacy: .public), probing \(grab.fallbacks.count) other spots")
        let outside = SpaceBarController.releasePoint(for: point, windowFrame: grab.frame)
        postMouse(.leftMouseDragged, at: outside, source: grab.source)
        postMouse(.leftMouseUp, at: outside, source: grab.source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.putBack(grab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                var next = grab
                next.fallbacks = []
                next.lastResort = point
                self?.probe(grab.fallbacks, at: 0, grab: next)
            }
        }
    }

    // MARK: - Workaround: Some title bars drawn as a web page say nothing about where they drag
    // Cause: Antigravity and apps alike answer "web page" or "group" at every point of the title
    //        bar, and only parts of it drag the window. The rest holds controls.
    // Context: Guessed spots are tried one by one: press, drag a few points, and see whether the
    //          window moved from where it was just before. One that did not is let go outside
    //          the window, so nothing under it is clicked. A window that moved only on that way
    //          out follows late (Hark): the spot does drag it, so the move goes on from there.
    private func probe(_ points: [CGPoint], at index: Int, grab: Grab) {
        guard index < points.count else {
            // None followed within the wait. Moving from the first spot is what worked before
            // spots were probed, for windows that are only slow to follow.
            logger.notice("Move: no guessed spot dragged the window, using the first")
            pressAndCarry(from: grab.lastResort ?? points[0], grab: grab)
            return
        }
        let point = points[index]
        let before = frame(of: grab.axWindow)?.origin ?? grab.frame.origin
        press(at: point, grab: grab)
        dragProbe(points, at: index, grab: grab, before: before, stage: 0)
    }

    private func dragProbe(_ points: [CGPoint], at index: Int, grab: Grab, before: CGPoint, stage: Int) {
        let point = points[index]
        let offset = Self.probeOffsets[stage]
        postMouse(.leftMouseDragged, at: CGPoint(x: point.x + offset.x, y: point.y + offset.y), source: grab.source)
        checkProbe(points, at: index, grab: grab, before: before, stage: stage, attempt: 0)
    }

    private func checkProbe(_ points: [CGPoint], at index: Int, grab: Grab, before: CGPoint, stage: Int, attempt: Int) {
        // The app needs a moment to move its window after the drag event
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            let point = points[index]
            let now = self.frame(of: grab.axWindow)
            if let now, SpaceBarController.windowFollowed(from: before, to: now.origin, dragOffset: Self.probeOffsets[stage].x) {
                logger.notice("Move: window followed at \(String(describing: point), privacy: .public), from \(String(describing: before), privacy: .public) to \(String(describing: now.origin), privacy: .public)")
                self.carry(from: point, grab: grab)
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
            let outside = SpaceBarController.releasePoint(for: point, windowFrame: grab.frame)
            self.postMouse(.leftMouseDragged, at: outside, source: grab.source)
            self.postMouse(.leftMouseUp, at: outside, source: grab.source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let after = self.frame(of: grab.axWindow)?.origin
                let followedLate = after.map { SpaceBarController.windowFollowed(from: before, to: $0, dragOffset: Self.probeOffsets[0].x) } ?? false
                self.putBack(grab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self else { return }
                    if followedLate {
                        logger.notice("Move: window followed late at \(String(describing: point), privacy: .public)")
                        self.pressAndCarry(from: point, grab: grab)
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
        let edgeMargin: CGFloat = 8
        if windowFrame.minY - 4 >= edgeMargin {
            return CGPoint(x: point.x, y: windowFrame.minY - 4)
        }
        if windowFrame.minX - 4 >= edgeMargin {
            return CGPoint(x: windowFrame.minX - 4, y: point.y)
        }
        return point
    }

    /// Returns the window to where it was when the move began, if a probe shifted it.
    private func putBack(_ grab: Grab) {
        guard let now = frame(of: grab.axWindow)?.origin, now != grab.frame.origin else { return }
        logger.notice("Move: putting the window back from \(String(describing: now), privacy: .public) to \(String(describing: grab.frame.origin), privacy: .public)")
        var origin = grab.frame.origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(grab.axWindow, kAXPositionAttribute as CFString, value)
    }

    /// Whether a window dragged by `dragOffset` points came along. `start` is where it was just
    /// before the press, not when the move began: an earlier spot may have shifted it.
    nonisolated static func windowFollowed(from start: CGPoint, to now: CGPoint, dragOffset: CGFloat) -> Bool {
        let moved = max(abs(now.x - start.x), abs(now.y - start.y))
        return moved >= dragOffset / 2
    }

    /// The mouse is down on `point` and the window follows it: switch the desktop under it.
    private func carry(from point: CGPoint, grab: Grab) {
        var move = WindowMove(
            window: grab.window, axWindow: grab.axWindow, origin: grab.frame.origin, targetID: grab.targetID, targetKey: grab.targetKey, displayID: grab.displayID,
            home: grab.home, grab: point, cursor: grab.cursor, source: grab.source,
            phaseStarted: Date()
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
        let axWindow: AXUIElement
        /// Where the window was before it was grabbed
        let origin: CGPoint
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
                self.undoProbeShift(move)
                if let targetKey = move.targetKey {
                    self.onDidMoveWindow?(window.windowID, targetKey, move.displayID)
                }
                if returnHome == nil {
                    self.performFocus(pid: window.pid, windowID: window.windowID)
                }
            } else {
                NSSound.beep()
            }
            self.refresh()
        }
    }

    /// A window that follows the mouse with a delay can arrive a few points off, by the length
    /// of the probe drag. It is put where it was; a window that is anywhere else was placed
    /// there on purpose and is left alone.
    private func undoProbeShift(_ move: WindowMove) {
        guard let now = frame(of: move.axWindow)?.origin,
              SpaceBarController.isProbeShift(from: move.origin, to: now) else { return }
        logger.notice("Move: putting the window back from \(String(describing: now), privacy: .public) to \(String(describing: move.origin), privacy: .public)")
        var origin = move.origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(move.axWindow, kAXPositionAttribute as CFString, value)
    }

    /// Whether a window ended up off its place by no more than a probe drag and a little.
    nonisolated static func isProbeShift(from origin: CGPoint, to now: CGPoint) -> Bool {
        let dx = abs(now.x - origin.x)
        let dy = abs(now.y - origin.y)
        return (dx > 0 || dy > 0) && dx <= 16 && dy <= 16
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.flags = []
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Where to press to drag the window. A spot Accessibility confirms is used as it is;
    /// guessed spots are probed one by one.
    private struct GrabPlan {
        let points: [CGPoint]
        let isGuess: Bool
        /// For a confirmed spot: what to probe when it turns out not to drag the window
        var fallbacks: [CGPoint] = []
    }

    /// Spots in the title bar that drag the window, not a tab or a button.
    private func grabPlan(in window: AXUIElement, frame: CGRect, pid: pid_t) -> GrabPlan? {
        guard var plan = primaryGrabPlan(in: window, frame: frame, pid: pid) else { return nil }
        if !plan.isGuess {
            plan.fallbacks = fallbackSpots(after: plan.points[0], in: window, frame: frame, pid: pid)
        }
        return plan
    }

    /// How many other spots are probed after a confirmed one failed: each costs a quarter of a second
    private static let fallbackLimit = 5

    /// Spots that are no control and lie on the window, next to the window buttons first, then
    /// along the title bar and along the top edge.
    private func fallbackSpots(after failed: CGPoint, in window: AXUIElement, frame: CGRect, pid: pid_t) -> [CGPoint] {
        var candidates: [CGPoint] = []
        let button = buttonFrame(kAXZoomButtonAttribute, of: window)
            ?? buttonFrame(kAXFullScreenButtonAttribute, of: window)
            ?? buttonFrame(kAXCloseButtonAttribute, of: window)
        if let button {
            candidates += [10.0, 28.0, 56.0].map { CGPoint(x: button.maxX + $0, y: button.midY) }
            candidates += SpaceBarController.guessedGrabXs(buttonsMaxX: button.maxX, frameMinX: frame.minX, frameMaxX: frame.maxX)
                .map { CGPoint(x: $0, y: button.midY) }
        }
        candidates += [frame.minX + 90, frame.maxX - 60, frame.minX + 20, frame.maxX - 150].map { CGPoint(x: $0, y: frame.minY + 10) }
        let windows = SpaceBarController.windowsFrontToBack()
        let usable = barePagePoints(candidates, frame: frame, pid: pid)
            .filter { SpaceBarController.windowIsOnTop(pid: pid, at: $0, among: windows) }
        return SpaceBarController.fallbackOrder(after: failed, candidates: usable, limit: Self.fallbackLimit)
    }

    /// The spots to probe after `failed`: none close to it or to one another, at most `limit`.
    nonisolated static func fallbackOrder(after failed: CGPoint, candidates: [CGPoint], limit: Int) -> [CGPoint] {
        Array(probeOrder(first: failed, then: candidates).dropFirst().prefix(limit))
    }

    private func primaryGrabPlan(in window: AXUIElement, frame: CGRect, pid: pid_t) -> GrabPlan? {
        var nextToButtons: [CGPoint] = []
        let button = buttonFrame(kAXZoomButtonAttribute, of: window)
            ?? buttonFrame(kAXFullScreenButtonAttribute, of: window)
            ?? buttonFrame(kAXCloseButtonAttribute, of: window)
        if let button {
            for offset in [10.0, 28.0, 56.0] {
                nextToButtons.append(CGPoint(x: button.maxX + offset, y: button.midY))
            }
        }
        // Vivaldi and apps alike draw their title bar as a web page, which still drags the window.
        // A page never starts level with the window buttons, so web content there is title bar.
        if let spot = firstDragSpot(nextToButtons, frame: frame, pid: pid, inToolbarOnly: false, webIsTitleBar: true) {
            guard spot.isWebContent else {
                return GrabPlan(points: [spot.point], isGuess: false)
            }
            // MARK: - Workaround: Web content next to the window buttons is not always title bar
            // Cause: Orca draws its title bar as a page and has controls right after the window
            //        buttons. The spot answers as a plain group inside the page, like Vivaldi's
            //        title bar does, but a press there drags nothing and the window stays behind.
            // Context: Such a spot is a guess, so it is probed like the others: it goes first, as
            //          it works for Vivaldi, and the guessed spots along the title bar follow.
            var guesses: [CGPoint] = []
            if let button {
                let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: button.maxX, frameMinX: frame.minX, frameMaxX: frame.maxX)
                guesses = barePagePoints(xs.map { CGPoint(x: $0, y: button.midY) }, frame: frame, pid: pid)
                    .filter { SpaceBarController.windowIsOnTop(pid: pid, at: $0, among: SpaceBarController.windowsFrontToBack()) }
            }
            return GrabPlan(points: SpaceBarController.probeOrder(first: spot.point, then: guesses), isGuess: true)
        }
        // Browsers with tabs in a sidebar hide these buttons and have empty toolbar space in the corners.
        let alongTop = [frame.midX, frame.minX + 90, frame.minX + 20, frame.minX + 50, frame.minX + 130, frame.maxX - 60, frame.maxX - 150]
            .map { CGPoint(x: $0, y: frame.minY + 10) }
        // MARK: - Workaround: Zen describes its page only a while after it is first asked
        // Until then the page answers as a bare window, so a toolbar spot is looked for first, twice.
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            if let point = firstDragPoint(alongTop, frame: frame, pid: pid, inToolbarOnly: true) {
                return GrabPlan(points: [point], isGuess: false)
            }
        }
        if let point = firstDragPoint(alongTop, frame: frame, pid: pid, inToolbarOnly: false) {
            return GrabPlan(points: [point], isGuess: false)
        }
        // Claude and apps alike draw their whole title bar as a page with nothing in it to point at.
        // Only bare page level with the window buttons counts, so no window that moved before changes.
        guard let button else { return nil }
        let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: button.maxX, frameMinX: frame.minX, frameMaxX: frame.maxX)
        let points = barePagePoints(xs.map { CGPoint(x: $0, y: button.midY) }, frame: frame, pid: pid)
            .filter { SpaceBarController.windowIsOnTop(pid: pid, at: $0, among: SpaceBarController.windowsFrontToBack()) }
        return points.isEmpty ? nil : GrabPlan(points: points, isGuess: true)
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

    /// Every window on screen, front to back, with its owner and frame (top-left origin).
    /// Rapto's own windows are left out: the border around the active window covers all of it
    /// and lets clicks through, and the ones that take clicks (the group indicator) are told
    /// apart by the hit test, which answers with Rapto there.
    private static func windowsFrontToBack() -> [(pid: pid_t, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
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

    /// The spots where no button, link or text field is hit: the page itself first, then
    /// anything else that is not a control. A group or a split view is sometimes a part of the
    /// title bar (Hark, Simplenote) and sometimes a container of controls; probing tells.
    private func barePagePoints(_ candidates: [CGPoint], frame: CGRect, pid: pid_t) -> [CGPoint] {
        let systemWide = AXUIElementCreateSystemWide()
        var pages: [CGPoint] = []
        var others: [CGPoint] = []
        for point in candidates where frame.contains(point) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { continue }
            var hitPID: pid_t = 0
            AXUIElementGetPid(hit, &hitPID)
            let role = stringAttribute(kAXRoleAttribute, of: hit)
            logger.notice("Move: bare page check at \(String(describing: point), privacy: .public) pid \(hitPID) role \(role ?? "?", privacy: .public)")
            guard hitPID == pid, let role else { continue }
            switch SpaceBarController.guessKind(forRole: role) {
            case .page: pages.append(point)
            case .other: others.append(point)
            case .control: break
            }
        }
        return pages + others
    }

    nonisolated enum GuessKind { case page, other, control }

    nonisolated static func guessKind(forRole role: String) -> GuessKind {
        if role == "AXWebArea" { return .page }
        return controlRoleNames.contains(role) ? .control : .other
    }

    /// Dragging one of these tears a tab off, and a click presses it.
    nonisolated private static let controlRoleNames: Set<String> = [
        "AXButton", "AXRadioButton", "AXTabGroup", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton",
        "AXCheckBox", "AXComboBox", "AXSlider", "AXTab", "AXLink", "AXMenuItem", "AXMenuBarItem"
    ]

    private func firstDragPoint(
        _ candidates: [CGPoint], frame: CGRect, pid: pid_t, inToolbarOnly: Bool, webIsTitleBar: Bool = false
    ) -> CGPoint? {
        firstDragSpot(candidates, frame: frame, pid: pid, inToolbarOnly: inToolbarOnly, webIsTitleBar: webIsTitleBar)?.point
    }

    /// `isWebContent`: the spot counts as a drag area only because web content was let through.
    private func firstDragSpot(
        _ candidates: [CGPoint], frame: CGRect, pid: pid_t, inToolbarOnly: Bool, webIsTitleBar: Bool = false
    ) -> (point: CGPoint, isWebContent: Bool)? {
        let systemWide = AXUIElementCreateSystemWide()
        for point in candidates where frame.contains(point) {
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
            guard status == .success, let hit else {
                logger.notice("Move: nothing at \(String(describing: point), privacy: .public) (\(status.rawValue))")
                continue
            }
            var hitPID: pid_t = 0
            AXUIElementGetPid(hit, &hitPID)
            let chain = roleChain(of: hit)
            logger.notice("Move: at \(String(describing: point), privacy: .public) pid \(hitPID) roles \(chain, privacy: .public)")
            guard hitPID == pid, isDragArea(hit, webIsTitleBar: webIsTitleBar) else { continue }
            if inToolbarOnly, !chain.contains(kAXToolbarRole) { continue }
            return (point, webIsTitleBar && !isDragArea(hit, webIsTitleBar: false))
        }
        return nil
    }

    private static let dragRoles: Set<String> = [
        kAXWindowRole, kAXToolbarRole, kAXGroupRole, kAXStaticTextRole, kAXUnknownRole
    ]
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXTabGroupRole, kAXTextFieldRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXCheckBoxRole, kAXComboBoxRole, "AXTab", "AXLink", "AXWebArea"
    ]

    /// Dragging a tab tears it off and a click on a control presses it.
    private func isDragArea(_ element: AXUIElement, webIsTitleBar: Bool) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element), Self.dragRoles.contains(role) else { return false }
        let controlRoles = webIsTitleBar ? Self.controlRoles.subtracting(["AXWebArea"]) : Self.controlRoles
        var current: AXUIElement? = element
        // Web pages nest their content deep, so look all the way up to the window.
        for _ in 0..<16 {
            guard let node = current else { break }
            if let role = stringAttribute(kAXRoleAttribute, of: node) {
                if role == kAXWindowRole { return true }
                if controlRoles.contains(role) { return false }
            }
            current = elementAttribute(kAXParentAttribute, of: node)
        }
        return true
    }

    private func roleChain(of element: AXUIElement) -> String {
        var roles: [String] = []
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let node = current else { break }
            roles.append(stringAttribute(kAXRoleAttribute, of: node) ?? "?")
            current = elementAttribute(kAXParentAttribute, of: node)
        }
        return roles.joined(separator: " < ")
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

    private func performFocus(pid: pid_t, windowID: UInt32) {
        var psn = ProcessSerialNumber()
        if let frontProcess, SpaceBarGetProcessForPID(pid, &psn) == 0 {
            let status = frontProcess(&psn, windowID, spaceBarFocusWindowOnly)
            if status != 0 {
                debugLog("SpaceBar", "Focus window \(windowID) failed: \(status)")
            }
        }
        // The window server call above still brings a hung app's window to the front
        guard AppResponsiveness.isResponding(pid) else { return }
        let application = AXUIElementCreateApplication(pid)
        if let axWindow = axWindow(pid: pid, windowID: windowID) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        guard AppResponsiveness.isResponding(pid) else { return }
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func axWindow(pid: pid_t, windowID: UInt32) -> AXUIElement? {
        guard AppResponsiveness.isResponding(pid) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AppResponsiveness.shared.ask(pid) {
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
        }
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return nil }
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
