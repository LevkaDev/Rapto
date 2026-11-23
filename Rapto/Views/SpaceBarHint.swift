//
//  SpaceBarHint.swift
//  Rapto
//
//  Floating dark-glass HUD pill used for contextual tips, live Desktops Bar drag hints,
//  and non-modal status notices. Uses behind-window vibrancy, a two-tier title/detail hierarchy,
//  an icon badge, and tactile inline keycaps to match Rapto's drag and overlay HUD surfaces.
//

import AppKit
import SwiftUI

nonisolated struct HintCardContent: Equatable, Sendable {
    let icon: String
    let title: String
    let detail: String?
    let isWarning: Bool

    init(icon: String = "sparkles", title: String, detail: String? = nil, isWarning: Bool = false) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.isWarning = isWarning
    }

    /// Splits a plain notice string into a two-tier HUD card with an appropriate SF Symbol.
    static func fromNotice(_ text: String) -> HintCardContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let isWarning = lower.contains("accessibility") || lower.contains("not responding")

        let icon: String
        if isWarning {
            icon = "exclamationmark.triangle.fill"
        } else if lower.contains("auto tiling") || lower.contains("auto-tiling") {
            icon = "wand.and.stars"
        } else if lower.contains("all desktops") {
            icon = "rectangle.on.rectangle.slash"
        } else {
            icon = "info.circle.fill"
        }

        if let range = trimmed.range(of: ". ") {
            let head = String(trimmed[..<range.lowerBound])
            let tail = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return HintCardContent(icon: icon, title: head, detail: tail.isEmpty ? nil : tail, isWarning: isWarning)
        }
        if let range = trimmed.range(of: ": ") {
            let head = String(trimmed[..<range.lowerBound])
            var tail = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if tail.hasSuffix(".") { tail.removeLast() }
            return HintCardContent(icon: icon, title: head, detail: tail.isEmpty ? nil : tail, isWarning: isWarning)
        }
        return HintCardContent(icon: icon, title: trimmed, detail: nil, isWarning: isWarning)
    }
}

/// Inline runs of plain text and tactile keycap badges (such as `⌥`, `⌃⇥`, `⌃⌥F`).
nonisolated enum HintTextSegment: Equatable, Sendable {
    case text(String)
    case keycap(String)

    private static let keycapSymbols = CharacterSet(charactersIn: "⌃⌥⇧⌘⇥⏎⎋⌫␣")

    static func parse(_ input: String) -> [HintTextSegment] {
        let words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }

        var segments: [HintTextSegment] = []
        var currentTextWords: [String] = []

        func flushText() {
            guard !currentTextWords.isEmpty else { return }
            segments.append(.text(currentTextWords.joined(separator: " ")))
            currentTextWords.removeAll()
        }

        for word in words {
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "().,"))
            if isKeycapToken(stripped) {
                flushText()
                segments.append(.keycap(stripped))
            } else {
                currentTextWords.append(word)
            }
        }
        flushText()
        return segments
    }

    private static func isKeycapToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 8 else { return false }
        if token.unicodeScalars.contains(where: { keycapSymbols.contains($0) }) {
            return true
        }
        if token.hasPrefix("F"), let n = Int(token.dropFirst()), (1...20).contains(n) {
            return true
        }
        return false
    }
}

@MainActor
final class SpaceBarHint {

    enum Placement {
        /// Centered horizontally under `anchor` (AppKit screen coordinates).
        case below(NSRect)
        /// Centered horizontally inside `rect` near its bottom edge (AppKit screen coordinates).
        case insideBottom(NSRect)
        /// Centered horizontally inside `rect` near its top edge (AppKit screen coordinates).
        case insideTop(NSRect)
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var onHiddenCallback: (() -> Void)?
    private var generation: Int = 0
    private var clickGlobalMonitor: Any?
    private var clickLocalMonitor: Any?

    deinit {
        if let clickGlobalMonitor { NSEvent.removeMonitor(clickGlobalMonitor) }
        if let clickLocalMonitor { NSEvent.removeMonitor(clickLocalMonitor) }
    }

    func show(_ text: String, below anchor: NSRect, on screen: NSScreen, look: SpaceBarHintLook) {
        show(.fromNotice(text), placement: .below(anchor), on: screen, look: look, autoHideAfter: 6, onHidden: nil)
    }

    /// Displays structured `HintCardContent` with behind-window HUD glass, optional auto-hide, and click-to-dismiss.
    func show(
        _ content: HintCardContent,
        placement: Placement,
        on screen: NSScreen,
        look: SpaceBarHintLook,
        autoHideAfter: TimeInterval? = 6,
        onHidden: (() -> Void)? = nil
    ) {
        generation &+= 1
        hideWork?.cancel()
        hideWork = nil
        removeClickMonitors()
        onHiddenCallback = onHidden

        let hosting = NSHostingView(rootView: SpaceBarHintView(content: content))
        let size = hosting.fittingSize
        let wasVisible = panel?.isVisible == true && (panel?.alphaValue ?? 0) > 0.5
        let panel = self.panel ?? makePanel()
        panel.contentView = hosting

        let visible = screen.visibleFrame
        let xOrigin: CGFloat
        let yOrigin: CGFloat

        switch placement {
        case .below(let anchor):
            xOrigin = anchor.midX - size.width / 2
            yOrigin = anchor.minY - size.height - 8
        case .insideBottom(let rect):
            xOrigin = rect.midX - size.width / 2
            yOrigin = rect.minY + 20
        case .insideTop(let rect):
            xOrigin = rect.midX - size.width / 2
            yOrigin = rect.maxY - size.height - 20
        }

        let clampedX = min(max(xOrigin, visible.minX + 10), visible.maxX - size.width - 10)
        let clampedY = min(max(yOrigin, visible.minY + 10), visible.maxY - size.height - 10)

        panel.setFrame(NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height).integral, display: true)
        panel.invalidateShadow()

        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        self.panel = panel

        if let autoHideAfter {
            installClickMonitorsIfNeeded()
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: work)
        }
    }

    func hide() {
        generation &+= 1
        let hideGeneration = generation
        hideWork?.cancel()
        hideWork = nil
        removeClickMonitors()
        let callback = onHiddenCallback
        onHiddenCallback = nil
        callback?()

        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                // Shown again while fading out
                guard let self, self.generation == hideGeneration else { return }
                panel.orderOut(nil)
                // MARK: - Workaround: a hidden .canJoinAllSpaces panel ends up on one desktop
                // Same as DragSnapLayoutPicker: the next hint gets a new panel
                if self.panel === panel {
                    self.panel = nil
                }
            }
        }
    }

    private func installClickMonitorsIfNeeded() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              clickGlobalMonitor == nil else { return }
        let checkClick: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let frame = self.panel?.frame, frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
        clickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            checkClick()
        }
        clickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            checkClick()
            return event
        }
    }

    private func removeClickMonitors() {
        if let clickGlobalMonitor {
            NSEvent.removeMonitor(clickGlobalMonitor)
            self.clickGlobalMonitor = nil
        }
        if let clickLocalMonitor {
            NSEvent.removeMonitor(clickLocalMonitor)
            self.clickLocalMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

/// Kept for call-site compatibility with `SpaceBarController`.
struct SpaceBarHintLook {
    var style: SpaceBarStyle = .dark
    var isDark = true
}

// MARK: - Behind-Window Masked Vibrancy

private struct HudPillBlurView: NSViewRepresentable {
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

// MARK: - HUD Card View

private struct SpaceBarHintView: View {
    let content: HintCardContent

    private static let cornerRadius: CGFloat = 14

    private var accentColor: Color {
        content.isWarning ? Color.orange : Color.white
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        HStack(alignment: .center, spacing: 11) {
            iconBadge

            VStack(alignment: .leading, spacing: 2.5) {
                Text(content.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: true, vertical: true)

                if let detail = content.detail, !detail.isEmpty {
                    detailView(detail)
                }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 15)
        .padding(.vertical, 10)
        .background {
            ZStack {
                HudPillBlurView(cornerRadius: Self.cornerRadius)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.64),
                            Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.76)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        Color.white.opacity(0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .environment(\.colorScheme, .dark)
    }

    private var iconBadge: some View {
        let badgeShape = RoundedRectangle(cornerRadius: 8.5, style: .continuous)
        return ZStack {
            badgeShape
                .fill(content.isWarning ? Color.orange.opacity(0.20) : Color.white.opacity(0.11))
            badgeShape
                .strokeBorder(
                    content.isWarning ? Color.orange.opacity(0.38) : Color.white.opacity(0.18),
                    lineWidth: 0.5
                )
            Image(systemName: content.icon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .frame(width: 30, height: 30)
    }

    @ViewBuilder
    private func detailView(_ detail: String) -> some View {
        if detail.count > 68 {
            Text(detail)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.76))
                .multilineTextAlignment(.leading)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .center, spacing: 4.5) {
                ForEach(Array(HintTextSegment.parse(detail).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let run):
                        Text(run)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                    case .keycap(let key):
                        keycapBadge(key)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func keycapBadge(_ key: String) -> some View {
        let capShape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        return Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.96))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background {
                capShape.fill(Color.white.opacity(0.15))
            }
            .overlay {
                capShape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.32), Color.white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
    }
}
