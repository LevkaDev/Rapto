//
//  RaptoApp.swift
//  Rapto
//
//  The app's entry point, its menu bar item and its windows.
//

import SwiftUI
import Combine
import Carbon

@main
enum RaptoMain {
    static func main() {
        // Unit tests run inside the app; a full Rapto there would arrange real windows and register shortcuts
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            RaptoApp.main()
        }
    }
}

struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct RaptoApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var overlayCoordinator = OverlayCoordinator()
    init() {
        // Created early so Sparkle's scheduled update checks start at launch
        _ = UpdaterManager.shared
    }
    
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { appState.isMenuBarIconVisible },
            set: { appState.menuBarIconInsertionChanged($0) }
        )) {
            MenuBarView()
                .environmentObject(appState)
                .onAppear {
                    appState.refreshAccessibilityPermission()
                    appState.checkAndShowOnboardingIfNeeded()
                }
        } label: {
            if appState.hasAccessibilityPermission {
                Image("MenuBarIcon")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: appState.isOverlayVisible) { _, isVisible in
            if isVisible {
                overlayCoordinator.showOverlay(appState: appState)
            } else {
                overlayCoordinator.hideOverlay()
            }
        }
    }
}

@MainActor
class OverlayCoordinator: ObservableObject {
    private var overlayController: OverlayWindowController?
    
    func showOverlay(appState: AppState) {
        let overlayView = OverlayView()
            .environmentObject(appState)
        
        overlayController?.hide()
        overlayController = OverlayWindowController(contentView: overlayView)
        overlayController?.onEscape = { [weak appState] in
            appState?.dismissOverlay()
        }
        overlayController?.show()
    }
    
    func hideOverlay() {
        overlayController?.hide()
        overlayController = nil
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updater = UpdaterManager.shared
    
    /// The active layout's template name, else the template configured for the current desktop
    private var currentTemplateName: String {
        if let template = appState.layoutManager.state.template {
            return template.name
        }
        let config = appState.configuration(forSpaceID: appState.spaceManager.currentSpaceID)
        if let templateID = config.templateID,
           let template = appState.allTemplates.first(where: { $0.id == templateID }) {
            return template.name
        }
        return "None"
    }
    
    /// The active layout's template name on a screen, else the template configured for that screen's desktop
    private func templateName(forScreenID screenID: String, screen: NSScreen) -> String {
        let layoutState = appState.layoutManager.state(forScreenID: screenID)
        if let template = layoutState.template {
            return template.name
        }
        // Each screen has its own current desktop, so look up this screen's Space
        let screenSpaceID = appState.spaceID(for: screen)
        let config = appState.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID
        )
        if let templateID = config.templateID,
           let template = appState.allTemplates.first(where: { $0.id == templateID }) {
            return template.name
        }
        // No template configured - return "None" so no checkmark appears in menu
        return "None"
    }
    
    private var isMultiMonitor: Bool {
        appState.screenManager.isMultiMonitor
    }
    
    private func spaceName(forDisplayID displayID: String) -> String {
        if let spaceID = appState.spaceManager.currentSpaceID(forDisplayID: displayID) {
            let name = appState.spaceManager.displayName(forSpaceID: spaceID, onDisplay: displayID)
            return name
        }
        return "Desktop"
    }
    
    var body: some View {
        if !appState.hasAccessibilityPermission {
            Button {
                AccessibilityService.openAccessibilitySettings()
            } label: {
                Label("Accessibility Is Turned Off — Open System Settings…", systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        }

        Section("\(appState.spaceManager.currentSpaceDisplayName)") {
            if isMultiMonitor {
                let screenInfoArray = appState.screenManager.allScreenInfo()
                ForEach(Array(screenInfoArray.enumerated()), id: \.element.id) { _, screenInfo in
                    let screenMode = appState.mode(for: screenInfo.screen)
                    let screenID = appState.screenManager.identifier(for: screenInfo.screen)
                    let screenTemplateName = templateName(forScreenID: screenID, screen: screenInfo.screen)
                    let displayID = appState.screenManager.displayIdentifier(for: screenInfo.screen)
                    let screenSpaceName = spaceName(forDisplayID: displayID)
                    
                    Menu("\(screenInfo.name) (\(screenSpaceName)): \(screenMode.displayName)") {
                        ForEach(TilingMode.allCases) { mode in
                            Toggle(mode.displayName, isOn: Binding(
                                get: { mode == screenMode },
                                set: { _ in appState.setMode(mode, for: screenInfo.screen) }
                            ))
                        }
                        
                        if screenMode == .manualAssignment {
                            Divider()
                            Menu("Layout: \(screenTemplateName)") {
                                ForEach(appState.listedTemplates) { template in
                                    Toggle(template.name, isOn: Binding(
                                        get: { template.name == screenTemplateName },
                                        set: { _ in appState.applyTemplateToScreen(template: template, screen: screenInfo.screen) }
                                    ))
                                }
                            }
                        } else if screenMode == .dragSnap {
                            Divider()
                            DragSnapLayoutMenu(appState: appState, screen: screenInfo.screen)
                        }
                    }
                }
            } else {
                Menu("Mode: \(appState.currentMode.displayName)") {
                    ForEach(TilingMode.allCases) { mode in
                        Button(mode.displayName) {
                            appState.currentMode = mode
                        }
                    }
                }
                
                if appState.currentMode == .manualAssignment {
                    Menu("Layout: \(currentTemplateName)") {
                        ForEach(appState.listedTemplates) { template in
                            Button(template.name) {
                                appState.applyTemplateDirectly(templateID: template.id)
                            }
                        }
                    }
                } else if appState.currentMode == .dragSnap {
                    DragSnapLayoutMenu(appState: appState, screen: appState.screenManager.activeScreen())
                }
            }
        }
        
        Divider()
        
        Section("Quick Actions") {
            Button("Open Overlay") {
                appState.toggleOverlay()
            }
            .keyboardShortcut("g", modifiers: [.control, .option])
            .disabled(appState.currentMode == .autoTiling)
            
            Button("Restore Layout") {
                appState.restoreLayoutToOriginal()
            }
            .keyboardShortcut("r", modifiers: [.control, .option])
            .disabled(!appState.layoutManager.state.isActive)
            
            Button("Create Layout from Windows") {
                appState.createLayoutFromWindowsAskingName()
            }
            
            Menu("Workspaces") {
                Button("Save as Workspace…") {
                    appState.saveWorkspaceFromScreen()
                }
                if !appState.workspaces.isEmpty {
                    Divider()
                    ForEach(appState.workspaces) { workspace in
                        Button(workspace.name) {
                            appState.requestOpenWorkspace(workspace)
                        }
                    }
                    Menu("Close Workspace") {
                        ForEach(appState.workspaces) { workspace in
                            Button(workspace.name) {
                                appState.closeWorkspace(workspace)
                            }
                        }
                    }
                    Divider()
                    Menu("Rename Workspace") {
                        ForEach(appState.workspaces) { workspace in
                            Button(workspace.name) {
                                appState.renameWorkspace(workspace)
                            }
                        }
                    }
                    Menu("Delete Workspace") {
                        ForEach(appState.workspaces) { workspace in
                            Button(workspace.name) {
                                appState.deleteWorkspace(workspace)
                            }
                        }
                    }
                }
            }

            if let frontApp = frontmostControllableApp {
                Menu(frontApp.name) {
                    Toggle("Always Ignore \(frontApp.name)", isOn: Binding(
                        get: { appState.ignoredApps.contains(frontApp.bundleID) },
                        set: { shouldIgnore in
                            if shouldIgnore {
                                appState.addIgnoredApp(frontApp.bundleID)
                            } else {
                                appState.removeIgnoredApp(frontApp.bundleID)
                            }
                        }
                    ))

                    Toggle("Pause Shortcuts in \(frontApp.name)", isOn: Binding(
                        get: { appState.passthroughApps.contains(frontApp.bundleID) },
                        set: { shouldPause in
                            if shouldPause {
                                appState.addPassthroughApp(frontApp.bundleID)
                            } else {
                                appState.removePassthroughApp(frontApp.bundleID)
                            }
                        }
                    ))
                }
            }
        }
        
        Divider()

        Toggle("Desktops Bar", isOn: Binding(
            get: { appState.showsSpaceBar },
            set: { appState.showsSpaceBar = $0 }
        ))

        if appState.showsSpaceBar {
            Button("Hide Menu Bar Icon") {
                appState.showsMenuBarIcon = false
            }
        }

        Button("Settings...") {
            SettingsWindowController.shared.showSettings(appState: appState)
        }
        .keyboardShortcut(",", modifiers: .command)
        
        Button(updater.availableUpdateVersion.map { "Install Rapto \($0)…" } ?? "Check for Updates...") {
            UpdaterManager.shared.checkForUpdates()
        }
        
        Divider()
        
        Button("Quit Rapto") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var frontmostControllableApp: (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              AppState.canManageAppRules(forBundleIdentifier: bundleID) else {
            return nil
        }
        return (name: app.localizedName ?? bundleID, bundleID: bundleID)
    }
}
