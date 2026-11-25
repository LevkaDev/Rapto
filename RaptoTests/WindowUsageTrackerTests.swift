//
//  WindowUsageTrackerTests.swift
//  RaptoTests
//
//  Verifies smart window ordering for the visual window strip:
//  current window at 0, previous genuine window at 1, frecency with decay at 2+.
//

import CoreGraphics
import Foundation
import Testing
@testable import Rapto

struct WindowUsageTrackerTests {

    @Test func currentWindowIsZeroAndPreviousGenuineWindowIsOne() {
        var ranker = WindowUsageRanker()
        let w1: CGWindowID = 101
        let w2: CGWindowID = 102
        let w3: CGWindowID = 103
        let w4: CGWindowID = 104

        // Build high frequency on w2 and w3
        ranker.focusChanged(to: w2, at: 0)
        ranker.focusChanged(to: w3, at: 10)
        ranker.focusChanged(to: w2, at: 20)
        ranker.focusChanged(to: w3, at: 30)
        ranker.focusChanged(to: w2, at: 40)

        // Now visit a rare window w4 briefly (genuine, >= 1.5s), then switch to w1
        ranker.focusChanged(to: w4, at: 50)
        ranker.focusChanged(to: w1, at: 55)

        let ordered = ranker.order([w1, w2, w3, w4], id: { $0 }, currentWindowID: w1, at: 60)
        // Slot 0 = current (w1), Slot 1 = previous genuine (w4), Slots 2+ = frecency (w2 > w3)
        #expect(ordered == [w1, w4, w2, w3])
    }

    @Test func briefTransientFlashDoesNotStealPreviousSlotOrGainScore() {
        var ranker = WindowUsageRanker()
        let wA: CGWindowID = 1
        let wB: CGWindowID = 2
        let wNoise: CGWindowID = 3

        ranker.focusChanged(to: wA, at: 0)
        ranker.focusChanged(to: wB, at: 10)
        // Brief 0.4s accidental click on wNoise, then back to wB
        ranker.focusChanged(to: wNoise, at: 20)
        ranker.focusChanged(to: wB, at: 20.4)

        let ordered = ranker.order([wB, wNoise, wA], id: { $0 }, currentWindowID: wB, at: 25)
        #expect(ordered[0] == wB)
        #expect(ordered[1] == wA)
        #expect(ranker.score(for: wNoise, at: 25) == 0)
    }

    @Test func oldFrequentWindowDecaysBehindNewActiveTask() {
        var ranker = WindowUsageRanker(halfLife: 2.5 * 3600)
        let morning: CGWindowID = 10
        let afternoon: CGWindowID = 20
        let current: CGWindowID = 30
        let prev: CGWindowID = 40

        // Heavy morning usage on `morning`
        for step in 0..<6 {
            let t = Double(step * 20)
            ranker.focusChanged(to: morning, at: t)
            ranker.focusChanged(to: prev, at: t + 10)
        }

        // 8 hours later (>3 half-lives), user switches to `afternoon` twice
        let later: TimeInterval = 8 * 3600
        ranker.focusChanged(to: afternoon, at: later)
        ranker.focusChanged(to: prev, at: later + 15)
        ranker.focusChanged(to: afternoon, at: later + 30)
        ranker.focusChanged(to: prev, at: later + 45)
        ranker.focusChanged(to: current, at: later + 60)

        let ordered = ranker.order([morning, afternoon, current, prev], id: { $0 }, currentWindowID: current, at: later + 65)
        #expect(ordered == [current, prev, afternoon, morning])
    }

    @Test func activeDwellAddsCappedBonusWithoutRewardingIdleTime() {
        var ranker = WindowUsageRanker()
        let activeWin: CGWindowID = 50
        let idleWin: CGWindowID = 51

        // 10 minutes of active work in `activeWin`
        ranker.focusChanged(to: activeWin, at: 0)
        ranker.settleActive(at: 600, userIdleSeconds: 0)
        let activeScore = ranker.score(for: activeWin, at: 600)
        // Visit (1.0) + capped dwell (~1.5), decayed slightly over 10 min
        #expect(activeScore > 2.3)
        #expect(activeScore <= 2.55)

        // 2 hours left open while user was idle the whole time -> should NOT earn full dwell bonus
        ranker.focusChanged(to: idleWin, at: 1000)
        ranker.settleActive(at: 1000 + 7200, userIdleSeconds: 7200)
        let idleScore = ranker.score(for: idleWin, at: 1000 + 7200)
        #expect(idleScore < 1.2)
    }

    @Test func explicitStripSelectionCommitsImmediately() {
        var ranker = WindowUsageRanker()
        let w1: CGWindowID = 70
        let w2: CGWindowID = 71

        ranker.focusChanged(to: w1, at: 0)
        ranker.settleActive(at: 5)
        ranker.recordExplicitSelection(w2, at: 10)

        // Immediately after picking w2 (even 0.2s later), w2 is scored and w1 is previous
        #expect(ranker.score(for: w2, at: 10.2) >= 0.99)
        #expect(ranker.previousWindow(excluding: w2) == w1)
    }

    @Test func orderingOneDisplayPreservesScoresOnOtherDisplays() {
        var ranker = WindowUsageRanker()
        let display1A: CGWindowID = 81
        let display1B: CGWindowID = 82
        let display2A: CGWindowID = 91

        ranker.focusChanged(to: display2A, at: 0)
        ranker.focusChanged(to: display1A, at: 10)
        ranker.focusChanged(to: display1B, at: 20)

        // Prune with all open windows across both displays, then order display 1 only
        ranker.prune(keeping: [display1A, display1B, display2A])
        _ = ranker.order([display1A, display1B], id: { $0 }, currentWindowID: display1B, at: 25)

        // Display 2 window still keeps its score
        #expect(ranker.score(for: display2A, at: 25) > 0.9)
    }
}
