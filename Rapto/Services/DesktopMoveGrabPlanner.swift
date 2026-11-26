//
//  DesktopMoveGrabPlanner.swift
//  Rapto
//
//  Pure geometry, Accessibility classification and per-app anchor memory for
//  finding a draggable title-bar spot when moving a window to another desktop.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// Outcome of a short, non-banning Accessibility window lookup at the start of a desktop move.
nonisolated enum DesktopMoveAXProbeOutcome: Equatable, Sendable {
    /// Accessibility returned the matching window element.
    case ready
    /// Accessibility timed out; the app is likely waking from App Nap (e.g. a Mac Catalyst scene wake).
    case waking
    /// Accessibility answered without a matching window (or the app is confirmed unresponsive).
    case unavailable
}

/// How a title-bar spot that successfully dragged an app's window is remembered
/// relative to the window frame so it keeps working after resizes and moves.
nonisolated enum DesktopMoveGrabAnchor: Equatable, Sendable {
    /// Offset from the rightmost window button (`maxX`, `midY`).
    case fromButtons(dx: CGFloat, dy: CGFloat)
    /// Offset from the window's top-left corner (`minX`, `minY`).
    case fromLeft(dx: CGFloat, dy: CGFloat)
    /// Offset from the window's top-right corner (`maxX`, `minY`); `dx` is negative.
    case fromRight(dx: CGFloat, dy: CGFloat)
    /// Proportional horizontal position across the window width (`0...1`) and vertical offset from `minY`.
    case proportional(xFraction: CGFloat, dy: CGFloat)

    /// Captures a proven grab spot as a relative anchor for reuse on future moves of the same app.
    static func record(point: CGPoint, in frame: CGRect, buttonFrame: CGRect?) -> DesktopMoveGrabAnchor {
        if let buttonFrame,
           point.x >= buttonFrame.maxX - 4,
           point.x - buttonFrame.maxX <= 160,
           abs(point.y - buttonFrame.midY) <= 18 {
            return .fromButtons(dx: point.x - buttonFrame.maxX, dy: point.y - buttonFrame.midY)
        }
        if frame.maxX - point.x <= 180 {
            return .fromRight(dx: point.x - frame.maxX, dy: point.y - frame.minY)
        }
        if point.x - frame.minX <= 180 {
            return .fromLeft(dx: point.x - frame.minX, dy: point.y - frame.minY)
        }
        let fraction = frame.width > 0
            ? min(max((point.x - frame.minX) / frame.width, 0.05), 0.95)
            : 0.5
        return .proportional(xFraction: fraction, dy: point.y - frame.minY)
    }

    /// Resolves this anchor against the window's current frame and traffic-light button frame.
    /// Returns `nil` when the resolved point would fall outside the title-bar strip or onto the traffic lights.
    func resolve(in frame: CGRect, buttonFrame: CGRect?) -> CGPoint? {
        guard frame.width >= 40, frame.height >= 24 else { return nil }
        let point: CGPoint
        switch self {
        case .fromButtons(let dx, let dy):
            guard let buttonFrame else { return nil }
            point = CGPoint(x: buttonFrame.maxX + dx, y: buttonFrame.midY + dy)
        case .fromLeft(let dx, let dy):
            point = CGPoint(x: frame.minX + dx, y: frame.minY + dy)
        case .fromRight(let dx, let dy):
            point = CGPoint(x: frame.maxX + dx, y: frame.minY + dy)
        case .proportional(let xFraction, let dy):
            point = CGPoint(x: frame.minX + frame.width * xFraction, y: frame.minY + dy)
        }

        let maxTitleBarY = min(frame.maxY - 2, frame.minY + DesktopMoveGrabPlanner.maxTitleBarHeight)
        guard point.x >= frame.minX + 4,
              point.x <= frame.maxX - 4,
              point.y >= frame.minY + 2,
              point.y <= maxTitleBarY else {
            return nil
        }
        if let buttonFrame,
           point.y >= buttonFrame.minY - 2,
           point.y <= buttonFrame.maxY + 2,
           point.x <= buttonFrame.maxX + 2 {
            return nil
        }
        return point
    }
}

/// Session memory of proven title-bar grab anchors keyed by app identifier.
nonisolated struct DesktopMoveGrabMemory: Sendable {
    private var anchors: [String: DesktopMoveGrabAnchor] = [:]
    /// Frame-relative backup recorded alongside button-relative anchors so a cached spot still
    /// resolves when an App-Napped app hasn't reported traffic-light buttons via Accessibility yet.
    private var frameFallbacks: [String: DesktopMoveGrabAnchor] = [:]

    mutating func remember(point: CGPoint, in frame: CGRect, buttonFrame: CGRect?, for appKey: String) {
        guard !appKey.isEmpty else { return }
        anchors[appKey] = DesktopMoveGrabAnchor.record(point: point, in: frame, buttonFrame: buttonFrame)
        frameFallbacks[appKey] = DesktopMoveGrabAnchor.record(point: point, in: frame, buttonFrame: nil)
    }

    func resolve(for appKey: String, in frame: CGRect, buttonFrame: CGRect?) -> CGPoint? {
        if let point = anchors[appKey]?.resolve(in: frame, buttonFrame: buttonFrame) {
            return point
        }
        if buttonFrame == nil {
            return frameFallbacks[appKey]?.resolve(in: frame, buttonFrame: nil)
        }
        return nil
    }

    mutating func invalidate(for appKey: String) {
        anchors.removeValue(forKey: appKey)
        frameFallbacks.removeValue(forKey: appKey)
    }

    func anchor(for appKey: String) -> DesktopMoveGrabAnchor? {
        anchors[appKey]
    }
}

/// Priority tier of an Accessibility hit chain at a candidate title-bar point.
nonisolated enum GrabHitTier: Int, Comparable, Sendable {
    /// Native window or toolbar chrome (or window title text) outside any control or web view.
    case chrome = 0
    /// Web-drawn or container chrome (AXWebArea, AXGroup, AXSplitGroup, AXUnknown) outside controls.
    case webOrContainer = 1
    /// Other non-control container (e.g. AXScrollArea, AXImage); tried only if higher tiers fail.
    case fallback = 2
    /// Interactive control (or descendant of one); must never be pressed.
    case control = 3

    static func < (lhs: GrabHitTier, rhs: GrabHitTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Pure planning, obstacle-gap computation and movement verification helpers for desktop moves.
nonisolated enum DesktopMoveGrabPlanner {
    /// Maximum vertical depth below `frame.minY` considered part of a window's title-bar / toolbar band.
    static let maxTitleBarHeight: CGFloat = 64

    /// Roles that represent interactive controls (clicking presses them; dragging tears off tabs or edits text).
    static let controlRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXTabGroup", "AXTab", "AXTextField", "AXTextArea",
        "AXSearchField", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXComboBox",
        "AXSlider", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle",
        "AXColorWell", "AXIncrementor", "AXSegmentedControl", "AXPopover", "AXSheet"
    ]

    /// Subroles that identify interactive controls even when their primary role is generic.
    static let controlSubroles: Set<String> = [
        "AXTabButton", "AXCloseButton", "AXMinimizeButton", "AXZoomButton",
        "AXFullScreenButton", "AXToolbarButton", "AXSearchField", "AXSegmentedControl",
        "AXTextLink"
    ]

    /// Native chrome roles that typically drag the window immediately when outside controls and web views.
    static let nativeChromeRoles: Set<String> = [
        "AXWindow", "AXToolbar", "AXStaticText"
    ]

    /// Container or web-drawn roles that may drag the window depending on the app (probed before trusting).
    static let containerChromeRoles: Set<String> = [
        "AXWebArea", "AXGroup", "AXSplitGroup", "AXUnknown"
    ]

    /// Classifies an Accessibility ancestor chain (from hit leaf up toward `AXWindow`) into a grab tier.
    /// Any control role or subrole anywhere along the chain rejects the spot as `.control`.
    static func classifyHitChain(_ chain: [(role: String, subrole: String?)]) -> GrabHitTier {
        guard let leaf = chain.first else { return .control }
        var hasWebArea = false
        var insideToolbar = false

        for node in chain {
            if node.role == "AXWindow" { break }
            if controlRoles.contains(node.role) { return .control }
            if let subrole = node.subrole, controlSubroles.contains(subrole) { return .control }
            if node.role == "AXWebArea" { hasWebArea = true }
            if node.role == "AXToolbar" { insideToolbar = true }
        }

        if hasWebArea {
            return .webOrContainer
        }
        if nativeChromeRoles.contains(leaf.role) {
            return .chrome
        }
        if insideToolbar && containerChromeRoles.contains(leaf.role) {
            return .chrome
        }
        if containerChromeRoles.contains(leaf.role) {
            return .webOrContainer
        }
        return .fallback
    }

    /// Computes horizontal midpoints of empty gaps between interactive controls on `rowY`, widest gap first.
    static func emptyGapMidpoints(
        in frame: CGRect,
        rowY: CGFloat,
        obstacles: [CGRect],
        minGapWidth: CGFloat = 18,
        obstaclePadding: CGFloat = 6,
        edgeMargin: CGFloat = 12
    ) -> [CGPoint] {
        let usableMinX = frame.minX + edgeMargin
        let usableMaxX = frame.maxX - edgeMargin
        guard usableMaxX - usableMinX >= minGapWidth else { return [] }

        let rowBandMinY = rowY - 7
        let rowBandMaxY = rowY + 7

        var blocked: [(CGFloat, CGFloat)] = []
        for rect in obstacles {
            guard rect.width > 0, rect.height > 0 else { continue }
            guard rect.maxY >= rowBandMinY && rect.minY <= rowBandMaxY else { continue }
            let start = max(usableMinX, rect.minX - obstaclePadding)
            let end = min(usableMaxX, rect.maxX + obstaclePadding)
            if end > start {
                blocked.append((start, end))
            }
        }

        blocked.sort { $0.0 < $1.0 }
        var merged: [(CGFloat, CGFloat)] = []
        for interval in blocked {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }

        var gaps: [(start: CGFloat, end: CGFloat)] = []
        var cursor = usableMinX
        for interval in merged {
            if interval.0 - cursor >= minGapWidth {
                gaps.append((cursor, interval.0))
            }
            cursor = max(cursor, interval.1)
        }
        if usableMaxX - cursor >= minGapWidth {
            gaps.append((cursor, usableMaxX))
        }

        return gaps
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            .map { CGPoint(x: ($0.start + $0.end) / 2, y: rowY) }
    }

    /// Horizontal title-bar rows to inspect, ordered by likelihood:
    /// 1) level with the traffic lights (or standard title-bar height when buttonless),
    /// 2) top hairline drag strip right above tabs,
    /// 3) lower unified-toolbar row on taller windows.
    static func titleBarRows(for frame: CGRect, buttonFrame: CGRect?) -> [CGFloat] {
        guard frame.height >= 16 else { return [] }
        let minY = frame.minY + 4
        let maxY = min(frame.maxY - 4, frame.minY + maxTitleBarHeight)
        guard maxY >= minY else { return [frame.midY] }

        var raw: [CGFloat] = []
        if let buttonFrame {
            raw.append(min(max(buttonFrame.midY, minY), maxY))
        } else {
            raw.append(min(max(frame.minY + min(16, frame.height * 0.2), minY), maxY))
        }
        raw.append(min(max(frame.minY + 5, minY), maxY))
        if frame.height >= 180 {
            let lowerY = frame.minY + 34
            if lowerY <= maxY && lowerY <= frame.maxY - 20 {
                raw.append(lowerY)
            }
        }

        var unique: [CGFloat] = []
        for y in raw where !unique.contains(where: { abs($0 - y) < 8 }) {
            unique.append(y)
        }
        return unique
    }

    /// Width-adaptive X coordinates along a title-bar row, covering narrow windows and ultrawides evenly.
    static func adaptiveXs(in frame: CGRect, buttonsMaxX: CGFloat?) -> [CGFloat] {
        let minX = (buttonsMaxX.map { $0 + 4 }) ?? (frame.minX + 12)
        let maxX = frame.maxX - 4
        guard maxX > minX else { return [] }

        var raw: [CGFloat] = []
        if let buttonsMaxX {
            raw.append(contentsOf: SpaceBarController.guessedGrabXs(
                buttonsMaxX: buttonsMaxX,
                frameMinX: frame.minX,
                frameMaxX: frame.maxX
            ))
        } else {
            raw.append(contentsOf: [
                frame.midX,
                frame.minX + 90,
                frame.maxX - 60,
                frame.minX + 24,
                frame.maxX - 150
            ])
        }

        let span = maxX - minX
        for fraction in [0.50, 0.78, 0.22, 0.90, 0.12, 0.64, 0.36, 0.96] as [CGFloat] {
            raw.append(minX + span * fraction)
        }

        var result: [CGFloat] = []
        for x in raw where x > minX && x < maxX {
            if !result.contains(where: { abs($0 - x) < 24 }) {
                result.append(x)
            }
        }
        return result
    }

    /// Three sample points along a window's top strip used to verify the window is raised and unobstructed.
    static func raiseCheckPoints(for frame: CGRect) -> [CGPoint] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        let y = frame.minY + min(10, frame.height / 2)
        let inset = min(40, frame.width * 0.2)
        let xs = [frame.midX, frame.minX + inset, frame.maxX - inset]
        var points: [CGPoint] = []
        for x in xs where x >= frame.minX && x <= frame.maxX {
            if !points.contains(where: { abs($0.x - x) < 12 }) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// Computes a probe drag target that moves downward (away from the menu bar) and inward
    /// horizontally so spots near the right edge of a display are not clamped by the screen border.
    static func probeDragTarget(from point: CGPoint, windowFrame: CGRect, offset: CGFloat) -> CGPoint {
        let dx: CGFloat = point.x > windowFrame.midX ? -offset : offset
        return CGPoint(x: point.x + dx, y: point.y + offset)
    }

    /// Whether a probe drag actually moved the window according to either Accessibility or Core Graphics.
    /// Uses a capped threshold (`min(dragOffset / 2, 4)`) so apps with an 8–10 pt drag threshold still pass
    /// on a 14 pt drag while 1–2 pt rounding jitter is ignored.
    static func didWindowFollow(
        beforeAX: CGPoint?,
        nowAX: CGPoint?,
        beforeCG: CGPoint?,
        nowCG: CGPoint?,
        dragOffset: CGFloat
    ) -> Bool {
        let threshold = min(dragOffset / 2, 4.0)
        if let beforeAX, let nowAX {
            if max(abs(nowAX.x - beforeAX.x), abs(nowAX.y - beforeAX.y)) >= threshold {
                return true
            }
        }
        if let beforeCG, let nowCG {
            if max(abs(nowCG.x - beforeCG.x), abs(nowCG.y - beforeCG.y)) >= threshold {
                return true
            }
        }
        return false
    }

    /// Orders classified probe candidates by tier first (chrome → web/container → fallback),
    /// preserving relative order within each tier and dropping near-duplicates within 24 pt.
    static func prioritizeCandidates(
        _ candidates: [(point: CGPoint, tier: GrabHitTier)],
        excluding excluded: [CGPoint] = [],
        limit: Int? = nil
    ) -> [CGPoint] {
        let sorted = candidates
            .enumerated()
            .filter { $0.element.tier != .control }
            .sorted { lhs, rhs in
                if lhs.element.tier != rhs.element.tier {
                    return lhs.element.tier < rhs.element.tier
                }
                return lhs.offset < rhs.offset
            }

        var result: [CGPoint] = []
        for item in sorted {
            let point = item.element.point
            if excluded.contains(where: { abs($0.x - point.x) < 24 && abs($0.y - point.y) < 24 }) {
                continue
            }
            if result.contains(where: { abs($0.x - point.x) < 24 && abs($0.y - point.y) < 24 }) {
                continue
            }
            result.append(point)
            if let limit, result.count >= limit {
                break
            }
        }
        return result
    }

    /// System processes whose overlay windows (e.g. Dock's full-screen layer-20 container or Window
    /// Server's menu bar) span the screen transparently and must not be treated as covering app title bars.
    static let systemOverlayOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "TextInputMenuAgent",
        "universalaccessd", "loginwindow", "WindowManager",
        "CursorUIViewService", "AirBuddyHelper"
    ]

    /// Whether a Core Graphics window entry represents a real clickable app window that can block
    /// mouse events to a title bar underneath it.
    /// Excludes desktop/wallpaper layers (`< 0`), system layers (`>= 20`, including Dock's full-screen
    /// `layer=20` container, menu bar `24`, status bar `25`, Window Server), Rapto's own windows and
    /// invisible windows, while keeping normal (`0`) and floating app windows (e.g. PiP at `3`).
    static func isBlockingWindow(layer: Int, owner: String, alpha: Double, pid: pid_t, ownPID: pid_t) -> Bool {
        guard pid != ownPID, alpha > 0 else { return false }
        guard layer >= 0 && layer < 20 else { return false }
        guard !systemOverlayOwners.contains(owner) else { return false }
        return true
    }

    /// Safe title-bar drag candidates computed purely from Core Graphics geometry when an app
    /// waking from App Nap has not answered Accessibility yet. Keeps clear of the standard macOS
    /// traffic-light area (`minX ..< minX + 82`) on the primary row and puts any cached point first.
    static func cgFallbackSpots(
        in frame: CGRect,
        cachedPoint: CGPoint? = nil,
        excluding: [CGPoint] = [],
        limit: Int = 8
    ) -> [CGPoint] {
        guard frame.width >= 40, frame.height >= 24, limit > 0 else { return [] }

        var raw: [CGPoint] = []
        if let cachedPoint, frame.contains(cachedPoint) {
            raw.append(cachedPoint)
        }

        let rows = titleBarRows(for: frame, buttonFrame: nil)
        // Standard traffic lights occupy roughly minX + 12 ... minX + 76; keep clear when wide enough.
        let safeButtonsMaxX: CGFloat? = frame.width >= 200 ? (frame.minX + 82) : nil

        for (rowIndex, rowY) in rows.enumerated() {
            if rowIndex == 0 {
                let primaryMinX = (safeButtonsMaxX.map { $0 + 4 }) ?? (frame.minX + 12)
                let seededXs: [CGFloat] = [
                    frame.midX,
                    frame.minX + 110,
                    frame.minX + 190,
                    frame.maxX - 110,
                    frame.maxX - 190
                ]
                for x in seededXs where x >= primaryMinX && x <= frame.maxX - 4 {
                    raw.append(CGPoint(x: x, y: rowY))
                }
                for x in adaptiveXs(in: frame, buttonsMaxX: safeButtonsMaxX) {
                    raw.append(CGPoint(x: x, y: rowY))
                }
            } else {
                for x in adaptiveXs(in: frame, buttonsMaxX: safeButtonsMaxX).prefix(4) {
                    raw.append(CGPoint(x: x, y: rowY))
                }
            }
        }

        var result: [CGPoint] = []
        for point in raw where frame.contains(point) {
            if excluding.contains(where: { abs($0.x - point.x) < 24 && abs($0.y - point.y) < 24 }) {
                continue
            }
            if result.contains(where: { abs($0.x - point.x) < 24 && abs($0.y - point.y) < 24 }) {
                continue
            }
            result.append(point)
            if result.count >= limit { break }
        }
        return result
    }

    /// Safe release point outside `windowFrame` that stays clear of display borders when `screenBounds` is known.
    static func releasePoint(for point: CGPoint, windowFrame: CGRect, screenBounds: CGRect?) -> CGPoint {
        let edgeMargin: CGFloat = 8
        let minYLimit = (screenBounds?.minY ?? 0) + edgeMargin
        if windowFrame.minY - 4 >= minYLimit {
            return CGPoint(x: point.x, y: windowFrame.minY - 4)
        }
        let minXLimit = (screenBounds?.minX ?? 0) + edgeMargin
        if windowFrame.minX - 4 >= minXLimit {
            return CGPoint(x: windowFrame.minX - 4, y: point.y)
        }
        if let screenBounds {
            if windowFrame.maxX + 4 <= screenBounds.maxX - edgeMargin {
                return CGPoint(x: windowFrame.maxX + 4, y: point.y)
            }
            if windowFrame.maxY + 4 <= screenBounds.maxY - edgeMargin {
                return CGPoint(x: point.x, y: windowFrame.maxY + 4)
            }
        }
        return point
    }

    // MARK: - App Nap / Catalyst Wake Coordination

    /// Standard wait for an already-awake window to rise above its neighbors before grabbing.
    static let normalRaiseDeadline: TimeInterval = 1.0
    /// Extended wait when the initial AX probe timed out (e.g. a Mac Catalyst app finishing its
    /// background-to-foreground scene wake before raising its window and accepting drags).
    static let wakingRaiseDeadline: TimeInterval = 3.0
    /// Elapsed times (seconds since `beginMove`) at which to re-nudge activation while still behind.
    static let raiseNudgeIntervals: [TimeInterval] = [0.25, 0.8, 1.5, 2.2]

    /// Distinguishes an app that timed out waking from App Nap from an awake app that simply
    /// returned no matching AX window.
    static func classifyQuickAXProbe(
        error: AXError,
        waited: TimeInterval,
        timeout: TimeInterval,
        foundWindow: Bool
    ) -> DesktopMoveAXProbeOutcome {
        if error == .success && foundWindow {
            return .ready
        }
        if error == .cannotComplete && waited >= timeout * 0.8 {
            return .waking
        }
        return .unavailable
    }

    static func raiseDeadlineDuration(axOutcome: DesktopMoveAXProbeOutcome) -> TimeInterval {
        axOutcome == .waking ? wakingRaiseDeadline : normalRaiseDeadline
    }

    /// Next re-nudge index due at `elapsed`, or `nil` when no nudge should fire yet.
    static func nextRaiseNudgeIndex(elapsed: TimeInterval, completedNudges: Int) -> Int? {
        guard completedNudges < raiseNudgeIntervals.count,
              elapsed >= raiseNudgeIntervals[completedNudges] else { return nil }
        return completedNudges
    }

    /// Whether `grabWhenRaised` should keep polling before grabbing.
    /// Awake apps grab immediately once on top; apps whose initial AX probe timed out wait
    /// (without blocking the main thread) until they answer or the wake deadline passes.
    static func shouldWaitBeforeGrab(
        isOnTop: Bool,
        waitingForWake: Bool,
        beforeDeadline: Bool
    ) -> Bool {
        guard beforeDeadline else { return false }
        return !isOnTop || waitingForWake
    }
}
