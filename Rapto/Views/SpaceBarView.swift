//
//  SpaceBarView.swift
//  Rapto
//
//  The desktops pill drawn in the menu bar.
//

import SwiftUI

struct SpaceBarView: View {
    let displayID: String
    @ObservedObject var controller: SpaceBarController
    @ObservedObject private var responsiveness = AppResponsiveness.shared
    @State private var drag: GlyphDrag?
    @State private var isHoveringFlowButton = false

    private struct GlyphDrag {
        let glyphID: String
        let sourceID: UInt64
        var translation: CGSize
        var targetID: UInt64?
    }

    private var display: SpaceBarDisplay? {
        controller.displays.first { $0.id == displayID }
    }

    var body: some View {
        Group {
            if let display, !display.spaces.isEmpty {
                bar(display)
            }
        }
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SpaceBarSizeKey.self, value: geo.size)
            }
        )
        .coordinateSpace(name: SpaceBarView.coordinateSpace)
        .onPreferenceChange(SpaceBarSizeKey.self) { size in
            controller.updateSize(size, for: displayID)
        }
        .onPreferenceChange(SpaceBarSegmentFramesKey.self) { frames in
            controller.updateSegmentFrames(frames, for: displayID)
        }
        .onPreferenceChange(SpaceBarGlyphFramesKey.self) { frames in
            controller.updateGlyphFrames(frames, for: displayID)
        }
        .onDisappear {
            if drag != nil {
                drag = nil
                controller.endGlyphDrag()
            }
        }
    }

    private static let coordinateSpace = "SpaceBarPill"

    /// The border color is stored see-through; the outline is drawn solid
    private var currentDesktopColor: Color {
        Color(nsColor: controller.currentDesktopColor.withAlphaComponent(1))
    }

    private var look: SpaceBarStyle { controller.look(displayID: displayID) }
    /// Glass and plain follow the menu bar: light over light wallpapers, dark over dark ones
    private var followsMenuBar: Bool { look != .dark }
    private var isPlain: Bool { look == .plain }
    /// Everything in the pill is sized from the app icon, which follows the menu bar height
    private var iconSize: CGFloat { controller.iconSize(displayID: displayID) }
    private var isDark: Bool { !followsMenuBar || controller.menuBarIsDark }
    /// Same ink as the menu bar's own text
    private var ink: Color { isDark ? .white : Color(white: 0.08) }

    private func bar(_ display: SpaceBarDisplay) -> some View {
        HStack(spacing: isPlain ? 2 : 6) {
            if !controller.hasAccessibilityPermission {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize * 0.72, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: iconSize + 2, height: iconSize)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        controller.handleAccessibilityWarningTap(displayID: displayID)
                    }
                    .help("Accessibility is turned off — Rapto can't move windows. Click for details.")
                    .accessibilityLabel("Accessibility is turned off")
            }

            windowFlowButton

            ForEach(display.spaces) { space in
                if space.isFullScreen {
                    fullScreenSegment(space)
                } else {
                    spaceSegment(space)
                }
            }
            addDesktopButton
        }
        .padding(.horizontal, isPlain ? 0 : 5)
        .padding(.vertical, 3)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            switch look {
            case .dark:
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(Color.black.opacity(0.28)) }
                    .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
            case .glass:
                shape
                    .fill(Color.white.opacity(isDark ? 0.10 : 0.38))
                    .overlay {
                        shape.strokeBorder(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08), lineWidth: 0.5)
                    }
            case .plain:
                Color.clear
            }
        }
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private var windowFlowButton: some View {
        let isActive = controller.isWindowFlowOpen
        let isHovered = isHoveringFlowButton
        let tooltip = controller.windowFlowShortcut.map { "Window Flow (\($0))" } ?? "Window Flow"
        return WindowFlowBarIcon(
            color: isActive ? currentDesktopColor : ink,
            isHighlighted: isHovered || isActive
        )
        .frame(width: iconSize * 0.68, height: iconSize * 0.58)
        .frame(width: iconSize, height: iconSize)
        .background {
            Circle().fill(
                isActive
                    ? currentDesktopColor.opacity(0.24)
                    : ink.opacity(isHovered ? 0.18 : 0)
            )
        }
        .overlay {
            Circle().strokeBorder(
                isActive
                    ? currentDesktopColor.opacity(0.95)
                    : ink.opacity(isHovered ? 0.85 : (isPlain ? 0 : 0.4)),
                lineWidth: 1
            )
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { inside in
            isHoveringFlowButton = inside
        }
        .onTapGesture {
            controller.openWindowFlow(displayID: displayID)
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Window Flow")
        .accessibilityAddTraits(.isButton)
    }

    private var addDesktopButton: some View {
        let isTarget = drag?.targetID == SpaceBarController.addDesktopSegmentID
        return Image(systemName: "plus")
            .font(.system(size: iconSize * 0.56, weight: .bold))
            .foregroundStyle(ink.opacity(isTarget ? 1 : 0.6))
            .frame(width: iconSize, height: iconSize)
            .background {
                Circle().fill(ink.opacity(isTarget ? 0.22 : 0))
            }
            .overlay {
                Circle().strokeBorder(ink.opacity(isTarget ? 0.9 : (isPlain ? 0 : 0.4)), lineWidth: 1)
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.addDesktop(displayID: displayID)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SpaceBarSegmentFramesKey.self,
                        value: [SpaceBarController.addDesktopSegmentID: geo.frame(in: .named(SpaceBarView.coordinateSpace))]
                    )
                }
            )
            .help("Add a desktop. Drop an app here to move its window to a new desktop.")
            .accessibilityLabel("Add desktop")
    }

    private func spaceSegment(_ space: SpaceBarSpace) -> some View {
        HStack(spacing: 5) {
            Text("\(space.number)")
                .font(.system(size: iconSize * 0.75, weight: .semibold, design: .rounded))
                .foregroundStyle(space.isCurrent ? ink : ink.opacity(followsMenuBar ? 0.6 : 0.5))
                .frame(minWidth: iconSize - 2, minHeight: iconSize)
                .contentShape(Rectangle())
                .onTapGesture {
                    controller.switchTo(spaceID: space.id, displayID: displayID)
                }

            if !space.glyphs.isEmpty {
                Capsule()
                    .fill(ink.opacity(0.28))
                    .frame(width: 1, height: iconSize - 4)

                HStack(spacing: 4) {
                    ForEach(space.glyphs) { glyph in
                        glyphView(glyph, on: space)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    space.isCurrent ? currentDesktopColor : Color.clear,
                    lineWidth: 1.5
                )
        }
        .background {
            if isDropTarget(space) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ink.opacity(0.22))
            } else if space.isCurrent && followsMenuBar {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    // Plain: the plate macOS draws behind an open menu bar item
                    .fill(ink.opacity(isPlain ? (isDark ? 0.22 : 0.12) : (isDark ? 0.16 : 0.10)))
            }
        }
        .opacity(space.isCurrent || isDropTarget(space) ? 1 : (followsMenuBar ? 0.85 : 0.72))
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SpaceBarSegmentFramesKey.self,
                    value: [space.id: geo.frame(in: .named(SpaceBarView.coordinateSpace))]
                )
            }
        )
        .help("Right-click for mode and layout")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desktop \(space.number)")
    }

    /// An app in full screen: just its icon. Windows can't be dragged in or out.
    private func fullScreenSegment(_ space: SpaceBarSpace) -> some View {
        let name = space.glyphs.first?.appName ?? "App"
        return HStack(spacing: 4) {
            ForEach(space.glyphs) { glyph in
                Image(nsImage: glyph.icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .frame(width: iconSize + 4, height: iconSize + 2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    space.isCurrent ? currentDesktopColor : ink.opacity(0.28),
                    style: StrokeStyle(lineWidth: space.isCurrent ? 1.5 : 1, dash: space.isCurrent ? [] : [2, 2])
                )
        }
        .opacity(space.isCurrent ? 1 : 0.72)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.switchTo(spaceID: space.id, displayID: displayID)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SpaceBarSegmentFramesKey.self,
                    value: [space.id: geo.frame(in: .named(SpaceBarView.coordinateSpace))]
                )
            }
        )
        .help("\(name) in full screen")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), full screen")
        .accessibilityAddTraits(.isButton)
    }

    private func glyphView(_ glyph: SpaceBarGlyph, on space: SpaceBarSpace) -> some View {
        Image(nsImage: glyph.icon)
            .resizable()
            .frame(width: iconSize, height: iconSize)
            .overlay(alignment: .topTrailing) {
                if glyph.count > 1 {
                    Text(glyph.count > 9 ? "9+" : "\(glyph.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: iconSize + 4, height: iconSize + 2)
            .opacity(responsiveness.notRespondingPIDs.contains(glyph.pid) ? 0.35 : 1)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SpaceBarGlyphFramesKey.self,
                        value: [
                            SpaceBarGlyphKey(spaceID: space.id, pid: glyph.pid):
                                geo.frame(in: .named(SpaceBarView.coordinateSpace))
                        ]
                    )
                }
            )
            .help(helpText(for: glyph))
            .offset(isDragging(glyph, from: space) ? drag?.translation ?? .zero : .zero)
            .onTapGesture {
                controller.focus(glyph, on: space.id, displayID: displayID)
            }
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(SpaceBarView.coordinateSpace))
                    .onChanged { value in
                        let targetID = controller.spaceID(atX: value.location.x, displayID: displayID)
                        drag = GlyphDrag(
                            glyphID: glyph.id,
                            sourceID: space.id,
                            translation: CGSize(width: value.translation.width, height: max(-3, min(3, value.translation.height))),
                            targetID: targetID
                        )
                        controller.updateGlyphDrag(
                            sourceSpaceID: space.id,
                            targetSpaceID: targetID,
                            displayID: displayID
                        )
                    }
                    .onEnded { value in
                        drag = nil
                        controller.endGlyphDrag()
                        guard let target = controller.spaceID(atX: value.location.x, displayID: displayID),
                              target != space.id, !isFullScreen(target) else { return }
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        if optionHeld {
                            HintKeyStore.recordCompletedUse(of: .spaceBarOptionKey)
                        }
                        let follow = controller.movesFollowWindow != optionHeld
                        if target == SpaceBarController.addDesktopSegmentID {
                            controller.moveToNewDesktop(glyph, from: space.id, displayID: displayID, follow: follow)
                        } else {
                            controller.move(glyph, from: space.id, to: target, displayID: displayID, follow: follow)
                        }
                    }
            )
            .accessibilityLabel(glyph.count > 1 ? "\(glyph.appName), \(glyph.count) windows" : glyph.appName)
    }

    private func isDragging(_ glyph: SpaceBarGlyph, from space: SpaceBarSpace) -> Bool {
        drag?.glyphID == glyph.id && drag?.sourceID == space.id
    }

    private func isDropTarget(_ space: SpaceBarSpace) -> Bool {
        guard let drag, let target = drag.targetID else { return false }
        return target == space.id && target != drag.sourceID
    }

    private func isFullScreen(_ spaceID: UInt64) -> Bool {
        display?.spaces.first { $0.id == spaceID }?.isFullScreen == true
    }

    private func helpText(for glyph: SpaceBarGlyph) -> String {
        let name = glyph.count == 1 ? (glyph.windows.first?.title ?? glyph.appName) : "\(glyph.appName) (\(glyph.count))"
        if responsiveness.notRespondingPIDs.contains(glyph.pid) {
            return "\(name)\nNot responding"
        }
        let option = controller.movesFollowWindow ? "Hold Option to stay here." : "Hold Option to go there too."
        return "\(name)\nDrag to another desktop to move the window (\(option))\nRight-click for \(glyph.appName) & desktop options."
    }
}

private struct WindowFlowBarIcon: View {
    let color: Color
    let isHighlighted: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let centerAlpha: Double = isHighlighted ? 1.0 : 0.72
            let sideAlpha: Double = isHighlighted ? 0.78 : 0.48

            // Left and right wing strokes (compact Flow silhouette matching the circular "+" button)
            var sides = Path()
            sides.move(to: CGPoint(x: w * 0.10, y: h * 0.25))
            sides.addLine(to: CGPoint(x: w * 0.10, y: h * 0.75))
            sides.move(to: CGPoint(x: w * 0.90, y: h * 0.25))
            sides.addLine(to: CGPoint(x: w * 0.90, y: h * 0.75))
            ctx.stroke(
                sides,
                with: .color(color.opacity(sideAlpha)),
                style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
            )

            // Center hero card
            let centerRect = CGRect(
                x: w * 0.28,
                y: h * 0.14,
                width: w * 0.44,
                height: h * 0.72
            )
            let centerPath = Path(roundedRect: centerRect, cornerRadius: max(1.1, h * 0.12))
            ctx.stroke(centerPath, with: .color(color.opacity(centerAlpha)), lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}

private struct SpaceBarGlyphFramesKey: PreferenceKey {
    static let defaultValue: [SpaceBarGlyphKey: CGRect] = [:]
    static func reduce(value: inout [SpaceBarGlyphKey: CGRect], nextValue: () -> [SpaceBarGlyphKey: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SpaceBarSegmentFramesKey: PreferenceKey {
    static let defaultValue: [UInt64: CGRect] = [:]
    static func reduce(value: inout [UInt64: CGRect], nextValue: () -> [UInt64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SpaceBarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 {
            value = next
        }
    }
}
