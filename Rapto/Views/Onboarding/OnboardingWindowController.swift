//
//  OnboardingWindowController.swift
//  Rapto
//
//  Window controller for first-launch onboarding.
//

import SwiftUI
import AppKit

@MainActor
final class OnboardingWindowController {
    
    static let shared = OnboardingWindowController()
    
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var closeObserver: NSObjectProtocol?
    
    private init() {}
    
    func show(appState: AppState) {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        
        let onboardingView = OnboardingView(
            onComplete: { [weak self] in
                self?.close()
                appState.completeOnboarding(launchingTour: false)
            },
            onStartTour: { [weak self] mode, alreadyArranged in
                self?.close()
                appState.completeOnboarding(launchingTour: true)
                InteractiveTourController.shared.start(
                    appState: appState,
                    mode: mode,
                    alreadyArranged: alreadyArranged
                )
            }
        )
        .environmentObject(appState)
        
        let controller = NSHostingController(rootView: AnyView(onboardingView))
        controller.sizingOptions = []
        hostingController = controller
        
        let size = NSSize(width: 700, height: 600)
        let newWindow = NSWindow(contentViewController: controller)
        newWindow.title = "Welcome to Rapto"
        // The demo stage runs under the transparent title bar
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isMovableByWindowBackground = true
        newWindow.setContentSize(size)
        newWindow.minSize = size
        newWindow.maxSize = size
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        
        // Normal level to allow system dialogs (Accessibility, Screen Recording) to appear on top
        newWindow.level = .normal
        
        // Showing it again from another desktop brings it there instead of raising it where it was opened
        newWindow.collectionBehavior = [.moveToActiveSpace]
        
        // Closing with the red button doesn't finish onboarding, but lets Settings → Show Onboarding open it again
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didClose()
                appState.isOnboardingVisible = false
            }
        }
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    
    func bringToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }
    
    private func didClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
        hostingController = nil
    }
}
