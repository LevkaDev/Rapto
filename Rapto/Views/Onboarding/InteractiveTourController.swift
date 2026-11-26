//
//  InteractiveTourController.swift
//  Rapto
//
//  Hosts the compact floating Interactive Tour HUD near the bottom center of the active screen.
//

import AppKit
import SwiftUI

@MainActor
final class InteractiveTourController {
    static let shared = InteractiveTourController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var appState: AppState?

    private init() {}

    var isVisible: Bool { panel != nil }

    func start(appState: AppState, mode: TilingMode, alreadyArranged: Bool) {
        close()
        self.appState = appState
        appState.isInteractiveTourActive = true

        // If the user's desktop has fewer than two movable windows, open two clean sample windows
        // right away so every tour step works on the first try.
        let activeScreen = appState.screenManager.activeScreen()
        if appState.eligibleWindowsForFirstArrange(on: activeScreen).count < 2 {
            appState.openTourSandboxWindows()
        }

        let tourView = InteractiveTourView(
            mode: mode,
            hasNotchedHoverBar: appState.hasNotchedHoverBar,
            alreadyArranged: alreadyArranged,
            showsSpaceBar: appState.showsSpaceBar,
            initialDesktopCount: appState.desktopCount(on: activeScreen),
            windowFlowShortcut: appState.shortcutDisplayString(for: .openWindowFlow),
            onLayoutChange: { [weak self] in
                self?.resizeToFit()
            },
            onFinish: { [weak self] in
                self?.close()
            }
        )
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: AnyView(tourView))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hostingView = hosting
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        let visible = activeScreen.visibleFrame
        let origin = NSPoint(
            x: round(visible.midX - size.width / 2),
            y: round(visible.minY + 26)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    /// Resizes the floating HUD smoothly when tasks expand/collapse or buttons change,
    /// preserving the bottom-center anchor so the card never clips or jumps.
    func resizeToFit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hosting = self.hostingView else { return }
            hosting.layoutSubtreeIfNeeded()
            let newSize = hosting.fittingSize
            guard newSize.width > 0, newSize.height > 0 else { return }
            let current = panel.frame
            let updated = NSRect(
                x: round(current.midX - newSize.width / 2),
                y: current.minY,
                width: newSize.width,
                height: newSize.height
            )
            if abs(updated.height - current.height) > 0.5 || abs(updated.width - current.width) > 0.5 {
                panel.setFrame(updated, display: true, animate: false)
                panel.invalidateShadow()
            }
        }
    }

    func close() {
        let existing = panel
        panel = nil
        hostingView = nil
        appState?.isInteractiveTourActive = false
        appState?.closeTourSandboxWindows()
        appState?.clearFirstRunArrangeUndo()
        existing?.orderOut(nil)
        existing?.contentView = nil
    }
}
