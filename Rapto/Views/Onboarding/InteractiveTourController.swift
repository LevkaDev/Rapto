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
            onFinish: { [weak self] in
                self?.close()
            }
        )
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: tourView)
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
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func close() {
        let existing = panel
        panel = nil
        appState?.isInteractiveTourActive = false
        appState?.closeTourSandboxWindows()
        appState?.clearFirstRunArrangeUndo()
        existing?.orderOut(nil)
        existing?.contentView = nil
    }
}
