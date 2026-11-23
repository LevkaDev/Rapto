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

    /// Zones are relative frames with the origin at the bottom left, like `SnapZone.resultFrame`
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
        var relativeFrame: CGRect { DragSnapLayoutPicker.layouts[layout][zone] }
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
    private(set) var isShowing = false

    private let thumbnailWidth: CGFloat = 84
    private let spacing: CGFloat = 10
    private let padding: CGFloat = 10
    private let captionHeight: CGFloat = 20

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
    ///   - showsCaption: Whether to show "Drop on a layout to snap there" above the thumbnails
    func show(in visibleFrame: CGRect, showsCaption: Bool = false) {
        let aspect = visibleFrame.width > 0 ? visibleFrame.height / visibleFrame.width : 0.6
        let thumbnailHeight = (thumbnailWidth * min(max(aspect, 0.35), 1)).rounded()
        let count = CGFloat(Self.layouts.count)
        let extraTop = showsCaption ? captionHeight : 0
        let size = CGSize(
            width: padding * 2 + count * thumbnailWidth + (count - 1) * spacing,
            height: padding * 2 + thumbnailHeight + extraTop
        )
        let frame = CGRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: visibleFrame.maxY - size.height - 12,
            width: size.width, height: size.height
        )
        guard !isShowing || screenFrame != visibleFrame || currentShowsCaption != showsCaption else { return }
        screenFrame = visibleFrame
        currentShowsCaption = showsCaption
        pickerView.thumbnails = (0..<Self.layouts.count).map { index in
            CGRect(x: padding + CGFloat(index) * (thumbnailWidth + spacing), y: padding,
                   width: thumbnailWidth, height: thumbnailHeight)
        }
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
        let extraTop = currentShowsCaption ? captionHeight : 0
        guard let layout = pickerView.thumbnails.firstIndex(where: {
            $0.insetBy(dx: -spacing / 2, dy: -padding - extraTop).contains(local)
        }) else {
            setHovered(nil)
            return nil
        }
        let tiles = pickerView.tiles(of: layout)
        let zone = tiles.indices.min { distance(local, to: tiles[$0]) < distance(local, to: tiles[$1]) } ?? 0
        let pick = Pick(layout: layout, zone: zone)
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
    var thumbnails: [CGRect] = []
    var hovered: DragSnapLayoutPicker.Pick?
    var caption: String?

    private let tileGap: CGFloat = 3

    func tiles(of layout: Int) -> [CGRect] {
        let thumbnail = thumbnails[layout]
        return DragSnapLayoutPicker.layouts[layout].map { zone in
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

        if let caption, let topOfThumbnails = thumbnails.first?.maxY {
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

        for layout in thumbnails.indices {
            for (zone, tile) in tiles(of: layout).enumerated() {
                let path = NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4)
                let isHovered = hovered == DragSnapLayoutPicker.Pick(layout: layout, zone: zone)
                (isHovered ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.18)).setFill()
                path.fill()
            }
        }
    }
}
