//
//  Workspaces.swift
//  Rapto
//
//  A workspace remembers the apps of one desktop, on every display, and where
//  each one goes. Opening it brings those apps back into the same places,
//  launching the ones that are not running.
//

import AppKit

// MARK: - Model

struct Workspace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var screens: [Screen]

    struct Screen: Codable, Equatable {
        var screenID: String
        /// Stays the same when the display is reconnected, unlike `screenID`.
        var displayUUID: String?
        var displayName: String?
        /// The layout the windows were in. Nil when they were placed freely.
        var templateID: UUID?
        var slots: [Slot]
    }

    struct Slot: Codable, Equatable {
        /// Relative to the screen's visible frame, with the origin at the top left.
        var frame: CGRect
        /// The front window's app first, then the rest of the group.
        var apps: [App]
    }

    struct App: Codable, Equatable, Hashable {
        var bundleID: String?
        var name: String

        var key: String { bundleID ?? name }
    }

    var appCount: Int {
        screens.reduce(0) { $0 + $1.slots.reduce(0) { $0 + $1.apps.count } }
    }
}

/// Windows each workspace placed, so closing a workspace closes those windows and
/// not other windows of the same apps. Kept across Rapto restarts; window ids stay
/// valid while their app runs.
@MainActor
enum WorkspaceSession {
    private static let key = "workspaces.windows.v1"
    private static let bootKey = "workspaces.windows.boot"

    static var windowIDs: [UUID: Set<CGWindowID>] = load() {
        didSet { save() }
    }

    /// The recorded windows that still belong to one of the workspace's apps. Window ids start
    /// over in a new login session, so an id alone can point at another app's window.
    static func recordedWindows(
        in entries: [WindowSwitcherEntry],
        recorded: Set<CGWindowID>,
        appKeys: Set<String>,
        appKey: (WindowSwitcherEntry) -> String
    ) -> [WindowSwitcherEntry] {
        entries.filter { recorded.contains($0.window.windowID) && appKeys.contains(appKey($0)) }
    }

    private static func load() -> [UUID: Set<CGWindowID>] {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: bootKey) == bootTime else {
            debugLog("Workspaces", "Mac restarted since the workspace windows were recorded, dropping them")
            return [:]
        }
        guard let stored = defaults.dictionary(forKey: key) as? [String: [UInt32]] else { return [:] }
        var result: [UUID: Set<CGWindowID>] = [:]
        for (id, windows) in stored {
            if let uuid = UUID(uuidString: id) { result[uuid] = Set(windows) }
        }
        return result
    }

    private static func save() {
        let stored = Dictionary(uniqueKeysWithValues: windowIDs.map { ($0.key.uuidString, Array($0.value)) })
        UserDefaults.standard.set(stored, forKey: key)
        UserDefaults.standard.set(bootTime, forKey: bootKey)
    }

    private static let bootTime: Int = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        return sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 ? Int(time.tv_sec) : 0
    }()
}

enum WorkspaceStorage {
    private static let key = "workspaces.v1"

    static func load() -> [Workspace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
    }

    static func save(_ workspaces: [Workspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Saving and opening

extension AppState {

    /// Asks for a name and saves the windows on screen now as a workspace.
    /// A workspace with the same name is replaced.
    func saveWorkspaceFromScreen() {
        guard let captured = captureWorkspace(named: "") else {
            NSSound.beep()
            showInfoAlert(
                title: "Nothing to Save",
                message: "Open the apps you want in this workspace and arrange them first"
            )
            return
        }
        guard let name = askName(
            title: "Save as Workspace",
            message: "Saves the apps on this desktop and where they are. Open it from the desktops bar or the Rapto menu to bring them back",
            button: "Save",
            initial: nextWorkspaceName()
        ) else { return }
        var workspace = captured
        workspace.name = name
        if let index = workspaces.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            workspace.id = workspaces[index].id
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
        debugLog("Workspaces", "Saved '\(name)': \(workspace.screens.count) screens, \(workspace.appCount) apps")
    }

    func renameWorkspace(_ workspace: Workspace) {
        guard let name = askName(
            title: "Rename “\(workspace.name)”",
            message: "Only the name changes. The apps and their places stay as saved",
            button: "Rename",
            initial: workspace.name
        ), name != workspace.name else { return }
        if workspaces.contains(where: { $0.id != workspace.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            NSSound.beep()
            showInfoAlert(title: "“\(name)” Already Exists", message: "Choose another name, or delete the other workspace first")
            return
        }
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].name = name
    }

    func hasWindowsToClose(_ workspace: Workspace) -> Bool {
        !windowsToClose(for: workspace).isEmpty
    }

    /// The workspace's windows on any desktop: the ones it placed or, when none of
    /// those are open, windows of its apps on the desktop that has the most of them.
    private func windowsToClose(for workspace: Workspace) -> [WindowSwitcherEntry] {
        let entries = spaceBarController.switcherWindows()
        var wanted: [String: Int] = [:]
        for app in workspace.screens.flatMap(\.slots).flatMap(\.apps) {
            wanted[app.key, default: 0] += 1
        }
        let appKey = { (entry: WindowSwitcherEntry) in
            NSRunningApplication(processIdentifier: entry.window.pid)?.bundleIdentifier ?? entry.appName
        }
        let tracked = WorkspaceSession.recordedWindows(
            in: entries,
            recorded: WorkspaceSession.windowIDs[workspace.id] ?? [],
            appKeys: Set(wanted.keys),
            appKey: appKey
        )
        if !tracked.isEmpty { return tracked }

        var best: [WindowSwitcherEntry] = []
        for spaceID in Set(entries.map(\.spaceID)) {
            var remaining = wanted
            let picked = entries.filter { entry in
                guard entry.spaceID == spaceID else { return false }
                let key = appKey(entry)
                guard let left = remaining[key], left > 0 else { return false }
                remaining[key] = left - 1
                return true
            }
            if picked.count > best.count || (picked.count == best.count && picked.first?.isOnCurrentDesktop == true) {
                best = picked
            }
        }
        return best
    }

    // MARK: - Workaround:
    // Cause: A window on a hidden desktop can't be reached through Accessibility, so it can't be closed from here.
    // Context: Rapto visits each desktop that has windows of the workspace, closes them
    //          and returns every display to the desktop it was showing before.
    /// Closes the workspace's windows wherever they are. Apps are not quit, and ask
    /// to save changes as usual.
    func closeWorkspace(_ workspace: Workspace) {
        let entries = windowsToClose(for: workspace)
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Close “\(workspace.name)”?"
        var seen = Set<String>()
        let apps = entries.map(\.appName).filter { seen.insert($0).inserted }
        let count = entries.count == 1 ? "1 window" : "\(entries.count) windows"
        let elsewhere = entries.contains { !$0.isOnCurrentDesktop }
            ? " Rapto switches to their desktop for a moment and brings you back"
            : ""
        alert.informativeText = "Closes \(count): \(apps.joined(separator: ", ")).\(elsewhere)"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var groups: [(spaceID: UInt64, displayID: String, windowIDs: Set<CGWindowID>)] = []
        for entry in entries.sorted(by: { $0.isOnCurrentDesktop && !$1.isOnCurrentDesktop }) {
            if let index = groups.firstIndex(where: { $0.spaceID == entry.spaceID }) {
                groups[index].windowIDs.insert(entry.window.windowID)
            } else {
                groups.append((entry.spaceID, entry.displayID, [entry.window.windowID]))
            }
        }
        var homes: [String: UInt64] = [:]
        for group in groups where homes[group.displayID] == nil {
            homes[group.displayID] = spaceBarController.currentDesktopID(on: group.displayID)
        }
        debugLog("Workspaces", "Closing '\(workspace.name)': \(entries.count) windows on \(groups.count) desktops")
        closeWindows(in: groups, workspace: workspace, homes: homes)
    }

    private func closeWindows(
        in groups: [(spaceID: UInt64, displayID: String, windowIDs: Set<CGWindowID>)],
        workspace: Workspace, homes: [String: UInt64]
    ) {
        guard let group = groups.first else {
            returnHome(Array(homes))
            return
        }
        let rest = Array(groups.dropFirst())
        spaceBarController.perform(on: group.spaceID, displayID: group.displayID) { [weak self] in
            guard let self else { return }
            let windows = self.windowManager.enumerateWindows().filter { group.windowIDs.contains($0.windowID) }
            let closed = windows.filter { self.accessibilityService.closeWindow($0) }.count
            WorkspaceSession.windowIDs[workspace.id]?.subtract(group.windowIDs)
            debugLog("Workspaces", "Closed \(closed) of \(group.windowIDs.count) windows on desktop \(group.spaceID)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.closeWindows(in: rest, workspace: workspace, homes: homes)
            }
        }
    }

    /// One display at a time: a new switch cancels the one still in progress
    private func returnHome(_ homes: [(key: String, value: UInt64)]) {
        guard let (displayID, home) = homes.first else { return }
        let rest = Array(homes.dropFirst())
        spaceBarController.perform(on: home, displayID: displayID) { [weak self] in
            self?.returnHome(rest)
        }
    }

    func deleteWorkspace(_ workspace: Workspace) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete “\(workspace.name)”?"
        alert.informativeText = "Your apps and windows stay open"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workspaces.removeAll { $0.id == workspace.id }
    }

    /// Opens the workspace on the desktops on screen now. Each display whose desktop
    /// already holds windows that are not part of the workspace asks on its own whether
    /// its part goes to a new desktop there, so two workspaces do not end up mixed.
    /// With `inNewDesktop` the display `displayID` gets a new desktop without asking.
    func requestOpenWorkspace(_ workspace: Workspace, displayID: String? = nil, inNewDesktop: Bool = false) {
        spaceManager.refresh()
        let unplaced = workspaceTargets(for: workspace).unplaced
        var includeUnplaced = false
        if !unplaced.isEmpty {
            guard let choice = askAboutMissingDisplays(workspace, unplaced: unplaced) else { return }
            includeUnplaced = choice
        }

        let targets = workspaceTargets(for: workspace, includeUnplaced: includeUnplaced).targets
        let primary = displayID ?? screenManager.displayIdentifier(for: screenManager.activeScreen())
        var busy = displaysWithOtherWindows(targets)
        var isMultiDisplay = Set(targets.map { screenManager.displayIdentifier(for: $0.screen) }).count > 1
        // Without separate Spaces all displays share one desktop, so it is one question and one new desktop.
        if !NSScreen.screensHaveSeparateSpaces {
            busy = busy.isEmpty ? [] : [(primary, busy[0].screen)]
            isMultiDisplay = false
        }

        var separate: [(displayID: String, emptyDesktop: UInt64?)] = inNewDesktop ? [(primary, nil)] : []
        let ordered = busy.filter { $0.id == primary } + busy.filter { $0.id != primary }
        for display in ordered where !separate.contains(where: { $0.displayID == display.id }) {
            let empty = spaceBarController.emptyDesktop(on: display.id)
            guard let choice = askAboutOtherWindows(
                workspace, on: display.screen, naming: isMultiDisplay, emptyDesktopNumber: empty?.number
            ) else { return }
            switch choice {
            case .emptyDesktop: separate.append((display.id, empty?.id))
            case .newDesktop: separate.append((display.id, nil))
            case .here: break
            }
        }
        openWorkspace(workspace, includeUnplaced: includeUnplaced, separatelyOn: separate)
    }

    /// Opens a workspace in a new desktop on this display. Other displays of the
    /// workspace still ask if their desktops already hold other windows.
    func requestOpenWorkspaceInNewDesktop(_ workspace: Workspace, displayID: String) {
        requestOpenWorkspace(workspace, displayID: displayID, inNewDesktop: true)
    }

    /// Displays that the workspace uses and whose desktop shows windows it does not
    /// include, in the order of the workspace.
    private func displaysWithOtherWindows(_ targets: [WorkspaceTarget]) -> [(id: String, screen: NSScreen)] {
        let windows = windowManager.enumerateWindows()
        let matchedIDs = Set(matchWorkspaceWindows(targets, windows: windows).joined().joined().map(\.windowID))
        var result: [(id: String, screen: NSScreen)] = []
        for target in targets {
            let id = screenManager.displayIdentifier(for: target.screen)
            guard !result.contains(where: { $0.id == id }) else { continue }
            let screenID = screenManager.identifier(for: target.screen)
            let hasOthers = windows.contains { window in
                !matchedIDs.contains(window.windowID)
                    && screenManager.identifier(for: screenManager.screen(for: window)) == screenID
            }
            if hasOthers {
                result.append((id, target.screen))
            }
        }
        return result
    }

    private enum OtherWindowsChoice {
        case emptyDesktop, newDesktop, here
    }

    /// Where this display's part goes when its desktop holds other windows; nil cancels.
    /// An empty desktop of the display is offered next to a new one. With several
    /// displays the alert names this one.
    private func askAboutOtherWindows(
        _ workspace: Workspace, on screen: NSScreen, naming: Bool, emptyDesktopNumber: Int?
    ) -> OtherWindowsChoice? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let separate = emptyDesktopNumber.map { "on Desktop \($0), which is empty, or in a new desktop" } ?? "in a new desktop"
        if naming {
            alert.messageText = "“\(screen.localizedName)” Has Other Windows"
            alert.informativeText = "Open the part of “\(workspace.name)” for this display \(separate), or next to those windows"
        } else {
            alert.messageText = "This Desktop Has Other Windows"
            alert.informativeText = "Open “\(workspace.name)” \(separate) to keep it separate, or open it here next to them"
        }
        var choices: [OtherWindowsChoice] = []
        if let emptyDesktopNumber {
            alert.addButton(withTitle: "Open on Desktop \(emptyDesktopNumber)")
            choices.append(.emptyDesktop)
        }
        alert.addButton(withTitle: "Open in New Desktop")
        alert.addButton(withTitle: "Open Here")
        choices += [.newDesktop, .here]
        alert.addButton(withTitle: "Cancel")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : nil
    }

    /// Switches each of these displays in turn to its empty desktop, or to a desktop
    /// added for it, then opens the workspace on the desktops now on screen.
    private func openWorkspace(
        _ workspace: Workspace, includeUnplaced: Bool, separatelyOn displays: [(displayID: String, emptyDesktop: UInt64?)]
    ) {
        guard let (displayID, emptyDesktop) = displays.first else {
            openWorkspace(workspace, includeUnplaced: includeUnplaced)
            return
        }
        let rest = Array(displays.dropFirst())
        let openRest: (UInt64) -> Void = { [weak self] desktopID in
            self?.spaceBarController.perform(on: desktopID, displayID: displayID) {
                self?.openWorkspace(workspace, includeUnplaced: includeUnplaced, separatelyOn: rest)
            }
        }
        if let emptyDesktop {
            debugLog("Workspaces", "Opening '\(workspace.name)' on empty desktop \(emptyDesktop)")
            openRest(emptyDesktop)
        } else {
            spaceBarController.addDesktop(displayID: displayID, then: openRest)
        }
    }

    /// Asks what to do with the apps saved for displays that are not connected.
    /// True opens them on the active display, false leaves them out, nil cancels.
    private func askAboutMissingDisplays(_ workspace: Workspace, unplaced: [Workspace.Screen]) -> Bool? {
        var seen = Set<String>()
        let apps = unplaced.flatMap(\.slots).flatMap(\.apps).filter { seen.insert($0.key).inserted }.map(\.name)
        let names = unplaced.compactMap(\.displayName)
        let display = names.count == 1 ? "“\(names[0])”" : (unplaced.count == 1 ? "a display" : "\(unplaced.count) displays")
        let thisDisplay = screenManager.activeScreen().localizedName

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = unplaced.count == 1 ? "A Display Is Not Connected" : "Some Displays Are Not Connected"
        alert.informativeText = "“\(workspace.name)” also uses \(display), with \(apps.joined(separator: ", ")). Open these apps on “\(thisDisplay)”, or open the workspace without them"
        alert.addButton(withTitle: "Open on This Display")
        alert.addButton(withTitle: "Open Without Them")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// Brings the workspace's apps onto the desktops on screen now. Windows already
    /// here move into place, apps that are not running are launched first.
    func openWorkspace(_ workspace: Workspace, includeUnplaced: Bool = false) {
        spaceManager.refresh()
        let targets = workspaceTargets(for: workspace, includeUnplaced: includeUnplaced).targets
        guard !targets.isEmpty else { return }

        var modeChanged = false
        for target in targets where target.part.templateID != nil && mode(for: target.screen) != .manualAssignment {
            setMode(.manualAssignment, for: target.screen, restoreManualLayout: false)
            modeChanged = true
        }

        let windows = windowManager.enumerateWindows()
        let matched = matchWorkspaceWindows(targets, windows: windows)
        let launched = launchMissingApps(targets, matched: matched)
        debugLog("Workspaces", "Opening '\(workspace.name)': \(targets.count) screens, launching \(launched.count) apps")

        // A mode change tiles the screen on its own first, so place after it.
        let firstTry: TimeInterval = modeChanged || !launched.isEmpty ? 0.5 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + firstTry) { [weak self] in
            self?.placeWorkspaceWhenReady(workspace, targets: targets, launched: launched,
                                          deadline: Date().addingTimeInterval(10))
        }
    }

    // MARK: Capture

    func captureWorkspace(named name: String) -> Workspace? {
        let windows = windowManager.enumerateWindows()
        let liveIDs = Set(windows.map(\.windowID))
        var parts: [Workspace.Screen] = []

        for screen in NSScreen.screens {
            let screenID = screenManager.identifier(for: screen)
            let visible = cgVisibleFrame(of: screen)
            let state = layoutManager.state(forScreenID: screenID)
            let screenMode = mode(for: screen)

            if [.manualAssignment, .autoTiling].contains(screenMode), state.isActive,
               let template = state.template, allTemplates.contains(where: { $0.id == template.id }) {
                let slots = state.slots.sorted { $0.index < $1.index }.map { slot in
                    Workspace.Slot(
                        frame: relative(slot.frame, in: visible),
                        apps: slot.windows.filter { liveIDs.contains($0.windowID) }.map(workspaceApp)
                    )
                }
                if slots.contains(where: { !$0.apps.isEmpty }) {
                    parts.append(workspaceScreen(screen, templateID: template.id, slots: slots))
                }
                continue
            }

            let onScreen = windows.filter { screenManager.identifier(for: screenManager.screen(for: $0)) == screenID }
            guard !onScreen.isEmpty else { continue }
            let slots = onScreen.map { Workspace.Slot(frame: relative($0.frame, in: visible), apps: [workspaceApp($0)]) }
            parts.append(workspaceScreen(screen, templateID: nil, slots: slots))
        }

        guard !parts.isEmpty else { return nil }
        return Workspace(name: name, screens: parts)
    }

    // MARK: Opening

    private struct WorkspaceTarget {
        let part: Workspace.Screen
        let screen: NSScreen
    }

    /// Each saved screen goes to the same display. Screens that are not connected
    /// now take a connected display the workspace does not use. The ones left over
    /// have no display; with `includeUnplaced` their windows go on top of the active
    /// display at their saved positions, without a layout.
    private func workspaceTargets(for workspace: Workspace, includeUnplaced: Bool = false)
        -> (targets: [WorkspaceTarget], unplaced: [Workspace.Screen]) {
        var free = NSScreen.screens
        var targets: [WorkspaceTarget] = []
        var missing: [Workspace.Screen] = []
        for part in workspace.screens {
            let index = free.firstIndex { screen in
                if let uuid = part.displayUUID, !uuid.isEmpty {
                    return screenManager.displayIdentifier(for: screen) == uuid
                }
                return screenManager.identifier(for: screen) == part.screenID
            }
            if let index {
                targets.append(WorkspaceTarget(part: part, screen: free.remove(at: index)))
            } else {
                missing.append(part)
            }
        }
        var unplaced: [Workspace.Screen] = []
        for part in missing {
            if free.isEmpty {
                unplaced.append(part)
            } else {
                targets.append(WorkspaceTarget(part: part, screen: free.removeFirst()))
            }
        }
        if includeUnplaced {
            let screen = screenManager.activeScreen()
            for part in unplaced {
                var loose = part
                loose.templateID = nil
                targets.append(WorkspaceTarget(part: loose, screen: screen))
            }
        }
        return (targets, unplaced)
    }

    private func workspaceScreen(_ screen: NSScreen, templateID: UUID?, slots: [Workspace.Slot]) -> Workspace.Screen {
        let uuid = screenManager.displayIdentifier(for: screen)
        return Workspace.Screen(
            screenID: screenManager.identifier(for: screen),
            displayUUID: uuid.isEmpty ? nil : uuid,
            displayName: screen.localizedName,
            templateID: templateID,
            slots: slots
        )
    }

    /// `result[target][slot]` holds the windows for that slot, in the saved order.
    /// Windows already on the target display are preferred.
    private func matchWorkspaceWindows(_ targets: [WorkspaceTarget], windows: [WindowInfo]) -> [[[WindowInfo]]] {
        var used = Set<CGWindowID>()
        return targets.map { target in
            let screenID = screenManager.identifier(for: target.screen)
            return target.part.slots.map { slot in
                slot.apps.compactMap { app in
                    let candidates = windows.filter { !used.contains($0.windowID) && workspaceApp($0).key == app.key }
                    let window = candidates.first { screenManager.identifier(for: screenManager.screen(for: $0)) == screenID }
                        ?? candidates.first
                    if let window { used.insert(window.windowID) }
                    return window
                }
            }
        }
    }

    // MARK: - Workaround:
    // Cause: An app's window can't be brought here from another desktop without dragging,
    //        and launching such an app again switches to its desktop.
    // Context: Only apps that are closed, or open without a single window, are launched.
    /// Launches the apps that have no window for their slot. Returns their keys.
    private func launchMissingApps(_ targets: [WorkspaceTarget], matched: [[[WindowInfo]]]) -> Set<String> {
        var missing: [Workspace.App] = []
        for (targetIndex, target) in targets.enumerated() {
            for (slotIndex, slot) in target.part.slots.enumerated() {
                let found = matched[targetIndex][slotIndex].map(workspaceApp)
                var remaining = found
                for app in slot.apps {
                    if let index = remaining.firstIndex(where: { $0.key == app.key }) {
                        remaining.remove(at: index)
                    } else if !missing.contains(app) {
                        missing.append(app)
                    }
                }
            }
        }
        guard !missing.isEmpty else { return [] }

        let pidsWithWindows = Set(spaceBarController.switcherWindows().map(\.window.pid))
        var launched = Set<String>()
        for app in missing {
            guard let bundleID = app.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            if let running, pidsWithWindows.contains(running.processIdentifier) {
                debugLog("Workspaces", "'\(app.name)' has windows on another desktop, leaving its slot empty")
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            // A running app without windows opens a new one only when it is activated.
            configuration.activates = running != nil
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched.insert(app.key)
        }
        return launched
    }

    /// Waits until every launched app shows a window, or until the deadline, then
    /// places everything. Apps often move their first window once they finish
    /// loading, so those windows are placed once more a moment later.
    private func placeWorkspaceWhenReady(_ workspace: Workspace, targets: [WorkspaceTarget],
                                         launched: Set<String>, deadline: Date) {
        let windows = windowManager.enumerateWindows()
        let matched = matchWorkspaceWindows(targets, windows: windows)
        let foundKeys = Set(matched.joined().joined().map { workspaceApp($0).key })
        if !launched.isSubset(of: foundKeys), Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.placeWorkspaceWhenReady(workspace, targets: targets, launched: launched, deadline: deadline)
            }
            return
        }

        let placed = placeWorkspace(targets, matched: matched)
        WorkspaceSession.windowIDs[workspace.id, default: []].formUnion(placed.map(\.window.windowID))
        let fresh = placed.filter { launched.contains(workspaceApp($0.window).key) }
        if !fresh.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                for item in fresh {
                    _ = self?.accessibilityService.setWindowFrame(item.window, frame: item.frame)
                }
            }
        }
        debugLog("Workspaces", "Opened '\(workspace.name)': placed \(placed.count) windows")
    }

    private func placeWorkspace(_ targets: [WorkspaceTarget], matched: [[[WindowInfo]]]) -> [(window: WindowInfo, frame: CGRect)] {
        var placed: [(window: WindowInfo, frame: CGRect)] = []
        var front: WindowInfo?
        let activeScreenID = screenManager.identifier(for: screenManager.activeScreen())

        for (targetIndex, target) in targets.enumerated() {
            let visible = cgVisibleFrame(of: target.screen)
            let frames = target.part.slots.map { absolute($0.frame, in: visible) }
            let assignments = matched[targetIndex]
            for (slotIndex, windows) in assignments.enumerated() {
                placed += windows.map { ($0, frames[slotIndex]) }
            }

            if let templateID = target.part.templateID,
               let template = allTemplates.first(where: { $0.id == templateID }) {
                placeWindows(assignments, in: template, on: target.screen, slotFrames: frames)
            } else {
                for (slotIndex, windows) in assignments.enumerated() {
                    for window in windows {
                        _ = accessibilityService.setWindowFrame(window, frame: frames[slotIndex])
                    }
                }
                for window in assignments.compactMap(\.first).reversed() {
                    accessibilityService.raiseWindow(window)
                }
            }

            if front == nil || screenManager.identifier(for: target.screen) == activeScreenID {
                front = assignments.compactMap(\.first).first ?? front
            }
        }

        if let front {
            NSRunningApplication(processIdentifier: front.ownerPID)?.activate()
            accessibilityService.raiseWindow(front)
        }
        return placed
    }

    // MARK: Helpers

    private func workspaceApp(_ window: WindowInfo) -> Workspace.App {
        Workspace.App(bundleID: window.bundleIdentifier, name: window.ownerName)
    }

    /// The visible frame in CG coordinates, the space window frames use.
    private func cgVisibleFrame(of screen: NSScreen) -> CGRect {
        screenManager.convertToCGCoordinates(frame: screen.visibleFrame, for: screen)
    }

    private func relative(_ frame: CGRect, in visible: CGRect) -> CGRect {
        CGRect(
            x: (frame.minX - visible.minX) / visible.width,
            y: (frame.minY - visible.minY) / visible.height,
            width: frame.width / visible.width,
            height: frame.height / visible.height
        )
    }

    private func absolute(_ frame: CGRect, in visible: CGRect) -> CGRect {
        CGRect(
            x: visible.minX + frame.minX * visible.width,
            y: visible.minY + frame.minY * visible.height,
            width: frame.width * visible.width,
            height: frame.height * visible.height
        ).integral
    }

    func askName(title: String, message: String, button: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func nextWorkspaceName() -> String {
        var number = workspaces.count + 1
        while workspaces.contains(where: { $0.name == "Workspace \(number)" }) {
            number += 1
        }
        return "Workspace \(number)"
    }

    func showInfoAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
