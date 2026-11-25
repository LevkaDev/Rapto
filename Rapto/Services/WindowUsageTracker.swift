//
//  WindowUsageTracker.swift
//  Rapto
//
//  Tracks which windows the user actually works in and orders the window strip by:
//    slot 0: currently focused window
//    slot 1: previous genuine window (instant back-and-forth)
//    slots 2+: frequency + recency score with smooth exponential time decay
//

import AppKit
import ApplicationServices
import CoreGraphics

/// Pure, time-injected frecency ranker so all ordering rules can be unit-tested deterministically.
nonisolated struct WindowUsageRanker: Sendable {
    struct Entry: Sendable {
        var score: Double
        var updatedAt: TimeInterval
        var lastFocusedAt: TimeInterval
    }

    /// Time for a window's accumulated score to decay by half (2.5 hours).
    let halfLife: TimeInterval
    /// Minimum dwell before a focus visit counts as intentional and updates "previous window".
    let minVisitDuration: TimeInterval
    /// Base points added for each intentional focus visit.
    let visitWeight: Double
    /// Maximum extra points earned from staying actively in one window during a single session.
    let maxDwellBonus: Double
    /// Active seconds needed to reach `maxDwellBonus` (10 minutes).
    let dwellSaturationSeconds: TimeInterval
    /// Idle grace period before user inactivity stops adding dwell points.
    let idleGraceSeconds: TimeInterval

    private(set) var entries: [CGWindowID: Entry] = [:]
    private(set) var activeWindowID: CGWindowID?
    private(set) var activeSince: TimeInterval = 0
    private(set) var activeCommitted = false
    private(set) var activeDwellCredited: Double = 0
    private(set) var lastCommittedWindowID: CGWindowID?
    private(set) var previousWindowID: CGWindowID?

    init(
        halfLife: TimeInterval = 2.5 * 3600,
        minVisitDuration: TimeInterval = 1.5,
        visitWeight: Double = 1.0,
        maxDwellBonus: Double = 1.5,
        dwellSaturationSeconds: TimeInterval = 600,
        idleGraceSeconds: TimeInterval = 30
    ) {
        self.halfLife = halfLife
        self.minVisitDuration = minVisitDuration
        self.visitWeight = visitWeight
        self.maxDwellBonus = maxDwellBonus
        self.dwellSaturationSeconds = dwellSaturationSeconds
        self.idleGraceSeconds = idleGraceSeconds
    }

    /// Records a system focus change to `windowID` (or `nil` if no normal window holds focus).
    mutating func focusChanged(
        to windowID: CGWindowID?,
        at now: TimeInterval,
        userIdleSeconds: TimeInterval = 0
    ) {
        if windowID == activeWindowID {
            settleActive(at: now, userIdleSeconds: userIdleSeconds)
            return
        }
        settleActive(at: now, userIdleSeconds: userIdleSeconds)
        activeWindowID = windowID
        activeSince = now
        activeCommitted = false
        activeDwellCredited = 0
    }

    /// Records an intentional selection from the strip (counts immediately without waiting `minVisitDuration`).
    mutating func recordExplicitSelection(
        _ windowID: CGWindowID,
        at now: TimeInterval,
        userIdleSeconds: TimeInterval = 0
    ) {
        settleActive(at: now, userIdleSeconds: userIdleSeconds)
        if activeWindowID == windowID, activeCommitted {
            addScore(visitWeight * 0.5, to: windowID, at: now)
            return
        }
        commitVisit(windowID, at: now)
        activeWindowID = windowID
        activeSince = now
        activeCommitted = true
        activeDwellCredited = 0
    }

    /// Commits the active window once it crosses `minVisitDuration` and credits capped active dwell time.
    mutating func settleActive(at now: TimeInterval, userIdleSeconds: TimeInterval = 0) {
        guard let id = activeWindowID else { return }
        let elapsed = max(0, now - activeSince)
        if !activeCommitted {
            guard elapsed >= minVisitDuration else { return }
            commitVisit(id, at: now)
            activeCommitted = true
        }
        let idlePenalty = max(0, userIdleSeconds - idleGraceSeconds)
        let effectiveDuration = max(0, elapsed - idlePenalty)
        let progress = dwellSaturationSeconds > 0 ? min(effectiveDuration / dwellSaturationSeconds, 1.0) : 0
        let targetDwell = maxDwellBonus * progress
        let delta = max(0, targetDwell - activeDwellCredited)
        if delta > 0.001 {
            addScore(delta, to: id, at: now)
            activeDwellCredited += delta
        }
    }

    /// Decayed frecency score of `windowID` at `now`.
    func score(for windowID: CGWindowID, at now: TimeInterval) -> Double {
        guard let entry = entries[windowID] else { return 0 }
        let value = decayed(entry.score, elapsed: max(0, now - entry.updatedAt))
        return value < 1e-6 ? 0 : value
    }

    /// The most recent confirmed window other than `currentWindowID`, used for slot 1 ping-pong.
    func previousWindow(excluding currentWindowID: CGWindowID?) -> CGWindowID? {
        if let last = lastCommittedWindowID, last != currentWindowID {
            return last
        }
        if let prev = previousWindowID, prev != currentWindowID {
            return prev
        }
        return nil
    }

    /// Removes entries for windows that are no longer open across any display.
    mutating func prune(keeping openWindowIDs: Set<CGWindowID>) {
        entries = entries.filter { openWindowIDs.contains($0.key) }
        if let prev = previousWindowID, !openWindowIDs.contains(prev) {
            previousWindowID = nil
        }
        if let last = lastCommittedWindowID, !openWindowIDs.contains(last) {
            lastCommittedWindowID = nil
        }
        if let active = activeWindowID, !openWindowIDs.contains(active) {
            activeWindowID = nil
            activeCommitted = false
            activeDwellCredited = 0
        }
    }

    /// Orders `items` for a single display:
    ///   0: `currentWindowID` (when present)
    ///   1: previous genuine window (when present on this display)
    ///   2+: descending frecency score, tie-breaking by `lastFocusedAt`, then original order.
    mutating func order<T>(
        _ items: [T],
        id: (T) -> CGWindowID,
        currentWindowID: CGWindowID?,
        at now: TimeInterval,
        userIdleSeconds: TimeInterval = 0
    ) -> [T] {
        settleActive(at: now, userIdleSeconds: userIdleSeconds)
        guard items.count > 1 else { return items }

        let indexed = items.enumerated().map { ($0.offset, $0.element, id($0.element)) }
        var result: [T] = []
        result.reserveCapacity(items.count)
        var usedIDs: Set<CGWindowID> = []

        // Slot 0: currently focused window
        if let currentWindowID,
           let match = indexed.first(where: { $0.2 == currentWindowID }) {
            result.append(match.1)
            usedIDs.insert(match.2)
        }

        // Slot 1: last genuine window before the current one
        let prevID = previousWindow(excluding: currentWindowID)
        if let prevID, !usedIDs.contains(prevID),
           let match = indexed.first(where: { $0.2 == prevID }) {
            result.append(match.1)
            usedIDs.insert(match.2)
        }

        // Slots 2+: frecency (score -> lastFocusedAt -> original order)
        let remaining = indexed.filter { !usedIDs.contains($0.2) }
        let sortedRemaining = remaining.sorted { lhs, rhs in
            let s1 = score(for: lhs.2, at: now)
            let s2 = score(for: rhs.2, at: now)
            if abs(s1 - s2) > 1e-6 { return s1 > s2 }
            let t1 = entries[lhs.2]?.lastFocusedAt ?? -Double.greatestFiniteMagnitude
            let t2 = entries[rhs.2]?.lastFocusedAt ?? -Double.greatestFiniteMagnitude
            if abs(t1 - t2) > 1e-6 { return t1 > t2 }
            return lhs.0 < rhs.0
        }
        result.append(contentsOf: sortedRemaining.map(\.1))
        return result
    }

    private mutating func commitVisit(_ windowID: CGWindowID, at now: TimeInterval) {
        if let last = lastCommittedWindowID, last != windowID {
            previousWindowID = last
        }
        lastCommittedWindowID = windowID
        addScore(visitWeight, to: windowID, at: now)
    }

    private mutating func addScore(_ delta: Double, to windowID: CGWindowID, at now: TimeInterval) {
        let current = score(for: windowID, at: now)
        entries[windowID] = Entry(
            score: current + delta,
            updatedAt: now,
            lastFocusedAt: now
        )
    }

    private func decayed(_ value: Double, elapsed: TimeInterval) -> Double {
        guard value > 0, halfLife > 0, elapsed > 0 else { return value }
        return value * pow(0.5, elapsed / halfLife)
    }
}

/// Lightweight event-driven observer feeding `WindowUsageRanker` from app switches,
/// space switches, same-app window switches, and explicit strip selections.
@MainActor
final class WindowUsageTracker {
    private let spaceBar: SpaceBarController
    private var ranker = WindowUsageRanker()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var axObservedApp: AXUIElement?
    private var axObservedPID: pid_t = 0
    private var settleTask: Task<Void, Never>?
    private var spaceSettleTask: Task<Void, Never>?
    private var isStarted = false

    /// Set true while the visual strip is open so overlay focus transitions never pollute history.
    var isSuppressed = false

    init(spaceBar: SpaceBarController) {
        self.spaceBar = spaceBar
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            nc.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                Task { @MainActor [weak self] in
                    self?.handleApplicationActivated(pid: pid)
                }
            }
        )
        workspaceObservers.append(
            nc.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSpaceChanged()
                }
            }
        )

        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            attachFocusedWindowObserver(for: frontPID)
        }
        recordCurrentFrontmostWindow()
    }

    func stop() {
        isStarted = false
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        detachFocusedWindowObserver()
        settleTask?.cancel()
        settleTask = nil
        spaceSettleTask?.cancel()
        spaceSettleTask = nil
    }

    func recordExplicitSelection(_ windowID: CGWindowID) {
        let now = ProcessInfo.processInfo.systemUptime
        ranker.recordExplicitSelection(windowID, at: now, userIdleSeconds: Self.userIdleSeconds())
        scheduleDwellSettle()
    }

    func order(
        _ displayEntries: [WindowSwitcherEntry],
        allOpenWindowIDs: Set<CGWindowID>,
        currentWindowID: CGWindowID?
    ) -> [WindowSwitcherEntry] {
        let now = ProcessInfo.processInfo.systemUptime
        let idle = Self.userIdleSeconds()
        ranker.prune(keeping: allOpenWindowIDs)
        let ordered = ranker.order(
            displayEntries,
            id: \.id,
            currentWindowID: currentWindowID,
            at: now,
            userIdleSeconds: idle
        )
        let summary = ordered.prefix(5).enumerated().map { idx, entry in
            let s = String(format: "%.2f", ranker.score(for: entry.id, at: now))
            return "#\(idx) \(entry.appName)(\(entry.id), \(s))"
        }.joined(separator: ", ")
        debugLog("WindowStrip", "Smart order [prev=\(ranker.previousWindow(excluding: currentWindowID).map(String.init) ?? "none")]: \(summary)")
        return ordered
    }

    // MARK: - Observation

    private func handleApplicationActivated(pid: pid_t?) {
        guard !isSuppressed else { return }
        let targetPID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if targetPID != 0, targetPID != ProcessInfo.processInfo.processIdentifier {
            attachFocusedWindowObserver(for: targetPID)
        } else {
            detachFocusedWindowObserver()
        }
        recordCurrentFrontmostWindow()
    }

    private func handleSpaceChanged() {
        guard !isSuppressed else { return }
        spaceSettleTask?.cancel()
        spaceSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, !self.isSuppressed else { return }
            if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               frontPID != self.axObservedPID {
                self.attachFocusedWindowObserver(for: frontPID)
            }
            self.recordCurrentFrontmostWindow()
        }
    }

    fileprivate func handleFocusedWindowNotification() {
        guard !isSuppressed else { return }
        recordCurrentFrontmostWindow()
    }

    private func recordCurrentFrontmostWindow() {
        guard !isSuppressed else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
            return
        }
        let focusedID = spaceBar.frontmostWindowID()
        let now = ProcessInfo.processInfo.systemUptime
        ranker.focusChanged(to: focusedID, at: now, userIdleSeconds: Self.userIdleSeconds())
        scheduleDwellSettle()
    }

    private func scheduleDwellSettle() {
        settleTask?.cancel()
        let delayNs = UInt64((ranker.minVisitDuration + 0.1) * 1_000_000_000)
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, let self, !self.isSuppressed else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.ranker.settleActive(at: now, userIdleSeconds: Self.userIdleSeconds())
        }
    }

    private func attachFocusedWindowObserver(for pid: pid_t) {
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier else {
            detachFocusedWindowObserver()
            return
        }
        if pid == axObservedPID, axObserver != nil { return }
        detachFocusedWindowObserver()
        guard AXIsProcessTrusted(), AppResponsiveness.isResponding(pid) else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowUsageTracker>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak tracker] in
                tracker?.handleFocusedWindowNotification()
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        guard status == .success || status == .notificationAlreadyRegistered else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        axObservedApp = appElement
        axObservedPID = pid
    }

    private func detachFocusedWindowObserver() {
        if let observer = axObserver {
            if let appElement = axObservedApp {
                AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        axObservedApp = nil
        axObservedPID = 0
    }

    private static func userIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }
}
