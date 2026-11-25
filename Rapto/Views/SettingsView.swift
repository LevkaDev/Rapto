//
//  SettingsView.swift
//  Rapto
//
//  Settings window: neumorphic sidebar with search, general settings, shortcuts,
//  workspaces, release notes, about, and window controller.
//  Behavior, Appearance, and Apps tabs live in Views/Settings/.
//

import SwiftUI
import AppKit
import Combine
import Carbon

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case guide = "Guide"
    case general = "General"
    case behavior = "Behavior"
    case appearance = "Appearance"
    case apps = "Apps"
    case shortcuts = "Shortcuts"
    case workspaces = "Workspaces"
    case whatsNew = "What's New"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guide: return "compass.drawing"
        case .general: return "gearshape"
        case .behavior: return "slider.horizontal.3"
        case .appearance: return "paintbrush"
        case .apps: return "app.badge.checkmark"
        case .shortcuts: return "keyboard"
        case .workspaces: return "square.stack.3d.up"
        case .whatsNew: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

/// Light or dark look of the Settings window
enum SettingsTheme: String, CaseIterable, Identifiable {
    /// Follows macOS
    case system
    case light
    case dark

    static let defaultsKey = "settingsTheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil lets the window follow macOS
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var saved: SettingsTheme {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SettingsTheme.init) ?? .system
    }
}

/// Selected Settings tab, so other parts of the app can open Settings on a given tab
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .general
    @Published var searchQuery: String = ""
}

// MARK: - Main Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var navigation = SettingsNavigation.shared
    @FocusState private var isSearchFocused: Bool
    @State private var findKeyMonitor: Any?

    private var selectedTab: SettingsTab { navigation.selectedTab }
    private var isSearching: Bool {
        !navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.neuTextSecondary)

                    TextField("Search…", text: $navigation.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .focused($isSearchFocused)
                        .onKeyPress(.escape) {
                            if !navigation.searchQuery.isEmpty {
                                navigation.searchQuery = ""
                                return .handled
                            }
                            isSearchFocused = false
                            return .ignored
                        }

                    if !navigation.searchQuery.isEmpty {
                        Button {
                            navigation.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.neuTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .neuInset(cornerRadius: AppRadius.md)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsSidebarRow(
                            tab: tab,
                            badgeText: (tab == .guide && !appState.hasCompletedSetupGuide)
                                ? "\(appState.setupGuideCompletedStepsCount)/4"
                                : nil,
                            isSelected: !isSearching && selectedTab == tab
                        ) {
                            navigation.searchQuery = ""
                            navigation.selectedTab = tab
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(AppSpacing.md)
            .frame(width: 205)
            .neuRaised(cornerRadius: AppRadius.xxl)
            .padding(.leading, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !appState.hasAccessibilityPermission {
                        AccessibilityWarningBanner()
                    }

                    if isSearching {
                        SettingsSearchResultsView(
                            query: navigation.searchQuery,
                            onSelect: { entry in
                                navigation.searchQuery = ""
                                navigation.selectedTab = entry.tab
                            }
                        )
                    } else {
                        switch selectedTab {
                        case .guide:
                            GuideSettingsView()
                        case .general:
                            GeneralSettingsView()
                        case .behavior:
                            BehaviorSettingsView()
                        case .appearance:
                            AppearanceSettingsView()
                        case .apps:
                            AppsSettingsView()
                        case .shortcuts:
                            ShortcutsSettingsView()
                        case .workspaces:
                            WorkspacesSettingsView()
                        case .whatsNew:
                            WhatsNewSettingsView()
                        case .about:
                            AboutSettingsView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .defaultScrollAnchor(.top)
            .id(isSearching ? "search" : selectedTab.rawValue)
            .frame(minWidth: 500)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color.neuBase.ignoresSafeArea())
        .tint(.neuAccent)
        .environmentObject(appState)
        .onAppear {
            installFindMonitor()
        }
        .onDisappear {
            removeFindMonitor()
        }
    }

    private func installFindMonitor() {
        removeFindMonitor()
        findKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !appState.isRecordingShortcut,
                  SettingsWindowController.shared.isSettingsKeyWindow(event.window),
                  event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else {
                return event
            }
            isSearchFocused = true
            return nil
        }
    }

    private func removeFindMonitor() {
        if let findKeyMonitor {
            NSEvent.removeMonitor(findKeyMonitor)
        }
        findKeyMonitor = nil
    }
}

// MARK: - Search Results View

private struct SettingsSearchResultsView: View {
    let query: String
    let onSelect: (SettingsSearchEntry) -> Void

    private var results: [SettingsSearchEntry] {
        SettingsSearch.filter(query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Results")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 8)

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundStyle(.neuTextSecondary)
                    Text("No settings matching “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .font(.callout)
                        .foregroundStyle(.neuTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .neuInset(cornerRadius: AppRadius.xl)
            } else {
                VStack(spacing: 10) {
                    ForEach(results) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.tab.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.neuAccent)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(entry.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.neuTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 4) {
                                    Text(entry.tab.rawValue)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.neuTextSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .neuInset(cornerRadius: AppRadius.sm)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .neuRaised(cornerRadius: AppRadius.md, depth: .small)
                            .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar Row

/// Navigation row: flat at rest, pressed into the panel when selected.
private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    var badgeText: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .neuAccent : .neuTextSecondary)

                Text(tab.rawValue)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.neuAccent : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.neuTextSecondary)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuSurface(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous),
                level: isSelected ? .inset(.small) : (isHovered ? .raised(.small) : .flat)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.appQuick, value: isHovered)
        .animation(.appQuick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Settings Section Component

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(.neuAccent)
                }
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuRaised(cornerRadius: AppRadius.xl)
        }
        .padding(.bottom, 24)
    }
}

// MARK: - Settings Row Component

struct SettingsRow<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let control: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                }
            }
            Spacer()
            control
        }
    }
}

// MARK: - macOS Tiling Warning

/// Shown at the top of Settings whenever macOS Accessibility permission is turned off
private struct AccessibilityWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.neuWarning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Rapto can't move windows: Accessibility is turned off")
                    .font(.body.weight(.semibold))
                Text("Turn on Rapto in System Settings → Privacy & Security → Accessibility. This message disappears automatically once permission is granted.")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open System Settings") {
                AccessibilityService.openAccessibilitySettings()
            }
            .buttonStyle(NeuButtonStyle(kind: .primary))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neuRaised(cornerRadius: AppRadius.xl)
        .padding(.bottom, 24)
    }
}

/// Shown only while macOS's own window tiling is on
private struct MacTilingWarning: View {
    @State private var enabled = MacOSTiling.enabledOptions()

    var body: some View {
        // A VStack stays in the view tree when empty, so the observers keep working
        VStack(spacing: 0) {
            if !enabled.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.neuWarning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MacOSTiling.headline(for: enabled))
                            .font(.body.weight(.semibold))
                        Text("When macOS and Rapto both place a window, it jumps around. \(MacOSTiling.instructions(for: enabled))")
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Settings…") { MacOSTiling.openSettings() }
                        .buttonStyle(.neu)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neuRaised(cornerRadius: AppRadius.xl)
                .padding(.bottom, 24)
            }
        }
        .onAppear { enabled = MacOSTiling.enabledOptions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = MacOSTiling.enabledOptions()
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var updater = UpdaterManager.shared

    private var spaceBarPresentationSubtitle: String {
        switch appState.spaceBarPresentation {
        case .automatic: return "Hidden on screens with a notch until you point at the notch. Always shown on other screens"
        case .always: return "Always in the menu bar. Below it on screens with a notch"
        case .onHover: return "Hidden on every screen until you point at the middle of the menu bar or at the notch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            MacTilingWarning()

            SettingsSection("Startup", icon: "power") {
                SettingsRow("Launch at Login", subtitle: "Start Rapto when you log in") {
                    Toggle("", isOn: $launchAtLoginManager.isEnabled)
                        .toggleStyle(.neu)
                }
            }

            SettingsSection("Menu Bar", icon: "menubar.rectangle") {
                SettingsRow("Desktops Bar", subtitle: "Your desktops and their apps. Right-click a desktop for its mode and layout") {
                    Toggle("", isOn: $appState.showsSpaceBar)
                        .toggleStyle(.neu)
                }

                Divider()

                SettingsRow("Show Desktops Bar", subtitle: spaceBarPresentationSubtitle) {
                    Picker("", selection: $appState.spaceBarPresentation) {
                        ForEach(SpaceBarPresentation.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .disabled(!appState.showsSpaceBar)
                }

                Divider()

                SettingsRow("Menu Bar Icon", subtitle: appState.showsSpaceBar
                            ? "The Desktops Bar has the same controls"
                            : "Always shown while the Desktops Bar is off") {
                    Toggle("", isOn: Binding(
                        get: { appState.isMenuBarIconVisible },
                        set: { appState.showsMenuBarIcon = $0 }
                    ))
                    .toggleStyle(.neu)
                    .disabled(!appState.showsSpaceBar)
                }

                Divider()

                SettingsRow("Go With Moved Window", subtitle: appState.spaceBarMoveFollowsWindow
                            ? "Moving a window to another desktop takes you there. When dragging, hold Option to stay"
                            : "Moving a window to another desktop keeps you here. When dragging, hold Option to go there") {
                    Toggle("", isOn: $appState.spaceBarMoveFollowsWindow)
                        .toggleStyle(.neu)
                }
            }

            if appState.screenManager.isMultiMonitor {
                SettingsSection("Multi-Monitor", icon: "display.2") {
                    Text("Each monitor can have its own tiling mode.")
                        .font(.callout)
                        .foregroundStyle(.neuTextSecondary)
                        .padding(.bottom, 8)

                    let screenInfoArray = appState.screenManager.allScreenInfo()
                    ForEach(Array(screenInfoArray.enumerated()), id: \.element.id) { index, screenInfo in
                        if index > 0 {
                            Divider()
                        }
                        MonitorModeRow(screen: screenInfo.screen, displayName: screenInfo.name)
                    }
                }
            }

            SettingsSection("New Space Defaults", icon: "plus.square.on.square") {
                Text("Default settings for newly created Desktop Spaces.")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.bottom, 8)

                SettingsRow("Default Mode", subtitle: "Tiling mode for new Spaces") {
                    Picker("", selection: $appState.defaultModeForNewSpaces) {
                        ForEach(TilingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                if appState.defaultModeForNewSpaces == .manualAssignment || appState.defaultModeForNewSpaces == .dragSnap {
                    Divider()

                    SettingsRow("Default Template", subtitle: appState.defaultModeForNewSpaces == .dragSnap
                                ? "Layout windows snap into on new Spaces"
                                : "Layout for Manual mode on new Spaces") {
                        Picker("", selection: Binding(
                            get: { appState.defaultTemplateForNewSpaces },
                            set: { appState.defaultTemplateForNewSpaces = $0 }
                        )) {
                            Text(appState.defaultModeForNewSpaces == .dragSnap ? DragSnapLayoutName.standard : "None").tag(nil as UUID?)
                            ForEach(appState.listedTemplates) { template in
                                Text(template.name).tag(template.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                }
            }

            SettingsSection("Settings File", icon: "externaldrive") {
                SettingsRow("Save Settings to a File") {
                    Button("Export…") {
                        SettingsBackupPanels.exportSettings()
                    }
                    .buttonStyle(.neu)
                }

                Divider()

                SettingsRow("Load Settings from a File") {
                    HStack(spacing: 12) {
                        if SettingsBackupPanels.hasSafetyCopies {
                            Button("Show Backups") {
                                SettingsBackupPanels.showSafetyCopies()
                            }
                            .buttonStyle(.neu)
                        }

                        Button("Import…") {
                            SettingsBackupPanels.importSettings()
                        }
                        .buttonStyle(.neu)
                    }
                }

                Text("Saves your settings, shortcuts, layouts and workspaces to one file. Importing replaces your current settings and restarts Rapto. The settings you had are kept as a backup.")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.vertical, 4)
            }

            SettingsSection("Updates", icon: "arrow.triangle.2.circlepath") {
                SettingsRow("Automatically Check for Updates") {
                    Toggle("", isOn: Binding(
                        get: { UpdaterManager.shared.automaticChecksEnabled },
                        set: { UpdaterManager.shared.automaticChecksEnabled = $0 }
                    ))
                    .toggleStyle(.neu)
                    .labelsHidden()
                }

                Divider()

                if let version = updater.availableUpdateVersion {
                    SettingsRow("Rapto \(version) Is Available") {
                        Button("Install…") {
                            UpdaterManager.shared.checkForUpdates()
                        }
                        .buttonStyle(.neuPrimary)
                    }
                } else {
                    SettingsRow("Check for Updates") {
                        Button("Check Now") {
                            UpdaterManager.shared.checkForUpdates()
                        }
                        .buttonStyle(.neu)
                        .disabled(!UpdaterManager.shared.canCheckForUpdates)
                    }
                }

                Divider()

                SettingsRow("What's New", subtitle: "What changed in each version") {
                    Button("Show") {
                        SettingsNavigation.shared.selectedTab = .whatsNew
                    }
                    .buttonStyle(.neu)
                }
            }
        }
    }
}

// MARK: - Monitor Mode Row

struct MonitorModeRow: View {
    @EnvironmentObject var appState: AppState
    let screen: NSScreen
    let displayName: String

    private var currentMode: TilingMode {
        appState.mode(for: screen)
    }

    private var isPrimary: Bool {
        screen == NSScreen.screens.first
    }

    var body: some View {
        SettingsRow(displayName, subtitle: isPrimary ? "Primary display" : nil) {
            Picker("", selection: Binding(
                get: { currentMode },
                set: { newMode in
                    appState.setMode(newMode, for: screen)
                }
            )) {
                ForEach(TilingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }
    }
}

// MARK: - Shortcuts Settings

struct ShortcutsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedPreset: HotkeyPresetType = .rapto
    @State private var basePresetType: HotkeyPresetType = .rapto
    @State private var customBindings: [HotkeyAction: HotkeyBinding] = [:]
    @State private var isCustomized: Bool = false
    @State private var recordingRowID: String?

    private let storage = HotkeyPresetStorage()

    /// Every shortcut Rapto uses right now, for the conflict check of the rows
    private var raptoShortcuts: [RaptoShortcut] {
        let actions = HotkeyAction.allCases.compactMap { action in
            currentBinding(for: action).map {
                RaptoShortcut(rowID: EditableHotkeyRow.rowID(for: action), name: action.displayName, binding: $0)
            }
        }
        let templates = appState.templateHotkeys.map { hotkey in
            RaptoShortcut(
                rowID: TemplateShortcutRow.rowID(for: hotkey.templateID),
                name: appState.allTemplates.first { $0.id == hotkey.templateID }?.name ?? hotkey.templateName,
                binding: HotkeyBinding(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
            )
        }
        return actions + templates
    }

    private var basePreset: HotkeyPreset {
        HotkeyPreset.preset(for: basePresetType)
    }

    private func currentBinding(for action: HotkeyAction) -> HotkeyBinding? {
        if isCustomized, let custom = customBindings[action] {
            return custom.isCleared ? nil : custom
        }
        return basePreset.bindings[action]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shortcuts")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                if isCustomized {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .buttonStyle(.neu)
                }
            }
            .padding(.bottom, 24)

            SettingsSection("Shortcut Style", icon: "keyboard") {
                HStack(spacing: 16) {
                    PresetOptionButton(
                        title: "Rapto",
                        subtitle: "⌃⌥ + Arrows",
                        icon: "square.grid.3x3",
                        isSelected: selectedPreset == .rapto,
                        action: { selectPreset(.rapto) }
                    )

                    PresetOptionButton(
                        title: "Vim Style",
                        subtitle: "⌥ + H/J/K/L",
                        icon: "keyboard",
                        isSelected: selectedPreset == .vimStyle,
                        action: { selectPreset(.vimStyle) }
                    )
                }

                if isCustomized {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.neuWarning)
                        Text("Some shortcuts have been customized. Changes are saved automatically.")
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)
                    }
                    .padding(.top, 8)
                }
            }

            SettingsSection("Window Focus", icon: "arrow.up.left.and.arrow.down.right") {
                EditableHotkeyRow(action: .focusLeft, binding: currentBinding(for: .focusLeft), onBindingChanged: { updateBinding(.focusLeft, $0) })
                Divider()
                EditableHotkeyRow(action: .focusRight, binding: currentBinding(for: .focusRight), onBindingChanged: { updateBinding(.focusRight, $0) })
                Divider()
                EditableHotkeyRow(action: .focusUp, binding: currentBinding(for: .focusUp), onBindingChanged: { updateBinding(.focusUp, $0) })
                Divider()
                EditableHotkeyRow(action: .focusDown, binding: currentBinding(for: .focusDown), onBindingChanged: { updateBinding(.focusDown, $0) })
                Divider()
                EditableHotkeyRow(action: .openWindowSwitcher, binding: currentBinding(for: .openWindowSwitcher), onBindingChanged: { updateBinding(.openWindowSwitcher, $0) })
                Divider()
                EditableHotkeyRow(action: .openWindowFlow, binding: currentBinding(for: .openWindowFlow), onBindingChanged: { updateBinding(.openWindowFlow, $0) })
            }

            SettingsSection("Window Swap", icon: "arrow.left.arrow.right") {
                EditableHotkeyRow(action: .swapLeft, binding: currentBinding(for: .swapLeft), onBindingChanged: { updateBinding(.swapLeft, $0) })
                Divider()
                EditableHotkeyRow(action: .swapRight, binding: currentBinding(for: .swapRight), onBindingChanged: { updateBinding(.swapRight, $0) })
                Divider()
                EditableHotkeyRow(action: .swapUp, binding: currentBinding(for: .swapUp), onBindingChanged: { updateBinding(.swapUp, $0) })
                Divider()
                EditableHotkeyRow(action: .swapDown, binding: currentBinding(for: .swapDown), onBindingChanged: { updateBinding(.swapDown, $0) })
            }

            SettingsSection("Window Move", icon: "arrow.right.to.line") {
                EditableHotkeyRow(action: .moveLeft, binding: currentBinding(for: .moveLeft), onBindingChanged: { updateBinding(.moveLeft, $0) })
                Divider()
                EditableHotkeyRow(action: .moveRight, binding: currentBinding(for: .moveRight), onBindingChanged: { updateBinding(.moveRight, $0) })
                Divider()
                EditableHotkeyRow(action: .moveUp, binding: currentBinding(for: .moveUp), onBindingChanged: { updateBinding(.moveUp, $0) })
                Divider()
                EditableHotkeyRow(action: .moveDown, binding: currentBinding(for: .moveDown), onBindingChanged: { updateBinding(.moveDown, $0) })
            }

            SettingsSection("Resize Slots", icon: "arrow.up.left.and.down.right.magnifyingglass") {
                EditableHotkeyRow(action: .resizeShrinkWidth, binding: currentBinding(for: .resizeShrinkWidth), onBindingChanged: { updateBinding(.resizeShrinkWidth, $0) })
                Divider()
                EditableHotkeyRow(action: .resizeGrowWidth, binding: currentBinding(for: .resizeGrowWidth), onBindingChanged: { updateBinding(.resizeGrowWidth, $0) })
                Divider()
                EditableHotkeyRow(action: .resizeShrinkHeight, binding: currentBinding(for: .resizeShrinkHeight), onBindingChanged: { updateBinding(.resizeShrinkHeight, $0) })
                Divider()
                EditableHotkeyRow(action: .resizeGrowHeight, binding: currentBinding(for: .resizeGrowHeight), onBindingChanged: { updateBinding(.resizeGrowHeight, $0) })
            }

            SettingsSection("Mode Selection", icon: "rectangle.3.group") {
                EditableHotkeyRow(action: .cycleLayout, binding: currentBinding(for: .cycleLayout), onBindingChanged: { updateBinding(.cycleLayout, $0) })
                Divider()
                EditableHotkeyRow(action: .switchToManual, binding: currentBinding(for: .switchToManual), onBindingChanged: { updateBinding(.switchToManual, $0) })
                Divider()
                EditableHotkeyRow(action: .switchToAuto, binding: currentBinding(for: .switchToAuto), onBindingChanged: { updateBinding(.switchToAuto, $0) })
                Divider()
                EditableHotkeyRow(action: .switchToDragSnap, binding: currentBinding(for: .switchToDragSnap), onBindingChanged: { updateBinding(.switchToDragSnap, $0) })
            }

            SettingsSection("Layout & Mode", icon: "square.grid.3x3") {
                EditableHotkeyRow(action: .openOverlay, binding: currentBinding(for: .openOverlay), onBindingChanged: { updateBinding(.openOverlay, $0) })
                Divider()
                EditableHotkeyRow(action: .toggleFloat, binding: currentBinding(for: .toggleFloat), onBindingChanged: { updateBinding(.toggleFloat, $0) })
                Divider()
                EditableHotkeyRow(action: .toggleFullscreen, binding: currentBinding(for: .toggleFullscreen), onBindingChanged: { updateBinding(.toggleFullscreen, $0) })
                Divider()
                EditableHotkeyRow(action: .restoreLayout, binding: currentBinding(for: .restoreLayout), onBindingChanged: { updateBinding(.restoreLayout, $0) })
            }

            SettingsSection("Window Groups", icon: "arrow.triangle.2.circlepath") {
                EditableHotkeyRow(action: .toggleGroupWindows, binding: currentBinding(for: .toggleGroupWindows), onBindingChanged: { updateBinding(.toggleGroupWindows, $0) })
                Divider()
                EditableHotkeyRow(action: .cycleGroupForward, binding: currentBinding(for: .cycleGroupForward), onBindingChanged: { updateBinding(.cycleGroupForward, $0) })
                Divider()
                EditableHotkeyRow(action: .toggleGroupIndicators, binding: currentBinding(for: .toggleGroupIndicators), onBindingChanged: { updateBinding(.toggleGroupIndicators, $0) })
            }

            SettingsSection("Focus Slots", icon: "number.square") {
                DisclosureGroup("Slot Shortcuts (1-9)") {
                    VStack(spacing: 0) {
                        EditableHotkeyRow(action: .focusSlot1, binding: currentBinding(for: .focusSlot1), onBindingChanged: { updateBinding(.focusSlot1, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot2, binding: currentBinding(for: .focusSlot2), onBindingChanged: { updateBinding(.focusSlot2, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot3, binding: currentBinding(for: .focusSlot3), onBindingChanged: { updateBinding(.focusSlot3, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot4, binding: currentBinding(for: .focusSlot4), onBindingChanged: { updateBinding(.focusSlot4, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot5, binding: currentBinding(for: .focusSlot5), onBindingChanged: { updateBinding(.focusSlot5, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot6, binding: currentBinding(for: .focusSlot6), onBindingChanged: { updateBinding(.focusSlot6, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot7, binding: currentBinding(for: .focusSlot7), onBindingChanged: { updateBinding(.focusSlot7, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot8, binding: currentBinding(for: .focusSlot8), onBindingChanged: { updateBinding(.focusSlot8, $0) })
                        Divider()
                        EditableHotkeyRow(action: .focusSlot9, binding: currentBinding(for: .focusSlot9), onBindingChanged: { updateBinding(.focusSlot9, $0) })
                    }
                }
            }

            SettingsSection("Move Window to Desktop", icon: "macwindow.on.rectangle") {
                EditableHotkeyRow(action: .moveToPreviousDesktop, binding: currentBinding(for: .moveToPreviousDesktop), onBindingChanged: { updateBinding(.moveToPreviousDesktop, $0) })
                Divider()
                EditableHotkeyRow(action: .moveToNextDesktop, binding: currentBinding(for: .moveToNextDesktop), onBindingChanged: { updateBinding(.moveToNextDesktop, $0) })
                Divider()
                DisclosureGroup("Desktop Shortcuts (1-9)") {
                    VStack(spacing: 0) {
                        ForEach(Array(HotkeyAction.moveToDesktopNumbered.enumerated()), id: \.element) { index, action in
                            if index > 0 { Divider() }
                            EditableHotkeyRow(action: action, binding: currentBinding(for: action), onBindingChanged: { updateBinding(action, $0) })
                        }
                    }
                }
            }

            if NSScreen.screens.count > 1 {
                SettingsSection("Multi-Monitor", icon: "display.2") {
                    EditableHotkeyRow(action: .moveToScreenLeft, binding: currentBinding(for: .moveToScreenLeft), onBindingChanged: { updateBinding(.moveToScreenLeft, $0) })
                    Divider()
                    EditableHotkeyRow(action: .moveToScreenRight, binding: currentBinding(for: .moveToScreenRight), onBindingChanged: { updateBinding(.moveToScreenRight, $0) })
                }
            }

            SettingsSection("Template Shortcuts", icon: "square.on.square") {
                Text("Assign custom shortcuts to apply templates:")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.bottom, 8)

                ForEach(appState.listedTemplates) { template in
                    TemplateShortcutRow(template: template)

                    if template.id != appState.listedTemplates.last?.id {
                        Divider()
                    }
                }
            }

            SettingsSection("Passthrough Apps", icon: "keyboard.badge.ellipsis") {
                SettingsRow(
                    "Pause Shortcuts in Specific Apps",
                    subtitle: "Manage terminals, Vim, VMs and games where Rapto pauses its keyboard shortcuts"
                ) {
                    Button("Open Apps") {
                        SettingsNavigation.shared.selectedTab = .apps
                    }
                    .buttonStyle(.neu)
                }
            }
        }
        .environment(\.shortcutRowsContext, ShortcutRowsContext(shortcuts: raptoShortcuts, recordingRowID: $recordingRowID))
        .onAppear {
            loadSavedState()
        }
        .onChange(of: recordingRowID) { _, row in
            appState.isRecordingShortcut = row != nil
        }
        .onDisappear {
            appState.isRecordingShortcut = false
        }
    }

    private func loadSavedState() {
        selectedPreset = storage.loadPresetType()
        basePresetType = storage.loadBasePresetType()
        if selectedPreset != .custom {
            basePresetType = selectedPreset
        }
        if let saved = storage.loadCustomBindings() {
            customBindings = saved
            isCustomized = !saved.isEmpty
        }
    }

    private func selectPreset(_ preset: HotkeyPresetType) {
        selectedPreset = preset
        basePresetType = preset
        storage.savePresetType(preset)
        storage.saveBasePresetType(preset)

        customBindings = [:]
        storage.saveCustomBindings([:])
        isCustomized = false

        appState.applyHotkeyPreset(preset)
    }

    private func updateBinding(_ action: HotkeyAction, _ binding: HotkeyBinding?) {
        let baseBinding = basePreset.bindings[action]
        let newBinding = binding ?? .cleared
        if newBinding == baseBinding || (newBinding.isCleared && baseBinding == nil) {
            customBindings.removeValue(forKey: action)
        } else {
            customBindings[action] = newBinding
        }

        storage.saveCustomBindings(customBindings)
        isCustomized = !customBindings.isEmpty

        if isCustomized {
            if selectedPreset != .custom {
                storage.saveBasePresetType(selectedPreset)
            }
            selectedPreset = .custom
            storage.savePresetType(.custom)
            appState.applyHotkeyPreset(.custom)
        } else {
            selectedPreset = basePresetType
            storage.savePresetType(basePresetType)
            appState.applyHotkeyPreset(basePresetType)
        }
    }

    private func resetToDefaults() {
        customBindings = [:]
        storage.saveCustomBindings([:])
        isCustomized = false
        selectedPreset = basePresetType
        storage.savePresetType(basePresetType)
        appState.applyHotkeyPreset(basePresetType)
    }
}

// MARK: - Preset Option Button

struct PresetOptionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .neuAccent : .neuTextSecondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.neuAccent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .neuSurface(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous),
                level: isSelected ? .inset(.small) : .raised(.small)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.appQuick, value: isSelected)
    }
}

// MARK: - Shortcut Rows Context

/// Shared by the shortcut rows of the Shortcuts page: the shortcuts Rapto uses and the one row that records
struct ShortcutRowsContext {
    var shortcuts: [RaptoShortcut] = []
    var recordingRowID: Binding<String?> = .constant(nil)
}

private struct ShortcutRowsContextKey: EnvironmentKey {
    static let defaultValue = ShortcutRowsContext()
}

extension EnvironmentValues {
    var shortcutRowsContext: ShortcutRowsContext {
        get { self[ShortcutRowsContextKey.self] }
        set { self[ShortcutRowsContextKey.self] = newValue }
    }
}

/// One recording row at a time, and checks against Rapto's own shortcuts before asking the system
private struct ShortcutRowBehavior: ViewModifier {
    let rowID: String
    @Binding var isRecording: Bool
    @Environment(\.shortcutRowsContext) private var context

    func body(content: Content) -> some View {
        content
            .onChange(of: isRecording) { _, recording in
                if recording {
                    context.recordingRowID.wrappedValue = rowID
                } else if context.recordingRowID.wrappedValue == rowID {
                    context.recordingRowID.wrappedValue = nil
                }
            }
            .onChange(of: context.recordingRowID.wrappedValue) { _, recordingRow in
                if isRecording && recordingRow != rowID {
                    isRecording = false
                }
            }
    }
}

extension HotkeyConflictDetector {
    /// Why `binding` can't go to the row `rowID`, nil when it can. `current` is the row's own shortcut:
    /// entering it again is fine, though the system check would fail because Rapto holds it.
    func blockReason(for binding: HotkeyBinding, rowID: String, current: HotkeyBinding?, shortcuts: [RaptoShortcut]) -> String? {
        if let other = Self.raptoConflict(for: binding, rowID: rowID, in: shortcuts) {
            return "This shortcut is already used by “\(other.name)” in Rapto."
        }
        if binding == current { return nil }
        let result = checkAvailability(for: binding)
        return result.isAvailable ? nil : (result.warningMessage ?? "This shortcut is already in use by another application.")
    }
}

// MARK: - Editable Hotkey Row

struct EditableHotkeyRow: View {
    let action: HotkeyAction
    let binding: HotkeyBinding?
    let onBindingChanged: (HotkeyBinding?) -> Void

    @State private var isRecording = false
    @State private var showBlockedAlert = false
    @State private var blockedMessage = ""
    @Environment(\.shortcutRowsContext) private var context

    private let conflictDetector = HotkeyConflictDetector.shared

    static func rowID(for action: HotkeyAction) -> String { "action-\(action.rawValue)" }

    var body: some View {
        SettingsRow(action.displayName) {
            HotkeyRecorderButton(
                binding: binding,
                isRecording: $isRecording,
                onBindingRecorded: handleNewBinding
            )
        }
        .modifier(ShortcutRowBehavior(rowID: Self.rowID(for: action), isRecording: $isRecording))
        .alert("Shortcut Blocked", isPresented: $showBlockedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(blockedMessage)
        }
    }

    private func handleNewBinding(_ newBinding: HotkeyBinding?) {
        guard let newBinding = newBinding else {
            onBindingChanged(nil)
            return
        }

        if conflictDetector.isSystemCritical(newBinding) {
            blockedMessage = "This shortcut (⌘Q, ⌘W, ⌘Tab) is critical for macOS and cannot be overridden."
            showBlockedAlert = true
            return
        }

        if let reason = conflictDetector.blockReason(for: newBinding, rowID: Self.rowID(for: action), current: binding, shortcuts: context.shortcuts) {
            blockedMessage = reason
            showBlockedAlert = true
            return
        }

        onBindingChanged(newBinding)
    }
}

// MARK: - Hotkey Recorder Button

struct HotkeyRecorderButton: View {
    let binding: HotkeyBinding?
    @Binding var isRecording: Bool
    let onBindingRecorded: (HotkeyBinding?) -> Void

    @State private var currentModifiers: UInt32 = 0
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording.toggle()
                if isRecording {
                    currentModifiers = 0
                }
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        if currentModifiers > 0 {
                            modifierKeysView(currentModifiers)
                            Text("+ ...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.neuAccent)
                        } else {
                            Text("Press shortcut...")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.neuAccent)
                        }
                    } else if let binding = binding {
                        keyDisplayView(binding)
                    } else {
                        Text("Click to record")
                            .font(.system(size: 13))
                            .foregroundStyle(.neuTextSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .neuSurface(
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous),
                    level: isRecording ? .inset(.small) : .raised(.small)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(.appQuick, value: isRecording)
            .onChange(of: isRecording) { _, recording in
                if recording {
                    startKeyMonitor()
                } else {
                    stopKeyMonitor()
                }
            }
            .onDisappear { stopKeyMonitor() }

            if binding != nil && !isRecording {
                Button {
                    onBindingRecorded(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.neuTextSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }

            if isRecording {
                Button("Cancel") {
                    isRecording = false
                    currentModifiers = 0
                }
                .buttonStyle(NeuButtonStyle(compact: true))
            }
        }
    }

    @ViewBuilder
    private func keyDisplayView(_ binding: HotkeyBinding) -> some View {
        HStack(spacing: 3) {
            modifierKeysView(binding.modifiers)

            KeyCapView(text: keyCodeToDisplayString(binding.keyCode), isModifier: false)
        }
    }

    @ViewBuilder
    private func modifierKeysView(_ modifiers: UInt32) -> some View {
        if modifiers & UInt32(controlKey) != 0 {
            KeyCapView(text: "⌃", isModifier: true)
        }
        if modifiers & UInt32(optionKey) != 0 {
            KeyCapView(text: "⌥", isModifier: true)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            KeyCapView(text: "⇧", isModifier: true)
        }
        if modifiers & UInt32(cmdKey) != 0 {
            KeyCapView(text: "⌘", isModifier: true)
        }
    }

    private func startKeyMonitor() {
        stopKeyMonitor()
        currentModifiers = 0
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                currentModifiers = carbonModifiers(from: event.modifierFlags)
                return event
            }
            record(event)
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        currentModifiers = 0
    }

    /// Uses the physical key, so any key works on any keyboard layout.
    private func record(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifiers = carbonModifiers(from: event.modifierFlags)
        if modifiers == 0, keyCode == 0x35 {
            isRecording = false
            return
        }
        guard modifiers != 0 || HotkeyBinding.functionKeyCodes.contains(keyCode) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onBindingRecorded(HotkeyBinding(keyCode: keyCode, modifiers: modifiers))
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func keyCodeToDisplayString(_ keyCode: UInt32) -> String {
        HotkeyBinding.keyCodeToString(keyCode)
    }
}

// MARK: - Key Cap View

struct KeyCapView: View {
    let text: String
    let isModifier: Bool

    var body: some View {
        Text(text)
            .font(.system(size: isModifier ? 14 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: isModifier ? 24 : 28, minHeight: 24)
            .padding(.horizontal, isModifier ? 4 : 6)
            .neuInset(cornerRadius: AppRadius.sm)
    }
}

// MARK: - Template Shortcut Row

struct TemplateShortcutRow: View {
    @EnvironmentObject var appState: AppState
    let template: GridTemplate

    @State private var isRecording = false
    @State private var showBlockedAlert = false
    @State private var blockedMessage = ""
    @Environment(\.shortcutRowsContext) private var context

    private let conflictDetector = HotkeyConflictDetector.shared

    static func rowID(for templateID: UUID) -> String { "template-\(templateID.uuidString)" }

    private var currentBinding: HotkeyBinding? {
        guard let hotkey = appState.hotkey(for: template) else { return nil }
        return HotkeyBinding(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    var body: some View {
        SettingsRow(template.name) {
            HotkeyRecorderButton(
                binding: currentBinding,
                isRecording: $isRecording,
                onBindingRecorded: handleNewBinding
            )
        }
        .modifier(ShortcutRowBehavior(rowID: Self.rowID(for: template.id), isRecording: $isRecording))
        .alert("Shortcut Blocked", isPresented: $showBlockedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(blockedMessage)
        }
    }

    private func handleNewBinding(_ newBinding: HotkeyBinding?) {
        guard let newBinding = newBinding else {
            appState.removeHotkey(from: template)
            return
        }

        if conflictDetector.isSystemCritical(newBinding) {
            blockedMessage = "This shortcut (⌘Q, ⌘W, ⌘Tab) is critical for macOS and cannot be overridden."
            showBlockedAlert = true
            return
        }

        if let reason = conflictDetector.blockReason(for: newBinding, rowID: Self.rowID(for: template.id), current: currentBinding, shortcuts: context.shortcuts) {
            blockedMessage = reason
            showBlockedAlert = true
            return
        }

        appState.assignCustomHotkey(to: template, binding: newBinding)
    }
}

// MARK: - Workspaces Settings

struct WorkspacesSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspaces")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            SettingsSection("Saved Workspaces", icon: "square.stack.3d.up") {
                Text("A workspace remembers the apps on a desktop and where each window goes. Opening it launches the apps that are closed and puts every window back in place")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.bottom, 8)

                if appState.workspaces.isEmpty {
                    Text("No workspaces yet")
                        .foregroundStyle(.neuTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .neuInset(cornerRadius: AppRadius.md)
                } else {
                    VStack(spacing: 0) {
                        ForEach(appState.workspaces) { workspace in
                            WorkspaceRow(workspace: workspace)
                            if workspace.id != appState.workspaces.last?.id {
                                Divider()
                            }
                        }
                    }
                    .neuInset(cornerRadius: AppRadius.md)
                }

                HStack {
                    Button {
                        appState.saveWorkspaceFromScreen()
                    } label: {
                        Label("Save Current Desktop…", systemImage: "plus")
                    }
                    .buttonStyle(.neu)
                    .help("Save the apps on the desktops on screen now as a workspace")
                    Spacer()
                }
                .padding(.top, 8)
            }

            SettingsSection("Tips", icon: "lightbulb") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right-click a desktop in the desktops bar and choose Workspaces to save it, or to open a workspace there or in a new desktop")
                    Text("Apps that already have windows on another desktop stay there, so their place in the workspace stays empty")
                    Text("Apps open with their usual window. Tabs and documents are not reopened")
                }
                .font(.callout)
                .foregroundStyle(.neuTextSecondary)
            }
        }
    }
}

private struct WorkspaceRow: View {
    @EnvironmentObject var appState: AppState
    let workspace: Workspace

    private var apps: [Workspace.App] {
        var seen = Set<String>()
        return workspace.screens.flatMap(\.slots).flatMap(\.apps).filter { seen.insert($0.key).inserted }
    }

    private var subtitle: String {
        let appText = apps.count == 1 ? "1 app" : "\(apps.count) apps"
        let screens = workspace.screens.count
        return screens > 1 ? "\(appText) · \(screens) displays" : appText
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(workspace.name)
                        .font(.body)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 4) {
                    ForEach(apps.prefix(12), id: \.key) { app in
                        Image(nsImage: icon(for: app))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .help(app.name)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Open") {
                appState.requestOpenWorkspace(workspace)
            }
            .buttonStyle(.neuPrimary)
            .help("Open on the desktop on screen now")

            Button("Close") {
                appState.closeWorkspace(workspace)
            }
            .buttonStyle(.neu)
            .help("Close all of its windows, on any desktop")

            Button {
                appState.renameWorkspace(workspace)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.neu)
            .help("Rename")
            .accessibilityLabel("Rename \(workspace.name)")

            Button {
                appState.deleteWorkspace(workspace)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.neuDestructive)
            .help("Delete")
            .accessibilityLabel("Delete \(workspace.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func icon(for app: Workspace.App) -> NSImage {
        if let bundleID = app.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}

// MARK: - About Settings

struct AboutSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var logSize: String = "Calculating..."
    @State private var showingAcknowledgements = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            SettingsSection("Rapto", icon: "square.grid.3x3") {
                HStack(spacing: 20) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    } else {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 64))
                            .foregroundStyle(.neuAccent)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rapto")
                            .font(.title)
                            .fontWeight(.semibold)

                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.neuTextSecondary)

                        Text("An ultimate macOS tiling window manager")
                            .font(.body)
                            .foregroundStyle(.neuTextSecondary)
                    }
                }
                .padding(.vertical, 8)
            }

            SettingsSection("Open Source", icon: "chevron.left.forwardslash.chevron.right") {
                SettingsRow("Source Code", subtitle: "Rapto is free and open source") {
                    Button {
                        NSWorkspace.shared.open(Self.repositoryURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text("View on GitHub")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.neu)
                }

                Divider()

                SettingsRow("Like Rapto?", subtitle: "A star helps other people find it") {
                    Button {
                        NSWorkspace.shared.open(Self.repositoryURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "star")
                            Text("Star on GitHub")
                        }
                    }
                    .buttonStyle(.neu)
                }

                Divider()

                SettingsRow("Acknowledgements", subtitle: "The work Rapto builds on, and its license") {
                    Button("Show") {
                        showingAcknowledgements = true
                    }
                    .buttonStyle(.neu)
                }
            }

            SettingsSection("Troubleshooting", icon: "ant") {
                SettingsRow("Report a Problem", subtitle: "Opens a report with your versions and setup filled in. Nothing is sent until you send it") {
                    HStack(spacing: 12) {
                        Button("On GitHub") {
                            NSWorkspace.shared.open(ProblemReport.gitHubURL(for: appState.problemReportDetails))
                        }
                        .buttonStyle(.neu)

                        Button("By Email") {
                            NSWorkspace.shared.open(ProblemReport.mailURL(for: appState.problemReportDetails))
                        }
                        .buttonStyle(.neu)
                    }
                }

                Divider()

                SettingsRow("Debug Logging") {
                    Toggle("", isOn: $appState.enableFileLogging)
                        .toggleStyle(.neu)
                        .labelsHidden()
                }

                Text("When enabled, writes detailed logs to help diagnose issues. Share these logs when reporting problems.")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.vertical, 4)

                Divider()

                SettingsRow("Log Files") {
                    HStack(spacing: 12) {
                        Text(logSize)
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)

                        Button("Clear") {
                            FileLogger.shared.clearLogs()
                            updateLogSize()
                        }
                        .buttonStyle(.neu)
                        .disabled(!appState.enableFileLogging)

                        Button {
                            FileLogger.shared.openLogDirectory()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Open Folder")
                                Image(systemName: "folder")
                            }
                        }
                        .buttonStyle(.neu)
                    }
                }
            }

            SettingsSection("Help", icon: "questionmark.circle") {
                SettingsRow("Onboarding") {
                    Button("Show Onboarding") {
                        appState.showOnboarding()
                    }
                    .buttonStyle(.neu)
                }

                Text("View the setup guide and learn about Rapto's features.")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.vertical, 4)

                #if DEBUG
                Divider()

                SettingsRow("Debug: Reset Onboarding") {
                    Button("Reset") {
                        appState.resetOnboardingForDebug()
                    }
                    .buttonStyle(.neuDestructive)
                }

                Text("Resets onboarding state so it shows again on next launch.")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.vertical, 4)
                #endif
            }
        }
        .onAppear {
            updateLogSize()
        }
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView()
        }
    }

    private func updateLogSize() {
        let size = FileLogger.shared.totalLogSize()
        if size < 1024 {
            logSize = "\(size) B"
        } else if size < 1024 * 1024 {
            logSize = String(format: "%.1f KB", Double(size) / 1024)
        } else {
            logSize = String(format: "%.1f MB", Double(size) / 1024 / 1024)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let repositoryURL = URL(string: "https://github.com/LevkaDev/Rapto")!
}

// MARK: - What's New Settings

struct WhatsNewSettingsView: View {
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            if let version = updater.availableUpdateVersion {
                SettingsSection("Update Available", icon: "arrow.down.circle") {
                    SettingsRow("Rapto \(version)", subtitle: "A new version is ready to install") {
                        Button("Install…") {
                            updater.checkForUpdates()
                        }
                        .buttonStyle(.neuPrimary)
                    }
                }
            }

            ForEach(ReleaseNotes.all) { note in
                SettingsSection(
                    note.version == ReleaseNotes.currentVersion ? "Version \(note.version) · Installed" : "Version \(note.version)",
                    icon: note.version == ReleaseNotes.currentVersion ? "checkmark.seal" : nil
                ) {
                    ForEach(note.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.neuTextSecondary)
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.neuTextSecondary)
                                    Text(item)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }

            if ReleaseNotes.all.isEmpty {
                Text("Release notes aren't available in this build.")
                    .foregroundStyle(.neuTextSecondary)
            }
        }
    }
}

// MARK: - Settings Window Controller

@MainActor
class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    private override init() {
        super.init()
    }

    func isSettingsKeyWindow(_ eventWindow: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isKeyWindow && eventWindow === window
    }

    func showSettings(appState: AppState, tab: SettingsTab? = nil) {
        appState.refreshAccessibilityPermission()
        SettingsNavigation.shared.searchQuery = ""
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        } else if window == nil {
            SettingsNavigation.shared.selectedTab = appState.hasCompletedSetupGuide ? .general : .guide
        }

        if let existingWindow = window {
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: AnyView(settingsView))
        hostingController = controller

        let newWindow = NSWindow(contentViewController: controller)
        newWindow.title = "Rapto Settings"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 780, height: 580))
        newWindow.minSize = NSSize(width: 720, height: 520)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self

        newWindow.level = .floating
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        newWindow.toolbarStyle = .unified
        newWindow.titlebarAppearsTransparent = true
        newWindow.backgroundColor = .neuBase
        newWindow.appearance = SettingsTheme.saved.appearance

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Sheets follow their parent window, so the app picker changes with it
    func applyTheme() {
        window?.appearance = SettingsTheme.saved.appearance
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        MainActor.assumeIsolated {
            guard self.window === closingWindow else { return }

            self.hostingController?.rootView = AnyView(EmptyView())
            self.hostingController = nil
            self.window = nil
        }
    }
}
