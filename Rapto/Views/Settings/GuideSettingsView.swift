//
//  GuideSettingsView.swift
//  Rapto
//
//  First Settings tab: Operating Modes & Starter Profiles, Fine-Tune Checklist
//  (with local Smart App Scanner), and live Essential Gestures & Shortcuts.
//

import SwiftUI
import AppKit

struct GuideSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared

    @State private var scanResult = AppSuggestionScanner.ScanResult(passthrough: [], optionalIgnored: [])
    @State private var isScanningApps = true
    @State private var didResetHintsRecently = false

    private var currentBindings: [HotkeyAction: HotkeyBinding] {
        HotkeyPresetStorage().loadCurrentPreset().bindings
    }

    private var overlayShortcutText: String {
        currentBindings[.openOverlay]?.displayString ?? "⌃⌥G"
    }

    private var dominantProfile: DisplayProfile {
        DisplayProfile.dominant(for: appState.screenManager.allScreens())
    }

    private var suggestedMaxWindows: Int {
        dominantProfile.suggestedMaxWindows
    }

    private var singleWindowLayoutName: String {
        dominantProfile.suggestedSingleWindowTemplateID == PredefinedTemplates.centerFocus.id
            ? PredefinedTemplates.centerFocus.name
            : PredefinedTemplates.full.name
    }

    private var gestureSnapshot: GuideGestureCopy.Snapshot {
        GuideGestureCopy.Snapshot(
            dragMode: DragModifierMode.from(
                swapRequiresControl: appState.swapRequiresOption,
                moveRequiresShift: appState.moveRequiresShift
            ),
            isGroupingEnabled: appState.isGroupingEnabled,
            enableScrollToSwitch: appState.enableScrollToSwitch,
            focusModeEnabled: appState.focusModeEnabled,
            focusModeDoubleTapEnabled: appState.focusModeDoubleTapEnabled,
            focusModeDoubleTapModifier: appState.focusModeDoubleTapModifier,
            hasCustomFocusZone: appState.focusModeZone != nil,
            floatingDoubleTapEnabled: appState.floatingDoubleTapEnabled,
            floatingDoubleTapModifier: appState.floatingDoubleTapModifier,
            spaceBarMoveFollowsWindow: appState.spaceBarMoveFollowsWindow,
            bindings: currentBindings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.bottom, 24)

            MacTilingWarningInline()

            starterProfilesSection

            fineTuneChecklistSection

            essentialGesturesSection
        }
        .task(id: appState.dismissedAppSuggestions) {
            isScanningApps = true
            scanResult = await AppSuggestionScanner.scan(dismissed: appState.dismissedAppSuggestions)
            appState.detectedNoPassthroughApps = scanResult.passthrough.isEmpty
            isScanningApps = false
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Guide & Quick Setup")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Pick how Rapto behaves, tune it for your installed apps in a minute, and keep your live shortcuts handy.")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if appState.hasCompletedSetupGuide {
                Button {
                    appState.hasCompletedSetupGuide = false
                } label: {
                    Label("Setup Complete", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.neuAccent)
                }
                .buttonStyle(NeuButtonStyle(compact: true))
                .help("Click to show the checklist progress badge in the sidebar again")
            } else {
                HStack(spacing: 8) {
                    Text("\(appState.setupGuideCompletedStepsCount)/4 tuned")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.neuTextSecondary)
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .neuInset(cornerRadius: AppRadius.sm)

                    Button("Mark Setup Complete") {
                        withAnimation(.appSpring) {
                            appState.hasCompletedSetupGuide = true
                        }
                    }
                    .buttonStyle(NeuButtonStyle(kind: .primary, compact: true))
                }
            }
        }
    }

    // MARK: - Section 1: Operating Modes & Starter Profiles

    private var starterProfilesSection: some View {
        SettingsSection("1. Operating Modes & Starter Profiles", icon: "sparkles.rectangle.stack") {
            Text("Each desktop and display can use its own mode. Pick a starter profile below to apply that mode now (with 4 px gaps and recommended defaults), or switch individual desktops anytime from the Desktops Bar.")
                .font(.callout)
                .foregroundStyle(.neuTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                StarterProfileCard(
                    mode: .dragSnap,
                    tagline: "Free windows, snap on demand",
                    description: "Windows stay free until you drag them — snap to screen edges & corners, the top layout bar, or a layout chosen for that desktop (right-click desktop → Layout). Drop into an occupied zone to group; hold ⌥ Option to move freely.",
                    defaultsSummary: "Applies Drag to Snap + 4 px gaps + hides active border on snapped windows",
                    isActiveProfile: isProfileActive(.dragSnap),
                    onApply: { appState.applyStarterProfile(.dragSnap) }
                )

                StarterProfileCard(
                    mode: .manualAssignment,
                    tagline: "Fixed grid with automatic window groups",
                    description: "Choose a layout from the Desktops Bar, menu, template shortcut, or optional \(overlayShortcutText) overlay — you never have to open the overlay. Rapto keeps current and new windows in its slots, resizes shared borders together, and automatically groups extra windows inside a slot with a group indicator so you can easily switch between them.",
                    defaultsSummary: "Applies Manual + 4 px gaps + 2 px active window border",
                    isActiveProfile: isProfileActive(.manualAssignment),
                    onApply: { appState.applyStarterProfile(.manualAssignment) }
                )

                StarterProfileCard(
                    mode: .autoTiling,
                    tagline: "Hands-off dynamic layouts",
                    description: "Rapto automatically switches and adapts the layout as you open and close windows (1–\(suggestedMaxWindows) slots per display, stacking extras into groups). Dragging onto another window on the same display swaps immediately.",
                    defaultsSummary: "Applies Auto-tiling (1–\(suggestedMaxWindows) windows, \(singleWindowLayoutName) for 1 window) + 4 px gaps + 2 px active border",
                    isActiveProfile: isProfileActive(.autoTiling),
                    onApply: { appState.applyStarterProfile(.autoTiling) }
                )
            }
        }
    }

    private func isProfileActive(_ mode: TilingMode) -> Bool {
        appState.currentMode == mode && appState.defaultModeForNewSpaces == mode
    }

    // MARK: - Section 2: Fine-Tune Checklist

    private var fineTuneChecklistSection: some View {
        SettingsSection("2. Fine-Tune for Your Mac", icon: "checklist") {
            smartAppScannerStep

            Divider()

            displaysAndNewDesktopsStep

            Divider()

            gapsChecklistStep

            Divider()

            ChecklistStepContainer(
                isDone: launchAtLoginManager.isEnabled,
                title: "Launch at Login",
                subtitle: "Start Rapto automatically when you log in to macOS"
            ) {
                Toggle("", isOn: $launchAtLoginManager.isEnabled)
                    .toggleStyle(.neu)
            }
        }
    }

    // MARK: - Step 1: Smart App Scanner

    private var unaddedPassthroughSuggestions: [DetectedAppSuggestion] {
        scanResult.passthrough.filter { !appState.passthroughApps.contains($0.bundleIdentifier) }
    }

    private var isAppStepDone: Bool {
        !appState.passthroughApps.isEmpty ||
        appState.ignoredApps != AppState.defaultIgnoredApps ||
        !appState.dismissedAppSuggestions.isEmpty ||
        (!isScanningApps && scanResult.passthrough.isEmpty)
    }

    private var smartAppScannerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ChecklistBadge(isDone: isAppStepDone)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Smart App Scanner")
                            .font(.body.weight(.semibold))
                        Spacer()
                        if !appState.dismissedAppSuggestions.isEmpty {
                            Button("Restore Hidden") {
                                appState.restoreDismissedAppSuggestions()
                            }
                            .buttonStyle(NeuButtonStyle(compact: true))
                        }
                        Button {
                            SettingsNavigation.shared.selectedTab = .apps
                        } label: {
                            HStack(spacing: 4) {
                                Text("All App Rules")
                                Image(systemName: "arrow.right")
                            }
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(NeuButtonStyle(compact: true))
                    }

                    Text("Built-in protection already skips dialogs, sheets, Settings/Preferences windows (including ⌘,), small pop-ups (< 300 pt), fixed-size utilities like Calculator, Xcode Organizer, and DMG installers.")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isScanningApps {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking installed apps on this Mac…")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                }
                .padding(.leading, 28)
            } else {
                if !scanResult.passthrough.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "keyboard.badge.ellipsis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.neuAccent)
                            Text("Pause Shortcuts in Terminals, Editors & VMs")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if !unaddedPassthroughSuggestions.isEmpty {
                                Button("Pause in Detected (\(unaddedPassthroughSuggestions.count))") {
                                    for app in unaddedPassthroughSuggestions {
                                        appState.addPassthroughApp(app.bundleIdentifier)
                                    }
                                }
                                .buttonStyle(NeuButtonStyle(kind: .primary, compact: true))
                            }
                        }

                        Text("Windows still tile normally, while Rapto pauses its keyboard shortcuts whenever one of these apps is focused.")
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        WrappingChipFlow(spacing: 8) {
                            ForEach(scanResult.passthrough) { suggestion in
                                let isSelected = appState.passthroughApps.contains(suggestion.bundleIdentifier)
                                AppSuggestionChip(
                                    suggestion: suggestion,
                                    isSelected: isSelected,
                                    activeHint: "Shortcuts paused",
                                    onToggle: {
                                        if isSelected {
                                            appState.removePassthroughApp(suggestion.bundleIdentifier)
                                        } else {
                                            appState.addPassthroughApp(suggestion.bundleIdentifier)
                                        }
                                    },
                                    onDismiss: {
                                        appState.dismissAppSuggestion(suggestion.bundleIdentifier)
                                    }
                                )
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neuInset(cornerRadius: AppRadius.md)
                    .padding(.leading, 28)
                }

                if !scanResult.optionalIgnored.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.app")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.neuTextSecondary)
                            Text("Optional: Leave Specific Chat & Media Apps Untiled")
                                .font(.subheadline.weight(.semibold))
                        }

                        Text("These have resizable windows, so Rapto tiles them by default. Click only the ones you prefer to keep free-floating:")
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        WrappingChipFlow(spacing: 8) {
                            ForEach(scanResult.optionalIgnored) { suggestion in
                                let isSelected = appState.ignoredApps.contains(suggestion.bundleIdentifier)
                                AppSuggestionChip(
                                    suggestion: suggestion,
                                    isSelected: isSelected,
                                    activeHint: "Ignored",
                                    onToggle: {
                                        if isSelected {
                                            appState.removeIgnoredApp(suggestion.bundleIdentifier)
                                        } else {
                                            appState.addIgnoredApp(suggestion.bundleIdentifier)
                                        }
                                    },
                                    onDismiss: {
                                        appState.dismissAppSuggestion(suggestion.bundleIdentifier)
                                    }
                                )
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .neuInset(cornerRadius: AppRadius.md)
                    .padding(.leading, 28)
                }

                if scanResult.passthrough.isEmpty && scanResult.optionalIgnored.isEmpty {
                    Text("All set — your installed apps work smoothly with Rapto out of the box.")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                        .padding(.leading, 28)
                }
            }
        }
    }

    // MARK: - Step 2: Displays & New Desktops

    private var displaysAndNewDesktopsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChecklistStepContainer(
                isDone: appState.defaultModeForNewSpaces != .none,
                title: "Default Mode for Newly Created Desktops",
                subtitle: appState.defaultModeForNewSpaces == .none
                    ? "Currently None — newly created macOS desktops won't tile until you pick a default mode"
                    : "Applied automatically whenever you create a new macOS desktop",
                emphasizeWarning: appState.defaultModeForNewSpaces == .none
            ) {
                Picker("", selection: $appState.defaultModeForNewSpaces) {
                    ForEach(TilingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 165)
            }

            if appState.defaultModeForNewSpaces == .manualAssignment || appState.defaultModeForNewSpaces == .dragSnap {
                let isDragSnap = appState.defaultModeForNewSpaces == .dragSnap
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Layout for New Desktops")
                            .font(.body.weight(.medium))
                        Text(isDragSnap
                             ? "The layout windows snap into on new desktops"
                             : "New desktops start with this layout. With None, you pick one on each desktop")
                            .font(.caption)
                            .foregroundStyle(.neuTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Picker("", selection: $appState.defaultTemplateForNewSpaces) {
                        Text(isDragSnap ? DragSnapLayoutName.standard : "None").tag(nil as UUID?)
                        ForEach(appState.listedTemplates) { template in
                            Text(template.name).tag(template.id as UUID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 165)
                }
                .padding(.leading, 28)
            }

            if appState.isMultiMonitor {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected Displays (Current Desktop)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.neuTextSecondary)

                    ForEach(appState.screenManager.allScreens(), id: \.self) { screen in
                        HStack {
                            Image(systemName: screen == NSScreen.main ? "display" : "rectangle.on.rectangle")
                                .foregroundStyle(.neuTextSecondary)
                                .frame(width: 18)
                            Text(appState.screenManager.displayName(for: screen))
                                .font(.subheadline)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { appState.mode(for: screen) },
                                set: { appState.setMode($0, for: screen) }
                            )) {
                                ForEach(TilingMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 165)
                        }
                    }
                }
                .padding(12)
                .neuInset(cornerRadius: AppRadius.md)
                .padding(.leading, 28)
            }
        }
    }

    // MARK: - Step 3: Gaps

    private var isGapsStepDone: Bool {
        UserDefaults.standard.object(forKey: "windowGap") != nil || appState.defaultModeForNewSpaces != .none
    }

    private var matchingGapPreset: Int? {
        let w = Int(appState.windowGap)
        let e = Int(appState.screenEdgeGap)
        guard w == e, [0, 4, 8, 12].contains(w) else { return nil }
        return w
    }

    private var gapsChecklistStep: some View {
        ChecklistStepContainer(
            isDone: isGapsStepDone,
            title: "Window & Screen Edge Gaps",
            subtitle: matchingGapPreset != nil
                ? "Currently \(Int(appState.windowGap)) px between windows and screen edges (4 px recommended)"
                : "Custom: \(Int(appState.windowGap)) px window gap · \(Int(appState.screenEdgeGap)) px edge gap"
        ) {
            HStack(spacing: 8) {
                ForEach([0, 4, 8, 12] as [Int], id: \.self) { (gap: Int) in
                    let isSelected = (matchingGapPreset == gap)
                    Button("\(gap) px") {
                        appState.setWindowGap(CGFloat(gap))
                        appState.setScreenEdgeGap(CGFloat(gap))
                    }
                    .buttonStyle(NeuButtonStyle(kind: isSelected ? .primary : .standard, compact: true))
                }

                Button {
                    SettingsNavigation.shared.selectedTab = .appearance
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(NeuButtonStyle(compact: true))
                .help("Open Appearance for separate Window & Edge gaps (0–24 px) and Live Preview")
            }
        }
    }

    // MARK: - Section 3: Essential Gestures & Shortcuts

    private var essentialGesturesSection: some View {
        SettingsSection("3. Essential Gestures & Shortcuts", icon: "hand.tap") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show In-Action Hints")
                        .font(.body)
                    Text("Subtle modifier reminders while dragging windows; hides automatically once learned")
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                }

                Spacer()

                Button(didResetHintsRecently ? "Hints Reset ✓" : "Show Hints Again") {
                    appState.resetHints()
                    didResetHintsRecently = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        didResetHintsRecently = false
                    }
                }
                .buttonStyle(NeuButtonStyle(compact: true))

                Button("Replay Onboarding") {
                    appState.showOnboarding()
                }
                .buttonStyle(NeuButtonStyle(compact: true))

                Toggle("", isOn: $appState.showsHints)
                    .toggleStyle(.neu)
            }

            Divider()

            Text("All shortcuts and modifier keys below reflect your current configuration live:")
                .font(.caption)
                .foregroundStyle(.neuTextSecondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 210), spacing: 12, alignment: .top),
                    GridItem(.flexible(minimum: 210), spacing: 12, alignment: .top)
                ],
                spacing: 12
            ) {
                ForEach(GuideGestureCopy.cards(for: gestureSnapshot)) { card in
                    GuideGestureCardView(card: card) {
                        SettingsNavigation.shared.selectedTab = card.targetTab
                    }
                }
            }
        }
    }
}

// MARK: - Inline macOS Tiling Warning

private struct MacTilingWarningInline: View {
    @State private var enabled = MacOSTiling.enabledOptions()

    var body: some View {
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
                    Button("Open Settings…") {
                        MacOSTiling.openSettings()
                    }
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

// MARK: - Starter Profile Card

private struct StarterProfileCard: View {
    let mode: TilingMode
    let tagline: String
    let description: String
    let defaultsSummary: String
    let isActiveProfile: Bool
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ModeMiniatureView(mode: mode, isActive: isActiveProfile)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(mode.displayName)
                        .font(.headline)
                        .foregroundStyle(isActiveProfile ? Color.neuAccent : Color.primary)

                    Text(tagline)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.neuTextSecondary)

                    Spacer(minLength: 8)

                    if isActiveProfile {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.neuAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .neuInset(cornerRadius: AppRadius.sm)
                    } else {
                        Button("Use \(mode.displayName)") {
                            withAnimation(.appSpring) {
                                onApply()
                            }
                        }
                        .buttonStyle(NeuButtonStyle(kind: .primary, compact: true))
                    }
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                Text(defaultsSummary)
                    .font(.caption2)
                    .foregroundStyle(.neuTextSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neuSurface(
            RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous),
            level: isActiveProfile ? .inset(.small) : .raised(.small)
        )
    }
}

// MARK: - Mode Visual Miniature

private struct ModeMiniatureView: View {
    let mode: TilingMode
    let isActive: Bool

    private var strokeColor: Color {
        isActive ? .neuAccent : .neuTextSecondary.opacity(0.75)
    }

    private var fillColor: Color {
        isActive ? Color.neuAccent.opacity(0.16) : Color.primary.opacity(0.07)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.8)
                )

            switch mode {
            case .dragSnap:
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(strokeColor, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                        .background(fillColor, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .frame(width: 22)
                    Spacer()
                }
                .padding(5)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.neuBase)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: 1.2)
                    )
                    .frame(width: 24, height: 18)
                    .offset(x: 8, y: 2)

            case .manualAssignment:
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fillColor)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(strokeColor, lineWidth: 1.2))
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(fillColor)
                            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(strokeColor, lineWidth: 1.1))
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(fillColor)
                            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(strokeColor, lineWidth: 1.1))
                    }
                }
                .padding(5)

            case .autoTiling, .none:
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(fillColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .strokeBorder(strokeColor.opacity(index == 0 ? 1 : 0.8), lineWidth: 1.1)
                            )
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 56, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - Checklist Helpers

private struct ChecklistBadge: View {
    let isDone: Bool

    var body: some View {
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(isDone ? Color.neuAccent : Color.neuTextSecondary.opacity(0.6))
            .frame(width: 18, height: 20)
    }
}

private struct ChecklistStepContainer<Control: View>: View {
    let isDone: Bool
    let title: String
    let subtitle: String
    var emphasizeWarning: Bool = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ChecklistBadge(isDone: isDone)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(emphasizeWarning ? Color.neuWarning : Color.neuTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            control
        }
    }
}

// MARK: - App Suggestion Chip

private struct AppSuggestionChip: View {
    let suggestion: DetectedAppSuggestion
    let isSelected: Bool
    let activeHint: String
    let onToggle: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    if let icon = AppSuggestionScanner.icon(for: suggestion.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app")
                            .font(.caption)
                    }

                    Text(suggestion.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.primary)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.neuTextSecondary)
                }
            }
            .buttonStyle(.plain)
            .help(isSelected ? "\(suggestion.name): \(activeHint) (click to remove)" : "Click to add \(suggestion.name)")

            if !isSelected && isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.neuTextSecondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Hide suggestion")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .neuSurface(
            Capsule(),
            level: isSelected ? .inset(.small) : .raised(.small)
        )
        .onHover { isHovered = $0 }
        .animation(.appQuick, value: isSelected)
    }
}

// MARK: - Gesture Card View

private struct GuideGestureCardView: View {
    let card: GuideGestureCardModel
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: card.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.neuAccent)
                    .frame(width: 18, height: 18)

                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)
            }

            if !card.badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(card.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .neuInset(cornerRadius: AppRadius.sm)
                    }
                }
            }

            Text(card.detail)
                .font(.caption)
                .foregroundStyle(.neuTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 2)

            Button(action: onNavigate) {
                HStack(spacing: 4) {
                    Text("Customize in \(card.targetLabel)")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.neuAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .neuInset(cornerRadius: AppRadius.md)
    }
}

// MARK: - Wrapping Flow Layout for App Chips

private struct WrappingChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            totalWidth = max(totalWidth, currentX + size.width)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }

        return CGSize(width: totalWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
