//
//  WindowSwitcher.swift
//  Rapto
//
//  A keyboard window switcher: type the first letters of an app or window
//  title to find any open window on any desktop and jump to it.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let windowSwitcherDidOpen = Notification.Name("RaptoWindowSwitcherDidOpen")
}

// MARK: - Entry

struct WindowSwitcherEntry: Identifiable {
    let window: SpaceBarWindowRef
    let appName: String
    let spaceID: UInt64
    let displayID: String
    let desktopNumber: Int
    /// The window is in full screen, on a space of its own with no desktop number.
    let isFullScreen: Bool
    let isOnCurrentDesktop: Bool
    /// Set only when there is more than one display.
    let displayName: String?
    /// The title read through Accessibility, when the window list did not have one.
    var resolvedTitle: String?

    var id: CGWindowID { window.windowID }
    var title: String {
        if let resolvedTitle, !resolvedTitle.isEmpty { return resolvedTitle }
        return window.title.isEmpty ? appName : window.title
    }
    /// The window list gives no titles without Screen Recording, only the app name.
    var lacksListedTitle: Bool { window.title.isEmpty || window.title == window.ownerName }
}

// MARK: - Matching

enum WindowSwitcherMatcher {

    /// Higher is better, nil when the query does not match. Every word of the
    /// query has to match the app name or the window title.
    static func score(query: String, appName: String, title: String) -> Int? {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let app = normalize(appName)
        let name = normalize(title)
        let appWords = words(app)
        let titleWords = words(name)
        let appInitials = String(appWords.compactMap(\.first))
        let titleInitials = String(titleWords.compactMap(\.first))

        var total = 0
        for token in tokens {
            let best: Int
            if app.hasPrefix(token) {
                best = 1000
            } else if appWords.contains(where: { $0.hasPrefix(token) }) {
                best = 900
            } else if token.count > 1, appInitials.hasPrefix(token) {
                best = 800
            } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
                best = 700
            } else if token.count > 1, app.contains(token) {
                best = 600
            } else if token.count > 1, name.contains(token) {
                best = 500
            } else if token.count > 1, titleInitials.hasPrefix(token) {
                best = 400
            } else if token.count > 1, app.first == token.first, isSubsequence(token, of: app) {
                best = 300
            } else {
                return nil
            }
            total += best
        }
        return total
    }

    static func rank(_ entries: [WindowSwitcherEntry], query: String) -> [WindowSwitcherEntry] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
        return entries.enumerated()
            .compactMap { index, entry in
                score(query: query, appName: entry.appName, title: entry.title).map { (entry, $0, index) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where remaining.first == character {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

// MARK: - Model

@MainActor
final class WindowSwitcherModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = WindowSwitcherMatcher.rank(entries, query: query)
            selection = 0
        }
    }
    @Published private(set) var results: [WindowSwitcherEntry] = []
    @Published var selection = 0

    private var entries: [WindowSwitcherEntry] = []
    private var icons: [pid_t: NSImage] = [:]

    var selectedEntry: WindowSwitcherEntry? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// With an empty query the window that is already in front is skipped,
    /// so Enter goes back to the previous one.
    func load(_ entries: [WindowSwitcherEntry]) {
        self.entries = entries
        icons.removeAll()
        query = ""
        results = entries
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        selection = entries.count > 1 && entries.first?.window.pid == frontPID ? 1 : 0
    }

    /// Titles that arrive after the list is shown. The selected window stays selected.
    func applyTitles(_ titles: [CGWindowID: String]) {
        var changed = false
        for index in entries.indices {
            guard let title = titles[entries[index].id], entries[index].resolvedTitle != title else { continue }
            entries[index].resolvedTitle = title
            changed = true
        }
        guard changed else { return }
        let selectedID = selectedEntry?.id
        results = WindowSwitcherMatcher.rank(entries, query: query)
        if let index = results.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else {
            selection = min(selection, max(0, results.count - 1))
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + offset + results.count) % results.count
    }

    func icon(for pid: pid_t) -> NSImage {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        icons[pid] = image
        return image
    }
}

// MARK: - Panel

final class WindowSwitcherPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Controller

@MainActor
final class WindowSwitcherController {
    static let width: CGFloat = 600
    static let searchHeight: CGFloat = 52
    static let rowHeight: CGFloat = 44
    static let visibleRows = 9

    private let spaceBar: SpaceBarController
    private let model = WindowSwitcherModel()
    private var panel: WindowSwitcherPanel?
    private var resultsObserver: AnyCancellable?
    /// Titles from the last time the switcher was open, shown until fresh ones arrive.
    private var titleCache: [CGWindowID: String] = [:]
    private var titleRequest = 0

    init(spaceBar: SpaceBarController) {
        self.spaceBar = spaceBar
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        var entries = spaceBar.switcherWindows()
        for index in entries.indices where entries[index].lacksListedTitle {
            entries[index].resolvedTitle = titleCache[entries[index].id]
        }
        model.load(entries)
        resolveTitles(for: entries)
        // MARK: - Workaround: a hidden .canJoinAllSpaces panel ends up on one desktop
        // Same as DragSnapLayoutPicker: when a temporary space goes away, macOS leaves a hidden all-desktops
        // window on one desktop, and it then shows only there. So a panel hidden by close() isn't shown again.
        if let hidden = self.panel, !hidden.isVisible {
            self.panel = nil
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hostingView = NSHostingView(rootView: WindowSwitcherView(
            model: model,
            onActivate: { [weak self] entry in self?.activate(entry) }
        ))
        // The panel follows the number of results, not the SwiftUI content size
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        place(panel, rows: model.results.count)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .windowSwitcherDidOpen, object: nil)
        debugLog("WindowSwitcher", "Opened with \(model.results.count) windows")
    }

    /// Asks the apps for the titles the window list did not have, off the main thread.
    private func resolveTitles(for entries: [WindowSwitcherEntry]) {
        let untitled = entries.filter(\.lacksListedTitle)
        titleRequest += 1
        guard !untitled.isEmpty else {
            titleCache.removeAll()
            return
        }
        let request = titleRequest
        let windowsByPID = Dictionary(grouping: untitled, by: \.window.pid).mapValues { Set($0.map(\.id)) }
        let openIDs = Set(untitled.map(\.id))
        Task.detached(priority: .userInitiated) { [weak self] in
            let titles = WindowTitleResolver.titles(for: windowsByPID)
            await self?.didResolveTitles(titles, request: request, openIDs: openIDs)
        }
    }

    private func didResolveTitles(_ titles: [CGWindowID: String], request: Int, openIDs: Set<CGWindowID>) {
        guard request == titleRequest else { return }
        titleCache = titleCache.filter { openIDs.contains($0.key) }.merging(titles) { _, new in new }
        model.applyTitles(titles)
        debugLog("WindowSwitcher", "Read \(titles.count) of \(openIDs.count) missing titles through Accessibility")
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func activate(_ entry: WindowSwitcherEntry) {
        close()
        debugLog("WindowSwitcher", "Activating '\(entry.appName)' window \(entry.window.windowID) on desktop \(entry.desktopNumber)")
        spaceBar.focusWindow(entry.window, on: entry.spaceID, displayID: entry.displayID)
    }

    private func makePanel() -> WindowSwitcherPanel {
        let panel = WindowSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in self?.close() }
        resultsObserver = model.$results.sink { [weak self, weak panel] results in
            guard let self, let panel, panel.isVisible else { return }
            self.place(panel, rows: results.count)
        }
        return panel
    }

    /// Centered on the screen with the pointer, its top edge 22% of the way down.
    private func place(_ panel: NSPanel, rows: Int) {
        let height = Self.searchHeight + CGFloat(max(1, min(rows, Self.visibleRows))) * Self.rowHeight + 12
        if panel.isVisible {
            let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - height, width: Self.width, height: height)
            panel.setFrame(frame, display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let top = visible.maxY - visible.height * 0.22
        let frame = NSRect(x: visible.midX - Self.width / 2, y: top - height, width: Self.width, height: height)
        panel.setFrame(frame.integral, display: true)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command),
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            if model.results.indices.contains(digit - 1) {
                activate(model.results[digit - 1])
            }
            return true
        }
        switch event.keyCode {
        case 53: // Escape
            close()
        case 36, 76: // Return, Enter
            if let entry = model.selectedEntry { activate(entry) }
        case 125: // Down
            model.moveSelection(by: 1)
        case 126: // Up
            model.moveSelection(by: -1)
        case 48: // Tab
            model.moveSelection(by: modifiers.contains(.shift) ? -1 : 1)
        default:
            return false
        }
        return true
    }
}
