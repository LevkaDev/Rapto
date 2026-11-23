//
//  AppearanceSettingsView.swift
//  Rapto
//
//  Visual appearance settings: Settings window theme, Desktops Bar style,
//  window & screen-edge gaps, active window border, and a live miniature preview.
//

import SwiftUI
import AppKit

struct AppearanceSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(SettingsTheme.defaultsKey) private var theme: SettingsTheme = .system

    private var spaceBarStyleSubtitle: String {
        switch appState.spaceBarStyle {
        case .dark: return "A dark pill on any wallpaper"
        case .glass: return "A translucent pill, light or dark like the menu bar"
        case .plain: return "No pill. The desktops look like menu bar items"
        }
    }

    private let colors: [(String, NSColor)] = [
        ("Blue", .systemBlue),
        ("Green", .systemGreen),
        ("Orange", .systemOrange),
        ("Red", .systemRed),
        ("Purple", .systemPurple),
        ("Yellow", .systemYellow),
        ("White", .white)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Appearance")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 24)

            SettingsSection("Theme", icon: "circle.lefthalf.filled") {
                SettingsRow("Settings Window", subtitle: theme == .system
                            ? "Follows the macOS appearance"
                            : "Stays \(theme == .light ? "light" : "dark") whatever macOS uses") {
                    NeuSegmentedControl(
                        selection: $theme,
                        options: SettingsTheme.allCases.map { (value: $0, label: $0.title) }
                    )
                    .frame(width: 220)
                }
            }
            .onChange(of: theme) { _, _ in
                SettingsWindowController.shared.applyTheme()
            }

            SettingsSection("Desktops Bar", icon: "menubar.rectangle") {
                SettingsRow("Style", subtitle: appState.showsSpaceBar
                            ? spaceBarStyleSubtitle
                            : "The Desktops Bar is off. Turn it on in General") {
                    NeuSegmentedControl(
                        selection: $appState.spaceBarStyle,
                        options: SpaceBarStyle.allCases.map { (value: $0, label: $0.title) }
                    )
                    .frame(width: 200)
                    .disabled(!appState.showsSpaceBar)
                    .opacity(appState.showsSpaceBar ? 1 : 0.45)
                }
            }

            SettingsSection("Window Gaps & Active Border", icon: "square.split.2x1") {
                AppearancePreviewCard(
                    windowGap: appState.windowGap,
                    screenEdgeGap: appState.screenEdgeGap,
                    highlightEnabled: appState.highlightActiveWindow,
                    highlightColor: Color(nsColor: appState.highlightColor.withAlphaComponent(1)),
                    borderWidth: appState.highlightBorderWidth,
                    badgePosition: appState.groupIndicatorPosition,
                    showsSpaceBar: appState.showsSpaceBar
                )

                Divider()

                SettingsRow("Window Gap", subtitle: "Space between tiled windows") {
                    Picker("", selection: Binding(
                        get: { Int(appState.windowGap) },
                        set: { appState.setWindowGap(CGFloat($0)) }
                    )) {
                        ForEach([0, 4, 8, 12, 16, 20, 24], id: \.self) { gap in
                            Text("\(gap) px").tag(gap)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                Divider()

                SettingsRow("Screen Edge Gap", subtitle: "Space from screen edges") {
                    Picker("", selection: Binding(
                        get: { Int(appState.screenEdgeGap) },
                        set: { appState.setScreenEdgeGap(CGFloat($0)) }
                    )) {
                        ForEach([0, 4, 8, 12, 16, 20, 24], id: \.self) { gap in
                            Text("\(gap) px").tag(gap)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                Divider()

                SettingsRow("Highlight Active Window", subtitle: "Draw a border around the focused window") {
                    Toggle("", isOn: $appState.highlightActiveWindow)
                        .toggleStyle(.neu)
                }

                if appState.highlightActiveWindow {
                    Divider()

                    SettingsRow("Border Color", subtitle: "Also outlines the current desktop in the Desktops Bar") {
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.0) { name, color in
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
                                    )
                                    .padding(4)
                                    .neuSurface(Circle(), level: isColorSelected(color) ? .inset(.small) : .flat)
                                    .onTapGesture {
                                        appState.highlightColor = color.withAlphaComponent(name == "White" ? 0.7 : 0.6)
                                    }
                                    .help(name)
                            }
                        }
                    }

                    Divider()

                    SettingsRow("Border Width") {
                        NeuSegmentedControl(
                            selection: Binding(
                                get: { Int(appState.highlightBorderWidth) },
                                set: { newValue in
                                    DispatchQueue.main.async {
                                        appState.highlightBorderWidth = CGFloat(newValue)
                                    }
                                }
                            ),
                            options: [1, 2, 3, 4].map { (value: $0, label: "\($0) px") }
                        )
                        .frame(width: 220)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    SettingsRow("Hide in Drag to Snap", subtitle: "No border on desktops in Drag to Snap mode") {
                        Toggle("", isOn: $appState.disableHighlightInDragSnapMode)
                            .toggleStyle(.neu)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private func isColorSelected(_ color: NSColor) -> Bool {
        let currentRGB = appState.highlightColor.usingColorSpace(.deviceRGB)
        let checkRGB = color.usingColorSpace(.deviceRGB)
        guard let current = currentRGB, let check = checkRGB else { return false }
        return abs(current.redComponent - check.redComponent) < 0.01 &&
               abs(current.greenComponent - check.greenComponent) < 0.01 &&
               abs(current.blueComponent - check.blueComponent) < 0.01
    }
}

// MARK: - Live Appearance Preview

private struct AppearancePreviewCard: View {
    let windowGap: CGFloat
    let screenEdgeGap: CGFloat
    let highlightEnabled: Bool
    let highlightColor: Color
    let borderWidth: CGFloat
    let badgePosition: GroupIndicatorPosition
    let showsSpaceBar: Bool

    /// Scaled down proportionally so 0–24 px reads clearly inside a 112 pt preview well.
    private var scaledEdgePadding: CGFloat {
        3 + screenEdgeGap * 0.55
    }

    private var scaledWindowGap: CGFloat {
        max(1, windowGap * 0.65)
    }

    private var summaryText: String {
        let borderText = highlightEnabled ? "Border \(Int(borderWidth)) px" : "Border off"
        return "Window \(Int(windowGap)) px · Edge \(Int(screenEdgeGap)) px · \(borderText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.neuTextSecondary)
                Spacer()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.neuTextSecondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 3) {
                        Circle().fill(Color.neuTextSecondary.opacity(0.45)).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.neuTextSecondary.opacity(0.3)).frame(width: 18, height: 4)
                    }
                    Spacer()
                    if showsSpaceBar {
                        HStack(spacing: 4) {
                            Text("1")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(highlightColor, lineWidth: 1.2)
                                )
                            Text("2")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(.neuTextSecondary)
                                .padding(.horizontal, 4)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.neuTextSecondary.opacity(0.3)).frame(width: 22, height: 4)
                }
                .padding(.horizontal, 10)
                .frame(height: 18)
                .background(Color.primary.opacity(0.04))

                HStack(spacing: scaledWindowGap) {
                    previewWindow(title: "Focused Window", isFocused: true, showsGroupBadge: true)
                    previewWindow(title: "Neighbor Slot", isFocused: false, showsGroupBadge: false)
                }
                .padding(scaledEdgePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 116)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .neuInset(cornerRadius: AppRadius.md)
            .animation(.appQuick, value: windowGap)
            .animation(.appQuick, value: screenEdgeGap)
            .animation(.appQuick, value: highlightEnabled)
            .animation(.appQuick, value: borderWidth)
            .animation(.appQuick, value: badgePosition)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Appearance preview: \(summaryText)")
    }

    private func previewWindow(title: String, isFocused: Bool, showsGroupBadge: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if showsGroupBadge && badgePosition == .left {
                    groupBadgePill
                    Spacer(minLength: 4)
                }
                Circle().fill(Color.neuTextSecondary.opacity(0.35)).frame(width: 4.5, height: 4.5)
                Circle().fill(Color.neuTextSecondary.opacity(0.35)).frame(width: 4.5, height: 4.5)
                Circle().fill(Color.neuTextSecondary.opacity(0.35)).frame(width: 4.5, height: 4.5)
                Spacer(minLength: 4)
                if showsGroupBadge && badgePosition == .right {
                    groupBadgePill
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 6)

            Spacer(minLength: 0)

            Text(title)
                .font(.caption2.weight(isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? Color.primary : Color.neuTextSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .neuSurface(shape, level: .raised(.small))
        .overlay(
            shape.strokeBorder(
                isFocused && highlightEnabled ? highlightColor : Color.primary.opacity(0.1),
                lineWidth: isFocused && highlightEnabled ? borderWidth : 0.75
            )
        )
    }

    private var groupBadgePill: some View {
        HStack(spacing: 2) {
            Circle().fill(Color.neuAccent).frame(width: 5, height: 5)
            Circle().fill(Color.neuTextSecondary.opacity(0.5)).frame(width: 5, height: 5)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.1), in: Capsule())
    }
}
