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
}
