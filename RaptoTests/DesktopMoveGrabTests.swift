//
//  DesktopMoveGrabTests.swift
//  RaptoTests
//
//  Where the Desktops Bar takes hold of a window to move it to another desktop.
//

import CoreGraphics
import Testing
@testable import Rapto

struct DesktopMoveGrabTests {

    @Test func guessedSpotsKeepTheOldOrderFirst() {
        let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: 73, frameMinX: 0, frameMaxX: 1400)
        #expect(Array(xs.prefix(5)) == [700, 193, 273, 1250, 1340])
    }

    @Test func guessedSpotsStayBetweenTheButtonsAndTheRightEdge() {
        let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: 1293, frameMinX: 1220, frameMaxX: 2620)
        #expect(!xs.isEmpty)
        #expect(xs.allSatisfy { $0 > 1293 + 4 && $0 < 2620 - 4 })
    }

    @Test func guessedSpotsAreSpreadApart() {
        let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: 73, frameMinX: 0, frameMaxX: 1400)
        for (index, x) in xs.enumerated() {
            for other in xs[(index + 1)...] {
                #expect(abs(x - other) >= 24)
            }
        }
    }

    @Test func narrowWindowGivesFewerSpotsButNoneOutside() {
        // 300 pt wide: most spots fall on each other or outside
        let xs = SpaceBarController.guessedGrabXs(buttonsMaxX: 173, frameMinX: 100, frameMaxX: 400)
        #expect(xs.allSatisfy { $0 > 177 && $0 < 396 })
        #expect(Set(xs).count == xs.count)
    }

    @Test func windowThatCameAlongCountsAsFollowed() {
        let start = CGPoint(x: 100, y: 200)
        #expect(SpaceBarController.windowFollowed(from: start, to: CGPoint(x: 105, y: 205), dragOffset: 5))
        // Some windows move along one axis only at first
        #expect(SpaceBarController.windowFollowed(from: start, to: CGPoint(x: 100, y: 204), dragOffset: 5))
    }

    @Test func windowThatStayedDoesNotCountAsFollowed() {
        let start = CGPoint(x: 100, y: 200)
        #expect(!SpaceBarController.windowFollowed(from: start, to: start, dragOffset: 5))
        // Rounding of a frame that did not move
        #expect(!SpaceBarController.windowFollowed(from: start, to: CGPoint(x: 101, y: 200), dragOffset: 5))
    }

    @Test func smallShiftAfterAMoveIsUndone() {
        let origin = CGPoint(x: 1374, y: 34)
        #expect(SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 1379, y: 39)))
        #expect(SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 1374, y: 30)))
    }

    @Test func windowInItsPlaceOrPlacedElsewhereIsLeftAlone() {
        let origin = CGPoint(x: 1374, y: 34)
        #expect(!SpaceBarController.isProbeShift(from: origin, to: origin))
        // Put into a slot on the new desktop
        #expect(!SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 8, y: 34)))
        #expect(!SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 1374, y: 800)))
        #expect(!SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 1394, y: 34)))
    }

    @Test func spotUnderAnotherWindowIsNotUsed() {
        let app: pid_t = 100
        let indicator: pid_t = 200
        let windows: [(pid: pid_t, frame: CGRect)] = [
            (indicator, CGRect(x: 3700, y: 60, width: 120, height: 30)),
            (app, CGRect(x: 1374, y: 34, width: 2461, height: 1544))
        ]
        #expect(!SpaceBarController.windowIsOnTop(pid: app, at: CGPoint(x: 3775, y: 72), among: windows))
        #expect(SpaceBarController.windowIsOnTop(pid: app, at: CGPoint(x: 1571, y: 72), among: windows))
        #expect(!SpaceBarController.windowIsOnTop(pid: app, at: CGPoint(x: 10, y: 10), among: windows))
    }

    @Test func failedSpotIsReleasedJustAboveTheWindow() {
        let frame = CGRect(x: 1374, y: 34, width: 2461, height: 1544)
        #expect(SpaceBarController.releasePoint(for: CGPoint(x: 1571, y: 72), windowFrame: frame) == CGPoint(x: 1571, y: 30))
    }

    @Test func failedSpotIsNotReleasedAtAScreenEdge() {
        // A window at the very top of a display without a menu bar
        let top = CGRect(x: 400, y: 0, width: 800, height: 600)
        #expect(SpaceBarController.releasePoint(for: CGPoint(x: 600, y: 14), windowFrame: top) == CGPoint(x: 396, y: 14))
        let corner = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(SpaceBarController.releasePoint(for: CGPoint(x: 600, y: 14), windowFrame: corner) == CGPoint(x: 600, y: 14))
    }

    @Test func controlsAreNeverGuessedAsTitleBar() {
        for role in ["AXButton", "AXTextField", "AXLink", "AXCheckBox", "AXPopUpButton", "AXTab"] {
            #expect(SpaceBarController.guessKind(forRole: role) == .control)
        }
    }

    @Test func pageComesBeforeContainers() {
        #expect(SpaceBarController.guessKind(forRole: "AXWebArea") == .page)
        // Hark answers "group" and Simplenote "split group" all along the title bar
        #expect(SpaceBarController.guessKind(forRole: "AXGroup") == .other)
        #expect(SpaceBarController.guessKind(forRole: "AXSplitGroup") == .other)
        #expect(SpaceBarController.guessKind(forRole: "AXStaticText") == .other)
    }

    @Test("A guessed first spot stays first and near duplicates of it are dropped")
    func probeOrderKeepsTheFirstSpotAndDropsItsNeighbours() {
        let first = CGPoint(x: 87, y: 51)
        let guesses = [CGPoint(x: 700, y: 51), CGPoint(x: 95, y: 51), CGPoint(x: 193, y: 51), CGPoint(x: 710, y: 51)]
        let order = SpaceBarController.probeOrder(first: first, then: guesses)
        #expect(order == [first, CGPoint(x: 700, y: 51), CGPoint(x: 193, y: 51)])
    }

    @Test("With nothing else to try the first spot is probed alone")
    func probeOrderWithoutGuesses() {
        #expect(SpaceBarController.probeOrder(first: CGPoint(x: 87, y: 51), then: []) == [CGPoint(x: 87, y: 51)])
    }

    @Test("After a spot failed, spots close to it are not tried again and the list is cut short")
    func fallbackOrderSkipsTheFailedSpotAndIsLimited() {
        let failed = CGPoint(x: 1920, y: 44)
        let candidates = [
            CGPoint(x: 88, y: 60), CGPoint(x: 1925, y: 50), CGPoint(x: 198, y: 60), CGPoint(x: 94, y: 44),
            CGPoint(x: 3776, y: 44), CGPoint(x: 278, y: 60), CGPoint(x: 3686, y: 44)
        ]
        let order = SpaceBarController.fallbackOrder(after: failed, candidates: candidates, limit: 3)
        #expect(order == [CGPoint(x: 88, y: 60), CGPoint(x: 198, y: 60), CGPoint(x: 3776, y: 44)])
    }

    @Test("With no other spot there is nothing to fall back on")
    func fallbackOrderWithoutCandidates() {
        #expect(SpaceBarController.fallbackOrder(after: CGPoint(x: 10, y: 10), candidates: [], limit: 5).isEmpty)
    }

    // MARK: - Structural empty-gap finder

    @Test("Empty gap finder picks the widest gap between tabs and right-side buttons first")
    func emptyGapMidpointsFindsWidestOpenStretch() {
        let frame = CGRect(x: 0, y: 34, width: 1400, height: 900)
        let rowY: CGFloat = 50
        let obstacles: [CGRect] = [
            CGRect(x: 12, y: 44, width: 60, height: 14),     // traffic lights
            CGRect(x: 80, y: 40, width: 620, height: 26),    // tabs
            CGRect(x: 706, y: 42, width: 26, height: 22),    // "+" new tab button
            CGRect(x: 1260, y: 42, width: 124, height: 24),  // profile / toolbar icons
            // Obstacle on another row far below should be ignored
            CGRect(x: 740, y: 90, width: 500, height: 30)
        ]

        let gaps = DesktopMoveGrabPlanner.emptyGapMidpoints(in: frame, rowY: rowY, obstacles: obstacles)
        #expect(!gaps.isEmpty)
        // Widest gap lies between x = 738 (732+6) and x = 1254 (1260-6), midpoint ~996
        let best = gaps[0]
        #expect(best.y == rowY)
        #expect(best.x > 950 && best.x < 1040)
    }

    @Test("Empty gap finder sorts multiple gaps widest first and skips tight gaps")
    func emptyGapMidpointsSortsWidestFirst() {
        let frame = CGRect(x: 100, y: 34, width: 1000, height: 700)
        let obstacles: [CGRect] = [
            CGRect(x: 100, y: 44, width: 200, height: 20),   // 100..300
            CGRect(x: 400, y: 44, width: 100, height: 20),   // 400..500 (gap ~88pt at 350)
            CGRect(x: 520, y: 44, width: 100, height: 20),   // 520..620 (tight 8pt gap -> skipped)
            CGRect(x: 1000, y: 44, width: 100, height: 20),  // 1000..1100 (wide ~368pt gap at 810)
        ]

        let gaps = DesktopMoveGrabPlanner.emptyGapMidpoints(in: frame, rowY: 54, obstacles: obstacles)
        #expect(gaps.count == 2)
        #expect(abs(gaps[0].x - 810) < 2)
        #expect(abs(gaps[1].x - 350) < 2)
    }

    @Test("Empty gap finder returns empty when controls fill the entire row")
    func emptyGapMidpointsWhenRowIsFull() {
        let frame = CGRect(x: 0, y: 34, width: 400, height: 600)
        let obstacles = [CGRect(x: 0, y: 40, width: 400, height: 24)]
        #expect(DesktopMoveGrabPlanner.emptyGapMidpoints(in: frame, rowY: 50, obstacles: obstacles).isEmpty)
    }

    // MARK: - Multi-row title bar & width-adaptive sweep

    @Test("Buttonless windows still produce multi-row title-bar scan bands")
    func titleBarRowsWorkWithoutTrafficLights() {
        let frame = CGRect(x: 0, y: 34, width: 1200, height: 800)
        let rows = DesktopMoveGrabPlanner.titleBarRows(for: frame, buttonFrame: nil)
        #expect(rows.count == 3)
        #expect(rows[0] == 50) // minY + 16
        #expect(rows[1] == 39) // minY + 5 hairline strip
        #expect(rows[2] == 68) // minY + 34 lower toolbar row
    }

    @Test("Compact windows skip the lower toolbar row and keep rows distinct")
    func titleBarRowsRespectWindowHeight() {
        let short = CGRect(x: 0, y: 34, width: 400, height: 120)
        let button = CGRect(x: 54, y: 42, width: 14, height: 14) // midY = 49
        let rows = DesktopMoveGrabPlanner.titleBarRows(for: short, buttonFrame: button)
        #expect(rows == [49, 39])
    }

    @Test("Adaptive X sweep covers an ultrawide window across its full width")
    func adaptiveXsCoversUltrawideEvenly() {
        let ultrawide = CGRect(x: 0, y: 34, width: 3840, height: 1580)
        let xs = DesktopMoveGrabPlanner.adaptiveXs(in: ultrawide, buttonsMaxX: 74)
        // Must have candidates in all four horizontal quarters
        #expect(xs.contains { $0 < 960 })
        #expect(xs.contains { $0 >= 960 && $0 < 1920 })
        #expect(xs.contains { $0 >= 1920 && $0 < 2880 })
        #expect(xs.contains { $0 >= 2880 })
        // Spread at least 24 pt apart
        for (i, x) in xs.enumerated() {
            for other in xs[(i + 1)...] {
                #expect(abs(x - other) >= 24)
            }
        }
    }

    @Test("Adaptive X sweep works for buttonless windows too")
    func adaptiveXsWorksWithoutButtons() {
        let frame = CGRect(x: 200, y: 34, width: 1000, height: 700)
        let xs = DesktopMoveGrabPlanner.adaptiveXs(in: frame, buttonsMaxX: nil)
        #expect(!xs.isEmpty)
        #expect(xs.allSatisfy { $0 > frame.minX + 12 && $0 < frame.maxX - 4 })
    }

    // MARK: - Ancestor-aware hit classification & tier ordering

    @Test("Group or text nested inside a button or tab is rejected as a control")
    func nestedControlAncestorsAreRejected() {
        // Real Phi pattern: AXGroup < AXButton < AXSplitGroup < AXWindow
        let phiButtonChild: [(String, String?)] = [
            ("AXGroup", nil), ("AXButton", nil), ("AXSplitGroup", nil), ("AXWindow", nil)
        ]
        #expect(DesktopMoveGrabPlanner.classifyHitChain(phiButtonChild) == .control)

        let tabLabel: [(String, String?)] = [
            ("AXStaticText", nil), ("AXRadioButton", "AXTabButton"), ("AXTabGroup", nil), ("AXWindow", nil)
        ]
        #expect(DesktopMoveGrabPlanner.classifyHitChain(tabLabel) == .control)

        let genericTabButton: [(String, String?)] = [
            ("AXGroup", "AXTabButton"), ("AXWindow", nil)
        ]
        #expect(DesktopMoveGrabPlanner.classifyHitChain(genericTabButton) == .control)
    }

    @Test("Native chrome, web title bars, containers and scroll areas map to distinct tiers")
    func hitChainsClassifyIntoPriorityTiers() {
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXWindow", nil)]) == .chrome)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXToolbar", nil), ("AXWindow", nil)]) == .chrome)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXGroup", nil), ("AXToolbar", nil), ("AXWindow", nil)]) == .chrome)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXStaticText", nil), ("AXWindow", nil)]) == .chrome)

        // Web-drawn title bar (Orca / Antigravity / Vivaldi) is probed, not trusted blindly
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXGroup", nil), ("AXWebArea", nil), ("AXWindow", nil)]) == .webOrContainer)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXWebArea", nil), ("AXWindow", nil)]) == .webOrContainer)
        // Bare group/split outside toolbar (Yab / Hark / Simplenote)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXGroup", nil), ("AXWindow", nil)]) == .webOrContainer)
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXSplitGroup", nil), ("AXWindow", nil)]) == .webOrContainer)

        // Scroll area is fallback-only
        #expect(DesktopMoveGrabPlanner.classifyHitChain([("AXScrollArea", nil), ("AXSplitGroup", nil), ("AXWindow", nil)]) == .fallback)
    }

    @Test("Candidate prioritization orders chrome before web/containers before fallback and skips controls")
    func prioritizeCandidatesOrdersByTierAndDropsDuplicates() {
        let candidates: [(CGPoint, GrabHitTier)] = [
            (CGPoint(x: 100, y: 50), .fallback),
            (CGPoint(x: 200, y: 50), .control),
            (CGPoint(x: 300, y: 50), .webOrContainer),
            (CGPoint(x: 400, y: 50), .chrome),
            (CGPoint(x: 408, y: 52), .chrome), // duplicate of 400
            (CGPoint(x: 500, y: 50), .webOrContainer),
        ]

        let ordered = DesktopMoveGrabPlanner.prioritizeCandidates(
            candidates,
            excluding: [CGPoint(x: 505, y: 50)],
            limit: 4
        )
        #expect(ordered == [
            CGPoint(x: 400, y: 50),
            CGPoint(x: 300, y: 50),
            CGPoint(x: 100, y: 50),
        ])
    }

    // MARK: - Per-app relative grab anchor memory

    @Test("Anchor near traffic lights resolves accurately after window moves and resizes")
    func anchorFromButtonsSurvivesMoveAndResize() {
        var memory = DesktopMoveGrabMemory()
        let initialFrame = CGRect(x: 100, y: 34, width: 1000, height: 700)
        let initialButtons = CGRect(x: 158, y: 44, width: 14, height: 14) // maxX = 172, midY = 51
        memory.remember(point: CGPoint(x: 220, y: 51), in: initialFrame, buttonFrame: initialButtons, for: "app.example.orca")

        #expect(memory.anchor(for: "app.example.orca") == .fromButtons(dx: 48, dy: 0))

        let movedFrame = CGRect(x: 1800, y: 80, width: 1600, height: 1100)
        let movedButtons = CGRect(x: 1858, y: 90, width: 14, height: 14) // maxX = 1872, midY = 97
        let resolved = memory.resolve(for: "app.example.orca", in: movedFrame, buttonFrame: movedButtons)
        #expect(resolved == CGPoint(x: 1920, y: 97))
    }

    @Test("Anchor near the right edge stays anchored to the right side when window widens")
    func anchorFromRightStaysAnchoredToRightEdge() {
        var memory = DesktopMoveGrabMemory()
        let narrow = CGRect(x: 0, y: 34, width: 1000, height: 700)
        memory.remember(point: CGPoint(x: 940, y: 48), in: narrow, buttonFrame: nil, for: "app.example.browser")

        #expect(memory.anchor(for: "app.example.browser") == .fromRight(dx: -60, dy: 14))

        let wide = CGRect(x: 0, y: 34, width: 3840, height: 1500)
        #expect(memory.resolve(for: "app.example.browser", in: wide, buttonFrame: nil) == CGPoint(x: 3780, y: 48))
    }

    @Test("Proportional anchor scales with window width and invalidation clears memory")
    func proportionalAnchorAndInvalidation() {
        var memory = DesktopMoveGrabMemory()
        let frame = CGRect(x: 0, y: 34, width: 1000, height: 700)
        memory.remember(point: CGPoint(x: 500, y: 46), in: frame, buttonFrame: nil, for: "app.example.web")

        let doubled = CGRect(x: 200, y: 34, width: 2000, height: 700)
        #expect(memory.resolve(for: "app.example.web", in: doubled, buttonFrame: nil) == CGPoint(x: 1200, y: 46))

        memory.invalidate(for: "app.example.web")
        #expect(memory.resolve(for: "app.example.web", in: doubled, buttonFrame: nil) == nil)
    }

    @Test("Cached anchor is rejected when a tiny window would land it on the traffic lights")
    func cachedAnchorRejectsOverlapWithTrafficLights() {
        var memory = DesktopMoveGrabMemory()
        let wide = CGRect(x: 0, y: 34, width: 1200, height: 700)
        memory.remember(point: CGPoint(x: 1120, y: 50), in: wide, buttonFrame: CGRect(x: 58, y: 43, width: 14, height: 14), for: "app.example.tight")

        // On a 120pt-wide window, maxX - 80 = 40 lands right on the traffic lights (maxX = 72)
        let tiny = CGRect(x: 0, y: 34, width: 120, height: 300)
        let buttons = CGRect(x: 58, y: 43, width: 14, height: 14)
        #expect(memory.resolve(for: "app.example.tight", in: tiny, buttonFrame: buttons) == nil)
    }

    // MARK: - Inward drag, dual CG+AX detection, raise check & safer release

    @Test("Probe drag moves inward horizontally so right-edge spots are never clipped")
    func probeDragTargetMovesInward() {
        let frame = CGRect(x: 0, y: 34, width: 1000, height: 700)
        let leftSpot = CGPoint(x: 120, y: 50)
        let rightSpot = CGPoint(x: 960, y: 50)

        #expect(DesktopMoveGrabPlanner.probeDragTarget(from: leftSpot, windowFrame: frame, offset: 14) == CGPoint(x: 134, y: 64))
        #expect(DesktopMoveGrabPlanner.probeDragTarget(from: rightSpot, windowFrame: frame, offset: 14) == CGPoint(x: 946, y: 64))
    }

    @Test("Dual follow check succeeds when Core Graphics moves even if AX stays stale")
    func didWindowFollowUsesEitherAXOrCG() {
        let start = CGPoint(x: 100, y: 34)
        // Stale AX, moved CG (e.g. Wine / Java / lagging Electron)
        #expect(DesktopMoveGrabPlanner.didWindowFollow(
            beforeAX: start, nowAX: start,
            beforeCG: start, nowCG: CGPoint(x: 105, y: 39),
            dragOffset: 14
        ))
        // 14 pt drag with 9 pt app threshold -> 5 pt movement still passes (threshold capped at 4)
        #expect(DesktopMoveGrabPlanner.didWindowFollow(
            beforeAX: start, nowAX: CGPoint(x: 105, y: 34),
            beforeCG: nil, nowCG: nil,
            dragOffset: 14
        ))
        // 1-2 pt rounding jitter on both still fails
        #expect(!DesktopMoveGrabPlanner.didWindowFollow(
            beforeAX: start, nowAX: CGPoint(x: 101, y: 35),
            beforeCG: start, nowCG: CGPoint(x: 102, y: 34),
            dragOffset: 14
        ))
    }

    @Test("Multi-point raise check spans left, center and right of the top strip")
    func raiseCheckPointsCoverThreeHorizontalZones() {
        let frame = CGRect(x: 100, y: 34, width: 1000, height: 700)
        let points = DesktopMoveGrabPlanner.raiseCheckPoints(for: frame)
        #expect(points.count == 3)
        #expect(points == [CGPoint(x: 600, y: 44), CGPoint(x: 140, y: 44), CGPoint(x: 1060, y: 44)])
    }

    @Test("Release point escapes right when a window sits at top-left (0, 0) on a display")
    func releasePointEscapesRightWhenParkedAtTopLeftCorner() {
        let cornerWindow = CGRect(x: 0, y: 0, width: 800, height: 600)
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let release = DesktopMoveGrabPlanner.releasePoint(
            for: CGPoint(x: 300, y: 14),
            windowFrame: cornerWindow,
            screenBounds: display
        )
        #expect(release == CGPoint(x: 804, y: 14))
    }

    @Test("A 14 pt stage-1 probe shift is still restored cleanly")
    func stageOneProbeShiftIsUndone() {
        let origin = CGPoint(x: 1374, y: 34)
        #expect(SpaceBarController.isProbeShift(from: origin, to: CGPoint(x: 1388, y: 48)))
    }

    @Test("Dock layer-20 and system overlays do not count as covering app title bars")
    func blockingWindowFiltersSystemOverlaysAndKeepsAppAndFloatingWindows() {
        let own: pid_t = 999
        // Real bug observed on macOS 26: Dock owns a full-screen layer-20 window
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 20, owner: "Dock", alpha: 1, pid: 100, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 24, owner: "Window Server", alpha: 1, pid: 101, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 25, owner: "Control Center", alpha: 1, pid: 102, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: -2147483623, owner: "Wallpaper", alpha: 1, pid: 103, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 0, owner: "Dock", alpha: 1, pid: 100, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 0, owner: "Rapto", alpha: 1, pid: own, ownPID: own))
        #expect(!DesktopMoveGrabPlanner.isBlockingWindow(layer: 0, owner: "Spotify", alpha: 0, pid: 200, ownPID: own))

        // Normal app windows (layer 0) and floating PiP/palettes (layer 3..8) still count
        #expect(DesktopMoveGrabPlanner.isBlockingWindow(layer: 0, owner: "Spotify", alpha: 1, pid: 200, ownPID: own))
        #expect(DesktopMoveGrabPlanner.isBlockingWindow(layer: 3, owner: "Phi", alpha: 1, pid: 201, ownPID: own))
    }

    // MARK: - App Nap wake & Core Graphics fallback

    @Test("Cached button-relative anchor falls back to frame-relative coordinates when AX buttons are unavailable")
    func cachedAnchorResolvesWithoutAXButtonsDuringAppNapWake() {
        var memory = DesktopMoveGrabMemory()
        let frame = CGRect(x: 8, y: 34, width: 1342, height: 753)
        let buttons = CGRect(x: 64, y: 43, width: 14, height: 14) // maxX = 78, midY = 50
        memory.remember(point: CGPoint(x: 88, y: 50), in: frame, buttonFrame: buttons, for: "net.whatsapp.WhatsApp")

        #expect(memory.anchor(for: "net.whatsapp.WhatsApp") == .fromButtons(dx: 10, dy: 0))
        // Even with buttonFrame == nil (App Nap CG fallback), the cached grab point still resolves!
        #expect(memory.resolve(for: "net.whatsapp.WhatsApp", in: frame, buttonFrame: nil) == CGPoint(x: 88, y: 50))

        memory.invalidate(for: "net.whatsapp.WhatsApp")
        #expect(memory.resolve(for: "net.whatsapp.WhatsApp", in: frame, buttonFrame: nil) == nil)
    }

    @Test("Core Graphics fallback spots keep clear of macOS traffic lights and honor cached spot first")
    func cgFallbackSpotsStayClearOfTrafficLightsAndPrioritizeCache() {
        let frame = CGRect(x: 8, y: 34, width: 1342, height: 753)
        let cached = CGPoint(x: 88, y: 50)
        let spots = DesktopMoveGrabPlanner.cgFallbackSpots(in: frame, cachedPoint: cached, limit: 6)

        #expect(!spots.isEmpty)
        #expect(spots[0] == cached)
        #expect(spots.count <= 6)
        // All spots stay inside the title bar and clear of the traffic-light zone (8...90)
        for spot in spots {
            #expect(frame.contains(spot))
            #expect(spot.x >= frame.minX + 80)
            #expect(spot.y <= frame.minY + DesktopMoveGrabPlanner.maxTitleBarHeight)
        }
        // Excluded spots are omitted
        let filtered = DesktopMoveGrabPlanner.cgFallbackSpots(in: frame, excluding: [spots[1]], limit: 6)
        #expect(!filtered.contains(where: { abs($0.x - spots[1].x) < 24 && abs($0.y - spots[1].y) < 24 }))
    }

    @Test("Core Graphics fallback still produces draggable spots on narrow windows")
    func cgFallbackSpotsWorkOnNarrowWindows() {
        let narrow = CGRect(x: 200, y: 34, width: 160, height: 400)
        let spots = DesktopMoveGrabPlanner.cgFallbackSpots(in: narrow, limit: 4)
        #expect(!spots.isEmpty)
        #expect(spots.allSatisfy { narrow.contains($0) })
    }
}
