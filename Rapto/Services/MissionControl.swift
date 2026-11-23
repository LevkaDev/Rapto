//
//  MissionControl.swift
//  Rapto
//
//  Detects whether Mission Control is open.
//

import AppKit
import ApplicationServices

enum MissionControl {
    // MARK: - Workaround:
    // Cause: In macOS 27 the Mission Control elements belong to the WindowManager process,
    //        and the Dock keeps only an empty "mc" group.
    // Context: Look for the Mission Control screens in WindowManager first, then in the Dock
    //          (macOS 26). They sit directly in the application or in the "mc" group.
    /// The `mc.display` elements of the open Mission Control, empty when it is closed.
    static func displays() -> [AXUIElement] {
        for bundleID in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let top = children(of: AXUIElementCreateApplication(app.processIdentifier))
            let candidates = top + top
                .filter { identifier(of: $0) == "mc" }
                .flatMap { children(of: $0) }
            let displays = candidates.filter { identifier(of: $0) == "mc.display" }
            if !displays.isEmpty { return displays }
        }
        return []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func identifier(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

extension Notification.Name {
    static let missionControlDidOpen = Notification.Name("RaptoMissionControlDidOpen")
    static let missionControlDidClose = Notification.Name("RaptoMissionControlDidClose")
}

/// Posts `.missionControlDidOpen` / `.missionControlDidClose` as Mission Control opens and closes.
@MainActor
final class MissionControlWatcher {
    static let shared = MissionControlWatcher()

    private(set) var isOpen = false
    private var sentinel: NSPanel?
    private var occlusionObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Workaround:
    // Cause: Mission Control posts no events (neither the Dock nor WindowManager in macOS 27),
    //        and our .stationary windows (border, group indicators) stay on top of it.
    // Context: Mission Control hides an invisible 1×1 .transient window about 0.1 s after it opens
    //          and brings it back on close, so a change in its visibility is the event.
    //          It also fires when the screen locks; hiding the border there is fine too.
    func start() {
        guard sentinel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        sentinel = panel

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sentinelOcclusionChanged() }
        }
    }

    private func sentinelOcclusionChanged() {
        guard let sentinel else { return }
        let hidden = !sentinel.occlusionState.contains(.visible)
        guard hidden != isOpen else { return }
        isOpen = hidden
        debugLog("MissionControl", hidden ? "Mission Control opened" : "Mission Control closed")
        NotificationCenter.default.post(name: hidden ? .missionControlDidOpen : .missionControlDidClose, object: nil)
    }
}
