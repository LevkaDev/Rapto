//
//  TourSandboxWindows.swift
//  Rapto
//
//  Two lightweight sample windows opened during the interactive first-run tour when
//  the user's desktop has fewer than two regular windows open.
//
//  Because these NSWindows live in Rapto's own process, calling Accessibility IPC on
//  our own PID from the main thread would deadlock. Services check `TourSandboxWindows.contains(_:)`
//  and move/resize/raise them directly via AppKit instead.
//

import AppKit
import CoreGraphics
import SwiftUI

extension Notification.Name {
    static let dragSnapDidSnapFromPicker = Notification.Name("RaptoDragSnapDidSnapFromPicker")
    static let raptoTourDidSwapWindows = Notification.Name("RaptoTourDidSwapWindows")
    static let raptoTourDidGroupWindows = Notification.Name("RaptoTourDidGroupWindows")
    static let raptoTourDidResizeSlot = Notification.Name("RaptoTourDidResizeSlot")
    static let raptoTourDidCycleGroup = Notification.Name("RaptoTourDidCycleGroup")
    static let raptoTourDidRevealNotchBar = Notification.Name("RaptoTourDidRevealNotchBar")
}

final class TourSandboxWindows {
    @MainActor static let shared = TourSandboxWindows()

    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var activeIDs: Set<CGWindowID> = []

    nonisolated static func contains(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeIDs.contains(windowID)
    }

    nonisolated static var hasActiveWindows: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeIDs.isEmpty
    }

    private nonisolated static func setActiveIDs(_ ids: Set<CGWindowID>) {
        lock.lock()
        activeIDs = ids
        lock.unlock()
    }

    @MainActor private var windows: [CGWindowID: NSWindow] = [:]
    @MainActor private var closeObservers: [CGWindowID: NSObjectProtocol] = [:]

    private init() {}

    @MainActor var count: Int { windows.count }

    /// Opens two draggable, resizable sample windows on `screen` if not already open.
    @MainActor
    func openSamplePair(on screen: NSScreen) {
        if windows.count >= 2 {
            for window in windows.values {
                window.orderFront(nil)
            }
            return
        }
        closeAll()

        let visible = screen.visibleFrame
        let cardWidth = min(560, max(380, (visible.width * 0.42).rounded()))
        let cardHeight = min(440, max(340, (visible.height * 0.56).rounded()))
        let topY = visible.maxY - cardHeight - 70
        let leftX = visible.minX + max(40, (visible.width - cardWidth * 1.55) / 2)

        let specs: [(title: String, subtitle: String, icon: String, tint: Color, origin: CGPoint)] = [
            (
                title: "Sample · Browser",
                subtitle: "Drag this window by its title bar to test Rapto",
                icon: "safari.fill",
                tint: Color(red: 0.22, green: 0.56, blue: 0.98),
                origin: CGPoint(x: leftX, y: max(visible.minY + 120, topY))
            ),
            (
                title: "Sample · Notes",
                subtitle: "A second sample window for snapping, swapping and grouping",
                icon: "note.text",
                tint: Color(red: 0.96, green: 0.64, blue: 0.14),
                origin: CGPoint(x: min(visible.maxX - cardWidth - 36, leftX + cardWidth * 0.55),
                                y: max(visible.minY + 90, topY - 46))
            )
        ]

        var ids = Set<CGWindowID>()
        for spec in specs {
            let content = TourSampleCardView(title: spec.title, subtitle: spec.subtitle, icon: spec.icon, tint: spec.tint)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: controller)
            window.title = spec.title
            window.styleMask = [.titled, .closable, .resizable]
            window.minSize = NSSize(width: 320, height: 320)
            window.isReleasedWhenClosed = false
            window.setFrame(NSRect(origin: spec.origin, size: NSSize(width: cardWidth, height: cardHeight)), display: true)
            window.orderFront(nil)

            let windowID = CGWindowID(window.windowNumber)
            guard windowID > 0 else { continue }
            windows[windowID] = window
            ids.insert(windowID)

            closeObservers[windowID] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.unregister(windowID: windowID)
                }
            }
        }
        Self.setActiveIDs(ids)
    }

    @MainActor
    func closeAll() {
        let existing = Array(windows.values)
        for observer in closeObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
        closeObservers.removeAll()
        windows.removeAll()
        Self.setActiveIDs([])
        for window in existing {
            window.close()
        }
    }

    @MainActor
    private func unregister(windowID: CGWindowID) {
        if let observer = closeObservers.removeValue(forKey: windowID) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows.removeValue(forKey: windowID)
        Self.setActiveIDs(Set(windows.keys))
    }

    /// Moves and resizes a sandbox window directly in AppKit using a CG-coordinate frame.
    @MainActor
    @discardableResult
    func setCGFrame(_ cgFrame: CGRect, for windowID: CGWindowID) -> Bool {
        guard let window = windows[windowID] else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 1080
        let appKitFrame = NSRect(
            x: cgFrame.origin.x,
            y: primaryHeight - cgFrame.origin.y - cgFrame.height,
            width: max(window.minSize.width, cgFrame.width),
            height: max(window.minSize.height, cgFrame.height)
        )
        window.setFrame(appKitFrame, display: true)
        return true
    }

    @MainActor
    func cgFrame(for windowID: CGWindowID) -> CGRect? {
        guard let window = windows[windowID] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 1080
        let frame = window.frame
        return CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    @MainActor
    @discardableResult
    func raise(windowID: CGWindowID) -> Bool {
        guard let window = windows[windowID] else { return false }
        window.orderFront(nil)
        return true
    }
}

private struct TourSampleCardView: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 60, height: 60)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 14)
                    .padding(.trailing, 48)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 14)
                    .padding(.trailing, 96)
            }
            .frame(maxWidth: 280)
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
