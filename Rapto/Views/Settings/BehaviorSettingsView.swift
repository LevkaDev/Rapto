//
//  BehaviorSettingsView.swift
//  Rapto
//
//  Window behavior settings: dragging onto slots (move/group vs swap), window grouping,
//  focus mode, floating windows, manual mode options and auto-tiling layouts.
//

import SwiftUI
import AppKit

struct BehaviorSettingsView: View {
    @EnvironmentObject var appState: AppState

    private var dragMode: DragModifierMode {
        DragModifierMode.from(
            swapRequiresControl: appState.swapRequiresOption,
            moveRequiresShift: appState.moveRequiresShift
        )
    }

    private var currentPresetBindings: [HotkeyAction: HotkeyBinding] {
        HotkeyPresetStorage().loadCurrentPreset().bindings
    }

    private var focusShortcutText: String {
        currentPresetBindings[.toggleFullscreen]?.displayString ?? "Not set"
    }

    private var floatShortcutText: String {
        currentPresetBindings[.toggleFloat]?.displayString ?? "Not set"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Behavior")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            SettingsSection("Dragging Windows", icon: "hand.draw") {
                Text("What happens when you drag a window onto another slot in Manual mode or across displays. On an Auto-tiling desktop, dragging onto another window on the same display always swaps.")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(DragModifierMode.allCases) { option in
                        DragModifierOptionRow(
                            option: option,
                            isSelected: dragMode == option,
                            action: { option.apply(to: appState) }
                        )
                    }
                }
            }

            SettingsSection("Window Grouping", icon: "rectangle.stack") {
                SettingsRow("Enable Grouping", subtitle: "Group multiple windows in one zone") {
                    Toggle("", isOn: $appState.isGroupingEnabled)
                        .toggleStyle(.neu)
                }

                if appState.isGroupingEnabled {
                    Divider()

                    SettingsRow("Auto-group Same App", subtitle: "Automatically group windows from the same app") {
                        Toggle("", isOn: $appState.autoGroupSameApp)
                            .toggleStyle(.neu)
                    }

                    Divider()

                    SettingsRow("Follow App to Monitor", subtitle: "New windows appear on same monitor as existing app windows") {
                        Toggle("", isOn: $appState.redirectNewWindowsToAppMonitor)
                            .toggleStyle(.neu)
                    }

                    Divider()

                    SettingsRow("Scroll to Cycle", subtitle: "Use scroll wheel on group indicator") {
                        Toggle("", isOn: $appState.enableScrollToSwitch)
                            .toggleStyle(.neu)
                    }

                    Divider()

                    SettingsRow("Indicator Size", subtitle: "Size of the floating group indicator") {
                        NeuSegmentedControl(
                            selection: $appState.groupIndicatorSize,
                            options: GroupIndicatorSize.allCases.map { (value: $0, label: $0.rawValue) }
                        )
                        .frame(width: 220)
                    }

                    Divider()

                    SettingsRow("Indicator Position", subtitle: "Corner where indicator appears") {
                        NeuSegmentedControl(
                            selection: $appState.groupIndicatorPosition,
                            options: GroupIndicatorPosition.allCases.map { (value: $0, label: $0.rawValue) }
                        )
                        .frame(width: 150)
                    }
                }
            }

            SettingsSection("Focus Mode", icon: "arrow.up.left.and.arrow.down.right") {
                SettingsRow(
                    "Enable Focus Mode",
                    subtitle: "Temporarily expand focused window (\(focusShortcutText) — change in Shortcuts)"
                ) {
                    Toggle("", isOn: $appState.focusModeEnabled)
                        .toggleStyle(.neu)
                }

                if appState.focusModeEnabled {
                    Divider()

                    SettingsRow(
                        "Focus Area",
                        subtitle: appState.focusModeZone == nil
                            ? "Expands to full screen. Set a custom Focus Zone anytime from the Layout Overlay"
                            : "Using a custom Focus Zone chosen in the Layout Overlay"
                    ) {
                        if appState.focusModeZone != nil {
                            Button("Reset to Full Screen") {
                                appState.clearFocusZone()
                            }
                            .buttonStyle(.neu)
                        } else {
                            Text("Full Screen")
                                .font(.subheadline)
                                .foregroundStyle(.neuTextSecondary)
                        }
                    }

                    Divider()

                    SettingsRow("Double-click Activation", subtitle: "Activate by double-clicking window with modifier key") {
                        Toggle("", isOn: $appState.focusModeDoubleTapEnabled)
                            .toggleStyle(.neu)
                    }

                    if appState.focusModeDoubleTapEnabled {
                        Divider()

                        SettingsRow("Modifier Key", subtitle: "Hold this key while double-clicking") {
                            Picker("", selection: $appState.focusModeDoubleTapModifier) {
                                ForEach(FocusModeModifierKey.allCases, id: \.self) { modifier in
                                    Text(modifier.displayName).tag(modifier)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 200)
                        }
                    }
                }
            }

            SettingsSection("Floating Windows", icon: "pin") {
                SettingsRow(
                    "Double-click Activation",
                    subtitle: "Toggle floating by double-clicking with modifier key (keyboard shortcut: \(floatShortcutText))"
                ) {
                    Toggle("", isOn: $appState.floatingDoubleTapEnabled)
                        .toggleStyle(.neu)
                }

                if appState.floatingDoubleTapEnabled {
                    Divider()

                    SettingsRow("Modifier Key", subtitle: "Hold this key while double-clicking") {
                        Picker("", selection: $appState.floatingDoubleTapModifier) {
                            ForEach(FloatingModifierKey.allCases, id: \.self) { modifier in
                                Text(modifier.displayName).tag(modifier)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
            }

            SettingsSection("Drag to Snap", icon: "hand.draw") {
                Text("Choose which custom layouts appear in the top layout bar when dragging a window in Drag to Snap (Standard Zones).")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                if !appState.customTemplates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(appState.customTemplates) { template in
                            HStack(spacing: 12) {
                                TemplateZoneGlyph(
                                    template: template,
                                    isHighlighted: appState.isInDragSnapPicker(template)
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .font(.body)
                                    Text("\(template.zones.count) zone\(template.zones.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.neuTextSecondary)
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { appState.isInDragSnapPicker(template) },
                                    set: { appState.setInDragSnapPicker($0, for: template) }
                                ))
                                .toggleStyle(.neu)
                                .labelsHidden()
                                .accessibilityLabel("Show \(template.name) in Drag to Snap bar")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                            if template.id != appState.customTemplates.last?.id {
                                Divider()
                            }
                        }
                    }
                    .neuInset(cornerRadius: AppRadius.md)
                } else {
                    Text("No custom layouts yet — create one from the Layout Overlay")
                        .font(.callout)
                        .foregroundStyle(.neuTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .neuInset(cornerRadius: AppRadius.md)
                }
            }

            SettingsSection("Manual Mode", icon: "square.grid.2x2") {
                SettingsRow("Minimize Others", subtitle: "Minimize unassigned windows after applying a layout from the overlay") {
                    Toggle("", isOn: $appState.minimizeOthersOnApply)
                        .toggleStyle(.neu)
                }

                // Multi-monitor requires Snap Back for cross-screen move detection
                if !appState.isMultiMonitor {
                    Divider()

                    SettingsRow("Snap Back", subtitle: "Windows return to their assigned slot after dragging") {
                        Toggle("", isOn: $appState.snapBackEnabled)
                            .toggleStyle(.neu)
                    }
                }
            }

            SettingsSection("Auto-tiling", icon: "wand.and.stars") {
                Text("Configure which layout is used based on the number of open windows.")
                    .font(.callout)
                    .foregroundStyle(.neuTextSecondary)
                    .padding(.bottom, 8)

                ForEach(1...max(1, appState.autoTilingPreferences.maxWindows), id: \.self) { count in
                    if count > 1 {
                        Divider()
                    }
                    AutoTilingTemplateRow(
                        windowCount: count,
                        label: count == 1 ? "1 Window" : "\(count) Windows"
                    )
                }

                Divider()

                SettingsRow("Max Windows (Global)", subtitle: "Default depth for all screens") {
                    Picker("", selection: Binding(
                        get: { appState.autoTilingPreferences.maxWindows },
                        set: { newValue in
                            var prefs = appState.autoTilingPreferences
                            prefs.maxWindows = newValue
                            appState.autoTilingPreferences = prefs
                        }
                    )) {
                        ForEach(AutoTilingPreferences.maxWindowsRange, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }

                if appState.screenManager.isMultiMonitor {
                    Divider()

                    Text("Per-Screen Depth Overrides")
                        .font(.callout)
                        .foregroundStyle(.neuTextSecondary)
                        .padding(.top, 4)

                    ForEach(appState.screenManager.allScreenInfo(), id: \.id) { screenInfo in
                        PerScreenDepthRow(
                            screenID: screenInfo.id,
                            screenName: screenInfo.name
                        )
                    }
                }
            }
        }
    }
}

private struct DragModifierOptionRow: View {
    let option: DragModifierMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.neuAccent : Color.neuTextSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.primary)
                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.neuTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    ForEach(option.keyBadges, id: \.self) { symbol in
                        KeyCapView(text: symbol, isModifier: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuSurface(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous),
                level: isSelected ? .inset(.small) : .raised(.small)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.appQuick, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small theme-aware miniature of a template's zones for Settings rows and menus.
struct TemplateZoneGlyph: View {
    let template: GridTemplate
    var isHighlighted: Bool = false

    private let width: CGFloat = 28
    private let height: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            ForEach(template.zones) { zone in
                zoneShape(zone.relativeFrame, in: geo.size)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    /// Kept apart from `body` with typed values: as one expression it is too much for the
    /// type checker of Xcode 26.
    private func zoneShape(_ frame: CGRect, in size: CGSize) -> some View {
        let flippedY: CGFloat = 1.0 - frame.origin.y - frame.height
        let flippedMidY: CGFloat = flippedY + frame.height / 2
        let fill: Color = isHighlighted ? Color.neuAccent.opacity(0.18) : Color.primary.opacity(0.08)
        let stroke: Color = isHighlighted ? Color.neuAccent : Color.neuTextSecondary.opacity(0.75)
        let zoneWidth: CGFloat = max(2, frame.width * size.width - 1.5)
        let zoneHeight: CGFloat = max(2, frame.height * size.height - 1.5)

        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .frame(width: zoneWidth, height: zoneHeight)
            .position(x: frame.midX * size.width, y: flippedMidY * size.height)
    }
}

struct PerScreenDepthRow: View {
    @EnvironmentObject var appState: AppState
    let screenID: String
    let screenName: String

    private var currentValue: Int? {
        appState.autoTilingMaxWindows(forScreenID: screenID)
    }

    private var effectiveValue: Int {
        appState.effectiveAutoTilingMaxWindows(forScreenID: screenID)
    }

    private var isUsingGlobal: Bool {
        currentValue == nil
    }

    var body: some View {
        SettingsRow(screenName, subtitle: isUsingGlobal ? "Using global (\(effectiveValue))" : "Custom: \(effectiveValue)") {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { currentValue ?? 0 },
                    set: { newValue in
                        if newValue == 0 {
                            appState.setAutoTilingMaxWindows(nil, forScreenID: screenID)
                        } else {
                            appState.setAutoTilingMaxWindows(newValue, forScreenID: screenID)
                        }
                    }
                )) {
                    Text("Global").tag(0)
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
            }
        }
    }
}

struct AutoTilingTemplateRow: View {
    @EnvironmentObject var appState: AppState
    let windowCount: Int
    let label: String

    private var currentTemplateID: UUID? {
        appState.autoTilingPreferences.templateID(for: windowCount)
    }

    private var currentTemplate: GridTemplate? {
        guard let id = currentTemplateID else { return nil }
        return appState.allTemplates.first { $0.id == id }
    }

    private var currentTemplateName: String {
        currentTemplate?.name ?? "Not Set"
    }

    var body: some View {
        SettingsRow(label) {
            Menu {
                ForEach(appState.listedTemplates) { template in
                    Button {
                        var prefs = appState.autoTilingPreferences
                        prefs.setTemplateID(template.id, for: windowCount)
                        appState.autoTilingPreferences = prefs
                    } label: {
                        HStack {
                            Image(systemName: template.icon)
                            Text(template.name)
                            if template.id == currentTemplateID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let template = currentTemplate {
                        TemplateZoneGlyph(template: template, isHighlighted: true)
                    }
                    Text(currentTemplateName)
                        .font(.subheadline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.neuTextSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .neuInset(cornerRadius: AppRadius.sm)
            }
            .menuStyle(.borderlessButton)
        }
    }
}
