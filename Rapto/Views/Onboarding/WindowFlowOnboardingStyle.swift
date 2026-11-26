//
//  WindowFlowOnboardingStyle.swift
//  Rapto
//
//  Window Flow–inspired atmospheric sky backdrop, sculpted dark-glass surfaces,
//  and refined glass button styles shared by Onboarding and the Interactive Tour.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Window Flow Design Tokens

enum WindowFlowThemeTokens {
    /// Deep azure-slate glass fill matching `WindowFlowTitleHUD` and `WindowFlowCard`.
    static let glassTop = Color(red: 0.11, green: 0.14, blue: 0.22).opacity(0.76)
    static let glassBottom = Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.86)

    static let selectedGlassTop = Color(red: 0.15, green: 0.23, blue: 0.36).opacity(0.84)
    static let selectedGlassBottom = Color(red: 0.07, green: 0.11, blue: 0.20).opacity(0.92)

    static let rimTop = Color.white.opacity(0.28)
    static let rimBottom = Color.white.opacity(0.07)

    static let hoverRimTop = Color.white.opacity(0.38)
    static let hoverRimBottom = Color.white.opacity(0.12)

    static let accentSky = Color(red: 0.42, green: 0.74, blue: 1.0)
    static let accentBlue = Color(red: 0.22, green: 0.54, blue: 0.96)
    static let accentDeep = Color(red: 0.13, green: 0.41, blue: 0.85)

    static let windowBackground = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1)

    static let glassFill = LinearGradient(
        colors: [glassTop, glassBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    static let selectedGlassFill = LinearGradient(
        colors: [selectedGlassTop, selectedGlassBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    static let rimGradient = LinearGradient(
        colors: [rimTop, rimBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    static let hoverRimGradient = LinearGradient(
        colors: [hoverRimTop, hoverRimBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    static let selectedRimGradient = LinearGradient(
        colors: [accentSky.opacity(0.95), accentBlue.opacity(0.45)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let fallbackSkyGradient = LinearGradient(
        colors: [
            Color(red: 0.038, green: 0.095, blue: 0.195),
            Color(red: 0.095, green: 0.205, blue: 0.365),
            Color(red: 0.055, green: 0.115, blue: 0.215)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Atmospheric Sky Backdrop (Reuses Window Flow's GPU Sky)

struct OnboardingSkyBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WindowFlowThemeTokens.fallbackSkyGradient

            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                OnboardingMetalSkyRepresentable(isAnimated: !reduceMotion)
            }

            // Soft atmospheric readability veil so glass cards and crisp white text pop
            // while the drifting Window Flow clouds breathe softly underneath.
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.04, blue: 0.09).opacity(0.20),
                    Color(red: 0.02, green: 0.04, blue: 0.09).opacity(0.36),
                    Color(red: 0.02, green: 0.03, blue: 0.08).opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingMetalSkyRepresentable: NSViewRepresentable {
    let isAnimated: Bool

    func makeNSView(context: Context) -> OnboardingMetalSkyView {
        OnboardingMetalSkyView(isAnimated: isAnimated)
    }

    func updateNSView(_ view: OnboardingMetalSkyView, context: Context) {
        view.setAnimated(isAnimated)
    }

    static func dismantleNSView(_ view: OnboardingMetalSkyView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
private final class OnboardingMetalSkyView: NSView {
    private static let sharedPipeline: WindowFlowMetalPipeline? = WindowFlowMetalPipeline.build()

    private let skyLayer: WindowFlowMetalSkyLayer?
    private var timer: Timer?
    private var isAnimated: Bool
    private var skyTime: Double = 6.0

    init(isAnimated: Bool) {
        self.isAnimated = isAnimated
        self.skyLayer = WindowFlowMetalSkyLayer(pipelineBundle: Self.sharedPipeline)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        if let skyLayer {
            layer?.addSublayer(skyLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        configureAndDraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            configureAndDraw()
            updateAnimationTimer()
        } else {
            stop()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureAndDraw()
    }

    func setAnimated(_ animated: Bool) {
        guard animated != isAnimated else { return }
        isAnimated = animated
        updateAnimationTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateAnimationTimer() {
        stop()
        guard isAnimated, window != nil, skyLayer != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.skyTime += 1.0 / 30.0
                self.skyLayer?.drawSky(mode: 0, time: self.skyTime, lean: .zero)
            }
        }
    }

    private func configureAndDraw() {
        guard let skyLayer, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        skyLayer.configureSize(bounds: bounds, backingScale: scale)
        skyLayer.drawSky(mode: 0, time: skyTime, lean: .zero)
    }
}

// MARK: - Sculpted Dark-Glass Surface

struct WindowFlowGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 15
    var isSelected: Bool = false
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(isSelected ? WindowFlowThemeTokens.selectedGlassFill : WindowFlowThemeTokens.glassFill)

                    if isSelected {
                        RadialGradient(
                            colors: [
                                WindowFlowThemeTokens.accentSky.opacity(0.18),
                                Color.clear
                            ],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 210
                        )
                        .clipShape(shape)
                    } else if isHovered {
                        shape.fill(Color.white.opacity(0.03))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    isSelected
                        ? WindowFlowThemeTokens.selectedRimGradient
                        : (isHovered ? WindowFlowThemeTokens.hoverRimGradient : WindowFlowThemeTokens.rimGradient),
                    lineWidth: isSelected ? 1.5 : 1
                )
            }
            .shadow(
                color: isSelected
                    ? WindowFlowThemeTokens.accentBlue.opacity(0.24)
                    : Color.black.opacity(0.32),
                radius: isSelected ? 16 : 12,
                y: isSelected ? 6 : 5
            )
    }
}

extension View {
    func windowFlowGlass(
        cornerRadius: CGFloat = 15,
        isSelected: Bool = false,
        isHovered: Bool = false
    ) -> some View {
        modifier(WindowFlowGlassSurface(cornerRadius: cornerRadius, isSelected: isSelected, isHovered: isHovered))
    }
}

// MARK: - Masked Behind-Window Vibrancy (No Rectangular Corner Ears on Borderless Panels)

struct WindowFlowMaskedBlurView: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
    }

    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 2
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Window Flow Button Styles

struct WindowFlowPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 8)
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [
                            WindowFlowThemeTokens.accentBlue.opacity(configuration.isPressed ? 0.85 : 1.0),
                            WindowFlowThemeTokens.accentDeep.opacity(configuration.isPressed ? 0.90 : 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: WindowFlowThemeTokens.accentBlue.opacity(0.35), radius: 10, y: 4)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct WindowFlowSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.90))
            .padding(.horizontal, compact ? 11 : 14)
            .padding(.vertical, compact ? 6 : 8)
            .background {
                shape.fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.10))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
