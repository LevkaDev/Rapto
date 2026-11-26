//
//  AppResponsiveness.swift
//  Rapto
//
//  Remembers which apps stopped answering Accessibility requests, so Rapto does not wait for them.
//

import AppKit
import ApplicationServices
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppResponsiveness")

/// The apps that are not answering right now. Read from any thread: window titles and the
/// end of a slot resize are handled off the main thread.
nonisolated final class NotRespondingApps: @unchecked Sendable {
    static let shared = NotRespondingApps()

    init() {}

    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func contains(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.contains(pid)
    }

    /// Returns false when the app was there already.
    func insert(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.insert(pid).inserted
    }

    /// Returns false when the app was not there.
    func remove(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.remove(pid) != nil
    }
}

// MARK: - Workaround: An app that hangs makes every Accessibility request to it wait
// Cause: Accessibility requests are synchronous and run on the main thread. A hung app answers
//        none of them, and each one waits for the whole messaging timeout before it fails.
// Context: Raising one window takes two or three requests and watching an app takes six, so
//          Rapto froze for seconds on the desktop of a hung app. The first request that times
//          out marks the app; requests to a marked app are skipped until it answers a probe
//          sent from a background thread.
final class AppResponsiveness: ObservableObject {
    static let shared = AppResponsiveness()

    /// The same timeout `AccessibilityService` sets for every request.
    nonisolated static let messagingTimeout: TimeInterval = 1.0

    /// An app is skipped from its first timeout, but the user is told only when it still has not
    /// answered this many probes: many apps are busy for a second or two while they launch
    nonisolated static let probesBeforeTelling = 2

    /// The apps the user has been told about. The indicator and the Desktops Bar dim their icons.
    @Published private(set) var notRespondingPIDs: Set<pid_t> = []

    /// Called once per hang, after the app missed `probesBeforeTelling` probes.
    var onStoppedResponding: ((pid_t) -> Void)?
    /// Called when a skipped app answers or quits, whether or not the user was told.
    var onRespondingAgain: ((pid_t) -> Void)?

    nonisolated static func isResponding(_ pid: pid_t) -> Bool {
        !NotRespondingApps.shared.contains(pid)
    }

    /// Whether a request failed because the app never answered, not because the element is gone:
    /// both fail with `cannotComplete`, but only a hung app makes the request wait.
    nonisolated static func timedOut(_ error: AXError, waited: TimeInterval, timeout: TimeInterval = messagingTimeout) -> Bool {
        error == .cannotComplete && waited >= timeout * 0.9
    }

    /// What the user is told, once per hang. Names the app: "a window" would not say which.
    nonisolated static func notRespondingMessage(appName: String?) -> String {
        let name = appName.flatMap { $0.isEmpty ? nil : $0 } ?? "An app"
        return "\(name) is not responding. Rapto will skip its windows until it does."
    }

    /// Runs one request to the app and remembers the app if it never answered.
    /// Only for requests under the system-wide timeout; ones with a shorter timeout of their own
    /// say nothing about an app that is just busy for a moment.
    @discardableResult
    func ask(_ pid: pid_t, _ request: () -> AXError) -> AXError {
        let started = CFAbsoluteTimeGetCurrent()
        let error = request()
        if Self.timedOut(error, waited: CFAbsoluteTimeGetCurrent() - started) {
            markNotResponding(pid)
        }
        return error
    }

    func markNotResponding(_ pid: pid_t) {
        guard NotRespondingApps.shared.insert(pid) else { return }
        logger.notice("App \(pid) is not responding, skipping it")
        debugLog("AppResponsiveness", "PID \(pid) is not responding, skipping it until it answers")
        probeUntilItAnswers(pid)
    }

    private func confirmNotResponding(_ pid: pid_t) {
        guard NotRespondingApps.shared.contains(pid), notRespondingPIDs.insert(pid).inserted else { return }
        debugLog("AppResponsiveness", "PID \(pid) still does not answer, telling the user")
        onStoppedResponding?(pid)
    }

    /// Clears a transient unresponsive mark immediately when another probe hears back from `pid`.
    func noteResponded(_ pid: pid_t) {
        guard NotRespondingApps.shared.contains(pid) else { return }
        DispatchQueue.main.async {
            self.markResponding(pid)
        }
    }

    private func markResponding(_ pid: pid_t) {
        guard NotRespondingApps.shared.remove(pid) else { return }
        notRespondingPIDs.remove(pid)
        logger.notice("App \(pid) answers again")
        debugLog("AppResponsiveness", "PID \(pid) answers again")
        onRespondingAgain?(pid)
    }

    /// Asks the app once a second, off the main thread, until it answers or quits.
    private func probeUntilItAnswers(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var missed = 0
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                if kill(pid, 0) != 0, errno == ESRCH { break }
                let started = CFAbsoluteTimeGetCurrent()
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXRoleAttribute as CFString, &value)
                if !Self.timedOut(error, waited: CFAbsoluteTimeGetCurrent() - started) { break }
                missed += 1
                if missed == Self.probesBeforeTelling {
                    DispatchQueue.main.async {
                        AppResponsiveness.shared.confirmNotResponding(pid)
                    }
                }
            }
            DispatchQueue.main.async {
                AppResponsiveness.shared.markResponding(pid)
            }
        }
    }
}
