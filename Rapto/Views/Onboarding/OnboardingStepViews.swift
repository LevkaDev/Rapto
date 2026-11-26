//
//  OnboardingStepViews.swift
//  Rapto
//
//  The text half of each onboarding step. The demos live in OnboardingDemos.swift.
//

import SwiftUI

// MARK: - Shortcuts

/// The user's current shortcuts, formatted for display
struct OnboardingShortcuts {
    let switcher: String
    let overlay: String
    let restore: String
    let focus: String
    let swap: String
    let focusRight: String
    let focusDown: String
    let swapLeft: String

    init(bindings: [HotkeyAction: HotkeyBinding] = HotkeyPresetStorage().loadCurrentPreset().bindings) {
        func key(_ action: HotkeyAction) -> String {
            bindings[action]?.displayString ?? "—"
        }

        /// "⌃⌥←→↑↓" when the four directions share modifiers, otherwise just left and right
        func directions(_ left: HotkeyAction, _ right: HotkeyAction, _ up: HotkeyAction, _ down: HotkeyAction) -> String {
            guard let l = bindings[left], let r = bindings[right], let u = bindings[up], let d = bindings[down] else {
                return key(left)
            }
            let all = [l, r, u, d]
            guard all.allSatisfy({ $0.modifiers == l.modifiers }) else {
                return "\(l.displayString) \(r.displayString)"
            }
            let modifiers = String(l.displayString.dropLast(HotkeyBinding.keyCodeToString(l.keyCode).count))
            let arrowCodes: Set<UInt32> = [0x7B, 0x7C, 0x7D, 0x7E]
            let keys = all.allSatisfy({ arrowCodes.contains($0.keyCode) })
                ? "←→↑↓"
                : [l, d, u, r].map { HotkeyBinding.keyCodeToString($0.keyCode) }.joined()
            return modifiers + keys
        }

        switcher = key(.openWindowSwitcher)
        overlay = key(.openOverlay)
        restore = key(.restoreLayout)
        focus = directions(.focusLeft, .focusRight, .focusUp, .focusDown)
        swap = directions(.swapLeft, .swapRight, .swapUp, .swapDown)
        focusRight = key(.focusRight)
        focusDown = key(.focusDown)
        swapLeft = key(.swapLeft)
    }
}

// MARK: - Shared Pieces

struct OnboardingHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
    }
}

/// Rounded card that groups rows in the lower half of a step
private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Key caps for the system-styled lower half, in light and dark appearance
struct ShortcutLabel: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(onboardingKeyCaps(shortcut).enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, cap.count > 1 ? 5 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                            )
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut)
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Welcome

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 24) {
            OnboardingHeader(
                title: "Welcome to Rapto",
                subtitle: "Snap windows into clean layouts, switch desktops from the menu bar and bring back a whole setup in one click"
            )

            HStack(alignment: .top, spacing: 10) {
                highlight(icon: "square.grid.2x2", title: "Layouts", text: "Windows snap into place")
                highlight(icon: "menubar.rectangle", title: "Desktops Bar", text: "Every desktop at a glance")
                highlight(icon: "square.stack.3d.up", title: "Workspaces", text: "Reopen a task's apps at once")
                highlight(icon: "magnifyingglass", title: "Window Switcher", text: "Find any window by name")
            }
        }
    }

    private func highlight(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Permissions

struct PermissionsStepView: View {
    let hasAccessibility: Bool
    let hasScreenRecording: Bool
    let onRequestAccessibility: () -> Void
    let onRequestScreenRecording: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                title: "Let Rapto move your windows",
                subtitle: "macOS asks you to allow this once. Rapto never collects or shares your data"
            )

            OnboardingCard {
                row(
                    title: "Accessibility",
                    badge: "Required",
                    text: "Lets Rapto move and resize windows",
                    isGranted: hasAccessibility,
                    isPrimary: true,
                    action: onRequestAccessibility
                )
                Divider()
                row(
                    title: "Screen Recording",
                    badge: "Optional",
                    text: "Shows window previews instead of app icons in the layout overlay",
                    isGranted: hasScreenRecording,
                    isPrimary: false,
                    action: onRequestScreenRecording
                )
            }
            .frame(maxWidth: 520)

            if !hasAccessibility {
                Text("Turn on Rapto in System Settings → Privacy & Security → Accessibility, then come back here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func row(title: String, badge: String, text: String, isGranted: Bool, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isPrimary ? Color.orange : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background((isPrimary ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body.weight(.medium))
            } else if isPrimary {
                Button("Allow…", action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - macOS Tiling

struct MacTilingStepView: View {
    let enabled: [MacOSTiling.Option]
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHeader(
                title: enabled.isEmpty ? "All set" : enabled == [.stageManager] ? "Turn off Stage Manager" : "Turn off macOS window tiling",
                subtitle: enabled.isEmpty
                    ? "macOS won't get in the way of your windows"
                    : "macOS can arrange windows too. When both try to place a window, it jumps around"
            )

            OnboardingCard {
                ForEach(Array(MacOSTiling.Option.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 { Divider() }
                    row(option)
                }
            }
            .frame(maxWidth: 520)

            if !enabled.isEmpty {
                VStack(spacing: 8) {
                    Button("Open \(MacOSTiling.paneName)…", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                    Text("Turn these off in System Settings → \(MacOSTiling.paneName) → \(MacOSTiling.sections(of: enabled).joined(separator: " and ")), then come back here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ option: MacOSTiling.Option) -> some View {
        let isOn = enabled.contains(option)
        return HStack(spacing: 12) {
            Text(option.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if isOn {
                Text("On")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            } else {
                Label("Off", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body.weight(.medium))
            }
        }
        .padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
    }
}

// MARK: - Mode

struct ModeChoice: Identifiable {
    let mode: TilingMode
    let icon: String
    let title: String
    let text: String
    var id: TilingMode { mode }

    static func all(overlayShortcut: String) -> [ModeChoice] {
        [
            ModeChoice(mode: .dragSnap, icon: "hand.draw", title: "Drag to Snap",
                       text: "Snap dragged windows to edges, the top bar or a layout. Drop in one zone to group"),
            ModeChoice(mode: .manualAssignment, icon: "square.grid.2x2", title: "Manual",
                       text: "Pick a layout for the desktop and Rapto keeps current and new windows in its slots"),
            ModeChoice(mode: .autoTiling, icon: "wand.and.stars", title: "Auto-tiling",
                       text: "Switches layouts on its own as windows open and close, grouping any extras"),
        ]
    }
}

struct ModeStepView: View {
    @Binding var selection: TilingMode?
    @Binding var hovered: TilingMode?
    @Binding var maxWindows: Int
    let suggestedMaxWindows: Int
    let overlayShortcut: String

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(
                title: "How do you like to arrange windows?",
                subtitle: "Each desktop and display can have its own mode. Change it anytime from the desktops bar"
            )

            HStack(spacing: 12) {
                ForEach(ModeChoice.all(overlayShortcut: overlayShortcut)) { choice in
                    card(choice)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // Always laid out and only faded: inserting it at runtime crashes the window's constraint pass
            windowCountRow
                .opacity(selection == .autoTiling ? 1 : 0)
                .allowsHitTesting(selection == .autoTiling)
                .accessibilityHidden(selection != .autoTiling)
                .animation(.easeInOut(duration: 0.2), value: selection)
        }
    }

    private var windowCountRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Windows on screen")
                    .font(.headline)
                Text("Extra windows join a slot as a group. Change it anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("We recommend 4 for laptops and regular monitors, 5 for wide displays", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(AutoTilingPreferences.maxWindowsRange, id: \.self) { count in
                    let isSelected = maxWindows == count
                    let isSuggested = count == suggestedMaxWindows
                    Button {
                        maxWindows = count
                    } label: {
                        Text("\(count)")
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                            .frame(width: 26, height: 24)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isSuggested && !isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(isSuggested ? "Recommended for your display" : "")
                    .accessibilityLabel(isSuggested ? "\(count) windows, recommended for your display" : "\(count) windows")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func card(_ choice: ModeChoice) -> some View {
        let isSelected = selection == choice.mode
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selection = choice.mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: choice.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(choice.title)
                    .font(.headline)
                Text(choice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(hovered == choice.mode ? 0.25 : 0.08)),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? choice.mode : (hovered == choice.mode ? nil : hovered)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Desktops Bar

struct DesktopsBarStepView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(
                title: "Your desktops, right in the menu bar",
                subtitle: "See every desktop and the apps open on it"
            )

            OnboardingCard {
                TipRow(icon: "cursorarrow.click", text: "Click a number to switch desktops instantly")
                Divider()
                TipRow(icon: "contextualmenu.and.cursorarrow", text: "Right-click a desktop to change its mode and layout")
                Divider()
                TipRow(icon: "hand.point.up.left", text: "Drag an app icon onto another desktop to move its window there")
                if NSScreen.screens.count > 1 {
                    Divider()
                    TipRow(icon: "display.2", text: "Each display has its own bar")
                }
            }
            .frame(maxWidth: 520)

            Toggle("Show Desktops Bar", isOn: $appState.showsSpaceBar)
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Workspaces

struct WorkspacesStepView: View {
    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(
                title: "Workspaces bring a whole setup back",
                subtitle: "Save the apps of a task with their layout, then reopen all of them in one click"
            )

            OnboardingCard {
                TipRow(icon: "square.and.arrow.down", text: "Right-click a desktop → Workspaces → Save as Workspace…")
                Divider()
                TipRow(icon: "macwindow.on.rectangle", text: "Open it on any desktop or in a new one. Rapto starts the apps and puts every window back in its place")
                Divider()
                TipRow(icon: "xmark.rectangle", text: "Done for the day? Close Workspace puts all its windows away at once")
            }
            .frame(maxWidth: 520)

            Text("Rename or delete workspaces in Settings → Workspaces")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsStepView: View {
    let shortcuts: OnboardingShortcuts
    let mode: TilingMode?

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(
                title: "A few shortcuts worth knowing",
                subtitle: "Change any of them in Settings → Shortcuts"
            )

            OnboardingCard {
                if mode == .dragSnap {
                    row("Move Without Snapping", shortcut: "⌥", note: "while dragging")
                    Divider()
                }
                row("Window Switcher", shortcut: shortcuts.switcher)
                Divider()
                row("Layout Overlay", shortcut: shortcuts.overlay)
                Divider()
                row("Move Focus", shortcut: shortcuts.focus)
                Divider()
                row("Swap Windows", shortcut: shortcuts.swap)
                Divider()
                row("Restore Layout", shortcut: shortcuts.restore)
            }
            .frame(maxWidth: 460)
        }
    }

    private func row(_ title: String, shortcut: String, note: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            ShortcutLabel(shortcut: shortcut)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Try It

enum OnboardingTask: Hashable {
    case windowSwitcher
    case layoutOverlay
    case dragSnap

    static func tasks(for mode: TilingMode?) -> [OnboardingTask] {
        switch mode {
        case .dragSnap: return [.windowSwitcher, .dragSnap]
        case .autoTiling: return [.windowSwitcher]
        default: return [.windowSwitcher, .layoutOverlay]
        }
    }
}

struct TryItStepView: View {
    @EnvironmentObject var appState: AppState
    let mode: TilingMode?
    let shortcuts: OnboardingShortcuts
    let completed: Set<OnboardingTask>

    private var tasks: [OnboardingTask] { OnboardingTask.tasks(for: mode) }

    var body: some View {
        VStack(spacing: 16) {
            OnboardingHeader(
                title: allDone ? "You've got it" : "Try it now",
                subtitle: allDone
                    ? "Rapto is in your menu bar whenever you need it"
                    : "Rapto works in the background. Give it a quick spin"
            )

            OnboardingCard {
                ForEach(Array(tasks.enumerated()), id: \.element) { index, task in
                    if index > 0 { Divider() }
                    row(task)
                }
                if mode == .autoTiling {
                    Divider()
                    TipRow(icon: "macwindow.badge.plus", text: "Open any app and watch its window find its place")
                }
            }
            .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 6) {
                if appState.showsSpaceBar && !appState.isMenuBarIconVisible {
                    discover(icon: "menubar.rectangle", text: "Rapto lives in the Desktops Bar. Turn on Menu Bar Icon in Settings if you want both")
                }
                discover(icon: "nosign", text: "Leave out apps Rapto shouldn't touch in Settings → Apps")
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var allDone: Bool { tasks.allSatisfy(completed.contains) }

    private func row(_ task: OnboardingTask) -> some View {
        let isDone = completed.contains(task)
        return HStack(spacing: 12) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isDone ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(task))
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                Text(detail(task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let shortcut = shortcut(task) {
                ShortcutLabel(shortcut: shortcut)
            }
        }
        .padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDone)
    }

    private func title(_ task: OnboardingTask) -> String {
        switch task {
        case .windowSwitcher: return "Open the Window Switcher"
        case .layoutOverlay: return "Open the Layout Overlay"
        case .dragSnap: return "Drag a window to the left edge"
        }
    }

    private func detail(_ task: OnboardingTask) -> String {
        switch task {
        case .windowSwitcher: return "Type a few letters of an app name, then press Return"
        case .layoutOverlay: return "Pick a layout and click windows in, or right-click a desktop in the bar"
        case .dragSnap: return "It fills the left half of the screen"
        }
    }

    private func shortcut(_ task: OnboardingTask) -> String? {
        switch task {
        case .windowSwitcher: return shortcuts.switcher
        case .layoutOverlay: return shortcuts.overlay
        case .dragSnap: return nil
        }
    }

    private func discover(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
