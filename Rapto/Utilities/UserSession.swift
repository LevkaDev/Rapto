//
//  UserSession.swift
//  Rapto
//
//  Tracks whether this user's login session is in front.
//

import AppKit
import CoreGraphics

// MARK: - Workaround: Fast User Switching hides all windows
// While another user is in front, macOS reports no windows to this session's apps.
// A window list read then must not be treated as "every window was closed".
enum UserSession {
    private static var isInFront = true
    private static var observers: [NSObjectProtocol] = []

    static var isActive: Bool {
        guard isInFront else { return false }
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return info[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    static var isScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// `onReturn` runs once windows are visible again after the user switches back.
    static func startMonitoring(onReturn: @escaping @MainActor () -> Void) {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                isInFront = false
                debugLog("UserSession", "Session moved to background, window tracking paused")
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                debugLog("UserSession", "Session back in front, resuming window tracking")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    isInFront = true
                    onReturn()
                }
            }
        })
    }
}
