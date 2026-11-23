//
//  HintLabel.swift
//  Rapto
//
//  Draws a centered translucent pill with a title and optional detail line inside
//  slot and snap-zone preview views.
//

import AppKit

enum HintLabel {

    private static let minWidthForAnyLabel: CGFloat = 140
    private static let minHeightForAnyLabel: CGFloat = 70
    private static let minWidthForDetail: CGFloat = 260
    private static let minHeightForDetail: CGFloat = 120

    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 10
    private static let lineSpacing: CGFloat = 3
    private static let pillCornerRadius: CGFloat = 10

    /// Draws `hint` centered inside `bounds` (AppKit bottom-left view coordinates).
    /// Drops the detail line in compact slots and draws nothing in very small slots.
    static func draw(_ hint: DragHint, in bounds: CGRect) {
        guard bounds.width >= minWidthForAnyLabel,
              bounds.height >= minHeightForAnyLabel else {
            return
        }

        let showsDetail = bounds.width >= minWidthForDetail && bounds.height >= minHeightForDetail
        let detailText = showsDetail ? hint.detail : nil

        let maxPillWidth = max(80, bounds.width - 24)
        let maxTextWidth = max(48, maxPillWidth - horizontalPadding * 2)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.86),
            .paragraphStyle: paragraph
        ]

        let titleString = NSAttributedString(string: hint.title, attributes: titleAttributes)
        let rawTitleSize = titleString.size()
        let titleWidth = min(ceil(rawTitleSize.width), maxTextWidth)
        let titleHeight = ceil(rawTitleSize.height)

        var detailString: NSAttributedString?
        var detailWidth: CGFloat = 0
        var detailHeight: CGFloat = 0

        if let detailText, !detailText.isEmpty {
            let attr = NSAttributedString(string: detailText, attributes: detailAttributes)
            let rawDetailSize = attr.size()
            detailString = attr
            detailWidth = min(ceil(rawDetailSize.width), maxTextWidth)
            detailHeight = ceil(rawDetailSize.height)
        }

        let contentWidth = max(titleWidth, detailWidth)
        let contentHeight = detailString != nil
            ? (titleHeight + lineSpacing + detailHeight)
            : titleHeight

        let pillWidth = contentWidth + horizontalPadding * 2
        let pillHeight = contentHeight + verticalPadding * 2

        let pillRect = CGRect(
            x: round(bounds.midX - pillWidth / 2),
            y: round(bounds.midY - pillHeight / 2),
            width: pillWidth,
            height: pillHeight
        )

        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillCornerRadius, yRadius: pillCornerRadius)
        NSColor.black.withAlphaComponent(0.62).setFill()
        pillPath.fill()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        if let detailString {
            // In non-flipped NSView coordinates, y=minY is at the bottom: detail sits below title.
            let detailRect = CGRect(
                x: pillRect.minX + horizontalPadding,
                y: pillRect.minY + verticalPadding,
                width: contentWidth,
                height: detailHeight
            )
            let titleRect = CGRect(
                x: pillRect.minX + horizontalPadding,
                y: detailRect.maxY + lineSpacing,
                width: contentWidth,
                height: titleHeight
            )
            titleString.draw(in: titleRect)
            detailString.draw(in: detailRect)
        } else {
            let titleRect = CGRect(
                x: pillRect.minX + horizontalPadding,
                y: pillRect.minY + verticalPadding,
                width: contentWidth,
                height: titleHeight
            )
            titleString.draw(in: titleRect)
        }
    }
}
