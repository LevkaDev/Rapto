//
//  SpaceBarStabilityTests.swift
//  RaptoTests
//
//  Tests for Desktops Bar stability: preserving per-desktop app icon order
//  across focus changes, exact integral panel framing without +1 pt inflation
//  on odd menu bars, and protecting hover fade-out animations from refresh ticks.
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Desktops Bar Stability Tests")
struct SpaceBarStabilityTests {

    // MARK: - Stable app icon order

    @Test("stableAppOrder keeps existing icons in place when focus changes")
    func stableOrderIgnoresZOrderShuffle() {
        let initial = SpaceBarController.stableAppOrder(previous: [], current: [101, 202, 303])
        #expect(initial == [101, 202, 303])

        // App 303 becomes frontmost, then app 202 — slot positions stay unchanged
        let afterFocus303 = SpaceBarController.stableAppOrder(previous: initial, current: [303, 101, 202])
        #expect(afterFocus303 == [101, 202, 303])

        let afterFocus202 = SpaceBarController.stableAppOrder(previous: afterFocus303, current: [202, 303, 101])
        #expect(afterFocus202 == [101, 202, 303])
    }

    @Test("stableAppOrder appends new apps at the end and removes closed ones")
    func stableOrderAppendsNewAndRemovesClosed() {
        // New frontmost app 404 is appended rather than jumping to index 0
        let withNew = SpaceBarController.stableAppOrder(previous: [101, 202, 303], current: [404, 303, 101, 202])
        #expect(withNew == [101, 202, 303, 404])

        // Closing app 202 preserves relative order of remaining apps
        let afterClose = SpaceBarController.stableAppOrder(previous: withNew, current: [404, 101, 303])
        #expect(afterClose == [101, 303, 404])

        // Duplicate PIDs in either input are deduplicated cleanly
        let deduped = SpaceBarController.stableAppOrder(previous: [101, 101, 303], current: [505, 505, 303, 101])
        #expect(deduped == [101, 303, 505])

        // Empty desktop yields empty order
        #expect(SpaceBarController.stableAppOrder(previous: [101, 202], current: []).isEmpty)
    }

    // MARK: - Panel framing without .integral inflation

    @Test("panelFrame does not inflate height on an odd 25 pt menu bar")
    func panelFrameOddMenuBarHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055) // 25 pt menu bar

        let frame = SpaceBarController.panelFrame(
            size: CGSize(width: 160, height: 24),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0
        )

        #expect(frame.width == 160)
        #expect(frame.height == 24)
        #expect(frame.minX == 880)
        #expect(frame.minY == 1056)
        #expect(frame.maxY <= screen.maxY)
        #expect(frame.minY >= visible.maxY)
    }

    @Test("panelFrame does not inflate odd widths and rounds fractional sizes up cleanly")
    func panelFrameOddAndFractionalWidths() {
        let screen = CGRect(x: 0, y: 0, width: 3840, height: 1620)
        let visible = CGRect(x: 0, y: 0, width: 3840, height: 1590) // 30 pt menu bar

        // Odd integer width on even screen width lands on .5 origin, but must stay 161 pt wide
        let odd = SpaceBarController.panelFrame(
            size: CGSize(width: 161, height: 26),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0
        )
        #expect(odd.width == 161)
        #expect(odd.height == 26)
        #expect(odd.minX == odd.minX.rounded())
        #expect(odd.minY == 1592)

        // Fractional ideal width rounds up to fit content without clipping
        let fractional = SpaceBarController.panelFrame(
            size: CGSize(width: 412.4, height: 25.2),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0
        )
        #expect(fractional.width == 413)
        #expect(fractional.height == 26)

        // Tiny floating-point noise above an integer does not jump to the next point
        let noisy = SpaceBarController.panelFrame(
            size: CGSize(width: 413.0001, height: 26.0001),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 0
        )
        #expect(noisy.width == 413)
        #expect(noisy.height == 26)
    }

    @Test("panelFrame places below the menu bar on notched displays and clamps tiny sizes")
    func panelFrameNotchedAndClamped() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

        let notched = SpaceBarController.panelFrame(
            size: CGSize(width: 300, height: 26),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 37
        )
        #expect(notched == CGRect(x: 606, y: 916, width: 300, height: 26))

        let clamped = SpaceBarController.panelFrame(
            size: CGSize(width: 10, height: 10),
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 37
        )
        #expect(clamped.width == 24)
        #expect(clamped.height == 22)
    }

    @Test("shouldUpdatePanelFrame detects 1 pt growth and ignores identical frames")
    func panelFrameUpdateComparison() {
        let current = CGRect(x: 100, y: 1056, width: 413, height: 24)
        #expect(!SpaceBarController.shouldUpdatePanelFrame(current: current, target: current))
        #expect(SpaceBarController.shouldUpdatePanelFrame(
            current: current,
            target: CGRect(x: 100, y: 1056, width: 414, height: 24)
        ))
        #expect(SpaceBarController.shouldUpdatePanelFrame(
            current: current,
            target: CGRect(x: 99, y: 1056, width: 413, height: 24)
        ))
        #expect(SpaceBarController.shouldUpdatePanelFrame(
            current: current,
            target: CGRect(x: 100, y: 1055, width: 413, height: 24)
        ))
    }

    // MARK: - Hover fade-out protection

    @Test("panelAlphaAction preserves in-flight fade-out and reveal animations")
    func panelAlphaActionStates() {
        // Always-visible displays always show immediately
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: false, isRevealed: false, isHiding: false) == .showImmediately)
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: false, isRevealed: true, isHiding: false) == .showImmediately)
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: false, isRevealed: false, isHiding: true) == .showImmediately)

        // Hover-only displays preserve alpha while revealed (or fading in) and while fading out
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: true, isRevealed: true, isHiding: false) == .preserve)
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: true, isRevealed: false, isHiding: true) == .preserve)

        // Hover-only display with no active reveal or fade-out snaps to hidden
        #expect(SpaceBarController.panelAlphaAction(isHoverOnly: true, isRevealed: false, isHiding: false) == .hideImmediately)
    }
}
