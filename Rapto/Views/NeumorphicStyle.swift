//
//  NeumorphicStyle.swift
//  Rapto
//
//  Neumorphic design tokens, surfaces and control styles.
//  Everything is carved out of one base colour: raised surfaces cast a dark
//  shadow down-right and a light one up-left, inset surfaces do the opposite.
//  Used by the Settings window.
//

import SwiftUI
import AppKit

// MARK: - Layout Tokens

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
}

enum AppRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
}

extension Animation {
    /// Spring for state changes such as a switch flipping.
    static let appSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)
    /// Quick ease for hover and press feedback.
    static let appQuick = Animation.easeOut(duration: 0.15)
}

// MARK: - Palette

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension NSColor {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: .dynamic(light: light, dark: dark))
    }
}

extension NSColor {
    /// `Color.neuBase` for AppKit, so a window and its title bar match the content.
    static let neuBase = NSColor.dynamic(light: 0xE6E9EF, dark: 0x26262C)
}

extension Color {
    // Dark accents follow the Rapto landing page.
    // The base is a neutral graphite, lighter than the page's #0A0A0C: relief
    // needs room for a shadow darker than the surface.

    /// The single surface colour every element is carved from.
    static let neuBase = Color(light: 0xE6E9EF, dark: 0x26262C)
    /// Shadow on the side facing away from the light (bottom-right).
    static let neuShadowDark = Color(light: 0xC2C8D4, dark: 0x17171B)
    /// Highlight on the side facing the light (top-left).
    static let neuShadowLight = Color(light: 0xFFFFFF, dark: 0x35353D)
    /// The one accent colour: active states, primary icons, links.
    /// Light: Rapto's app-icon indigo. Dark: the landing page's electric lime,
    /// which has no contrast on the light base.
    static let neuAccent = Color(light: 0x4F46E5, dark: 0xBFFF00)
    /// Errors and destructive actions.
    static let neuRecording = Color(light: 0xD64545, dark: 0xFF6B6B)
    static let neuWarning = Color(light: 0xB7791F, dark: 0xFFB800)
    /// Supporting text, tuned for contrast against `neuBase`.
    static let neuTextSecondary = Color(light: 0x566074, dark: 0x9A9AA3)
}

/// Lets the palette be used wherever a `ShapeStyle` is expected (`.fill(.neuAccent)`).
extension ShapeStyle where Self == Color {
    static var neuAccent: Color { Color.neuAccent }
    static var neuRecording: Color { Color.neuRecording }
    static var neuWarning: Color { Color.neuWarning }
    static var neuTextSecondary: Color { Color.neuTextSecondary }
}

// MARK: - Depth

/// How far a surface is pushed out of (or into) the base plane.
enum NeuDepth {
    case small, medium, large

    var offset: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 4
        case .large: return 6
        }
    }

    var radius: CGFloat {
        switch self {
        case .small: return 4
        case .medium: return 8
        case .large: return 14
        }
    }
}

enum NeuLevel: Equatable {
    case raised(NeuDepth)
    case inset(NeuDepth)
    case flat
}

// MARK: - Surface

struct NeuSurface<S: InsettableShape>: View {
    let shape: S
    var level: NeuLevel = .raised(.medium)

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            switch level {
            case .raised(let depth):
                shape
                    .fill(Color.neuBase)
                    .shadow(color: .neuShadowDark, radius: depth.radius, x: depth.offset, y: depth.offset)
                    .shadow(color: .neuShadowLight, radius: depth.radius, x: -depth.offset, y: -depth.offset)
            case .inset(let depth):
                shape
                    .fill(
                        Color.neuBase
                            .shadow(.inner(color: .neuShadowDark, radius: depth.radius * 0.6, x: depth.offset, y: depth.offset))
                            .shadow(.inner(color: .neuShadowLight, radius: depth.radius * 0.6, x: -depth.offset, y: -depth.offset))
                    )
            case .flat:
                shape.fill(Color.neuBase)
            }

            // Soft relief alone is too faint for "Increase contrast" users.
            if contrast == .increased && level != .flat {
                shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

extension View {
    func neuRaised(cornerRadius: CGFloat = AppRadius.xl, depth: NeuDepth = .medium) -> some View {
        background(NeuSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), level: .raised(depth)))
    }

    func neuInset(cornerRadius: CGFloat = AppRadius.md, depth: NeuDepth = .small) -> some View {
        background(NeuSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), level: .inset(depth)))
    }

    func neuSurface<S: InsettableShape>(_ shape: S, level: NeuLevel) -> some View {
        background(NeuSurface(shape: shape, level: level))
    }
}

// MARK: - Icon Well

struct NeuIconWell: View {
    let icon: String
    var color: Color = .neuAccent
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .neuInset(cornerRadius: size * 0.32)
    }
}

// MARK: - Button

struct NeuButtonStyle: ButtonStyle {
    enum Kind {
        /// Accent-coloured label: the main action of a group.
        case primary
        case standard
        case destructive
    }

    var kind: Kind = .standard
    var cornerRadius: CGFloat = AppRadius.md
    /// Small 11pt variant for dense rows.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NeuButtonBody(configuration: configuration, kind: kind, cornerRadius: compact ? AppRadius.sm + 2 : cornerRadius, compact: compact)
    }

    private struct NeuButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let cornerRadius: CGFloat
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        private var labelColor: Color {
            guard isEnabled else { return .neuTextSecondary.opacity(0.6) }
            switch kind {
            case .primary: return .neuAccent
            case .standard: return .primary
            case .destructive: return .neuRecording
            }
        }

        private var level: NeuLevel {
            if !isEnabled { return .flat }
            return configuration.isPressed ? .inset(.small) : .raised(.small)
        }

        var body: some View {
            configuration.label
                .font(compact ? .system(size: 11, weight: .medium) : .subheadline.weight(.medium))
                .foregroundStyle(labelColor)
                .padding(.horizontal, compact ? AppSpacing.sm + 2 : AppSpacing.lg)
                .padding(.vertical, compact ? 5 : 7)
                .neuSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), level: level)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .animation(.appQuick, value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == NeuButtonStyle {
    static var neu: NeuButtonStyle { NeuButtonStyle() }
    static var neuPrimary: NeuButtonStyle { NeuButtonStyle(kind: .primary) }
    static var neuDestructive: NeuButtonStyle { NeuButtonStyle(kind: .destructive) }
}

// MARK: - Toggle

struct NeuToggleStyle: ToggleStyle {
    /// Pushes the switch to the trailing edge (settings rows). Off: the switch hugs its label.
    var fillsWidth = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NeuToggleBody(configuration: configuration, fillsWidth: fillsWidth, compact: compact)
    }

    private struct NeuToggleBody: View {
        let configuration: ToggleStyleConfiguration
        let fillsWidth: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: AppSpacing.md) {
                configuration.label
                if fillsWidth {
                    Spacer(minLength: AppSpacing.md)
                }
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(Color.clear)
                        .frame(width: compact ? 34 : 46, height: compact ? 20 : 26)
                        .neuSurface(Capsule(), level: .inset(.small))
                    Circle()
                        .fill(configuration.isOn ? Color.neuAccent : Color.neuTextSecondary)
                        .frame(width: compact ? 12 : 18, height: compact ? 12 : 18)
                        .shadow(color: .neuShadowDark, radius: 2, x: 1, y: 1)
                        .padding(4)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.appSpring, value: configuration.isOn)
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

extension ToggleStyle where Self == NeuToggleStyle {
    static var neu: NeuToggleStyle { NeuToggleStyle() }
}

// MARK: - Text Field

extension View {
}

// MARK: - Segmented Control

struct NeuSegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.neuAccent : Color.neuTextSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, AppSpacing.sm)
                        .neuSurface(
                            RoundedRectangle(cornerRadius: AppRadius.sm + 2, style: .continuous),
                            level: isSelected ? .raised(.small) : .flat
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .neuInset(cornerRadius: AppRadius.md + 2)
        .animation(.appQuick, value: selection)
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            NeuIconWell(icon: "square.grid.3x3")
            Button("Save") {}.buttonStyle(.neuPrimary)
            Button("Clear") {}.buttonStyle(.neu)
        }
        Toggle("Launch at Login", isOn: .constant(true)).toggleStyle(.neu)
        NeuSegmentedControl(
            selection: .constant("a"),
            options: [(value: "a", label: "Small"), (value: "b", label: "Medium"), (value: "c", label: "Large")]
        )
    }
    .padding(32)
    .frame(width: 420)
    .background(Color.neuBase)
}
