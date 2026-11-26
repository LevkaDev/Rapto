//
//  Scripting.swift
//  Rapto
//
//  AppleScript commands from Rapto.sdef, used by the Raycast extension.
//  Lists are returned as JSON text so the extension can parse them directly.
//

import AppKit

@MainActor
enum Scripting {
    static weak var appState: AppState?

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Windows

    struct WindowItem: Encodable {
        let id: UInt32
        let app: String
        let title: String
        let appPath: String?
        let desktop: Int
        let isFullScreen: Bool
        let isCurrentDesktop: Bool
        let display: String?
    }

    static func windowsJSON() -> String {
        let entries = appState?.spaceBarController.switcherWindows() ?? []
        return json(entries.map { entry in
            WindowItem(
                id: entry.window.windowID,
                app: entry.appName,
                title: entry.title,
                appPath: NSRunningApplication(processIdentifier: entry.window.pid)?.bundleURL?.path,
                desktop: entry.desktopNumber,
                isFullScreen: entry.isFullScreen,
                isCurrentDesktop: entry.isOnCurrentDesktop,
                display: entry.displayName
            )
        })
    }

    static func focusWindow(id: CGWindowID) -> Bool {
        guard let spaceBar = appState?.spaceBarController,
              let entry = spaceBar.switcherWindows().first(where: { $0.window.windowID == id }) else {
            debugLog("Scripting", "focus window \(id): not found")
            return false
        }
        debugLog("Scripting", "focus window: '\(entry.appName)' window \(id) on desktop \(entry.desktopNumber)")
        spaceBar.focusWindow(entry.window, on: entry.spaceID, displayID: entry.displayID)
        return true
    }

    // MARK: - Desktop: mode and layout

    struct DesktopInfo: Encodable {
        let mode: String
        let display: String?
        let currentLayoutID: UUID?
        let modes: [ModeItem]
        let layouts: [LayoutItem]
    }

    struct ModeItem: Encodable {
        let id: String
        let name: String
    }

    struct LayoutItem: Encodable {
        let id: UUID
        let name: String
        let isCustom: Bool
        /// x, y, width, height relative to the screen, with the origin at the bottom left (as `Zone.relativeFrame`)
        let zones: [[Double]]
    }

    static func modeName(_ mode: TilingMode) -> String {
        switch mode {
        case .none: return "Off"
        case .autoTiling: return "Auto Tiling"
        case .dragSnap: return "Drag to Snap"
        case .manualAssignment: return "Manual"
        }
    }

    /// The desktop on screen now, on the active display (`NSScreen.main`).
    static func desktopJSON() -> String {
        guard let appState else { return "null" }
        let screen = appState.screenManager.activeScreen()
        let mode = appState.mode(for: screen)
        let currentLayoutID: UUID?
        switch mode {
        case .manualAssignment:
            let screenID = appState.screenManager.identifier(for: screen)
            let config = appState.configuration(forSpaceID: appState.spaceID(for: screen), screenID: screenID)
            currentLayoutID = appState.layoutManager.state(forScreenID: screenID).template?.id ?? config.templateID
        case .dragSnap:
            currentLayoutID = appState.dragSnapTemplate(for: screen)?.id
        case .autoTiling, .none:
            currentLayoutID = nil
        }
        let customIDs = Set(appState.customTemplates.map(\.id))
        return json(DesktopInfo(
            mode: mode.rawValue,
            display: NSScreen.screens.count > 1 ? screen.localizedName : nil,
            currentLayoutID: currentLayoutID,
            modes: TilingMode.allCases.map { ModeItem(id: $0.rawValue, name: modeName($0)) },
            layouts: appState.listedTemplates.map { template in
                LayoutItem(
                    id: template.id,
                    name: template.name,
                    isCustom: customIDs.contains(template.id),
                    zones: template.zones.map {
                        let frame = $0.relativeFrame
                        return [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
                    }
                )
            }
        ))
    }

    /// Manual arranges the windows into the layout, Drag to Snap snaps windows into its zones from then on.
    /// Other modes don't use layouts.
    static func applyLayout(id: String) -> Bool {
        guard let appState,
              let uuid = UUID(uuidString: id),
              let template = appState.template(withID: uuid) else { return false }
        let screen = appState.screenManager.activeScreen()
        switch appState.mode(for: screen) {
        case .manualAssignment:
            debugLog("Scripting", "apply layout '\(template.name)'")
            appState.applyTemplateToScreen(template: template, screen: screen)
        case .dragSnap:
            debugLog("Scripting", "apply layout '\(template.name)' as the Drag to Snap layout")
            appState.setDragSnapTemplate(template, for: screen)
        case .autoTiling, .none:
            return false
        }
        return true
    }

    static func setMode(_ rawValue: String) -> Bool {
        guard let appState, let mode = TilingMode(rawValue: rawValue) else { return false }
        debugLog("Scripting", "set mode \(mode)")
        appState.setMode(mode, for: appState.screenManager.activeScreen())
        return true
    }

    // MARK: - Workspaces

    struct WorkspaceItem: Encodable {
        let id: UUID
        let name: String
        let apps: [String]
        let displays: Int
    }

    static func workspacesJSON() -> String {
        json((appState?.workspaces ?? []).map { workspace in
            var seen = Set<String>()
            let apps = workspace.screens
                .flatMap { $0.slots.flatMap(\.apps) }
                .filter { seen.insert($0.key).inserted }
                .map(\.name)
            return WorkspaceItem(id: workspace.id, name: workspace.name, apps: apps, displays: workspace.screens.count)
        })
    }

    static func openWorkspace(id: String) -> Bool {
        guard let appState,
              let uuid = UUID(uuidString: id),
              let workspace = appState.workspaces.first(where: { $0.id == uuid }) else { return false }
        debugLog("Scripting", "open workspace '\(workspace.name)'")
        // After the reply, so a question Rapto asks doesn't hold up the caller
        DispatchQueue.main.async { appState.requestOpenWorkspace(workspace) }
        return true
    }
}

// MARK: - Commands

@objc(RaptoListWindowsCommand)
final class ListWindowsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { Scripting.windowsJSON() }
    }
}

@objc(RaptoFocusWindowCommand)
final class FocusWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let id = (directParameter as? NSNumber)?.uint32Value else {
            scriptErrorNumber = errAEParamMissed
            return false
        }
        return MainActor.assumeIsolated { Scripting.focusWindow(id: id) }
    }
}

@objc(RaptoDesktopInfoCommand)
final class DesktopInfoCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { Scripting.desktopJSON() }
    }
}

@objc(RaptoApplyLayoutCommand)
final class ApplyLayoutCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let id = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            return false
        }
        return MainActor.assumeIsolated { Scripting.applyLayout(id: id) }
    }
}

@objc(RaptoSetModeCommand)
final class SetModeCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let mode = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            return false
        }
        return MainActor.assumeIsolated { Scripting.setMode(mode) }
    }
}

@objc(RaptoListWorkspacesCommand)
final class ListWorkspacesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { Scripting.workspacesJSON() }
    }
}

@objc(RaptoOpenWorkspaceCommand)
final class OpenWorkspaceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let id = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            return false
        }
        return MainActor.assumeIsolated { Scripting.openWorkspace(id: id) }
    }
}
