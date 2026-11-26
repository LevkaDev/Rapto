//
//  OnboardingDemos.swift
//  Rapto
//
//  Animated demos shown on the dark stage at the top of each onboarding step.
//  Built with the rapto.app palette.
//

import SwiftUI

// MARK: - Palette

enum OnboardingPalette {
    static let lime = Color(red: 0.75, green: 1.0, blue: 0.0)
    static let cyan = Color(red: 0.0, green: 1.0, blue: 0.9)
    static let violet = Color(red: 0.66, green: 0.33, blue: 0.97)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.0)
    /// #0B0C0A, the background of every clip
    static let field = Color(red: 11 / 255, green: 12 / 255, blue: 10 / 255)
    static let windows = [lime, cyan, violet, amber]
}

// MARK: - Loop

extension View {
    /// Calls `tick` every `interval` while the view is on screen
    func demoLoop(every interval: Duration, _ tick: @escaping () -> Void) -> some View {
        task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }
}

private extension Animation {
    static func demo(_ reduceMotion: Bool, response: Double = 0.45, damping: Double = 0.75) -> Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: damping)
    }
}

/// Maps a rect in 0...1 units into `size`, leaving a small gap between neighbors
private func place(_ unit: CGRect, in size: CGSize, gap: CGFloat = 3) -> CGRect {
    CGRect(
        x: unit.minX * size.width + gap,
        y: unit.minY * size.height + gap,
        width: unit.width * size.width - gap * 2,
        height: unit.height * size.height - gap * 2
    )
}

// MARK: - Stage

/// Sculpted floating Window Flow glass viewport for onboarding clips and live demos.
struct OnboardingStage<Content: View>: View {
    var clip: OnboardingClip?
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            if let clip {
                OnboardingPalette.field
                OnboardingClipView(clip: clip)
                    .id(clip)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.11, blue: 0.18).opacity(0.84),
                        Color(red: 0.04, green: 0.06, blue: 0.11).opacity(0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                content
                    .padding(.vertical, 18)
                    .padding(.horizontal, 32)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.46), radius: 22, y: 10)
        .animation(.easeInOut(duration: 0.25), value: clip)
        .environment(\.colorScheme, .dark)
    }
}

private struct DemoScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
            content
                .padding(4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}

// MARK: - Mini Window

struct MiniWindowView: View {
    let color: Color
    var hasTitleBar: Bool = true
    var isFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if hasTitleBar {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.white.opacity(0.3)).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(color.opacity(0.3))
            }
            Rectangle().fill(color.opacity(0.12))
        }
        .background(
            LinearGradient(colors: [color.opacity(0.2), color.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isFocused ? OnboardingPalette.lime : color.opacity(0.4), lineWidth: isFocused ? 2 : 1)
        )
        .shadow(color: isFocused ? OnboardingPalette.lime.opacity(0.35) : .clear, radius: 8)
    }
}

// MARK: - Key Caps

/// Splits "⌃⌥→" into ["⌃", "⌥", "→"], keeping names like "Tab" whole
func onboardingKeyCaps(_ shortcut: String) -> [String] {
    let modifiers: Set<Character> = ["⌘", "⌃", "⌥", "⇧"]
    var caps: [String] = []
    var rest = ""
    for character in shortcut {
        if modifiers.contains(character) && rest.isEmpty {
            caps.append(String(character))
        } else {
            rest.append(character)
        }
    }
    if !rest.isEmpty { caps.append(rest) }
    return caps
}

struct OnboardingKeyCapView: View {
    let label: String
    var isActive: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.7))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? OnboardingPalette.lime : Color.white.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(isActive ? 0 : 0.2), lineWidth: 0.5)
                    )
                    .shadow(color: isActive ? OnboardingPalette.lime.opacity(0.5) : .clear, radius: 8)
            )
            .scaleEffect(isActive ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

struct OnboardingShortcutCaps: View {
    let shortcut: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(onboardingKeyCaps(shortcut).enumerated()), id: \.offset) { _, cap in
                OnboardingKeyCapView(label: cap, isActive: isActive)
            }
        }
    }
}

// MARK: - Permission Demo

/// A System Settings row with the Rapto switch turning on
struct PermissionDemo: View {
    let isGranted: Bool
    @State private var pulseOn = false

    private var isOn: Bool { isGranted || pulseOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Privacy & Security  ›  Accessibility")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 11, weight: .medium))

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Rapto")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.accentColor : Color.white.opacity(0.2))
                        .frame(width: 38, height: 22)
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isGranted ? Color.green.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .demoLoop(every: .seconds(1.6)) {
            if !isGranted { pulseOn.toggle() }
        }
    }
}

// MARK: - macOS Tiling Demo

/// The Desktop & Dock sections with the user's own switches
struct MacTilingDemo: View {
    let enabled: [MacOSTiling.Option]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(MacOSTiling.sections(of: MacOSTiling.Option.allCases), id: \.self) { section in
                group(section, options: MacOSTiling.Option.allCases.filter { $0.section == section })
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func group(_ section: String, options: [MacOSTiling.Option]) -> some View {
        let allOff = !options.contains(where: enabled.contains)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "menubar.dock.rectangle")
                Text("\(MacOSTiling.paneName)  ›  \(section)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    if index > 0 {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                    }
                    row(option.title, isOn: enabled.contains(option))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(allOff ? Color.green.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func row(_ title: String, isOn: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.2))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Shortcuts Demo

/// Focus moves between windows, then two windows swap places
struct ShortcutsDemo: View {
    let focusRight: String
    let focusDown: String
    let swapLeft: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var isPressing = false

    private let slots = [
        CGRect(x: 0, y: 0, width: 0.5, height: 1),
        CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
        CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
    ]

    /// Per step: the shortcut shown, the focused slot, and which window sits in each slot
    private var steps: [(keys: String, focus: Int, order: [Int])] {
        [
            (focusRight, 1, [0, 1, 2]),
            (focusDown, 2, [0, 1, 2]),
            (swapLeft, 0, [2, 1, 0]),
            (focusRight, 1, [2, 1, 0]),
            (swapLeft, 0, [1, 2, 0]),
        ]
    }

    var body: some View {
        let current = steps[step]
        VStack(spacing: 12) {
            DemoScreen {
                GeometryReader { geo in
                    ForEach(0..<3, id: \.self) { window in
                        let slot = current.order.firstIndex(of: window) ?? window
                        let frame = place(slots[slot], in: geo.size)
                        MiniWindowView(color: OnboardingPalette.windows[window], isFocused: slot == current.focus)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            OnboardingShortcutCaps(shortcut: current.keys, isActive: isPressing)
        }
        .animation(.demo(reduceMotion, response: 0.4, damping: 0.75), value: step)
        .demoLoop(every: .seconds(1.4)) {
            isPressing = true
            step = (step + 1) % steps.count
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                isPressing = false
            }
        }
    }
}

// MARK: - Window Switcher Demo

/// The Window Switcher filtering windows as a name is typed
struct WindowSwitcherDemo: View {
    let shortcut: String

    @State private var typed = 0

    private struct Entry: Identifiable {
        let id: String
        let app: String
        let title: String
        let symbol: String
        let color: Color
        let desktop: Int
    }

    private let entries = [
        Entry(id: "1", app: "Safari", title: "rapto.app", symbol: "safari.fill", color: .blue, desktop: 1),
        Entry(id: "2", app: "Notes", title: "Ideas", symbol: "note.text", color: .orange, desktop: 2),
        Entry(id: "3", app: "Music", title: "Focus Mix", symbol: "music.note", color: .pink, desktop: 3),
        Entry(id: "4", app: "Mail", title: "Inbox", symbol: "envelope.fill", color: Color(red: 0.2, green: 0.55, blue: 1), desktop: 1),
    ]

    private let word = "notes"
    /// Extra ticks with the full word shown before starting over
    private let hold = 3

    private var query: String { String(word.prefix(min(typed, word.count))) }

    private var results: [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.app.lowercased().hasPrefix(query) || $0.title.lowercased().hasPrefix(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.5))
                Group {
                    if query.isEmpty {
                        Text("Search windows").foregroundStyle(.white.opacity(0.35))
                    } else {
                        Text(query).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                Spacer()
                OnboardingShortcutCaps(shortcut: shortcut)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)

            VStack(spacing: 2) {
                ForEach(Array(results.prefix(3).enumerated()), id: \.element.id) { index, entry in
                    row(entry, isSelected: index == 0)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .frame(width: 340, height: 160)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: typed)
        .demoLoop(every: .milliseconds(450)) { typed = (typed + 1) % (word.count + hold + 1) }
    }

    private func row(_ entry: Entry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(entry.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(entry.app)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(entry.title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text("Desktop \(entry.desktop)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(isSelected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transition(.opacity)
    }
}

// MARK: - Previews

#Preview("Shortcuts") {
    OnboardingStage { ShortcutsDemo(focusRight: "⌃⌥→", focusDown: "⌃⌥↓", swapLeft: "⌃⇧←").frame(maxWidth: 380) }
        .frame(width: 700, height: 230)
}

#Preview("Window Switcher") {
    OnboardingStage { WindowSwitcherDemo(shortcut: "⌃⌥W") }
        .frame(width: 700, height: 230)
}
