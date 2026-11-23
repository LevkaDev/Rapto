//
//  DragSnapPreviewWindow.swift
//  Rapto
//
//  A semi-transparent preview window that shows where a window will snap to.
//

import Foundation
import AppKit
import SwiftUI

@MainActor
class DragSnapPreviewWindow {
    
    private var window: NSWindow?
    private var isVisible: Bool = false
    
    // MARK: - Configuration
    
    private let previewColor = NSColor.systemBlue.withAlphaComponent(0.2)
    
    private let borderColor = NSColor.systemBlue.withAlphaComponent(0.6)
    
    private let borderWidth: CGFloat = 3
    
    private let cornerRadius: CGFloat = 12
    
    private let animationDuration: TimeInterval = 0.15
    
    // MARK: - Initialization
    
    init() {
        setupWindow()
    }
    
    // MARK: - Window Setup
    
    private func setupWindow() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above the layout zone outlines
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        
        let contentView = PreviewContentView()
        contentView.previewColor = previewColor
        contentView.borderColor = borderColor
        contentView.borderWidth = borderWidth
        contentView.cornerRadius = cornerRadius
        
        window.contentView = contentView
        
        self.window = window
    }
    
    // MARK: - Public Methods
    
    private var targetFrame: CGRect?
    
    var isShowing: Bool { isVisible }
    
    /// - Parameters:
    ///   - frame: The frame where the preview should appear (AppKit screen coordinates)
    ///   - startFrame: When the preview appears, it grows from here (the dragged window)
    func showPreview(frame: CGRect, growingFrom startFrame: CGRect? = nil, hint: DragHint? = nil) {
        guard let window = window else { return }
        if let contentView = window.contentView as? PreviewContentView, contentView.hint != hint {
            contentView.hint = hint
            contentView.needsDisplay = true
        }
        guard !isVisible || targetFrame != frame || !window.isVisible else { return }
        targetFrame = frame
        
        if !isVisible {
            isVisible = true
            window.setFrame(startFrame ?? frame, display: true)
            window.alphaValue = 0
        }
        if !window.isVisible {
            window.orderFront(nil)
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }
    
    func hidePreview() {
        guard let window = window, isVisible else { return }
        
        isVisible = false
        targetFrame = nil
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // The preview may have been shown again while fading out
                guard self?.isVisible == false else { return }
                window.orderOut(nil)
            }
        }
    }
    
    /// Takes the preview off screen at once, without the fade. Call before dropping this object
    func remove() {
        isVisible = false
        targetFrame = nil
        window?.orderOut(nil)
    }
}

// MARK: - Layout Zones Window

/// Outlines of all zones of the desktop's layout, shown under the preview while ⌥ is held
@MainActor
class DragSnapZonesWindow {
    
    private let window: NSWindow
    private let zonesView = ZonesOutlineView()
    private var shownZones: [CGRect] = []
    
    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = zonesView
    }
    
    /// - Parameters:
    ///   - zones: Zone frames in AppKit screen coordinates
    func show(zones: [CGRect], on screenFrame: CGRect) {
        guard zones != shownZones || !window.isVisible else { return }
        shownZones = zones
        window.setFrame(screenFrame, display: false)
        zonesView.zones = zones.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        zonesView.needsDisplay = true
        window.orderFront(nil)
    }
    
    func hide() {
        guard window.isVisible else { return }
        shownZones = []
        window.orderOut(nil)
    }
}

private class ZonesOutlineView: NSView {
    var zones: [CGRect] = []
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for zone in zones {
            let path = NSBezierPath(roundedRect: zone.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            NSColor.systemBlue.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

// MARK: - Preview Content View

private class PreviewContentView: NSView {
    
    var previewColor: NSColor = .systemBlue.withAlphaComponent(0.2)
    var borderColor: NSColor = .systemBlue.withAlphaComponent(0.6)
    var borderWidth: CGFloat = 3
    var cornerRadius: CGFloat = 12
    var hint: DragHint?
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        
        previewColor.setFill()
        path.fill()
        
        borderColor.setStroke()
        path.lineWidth = borderWidth
        path.stroke()

        if let hint {
            HintLabel.draw(hint, in: bounds)
        }
    }
}

// MARK: - SwiftUI Preview Wrapper (for testing)

#if DEBUG
struct DragSnapPreviewView: NSViewRepresentable {
    let frame: CGRect
    
    func makeNSView(context: Context) -> NSView {
        let view = PreviewContentView()
        view.previewColor = .systemBlue.withAlphaComponent(0.2)
        view.borderColor = .systemBlue.withAlphaComponent(0.6)
        view.borderWidth = 3
        view.cornerRadius = 12
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct DragSnapPreviewWindow_Previews: PreviewProvider {
    static var previews: some View {
        DragSnapPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            .frame(width: 400, height: 300)
    }
}
#endif
