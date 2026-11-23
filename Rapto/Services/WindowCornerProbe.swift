//
//  WindowCornerProbe.swift
//  Rapto
//
//  Measures the real corner shape of a window from its pixels, so the active
//  window border can follow the corners exactly on any macOS version.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

nonisolated struct WindowCornerShape: Equatable, Sendable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var bottomLeft: CGFloat
    var style: RoundedCornerStyle

    static func uniform(radius: CGFloat, style: RoundedCornerStyle = .continuous) -> WindowCornerShape {
        WindowCornerShape(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius, style: style)
    }

    /// Outline of a window occupying `rect` in AppKit coordinates (y grows upward)
    func path(in rect: CGRect) -> CGPath {
        // SwiftUI paths are y-down, so its "top" corners are the visual bottom ones here
        let radii = RectangleCornerRadii(
            topLeading: bottomLeft,
            bottomLeading: topLeft,
            bottomTrailing: topRight,
            topTrailing: bottomRight
        )
        return UnevenRoundedRectangle(cornerRadii: radii, style: style).path(in: rect).cgPath
    }
}

nonisolated enum WindowCornerProbe {

    /// Largest corner the probe looks for, in points
    private static let maxCornerSize: CGFloat = 64

    /// Capture the window once and read its corner shape from the transparent pixels.
    /// Returns nil without Screen Recording permission or when the corners can't be read
    /// reliably (for example, a window with see-through content at the edges).
    @MainActor
    static func measure(windowID: CGWindowID) async -> WindowCornerShape? {
        // Never trigger the Screen Recording prompt from here
        guard CGPreflightScreenCaptureAccess() else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }),
                  scWindow.frame.width > 0, scWindow.frame.height > 0 else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = CGFloat(max(filter.pointPixelScale, 1))

            let configuration = SCStreamConfiguration()
            configuration.width = Int((scWindow.frame.width * scale).rounded())
            configuration.height = Int((scWindow.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let pointWidth = scWindow.frame.width
            let shape = await Task.detached(priority: .utility) {
                analyze(image, pointWidth: pointWidth)
            }.value
            if let shape {
                debugLog("WindowHighlight", "Corner probe for window \(windowID): radius \(shape.topLeft)pt, \(shape.style == .continuous ? "continuous" : "circular")")
            } else {
                debugLog("WindowHighlight", "Corner probe for window \(windowID): corners unreadable")
            }
            return shape
        } catch {
            debugLog("WindowHighlight", "Corner probe failed for window \(windowID): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pixel Analysis

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft

        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    /// Measures each corner's edge profile, then finds the circular or continuous
    /// rounded corner that renders the same profile
    static func analyze(_ image: CGImage, pointWidth: CGFloat) -> WindowCornerShape? {
        let scale = CGFloat(image.width) / pointWidth
        guard scale > 0 else { return nil }

        let n = Int(min(maxCornerSize * scale, CGFloat(image.width) / 2 - 1, CGFloat(image.height) / 2 - 1))
        guard n >= 8 else { return nil }

        var measured: [Corner: [CGFloat]] = [:]
        for corner in Corner.allCases {
            guard let insets = edgeInsets(of: corner, in: image, size: n) else { return nil }
            measured[corner] = insets
        }

        let radii = stride(from: CGFloat(0), through: maxCornerSize * 0.75, by: 0.5).map { $0 }
        var best: (shape: WindowCornerShape, error: CGFloat)?

        for style in [RoundedCornerStyle.continuous, .circular] {
            let models = radii.map { modelInsets(radius: $0, style: style, size: n, scale: scale) }
            var fitted: [Corner: CGFloat] = [:]
            var totalError: CGFloat = 0

            for corner in Corner.allCases {
                guard let insets = measured[corner] else { return nil }
                var bestRadius: (radius: CGFloat, error: CGFloat) = (0, .infinity)
                for (radius, model) in zip(radii, models) {
                    let error = meanSquaredError(insets, model)
                    if error < bestRadius.error { bestRadius = (radius, error) }
                }
                fitted[corner] = bestRadius.radius
                totalError += bestRadius.error
            }

            let shape = WindowCornerShape(
                topLeft: fitted[.topLeft] ?? 0,
                topRight: fitted[.topRight] ?? 0,
                bottomRight: fitted[.bottomRight] ?? 0,
                bottomLeft: fitted[.bottomLeft] ?? 0,
                style: style
            )
            let error = totalError / 4
            if error < (best?.error ?? .infinity) { best = (shape, error) }
        }

        // Reject shapes no rounded corner explains (RMS above ~half a pixel)
        guard let best, best.error < 0.3 else { return nil }
        return best.shape
    }

    private static func meanSquaredError(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let count = min(a.count, b.count)
        guard count > 0 else { return .infinity }
        var sum: CGFloat = 0
        for i in 0..<count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum / CGFloat(count)
    }

    /// For each pixel row near the corner, how far (in pixels, sub-pixel precise) the
    /// window edge sits from the vertical window edge
    private static func edgeInsets(of corner: Corner, in image: CGImage, size n: Int) -> [CGFloat]? {
        // One extra column holds the reference alpha of the window content in each row
        let tileWidth = n + 1
        let tileRect = CGRect(
            x: corner.isRight ? image.width - tileWidth : 0,
            y: corner.isBottom ? image.height - n : 0,
            width: tileWidth,
            height: n
        )
        guard let tile = image.cropping(to: tileRect),
              let alpha = alphaPixels(of: tile) else {
            return nil
        }

        var insets: [CGFloat] = []
        insets.reserveCapacity(n)
        for d in 0..<n {
            let row = corner.isBottom ? n - 1 - d : d
            let base = row * tileWidth
            let reference = CGFloat(alpha[base + (corner.isRight ? 0 : n)])
            // See-through content makes the edge unreadable
            guard reference >= 64 else { return nil }

            var inset: CGFloat = 0
            for k in 0..<n {
                let column = corner.isRight ? n - k : k
                inset += 1 - min(CGFloat(alpha[base + column]) / reference, 1)
            }
            insets.append(inset)
        }

        // The edge must be straight again at the end of the tile
        guard let last = insets.last, last < 1 else { return nil }
        return insets
    }

    /// Edge insets of a rendered rounded corner, measured the same way as a real window
    private static func modelInsets(radius: CGFloat, style: RoundedCornerStyle, size n: Int, scale: CGFloat) -> [CGFloat] {
        let tileWidth = n + 1
        var rgba = [UInt8](repeating: 0, count: tileWidth * n * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: tileWidth,
                height: n,
                bitsPerComponent: 8,
                bytesPerRow: tileWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // Flip so the shape's top-left corner lands on the first row in memory
            context.translateBy(x: 0, y: CGFloat(n))
            context.scaleBy(x: 1, y: -1)
            let big = CGFloat(n) * 4
            let path = RoundedRectangle(cornerRadius: radius * scale, style: style)
                .path(in: CGRect(x: 0, y: 0, width: big, height: big))
                .cgPath
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }

        return (0..<n).map { row in
            var inset: CGFloat = 0
            for k in 0..<n {
                inset += 1 - CGFloat(rgba[(row * tileWidth + k) * 4 + 3]) / 255
            }
            return inset
        }
    }

    /// Alpha channel of an image, row 0 at the top
    private static func alphaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (0..<(width * height)).map { rgba[$0 * 4 + 3] }
    }
}
