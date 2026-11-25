//
//  AppsSettingsView.swift
//  Rapto
//
//  Per-application rules: Ignored Apps (never tiled or snapped) and Passthrough Apps
//  (keyboard shortcuts paused while focused), plus the shared installed-app picker.
//

import SwiftUI
import AppKit

struct AppsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.neuAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Built-in Window Filter Is Active")
                        .font(.subheadline.weight(.semibold))
                    Text("Dialogs, sheets, Settings and Preferences windows (including ⌘,), small pop-ups (< 300 pt), fixed-size apps such as Calculator, Xcode Organizer/Welcome, and mounted DMG installers are already excluded automatically.")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuRaised(cornerRadius: AppRadius.xl)
            .padding(.bottom, 24)

            SettingsSection("Ignored Apps", icon: "xmark.app") {
                Text("Rapto never tiles, snaps, or manages windows of these applications in any mode. Windows software run through Wine counts as the app that launches it, so programs started from one launcher are ignored together.")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.bottom, 8)

                if !appState.ignoredApps.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(appState.ignoredApps.sorted(), id: \.self) { bundleID in
                            IgnoredAppRow(bundleID: bundleID)

                            if bundleID != appState.ignoredApps.sorted().last {
                                Divider()
                            }
                        }
                    }
                    .neuInset(cornerRadius: AppRadius.md)
                } else {
                    Text("No ignored apps")
                        .foregroundStyle(.neuTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .neuInset(cornerRadius: AppRadius.md)
                }

                HStack {
                    Menu {
                        ForEach(runningAppsNotIgnored, id: \.bundleID) { app in
                            Button {
                                appState.addIgnoredApp(app.bundleID)
                            } label: {
                                Label(app.name, systemImage: "app")
                            }
                        }

                        if runningAppsNotIgnored.isEmpty {
                            Text("No running apps available")
                                .foregroundStyle(.neuTextSecondary)
                        }
                    } label: {
                        Label("Add Running App", systemImage: "play.circle")
                    }
                    .menuStyle(.borderlessButton)

                    Spacer()

                    Button {
                        showingAppPicker = true
                    } label: {
                        Label("Browse Apps...", systemImage: "folder")
                    }
                    .buttonStyle(.neu)

                    Spacer()

                    Button("Reset to Defaults") {
                        appState.resetIgnoredAppsToDefaults()
                    }
                    .buttonStyle(.neu)
                }
                .padding(.top, 8)
            }

            PassthroughAppsSection()
        }
        .sheet(isPresented: $showingAppPicker) {
            InstalledAppPickerView(
                isAlreadyAdded: { appState.ignoredApps.contains($0) },
                onSelect: { bundleID in
                    appState.addIgnoredApp(bundleID)
                }
            )
            .environmentObject(appState)
        }
    }

    /// Running apps that can be added, one entry per app: an app run through Wine has several
    /// helper processes, which all count as that app.
    private var runningAppsNotIgnored: [(bundleID: String, name: String)] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> (bundleID: String, name: String)? in
                guard app.activationPolicy == .regular,
                      let bundleID = AppBundleLookup.bundleIdentifier(for: app),
                      !appState.ignoredApps.contains(bundleID),
                      bundleID != Bundle.main.bundleIdentifier,
                      seen.insert(bundleID).inserted else { return nil }
                return (bundleID, AppBundleLookup.displayName(for: app))
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Passthrough Apps Section

struct PassthroughAppsSection: View {
    @EnvironmentObject var appState: AppState
    @State private var showingPassthroughPicker = false

    var body: some View {
        SettingsSection("Passthrough Apps", icon: "keyboard.badge.ellipsis") {
            Text("Rapto pauses its keyboard shortcuts while these apps are focused (for terminals, Vim, VMs, or games). Windows still tile normally unless the app is also in Ignored Apps.")
                .font(.callout)
                .foregroundStyle(.neuTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            if !appState.passthroughApps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(appState.passthroughApps.sorted(), id: \.self) { bundleID in
                        PassthroughAppRow(bundleID: bundleID)

                        if bundleID != appState.passthroughApps.sorted().last {
                            Divider()
                        }
                    }
                }
                .neuInset(cornerRadius: AppRadius.md)
            } else {
                Text("No passthrough apps — all hotkeys are active")
                    .foregroundStyle(.neuTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .neuInset(cornerRadius: AppRadius.md)
            }

            HStack {
                Menu {
                    ForEach(runningAppsNotPassthrough, id: \.bundleIdentifier) { app in
                        Button {
                            if let bundleID = app.bundleIdentifier {
                                appState.addPassthroughApp(bundleID)
                            }
                        } label: {
                            Label(app.localizedName ?? "Unknown", systemImage: "app")
                        }
                    }

                    if runningAppsNotPassthrough.isEmpty {
                        Text("No running apps available")
                            .foregroundStyle(.neuTextSecondary)
                    }
                } label: {
                    Label("Add Running App", systemImage: "play.circle")
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button {
                    showingPassthroughPicker = true
                } label: {
                    Label("Browse Apps...", systemImage: "folder")
                }
                .buttonStyle(.neu)

                Spacer()

                Button("Reset to Defaults") {
                    appState.resetPassthroughAppsToDefaults()
                }
                .buttonStyle(.neu)
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showingPassthroughPicker) {
            InstalledAppPickerView(
                isAlreadyAdded: { appState.passthroughApps.contains($0) },
                onSelect: { bundleID in
                    appState.addPassthroughApp(bundleID)
                }
            )
            .environmentObject(appState)
        }
    }

    private var runningAppsNotPassthrough: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bundleID = app.bundleIdentifier else { return false }
                guard app.activationPolicy == .regular else { return false }
                guard !appState.passthroughApps.contains(bundleID) else { return false }
                guard bundleID != Bundle.main.bundleIdentifier else { return false }
                return true
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

// MARK: - Installed App Model & Scanner

struct InstalledApp: Identifiable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String
    let icon: NSImage
    let path: String

    /// Enumerates standard macOS application folders off the main actor.
    static func scanInstalledApps() async -> [InstalledApp] {
        let ownBundleID = Bundle.main.bundleIdentifier
        return await Task.detached {
            var seenBundleIDs = Set<String>()
            var foundApps: [InstalledApp] = []
            let fileManager = FileManager.default
            let appDirectories = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications"
            ]

            for directory in appDirectories {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }

                for item in contents where item.hasSuffix(".app") {
                    let appPath = (directory as NSString).appendingPathComponent(item)
                    let appURL = URL(fileURLWithPath: appPath)

                    guard let bundle = Bundle(url: appURL),
                          let bundleID = bundle.bundleIdentifier else { continue }

                    if bundleID == ownBundleID || !seenBundleIDs.insert(bundleID).inserted {
                        continue
                    }

                    let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String ??
                               bundle.infoDictionary?["CFBundleName"] as? String ??
                               item.replacingOccurrences(of: ".app", with: "")

                    let icon = NSWorkspace.shared.icon(forFile: appPath)

                    foundApps.append(InstalledApp(
                        name: name,
                        bundleIdentifier: bundleID,
                        icon: icon,
                        path: appPath
                    ))
                }
            }

            return foundApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
}

// MARK: - Installed App Picker

struct InstalledAppPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var installedApps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var selectedAppID: UUID? = nil
    @FocusState private var isSearchFieldFocused: Bool

    let isAlreadyAdded: (String) -> Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Application")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.neu)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.neuTextSecondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        if let firstApp = filteredApps.first {
                            onSelect(firstApp.bundleIdentifier)
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.neuTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .neuInset(cornerRadius: AppRadius.md)
            .padding()
            .onKeyPress(.downArrow) {
                moveSelection(direction: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(direction: -1)
                return .handled
            }
            .onKeyPress(.return) {
                if let selectedID = selectedAppID,
                   let app = filteredApps.first(where: { $0.id == selectedID }) {
                    onSelect(app.bundleIdentifier)
                } else if let firstApp = filteredApps.first {
                    onSelect(firstApp.bundleIdentifier)
                }
                return .handled
            }

            Divider()

            if !isLoading && !searchText.isEmpty {
                HStack {
                    Text("\(filteredApps.count) app\(filteredApps.count == 1 ? "" : "s") found")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            if isLoading {
                Spacer()
                ProgressView("Loading apps...")
                Spacer()
            } else if filteredApps.isEmpty && !searchText.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.neuTextSecondary)
                    Text("No apps matching \"\(searchText)\"")
                        .foregroundStyle(.neuTextSecondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredApps) { app in
                                InstalledAppRowSelectable(
                                    app: app,
                                    isAdded: isAlreadyAdded(app.bundleIdentifier),
                                    isSelected: selectedAppID == app.id,
                                    onAdd: {
                                        onSelect(app.bundleIdentifier)
                                    },
                                    onSelect: {
                                        selectedAppID = app.id
                                    }
                                )
                                .id(app.id)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: selectedAppID) { _, newID in
                        if let id = newID {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 600)
        .background(Color.neuBase)
        .tint(.neuAccent)
        .task {
            isLoading = true
            installedApps = await InstalledApp.scanInstalledApps()
            isLoading = false
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: searchText) { _, _ in
            selectedAppID = filteredApps.first?.id
        }
        .onDisappear {
            installedApps = []
        }
    }

    private var filteredApps: [InstalledApp] {
        if searchText.isEmpty {
            return installedApps
        }
        return installedApps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
            app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func moveSelection(direction: Int) {
        let apps = filteredApps
        guard !apps.isEmpty else { return }

        if let currentID = selectedAppID,
           let currentIndex = apps.firstIndex(where: { $0.id == currentID }) {
            let newIndex = max(0, min(apps.count - 1, currentIndex + direction))
            selectedAppID = apps[newIndex].id
        } else {
            selectedAppID = direction > 0 ? apps.first?.id : apps.last?.id
        }
    }
}

// MARK: - Installed App Row

struct InstalledAppRowSelectable: View {
    let app: InstalledApp
    let isAdded: Bool
    let isSelected: Bool
    let onAdd: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.neuAccent : Color.primary)
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
            }

            Spacer()

            if isAdded {
                Text("Added")
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .neuInset(cornerRadius: AppRadius.sm)
            } else {
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(NeuButtonStyle(kind: .primary, compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                NeuSurface(shape: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous), level: .inset(.small))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        // SwiftUI needs the higher-count gesture first so it waits for a second tap
        .onTapGesture(count: 2) {
            if !isAdded {
                onAdd()
            }
        }
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Ignored & Passthrough App Rows

struct IgnoredAppRow: View {
    @EnvironmentObject var appState: AppState
    let bundleID: String

    var body: some View {
        AppRuleRow(bundleID: bundleID) {
            appState.removeIgnoredApp(bundleID)
        }
    }
}

struct PassthroughAppRow: View {
    @EnvironmentObject var appState: AppState
    let bundleID: String

    var body: some View {
        AppRuleRow(bundleID: bundleID) {
            appState.removePassthroughApp(bundleID)
        }
    }
}

private struct AppRuleRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = Self.appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app")
                    .font(.title)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.neuTextSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.appName(for: bundleID))
                    .font(.body)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.neuRecording)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func appName(for bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.localizedName ?? bundleID
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL) {
            return bundle.infoDictionary?["CFBundleDisplayName"] as? String ??
                   bundle.infoDictionary?["CFBundleName"] as? String ??
                   bundleID
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    static func appIcon(for bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.icon
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }
}
