//
//  SpaceBarMenu.swift
//  Rapto
//
//  Right-click menu for a desktop in the desktops pill.
//

import AppKit

extension AppState {
    /// Whether an app's bundle identifier can have user Ignored / Passthrough rules toggled from menus.
    nonisolated static func canManageAppRules(
        forBundleIdentifier bundleID: String?,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == ownBundleIdentifier { return false }
        if bundleID == "com.apple.systempreferences" { return false }
        return true
    }

    /// Mode and layout for one desktop, plus an optional `<App Name>` submenu when right-clicking an app icon.
    /// Everything else stays in Settings.
    func makeSpaceBarMenu(for space: SpaceBarSpace, glyph: SpaceBarGlyph? = nil, displayID: String) -> NSMenu? {
        refreshAccessibilityPermission()
        guard let screen = screenManager.screen(forDisplayID: displayID) else { return nil }
        let screenID = screenManager.identifier(for: screen)
        let isOnScreen = space.isCurrent && spaceID(for: screen) == space.key
        let config = configuration(forSpaceID: space.key, screenID: screenID)
        let mode = config.mode
        let templateID = isOnScreen
            ? (layoutManager.state(forScreenID: screenID).template?.id ?? config.templateID)
            : config.templateID

        let menu = NSMenu()
        menu.autoenablesItems = false

        if !hasAccessibilityPermission {
            let warningItem = SpaceBarMenuItem(title: "Accessibility Is Turned Off — Open System Settings…") {
                AccessibilityService.openAccessibilitySettings()
            }
            warningItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Accessibility warning"
            )
            menu.addItem(warningItem)
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Desktop \(space.number)"))

        let modeMenu = NSMenu()
        for option in TilingMode.allCases {
            let item = SpaceBarMenuItem(title: option.displayName) { [weak self] in
                self?.spaceBarController.perform(on: space.id, displayID: displayID) {
                    self?.setMode(option, forSpaceKey: space.key, displayID: displayID)
                }
            }
            item.state = option == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Mode: \(mode.displayName)", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        if mode == .manualAssignment {
            let layoutMenu = NSMenu()
            for template in listedTemplates {
                let item = SpaceBarMenuItem(title: template.name) { [weak self] in
                    self?.spaceBarController.perform(on: space.id, displayID: displayID) {
                        guard let self, let screen = self.screenManager.screen(forDisplayID: displayID) else { return }
                        self.applyTemplateToScreen(template: template, screen: screen)
                    }
                }
                item.state = template.id == templateID ? .on : .off
                layoutMenu.addItem(item)
            }
            let templateName = allTemplates.first { $0.id == templateID }?.name ?? "None"
            let layoutItem = NSMenuItem(title: "Layout: \(templateName)", action: nil, keyEquivalent: "")
            layoutItem.submenu = layoutMenu
            menu.addItem(layoutItem)
        } else if mode == .dragSnap {
            let current = dragSnapTemplate(forSpaceKey: space.key, screenID: screenID)
            let layoutMenu = NSMenu()
            let standard = SpaceBarMenuItem(title: DragSnapLayoutName.standard) { [weak self] in
                self?.setDragSnapTemplate(nil, forSpaceKey: space.key, screenID: screenID)
            }
            standard.state = current == nil ? .on : .off
            layoutMenu.addItem(standard)
            layoutMenu.addItem(.separator())
            for template in listedTemplates {
                let item = SpaceBarMenuItem(title: template.name) { [weak self] in
                    self?.setDragSnapTemplate(template, forSpaceKey: space.key, screenID: screenID)
                }
                item.state = template.id == current?.id ? .on : .off
                layoutMenu.addItem(item)
            }
            let layoutItem = NSMenuItem(title: "Layout: \(current?.name ?? DragSnapLayoutName.standard)", action: nil, keyEquivalent: "")
            layoutItem.submenu = layoutMenu
            menu.addItem(layoutItem)
        }

        menu.addItem(workspacesItem(for: space, displayID: displayID, isOnScreen: isOnScreen))

        if let glyph,
           let appItem = appRulesSubmenuItem(for: glyph) {
            menu.addItem(.separator())
            menu.addItem(appItem)
        }

        if isOnScreen {
            menu.addItem(.separator())
            let overlay = SpaceBarMenuItem(title: "Open Overlay") { [weak self] in
                self?.toggleOverlay()
            }
            overlay.keyEquivalent = "g"
            overlay.keyEquivalentModifierMask = [.control, .option]
            overlay.isEnabled = mode != .autoTiling
            menu.addItem(overlay)

            let restore = SpaceBarMenuItem(title: "Restore Layout") { [weak self] in
                self?.restoreLayoutToOriginal()
            }
            restore.keyEquivalent = "r"
            restore.keyEquivalentModifierMask = [.control, .option]
            restore.isEnabled = layoutManager.state(forScreenID: screenID).isActive
            menu.addItem(restore)

            let fromWindows = SpaceBarMenuItem(title: "Create Layout from Windows") { [weak self] in
                guard let self else { return }
                self.createLayoutFromWindowsAskingName(on: self.screenManager.screen(for: screenID))
            }
            fromWindows.toolTip = "Saves where the windows on this display are as a new layout"
            menu.addItem(fromWindows)
        }

        menu.addItem(.separator())
        if let version = UpdaterManager.shared.availableUpdateVersion {
            menu.addItem(SpaceBarMenuItem(title: "Install Rapto \(version)…") {
                UpdaterManager.shared.checkForUpdates()
            })
        }
        let settings = SpaceBarMenuItem(title: "Settings…") { [weak self] in
            guard let self else { return }
            SettingsWindowController.shared.showSettings(appState: self)
        }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(SpaceBarMenuItem(title: "Quit Rapto") {
            NSApplication.shared.terminate(nil)
        })
        return menu
    }

    /// Open a saved workspace on this desktop or a new one, or save what is on screen.
    private func workspacesItem(for space: SpaceBarSpace, displayID: String, isOnScreen: Bool) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let save = SpaceBarMenuItem(title: "Save as Workspace…") { [weak self] in
            self?.saveWorkspaceFromScreen()
        }
        save.isEnabled = isOnScreen
        if !isOnScreen {
            save.toolTip = "Switch to this desktop to save it"
        }
        submenu.addItem(save)

        if !workspaces.isEmpty {
            submenu.addItem(.separator())
            for workspace in workspaces {
                submenu.addItem(SpaceBarMenuItem(title: workspace.name) { [weak self] in
                    self?.spaceBarController.perform(on: space.id, displayID: displayID) {
                        self?.requestOpenWorkspace(workspace, displayID: displayID)
                    }
                })
            }
            let newDesktop = NSMenu()
            for workspace in workspaces {
                newDesktop.addItem(SpaceBarMenuItem(title: workspace.name) { [weak self] in
                    self?.requestOpenWorkspaceInNewDesktop(workspace, displayID: displayID)
                })
            }
            let newDesktopItem = NSMenuItem(title: "Open in New Desktop", action: nil, keyEquivalent: "")
            newDesktopItem.submenu = newDesktop
            submenu.addItem(newDesktopItem)

            let close = NSMenu()
            close.autoenablesItems = false
            for workspace in workspaces {
                let item = SpaceBarMenuItem(title: workspace.name) { [weak self] in
                    self?.closeWorkspace(workspace)
                }
                item.isEnabled = hasWindowsToClose(workspace)
                close.addItem(item)
            }
            let closeItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
            closeItem.submenu = close
            submenu.addItem(closeItem)

            submenu.addItem(.separator())
            let rename = NSMenu()
            for workspace in workspaces {
                rename.addItem(SpaceBarMenuItem(title: workspace.name) { [weak self] in
                    self?.renameWorkspace(workspace)
                })
            }
            let renameItem = NSMenuItem(title: "Rename Workspace", action: nil, keyEquivalent: "")
            renameItem.submenu = rename
            submenu.addItem(renameItem)

            let delete = NSMenu()
            for workspace in workspaces {
                delete.addItem(SpaceBarMenuItem(title: workspace.name) { [weak self] in
                    self?.deleteWorkspace(workspace)
                })
            }
            let deleteItem = NSMenuItem(title: "Delete Workspace", action: nil, keyEquivalent: "")
            deleteItem.submenu = delete
            submenu.addItem(deleteItem)
        }

        let item = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Builds the `<App Name>` submenu with `Always Ignore` and `Pause Shortcuts` toggles
    /// when right-clicking an app icon in the Desktops Bar.
    func appRulesSubmenuItem(for glyph: SpaceBarGlyph) -> NSMenuItem? {
        let resolvedBundleID = glyph.bundleIdentifier
            ?? NSRunningApplication(processIdentifier: glyph.pid)?.bundleIdentifier
        guard let bundleID = resolvedBundleID,
              Self.canManageAppRules(forBundleIdentifier: bundleID) else {
            return nil
        }

        let appName = glyph.appName.isEmpty ? bundleID : glyph.appName
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let isIgnored = ignoredApps.contains(bundleID)
        let ignoreItem = SpaceBarMenuItem(title: "Always Ignore \(appName)") { [weak self] in
            guard let self else { return }
            if self.ignoredApps.contains(bundleID) {
                self.removeIgnoredApp(bundleID)
            } else {
                self.addIgnoredApp(bundleID)
            }
        }
        ignoreItem.state = isIgnored ? .on : .off
        submenu.addItem(ignoreItem)

        let isPassthrough = passthroughApps.contains(bundleID)
        let passthroughItem = SpaceBarMenuItem(title: "Pause Shortcuts in \(appName)") { [weak self] in
            guard let self else { return }
            if self.passthroughApps.contains(bundleID) {
                self.removePassthroughApp(bundleID)
            } else {
                self.addPassthroughApp(bundleID)
            }
        }
        passthroughItem.state = isPassthrough ? .on : .off
        submenu.addItem(passthroughItem)

        let item = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Set the mode of one desktop. Applies it now if that desktop is on screen,
    /// otherwise stores it for when the desktop is next shown.
    func setMode(_ mode: TilingMode, forSpaceKey spaceKey: String, displayID: String) {
        guard let screen = screenManager.screen(forDisplayID: displayID) else { return }
        if spaceID(for: screen) != spaceKey {
            spaceManager.refresh()
        }
        if spaceID(for: screen) == spaceKey {
            setMode(mode, for: screen)
            return
        }
        let screenID = screenManager.identifier(for: screen)
        var config = configuration(forSpaceID: spaceKey, screenID: screenID)
        if config.mode == .manualAssignment && mode != .manualAssignment {
            layoutManager.saveManualLayoutFromSavedInfo(forSpaceID: spaceKey, screenID: screenID)
        }
        config.mode = mode
        ScreenConfigurationStorage.setConfiguration(config, forSpaceID: spaceKey, screenID: screenID, in: &screenConfigurations)
    }
}

/// A menu item that runs a closure, so the menu needs no target object.
private final class SpaceBarMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
