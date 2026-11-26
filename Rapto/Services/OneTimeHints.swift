//
//  OneTimeHints.swift
//  Rapto
//
//  Contextual tips shown up to 10 times per Mac (`shownHintCounts` in UserDefaults) right when the
//  user triggers a mechanic, without artificial post-action delays.
//  Turned off anytime via `showsHints` or reset by "Show Hints Again" in Settings → Guide.
//

import AppKit
import Foundation

/// Permanent UserDefaults identifiers for contextual tips.
/// Never rename raw values after release.
nonisolated enum HintID: String, CaseIterable, Hashable, Sendable {
    case manualNeedsLayout = "manualNeedsLayout"
    case snapBack = "snapBack"
    case groupBadge = "groupBadge"
    case focusMode = "focusMode"
    case notchDesktopsBar = "notchDesktopsBar"

    /// Maximum displays before this hint retires automatically.
    var maxDisplays: Int {
        switch self {
        case .notchDesktopsBar: return 2
        default: return OneTimeHintScheduler.maxDisplays
        }
    }
}

/// Pure scheduling state machine for unit testing contextual tips without real timers or windows.
nonisolated final class OneTimeHintScheduler {
    static let countsDefaultsKey = "shownHintCounts"
    static let legacyDefaultsKey = "shownHints"
    static let maxDisplays = 10
    /// Guards against two hints firing from a single composite action (such as entering Manual mode
    /// while also auto-grouping existing windows within the same half-second).
    static let simultaneousGuardWindow: TimeInterval = 0.5
    /// Keeps consecutive `updateIndicators()` passes from double-counting the same group event.
    static let groupBadgeRepeatGap: TimeInterval = 3.0

    enum Decision: Equatable {
        case showNow(count: Int)
        case alreadyVisible
        case simultaneousSkipped
        case cooldownSkipped
        case suppressed
        case exhausted
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let overrideMaxDisplayCount: Int?
    private let simultaneousWindow: TimeInterval
    private let groupBadgeGap: TimeInterval

    private(set) var currentlyShowing: HintID?
    private var currentShowStartedAt: Date?
    private var lastShownAtByID: [HintID: Date] = [:]

    init(
        defaults: UserDefaults = .standard,
        maxDisplayCount: Int? = nil,
        simultaneousWindow: TimeInterval = OneTimeHintScheduler.simultaneousGuardWindow,
        groupBadgeGap: TimeInterval = OneTimeHintScheduler.groupBadgeRepeatGap,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.overrideMaxDisplayCount = maxDisplayCount
        self.simultaneousWindow = simultaneousWindow
        self.groupBadgeGap = groupBadgeGap
        self.now = now
    }

    func maxDisplayCount(for id: HintID) -> Int {
        overrideMaxDisplayCount ?? id.maxDisplays
    }

    func displayCount(for id: HintID) -> Int {
        if let raw = defaults.dictionary(forKey: Self.countsDefaultsKey),
           let number = (raw[id.rawValue] as? NSNumber)?.intValue {
            return max(0, number)
        }
        if Set(defaults.stringArray(forKey: Self.legacyDefaultsKey) ?? []).contains(id.rawValue) {
            return 1
        }
        return 0
    }

    func isExhausted(_ id: HintID) -> Bool {
        displayCount(for: id) >= maxDisplayCount(for: id)
    }

    /// Retires a hint early once the user completes the interaction it teaches (e.g., hovering the notch).
    func markCompleted(_ id: HintID) {
        let limit = maxDisplayCount(for: id)
        var counts: [String: Int] = [:]
        if let existing = defaults.dictionary(forKey: Self.countsDefaultsKey) {
            for (key, value) in existing {
                if let n = (value as? NSNumber)?.intValue {
                    counts[key] = n
                }
            }
        }
        counts[id.rawValue] = max(counts[id.rawValue] ?? 0, limit)
        defaults.set(counts, forKey: Self.countsDefaultsKey)
        if currentlyShowing == id {
            didHideCurrentHint()
        }
    }

    /// Shows immediately on every distinct user action (replacing any older visible tip), while
    /// skipping simultaneous side-effect triggers without burning a display count.
    func request(_ id: HintID, showsHints: Bool) -> Decision {
        guard showsHints else { return .suppressed }
        if currentlyShowing == id {
            return .alreadyVisible
        }
        let currentCount = displayCount(for: id)
        guard currentCount < maxDisplayCount(for: id) else { return .exhausted }

        let currentTime = now()

        if currentlyShowing != nil, let started = currentShowStartedAt,
           currentTime.timeIntervalSince(started) < simultaneousWindow {
            return .simultaneousSkipped
        }

        if id == .groupBadge,
           let previousBadgeAt = lastShownAtByID[.groupBadge],
           currentTime.timeIntervalSince(previousBadgeAt) < groupBadgeGap {
            return .cooldownSkipped
        }

        let updatedCount = recordDisplay(of: id, previousCount: currentCount, at: currentTime)
        return .showNow(count: updatedCount)
    }

    func didHideCurrentHint() {
        currentlyShowing = nil
        currentShowStartedAt = nil
    }

    func resetState() {
        currentlyShowing = nil
        currentShowStartedAt = nil
        lastShownAtByID.removeAll()
    }

    private func recordDisplay(of id: HintID, previousCount: Int, at date: Date) -> Int {
        var counts: [String: Int] = [:]
        if let existing = defaults.dictionary(forKey: Self.countsDefaultsKey) {
            for (key, value) in existing {
                if let n = (value as? NSNumber)?.intValue {
                    counts[key] = n
                }
            }
        }
        let updated = previousCount + 1
        counts[id.rawValue] = updated
        defaults.set(counts, forKey: Self.countsDefaultsKey)
        currentlyShowing = id
        currentShowStartedAt = date
        lastShownAtByID[id] = date
        return updated
    }
}

// MARK: - Live Hint Card Builders

enum OneTimeHintCopy {

    nonisolated static func manualNeedsLayout(overlayShortcut: String?) -> HintCardContent {
        let detail: String
        if let overlayShortcut, !overlayShortcut.isEmpty {
            detail = "Right-click this desktop → Layout, or press \(overlayShortcut)"
        } else {
            detail = "Right-click this desktop in the bar → Layout"
        }
        return HintCardContent(
            icon: "rectangle.3.group",
            title: "Choose a Layout",
            detail: detail
        )
    }

    nonisolated static let snapBack = HintCardContent(
        icon: "square.grid.2x2.fill",
        title: "Windows Stay in Slots",
        detail: "Drop onto another window or empty slot to move"
    )

    nonisolated static let autoTilingSnapBack = HintCardContent(
        icon: "wand.and.stars",
        title: "Auto-tiling Keeps Windows in Place",
        detail: "Drag onto another window to swap, or pause Rapto from the menu bar"
    )

    nonisolated static let notchDesktopsBar = HintCardContent(
        icon: "menubar.rectangle",
        title: "Desktops Bar Is Up Here",
        detail: "Move your pointer to the notch to show desktops and apps",
        showsUpwardPointer: true
    )

    nonisolated static func groupBadge(enableScroll: Bool, cycleShortcut: String?) -> HintCardContent {
        let detail: String
        switch (enableScroll, cycleShortcut) {
        case (true, let shortcut?) where !shortcut.isEmpty:
            detail = "Scroll the badge or press \(shortcut) to switch"
        case (false, let shortcut?) where !shortcut.isEmpty:
            detail = "Click an icon in the badge or press \(shortcut) to switch"
        case (true, _):
            detail = "Scroll or click the badge to switch windows"
        case (false, _):
            detail = "Click an icon in the badge to switch windows"
        }
        return HintCardContent(
            icon: "rectangle.stack.fill",
            title: "Window Group",
            detail: detail
        )
    }

    nonisolated static func focusMode(
        doubleTapEnabled: Bool,
        modifierSymbol: String,
        shortcut: String?
    ) -> HintCardContent {
        let validShortcut = (shortcut?.isEmpty == false) ? shortcut : nil
        let detail: String
        switch (doubleTapEnabled, validShortcut) {
        case (true, let hk?):
            detail = "\(modifierSymbol) double-click or press \(hk) to restore"
        case (false, let hk?):
            detail = "Press \(hk) to restore"
        case (true, nil):
            detail = "\(modifierSymbol) double-click to restore"
        case (false, nil):
            detail = "Restore from Settings → Behavior"
        }
        return HintCardContent(
            icon: "arrow.down.right.and.arrow.up.left",
            title: "Focus Mode",
            detail: detail
        )
    }

    nonisolated static func spaceBarDrag(
        targetDesktopNumber: Int?,
        movesFollowWindow: Bool,
        optionPressed: Bool,
        learnedKeys: Set<HintKeyID>
    ) -> HintCardContent {
        let icon = targetDesktopNumber == nil ? "plus.rectangle.on.rectangle" : "arrow.right.square.fill"
        let title = targetDesktopNumber.map { "Move to Desktop \($0)" } ?? "Move to New Desktop"

        if optionPressed {
            let detail = movesFollowWindow ? "Staying on this desktop · ⌥" : "Going there too · ⌥"
            return HintCardContent(icon: icon, title: title, detail: detail)
        }
        guard !learnedKeys.contains(.spaceBarOptionKey) else {
            return HintCardContent(icon: icon, title: title, detail: nil)
        }
        let detail = movesFollowWindow ? "Hold ⌥ to stay here" : "Hold ⌥ to go there too"
        return HintCardContent(icon: icon, title: title, detail: detail)
    }
}

// MARK: - Main-Actor Coordinator

@MainActor
final class OneTimeHints {

    private weak var appState: AppState?
    private let panel = SpaceBarHint()
    private let scheduler = OneTimeHintScheduler()
    private var resetObserver: NSObjectProtocol?

    init(appState: AppState) {
        self.appState = appState
        self.resetObserver = NotificationCenter.default.addObserver(
            forName: .raptoHintsDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reset()
            }
        }
    }

    deinit {
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    func reset() {
        panel.hide()
        scheduler.resetState()
    }

    func hideIfShowing(_ id: HintID) {
        guard scheduler.currentlyShowing == id else { return }
        panel.hide()
    }

    /// Marks `id` learned and hides it immediately if currently visible.
    func markCompleted(_ id: HintID) {
        let wasShowing = scheduler.currentlyShowing == id
        scheduler.markCompleted(id)
        if wasShowing {
            panel.hide()
        }
    }

    /// Shows `id` immediately up to its limit on `screen` when `stillValid()` holds.
    func showOnce(
        _ id: HintID,
        content: @escaping () -> HintCardContent,
        placement: @escaping () -> (SpaceBarHint.Placement, NSScreen)?,
        stillValid: @escaping () -> Bool,
        autoHideAfter: TimeInterval = 6
    ) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let appState else {
            return
        }
        guard stillValid() else { return }

        switch scheduler.request(id, showsHints: appState.showsHints) {
        case .suppressed, .exhausted, .alreadyVisible, .simultaneousSkipped, .cooldownSkipped:
            return

        case .showNow:
            guard let (resolvedPlacement, screen) = placement() else {
                scheduler.didHideCurrentHint()
                return
            }
            let look = appState.spaceBarController.lookForHint(on: screen)
            panel.show(
                content(),
                placement: resolvedPlacement,
                on: screen,
                look: look,
                autoHideAfter: autoHideAfter,
                onHidden: { [weak self] in
                    self?.scheduler.didHideCurrentHint()
                }
            )
        }
    }
}
