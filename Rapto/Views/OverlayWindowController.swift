//
//  OverlayWindowController.swift
//  Rapto
//
//  Custom NSPanel wrapper for the fullscreen overlay window.
//

import AppKit
import SwiftUI

class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Creates an NSPanel with borderless, nonactivatingPanel style that floats above other windows
class OverlayWindowController: NSWindowController {
    
    /// Called when ESC is pressed while the overlay is on screen
    var onEscape: (() -> Void)?
    
    /// Local ESC monitor, alive only between show() and hide(): it swallows ESC for the whole app
    private var escapeMonitor: Any?
    
    var isListeningForEscape: Bool { escapeMonitor != nil }
    
    // MARK: - Initialization
    
    convenience init<Content: View>(contentView: Content) {
        let hostingView = NSHostingView(rootView: contentView)
        self.init(contentView: hostingView)
    }
    
    convenience init(contentView: NSView) {
        let panel = OverlayPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        
        // Use stationary to keep overlay on its original Space
        panel.collectionBehavior = [.stationary, .fullScreenAuxiliary, .ignoresCycle]
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = contentView
        
        // Allow the panel to become key window for keyboard events
        panel.becomesKeyOnlyIfNeeded = false
        
        self.init(window: panel)
    }
    
    // MARK: - Show/Hide Methods
    
    /// Show the overlay on the active screen
    func show() {
        guard let panel = window else { return }
        
        let screenFrame = NSScreen.main?.frame ?? .zero
        panel.setFrame(screenFrame, display: true)
        
        // Order front without making key (to avoid stealing focus)
        panel.orderFrontRegardless()
        
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.window?.isVisible == true else { return event }
            Task { @MainActor [weak self] in
                self?.onEscape?()
            }
            return nil // Consume the event
        }
    }
    
    func hide() {
        removeEscapeMonitor()
        window?.orderOut(nil)
    }
    
    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
        debugLog("OverlayWindowController", "Removed ESC monitor")
    }
}
