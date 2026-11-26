//
//  DragSnapLayoutPicker.swift
//  Rapto
//
//  Panel at the top of the screen with small layouts. In Drag to Snap without a chosen
//  layout, a window dropped on one of their zones takes that zone.
//

import AppKit

@MainActor
final class DragSnapLayoutPicker {

    static let pickerHintID = "dragSnapPicker"

    /// Built-in layouts. Zones are relative frames with the origin at the bottom left, like `SnapZone.resultFrame`.
    static let layouts: [[CGRect]] = [
        [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)],
        [CGRect(x: 0, y: 0.5, width: 1, height: 0.5), CGRect(x: 0, y: 0, width: 1, height: 0.5)],
        [CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
         CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)],
        [CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1), CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)],
        [CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)],
        [CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
         CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)],
        [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
         CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)],
        [CGRect(x: 0, y: 0, width: 1, height: 1)],
    ]

    struct Pick: Equatable {
        let layout: Int
        let zone: Int
        let relativeFrame: CGRect
    }

    nonisolated struct LayoutGeometry: Equatable, Sendable {
        let panelSize: CGSize
        /// Thumbnail rects in view coordinates (AppKit bottom-left origin)
        let thumbnails: [CGRect]
        /// Vertical separator between standard and custom layouts when shown in one row
        let verticalDividerX: CGFloat?
        /// Horizontal separator between standard and custom rows when wrapped
        let horizontalDividerY: CGFloat?
    }

    // MARK: - Workaround: a hidden .canJoinAllSpaces window ends up on one desktop
    // When a temporary space goes away (seen each time one was removed, e.g. after leaving a full screen app),
    // macOS leaves a hidden all-desktops window on the active desktop only (the tag stays set), and it then
    // shows only there until Rapto is restarted. Windows that are on screen at that moment are not affected.
    // So the window lives only while the picker is on screen: every show creates a new one.
    private var window: NSWindow?
    private let pickerView = PickerView()
    private var screenFrame: CGRect?
    private var currentShowsCaption = false
    private var currentExtraLayouts: [[CGRect]] = []
    private var activeLayouts: [[CGRect]] = DragSnapLayoutPicker.layouts
    private(set) var isShowing = false

    nonisolated static let defaultThumbnailWidth: CGFloat = 84
    nonisolated static let compactThumbnailWidth: CGFloat = 68
    nonisolated static let spacing: CGFloat = 10
    nonisolated static let dividerGap: CGFloat = 16
    nonisolated static let padding: CGFloat = 10
    nonisolated static let captionHeight: CGFloat = 20

    /// Computes panel size and thumbnail frames so standard and pinned custom layouts always fit
    /// comfortably inside `visibleFrame`. Uses a single row when everything fits, shrinking slightly
    /// if needed, and wraps custom layouts into centered rows underneath on narrower screens.
    nonisolated static func layoutGeometry(
        standardCount: Int,
        customCount: Int,
        visibleFrame: CGRect,
        showsCaption: Bool
    ) -> LayoutGeometry {
        let aspect = visibleFrame.width > 0 ? visibleFrame.height / visibleFrame.width : 0.6
        let clampedAspect = min(max(aspect, 0.35), 1)
        let extraTop = showsCaption ? captionHeight : 0
        let maxPanelWidth = max(320, visibleFrame.width - 32)
        let total = standardCount + customCount

        func singleRowWidth(thumbWidth: CGFloat) -> CGFloat {
            guard total > 0 else { return padding * 2 }
            let base = padding * 2 + CGFloat(total) * thumbWidth + CGFloat(max(0, total - 1)) * spacing
            return customCount > 0 && standardCount > 0 ? base + dividerGap - spacing : base
        }

        // Fit on one row at default width, or slightly compacted down to `compactThumbnailWidth`.
        if customCount == 0 || singleRowWidth(thumbWidth: compactThumbnailWidth) <= maxPanelWidth {
            let thumbWidth: CGFloat
            if singleRowWidth(thumbWidth: defaultThumbnailWidth) <= maxPanelWidth {
                thumbWidth = defaultThumbnailWidth
            } else {
                let extraGap = (customCount > 0 && standardCount > 0) ? (dividerGap - spacing) : 0
                let available = maxPanelWidth - padding * 2 - CGFloat(max(0, total - 1)) * spacing - extraGap
                thumbWidth = max(compactThumbnailWidth, floor(available / CGFloat(max(1, total))))
            }
            let thumbHeight = (thumbWidth * clampedAspect).rounded()
            let width = singleRowWidth(thumbWidth: thumbWidth)
            let height = padding * 2 + thumbHeight + extraTop

            var thumbnails: [CGRect] = []
            thumbnails.reserveCapacity(total)
            var x = padding
            var dividerX: CGFloat?
            for index in 0..<total {
                if customCount > 0 && standardCount > 0 && index == standardCount {
                    dividerX = (x - spacing + dividerGap / 2).rounded()
                    x += dividerGap - spacing
                }
                thumbnails.append(CGRect(x: x, y: padding, width: thumbWidth, height: thumbHeight))
                x += thumbWidth + spacing
            }
            return LayoutGeometry(
                panelSize: CGSize(width: width, height: height),
                thumbnails: thumbnails,
                verticalDividerX: dividerX,
                horizontalDividerY: nil
            )
        }

        // Wrap: standard layouts sit in the top row, custom layouts sit in centered rows below.
        let standardWidth: CGFloat = {
            let needed = padding * 2 + CGFloat(standardCount) * defaultThumbnailWidth + CGFloat(max(0, standardCount - 1)) * spacing
            if needed <= maxPanelWidth { return defaultThumbnailWidth }
            let available = maxPanelWidth - padding * 2 - CGFloat(max(0, standardCount - 1)) * spacing
            return max(compactThumbnailWidth, floor(available / CGFloat(max(1, standardCount))))
        }()
        let thumbWidth = standardWidth
        let thumbHeight = (thumbWidth * clampedAspect).rounded()
        let maxPerRow = max(1, min(standardCount, Int(floor((maxPanelWidth - padding * 2 + spacing) / (thumbWidth + spacing)))))

        var rows: [[Int]] = []
        if standardCount > 0 {
            rows.append(Array(0..<standardCount))
        }
        var nextCustom = standardCount
        while nextCustom < total {
            let end = min(total, nextCustom + maxPerRow)
            rows.append(Array(nextCustom..<end))
            nextCustom = end
        }

        let widestRowCount = rows.map(\.count).max() ?? 1
        let panelWidth = padding * 2 + CGFloat(widestRowCount) * thumbWidth + CGFloat(max(0, widestRowCount - 1)) * spacing
        let dividerBand: CGFloat = standardCount > 0 ? 12 : 0
        let panelHeight = padding * 2
            + CGFloat(rows.count) * thumbHeight
            + CGFloat(max(0, rows.count - 1)) * spacing
            + dividerBand
            + extraTop

        var thumbnails = Array(repeating: CGRect.zero, count: total)
        var horizontalDividerY: CGFloat?
        // In AppKit coordinates row 0 is at the top (highest y).
        var currentTopY = panelHeight - padding - extraTop
        for (rowIndex, indices) in rows.enumerated() {
            let rowWidth = CGFloat(indices.count) * thumbWidth + CGFloat(max(0, indices.count - 1)) * spacing
            var x = ((panelWidth - rowWidth) / 2).rounded()
            let rowY = currentTopY - thumbHeight
            for layoutIndex in indices {
                thumbnails[layoutIndex] = CGRect(x: x, y: rowY, width: thumbWidth, height: thumbHeight)
                x += thumbWidth + spacing
            }
            if rowIndex == 0 && standardCount > 0 && rows.count > 1 {
                horizontalDividerY = (rowY - (spacing + dividerBand) / 2).rounded()
                currentTopY = rowY - spacing - dividerBand
            } else {
                currentTopY = rowY - spacing
            }
        }

        return LayoutGeometry(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            thumbnails: thumbnails,
            verticalDividerX: nil,
            horizontalDividerY: horizontalDividerY
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // The pointer stays with the dragged window; the picker is hit-tested by position
        window.ignoresMouseEvents = true
        // Above the dragged window and the snap preview
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = pickerView
        return window
    }

    /// - Parameters:
    ///   - visibleFrame: The screen's visible frame (AppKit coordinates). The picker hangs from its top
    ///   - extraLayouts: Pinned custom layouts to show next to the built-in ones
    ///   - showsCaption: Whether to show "Drop on a layout to snap there" above the thumbnails
    func show(in visibleFrame: CGRect, extraLayouts: [[CGRect]] = [], showsCaption: Bool = false) {
        let validExtras = extraLayouts.filter { !$0.isEmpty }
        guard !isShowing
                || screenFrame != visibleFrame
                || currentShowsCaption != showsCaption
                || currentExtraLayouts != validExtras else { return }

        screenFrame = visibleFrame
        currentShowsCaption = showsCaption
        currentExtraLayouts = validExtras
        activeLayouts = Self.layouts + validExtras

        let geometry = Self.layoutGeometry(
            standardCount: Self.layouts.count,
            customCount: validExtras.count,
            visibleFrame: visibleFrame,
            showsCaption: showsCaption
        )
        let size = geometry.panelSize
        let frame = CGRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: visibleFrame.maxY - size.height - 12,
            width: size.width, height: size.height
        )
        pickerView.layouts = activeLayouts
        pickerView.thumbnails = geometry.thumbnails
        pickerView.verticalDividerX = geometry.verticalDividerX
        pickerView.horizontalDividerY = geometry.horizontalDividerY
        pickerView.caption = showsCaption ? "Drop on a layout to snap there" : nil
        pickerView.hovered = nil
        pickerView.needsDisplay = true
        if !isShowing {
            isShowing = true
            // A window that is still fading out is on screen, so it can be used again
            let window = self.window ?? makeWindow()
            self.window = window
            window.setFrame(frame.offsetBy(dx: 0, dy: 8), display: false)
            window.alphaValue = 0
            window.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window?.setFrame(frame, display: true)
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        screenFrame = nil
        currentShowsCaption = false
        currentExtraLayouts = []
        pickerView.hovered = nil
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShowing, self.window === window else { return }
                window.orderOut(nil)
                window.contentView = nil
                self.window = nil
            }
        }
    }

    /// Whether the pointer (AppKit coordinates) is over the picker, gaps and padding included
    func contains(_ point: CGPoint) -> Bool {
        isShowing && window?.frame.contains(point) == true
    }

    /// The zone under the pointer. In a thumbnail the nearest zone counts, so the gaps between zones don't flicker
    func pick(at point: CGPoint) -> Pick? {
        guard contains(point), let window else {
            setHovered(nil)
            return nil
        }
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let extraTop = currentShowsCaption ? Self.captionHeight : 0
        let topRowMaxY = pickerView.thumbnails.map(\.maxY).max() ?? 0
        guard let layout = pickerView.thumbnails.indices.min(by: { a, b in
            distance(local, to: pickerView.thumbnails[a]) < distance(local, to: pickerView.thumbnails[b])
        }) else {
            setHovered(nil)
            return nil
        }
        let candidateRect = pickerView.thumbnails[layout]
        let isTopRow = abs(candidateRect.maxY - topRowMaxY) < 1
        let hitRect = CGRect(
            x: candidateRect.minX - Self.spacing / 2,
            y: candidateRect.minY - Self.padding,
            width: candidateRect.width + Self.spacing,
            height: candidateRect.height + Self.padding * 2 + (isTopRow ? extraTop : 0)
        )
        guard hitRect.contains(local), activeLayouts.indices.contains(layout) else {
            setHovered(nil)
            return nil
        }
        let tiles = pickerView.tiles(of: layout)
        let zone = tiles.indices.min { distance(local, to: tiles[$0]) < distance(local, to: tiles[$1]) } ?? 0
        guard activeLayouts[layout].indices.contains(zone) else {
            setHovered(nil)
            return nil
        }
        let pick = Pick(layout: layout, zone: zone, relativeFrame: activeLayouts[layout][zone])
        setHovered(pick)
        return pick
    }

    private func setHovered(_ pick: Pick?) {
        guard pickerView.hovered != pick else { return }
        pickerView.hovered = pick
        pickerView.needsDisplay = true
    }

    private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

private final class PickerView: NSView {
    var layouts: [[CGRect]] = DragSnapLayoutPicker.layouts
    var thumbnails: [CGRect] = []
    var hovered: DragSnapLayoutPicker.Pick?
    var caption: String?
    var verticalDividerX: CGFloat?
    var horizontalDividerY: CGFloat?

    private let tileGap: CGFloat = 3

    func tiles(of layout: Int) -> [CGRect] {
        guard thumbnails.indices.contains(layout), layouts.indices.contains(layout) else { return [] }
        let thumbnail = thumbnails[layout]
        return layouts[layout].map { zone in
            CGRect(
                x: thumbnail.minX + zone.minX * thumbnail.width,
                y: thumbnail.minY + zone.minY * thumbnail.height,
                width: zone.width * thumbnail.width,
                height: zone.height * thumbnail.height
            ).insetBy(dx: tileGap / 2, dy: tileGap / 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(white: 0.12, alpha: 0.88).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        background.lineWidth = 1
        background.stroke()

        if let caption, let topOfThumbnails = thumbnails.map(\.maxY).max() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82),
                .paragraphStyle: paragraph
            ]
            let attrString = NSAttributedString(string: caption, attributes: attributes)
            let size = attrString.size()
            let captionRect = CGRect(
                x: 8,
                y: round(topOfThumbnails + (bounds.maxY - topOfThumbnails - size.height) / 2 - 1),
                width: bounds.width - 16,
                height: ceil(size.height)
            )
            attrString.draw(in: captionRect)
        }

        if let dividerX = verticalDividerX, let first = thumbnails.first {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: dividerX, y: first.minY + 4))
            line.line(to: CGPoint(x: dividerX, y: first.maxY - 4))
            NSColor.white.withAlphaComponent(0.18).setStroke()
            line.lineWidth = 1
            line.stroke()
        }

        if let dividerY = horizontalDividerY {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: DragSnapLayoutPicker.padding + 6, y: dividerY))
            line.line(to: CGPoint(x: bounds.width - DragSnapLayoutPicker.padding - 6, y: dividerY))
            NSColor.white.withAlphaComponent(0.18).setStroke()
            line.lineWidth = 1
            line.stroke()
        }

        for layout in thumbnails.indices {
            for (zone, tile) in tiles(of: layout).enumerated() {
                let path = NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4)
                let isHovered = hovered?.layout == layout && hovered?.zone == zone
                (isHovered ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.18)).setFill()
                path.fill()
            }
        }
    }
}
