//
//  WindowFlowTests.swift
//  RaptoTests
//
//  Unit tests for Window Flow's pure layout, spring, scroll coasting,
//  title formatting, mini-player filtering, and hotkey presets.
//

import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import Rapto

struct WindowFlowTests {

    @Test func springSettlesSmoothlyToTarget() {
        var spring = WindowFlowSpring(0, stiffness: 200, damping: 26)
        spring.target = 1.0
        for _ in 0..<240 {
            spring.step(1.0 / 120.0)
        }
        #expect(spring.isSettled)
        #expect(spring.value == 1.0)
        #expect(spring.velocity == 0)
    }

    @Test func springCanRedirectMidFlight() {
        var spring = WindowFlowSpring(0, stiffness: 220, damping: 24)
        spring.target = 3.0
        for _ in 0..<20 {
            spring.step(1.0 / 120.0)
        }
        #expect(spring.value > 0.2)
        spring.target = 1.0
        for _ in 0..<240 {
            spring.step(1.0 / 120.0)
        }
        #expect(spring.isSettled)
        #expect(spring.value == 1.0)
    }

    @Test func coastTargetClampsToBoundsAndRounds() {
        // Gentle forward flick from 1.2 -> coasts to 2
        let mid = WindowFlowLayout.coastTarget(position: 1.2, velocity: 2.0, coastSeconds: 0.42, count: 6)
        #expect(mid == 2.0)

        // Strong forward flick clamps at last card (5)
        let maxEnd = WindowFlowLayout.coastTarget(position: 3.0, velocity: 25.0, coastSeconds: 0.42, count: 6)
        #expect(maxEnd == 5.0)

        // Strong backward flick clamps at 0
        let minEnd = WindowFlowLayout.coastTarget(position: 1.0, velocity: -20.0, coastSeconds: 0.42, count: 6)
        #expect(minEnd == 0.0)

        // Single card always stays at 0
        let single = WindowFlowLayout.coastTarget(position: 0, velocity: 5.0, coastSeconds: 0.42, count: 1)
        #expect(single == 0.0)
    }

    @Test func cardSizeShrinksSmoothlyAwayFromCenterAndPreservesAspect() {
        let centerBox = CGSize(width: 800, height: 500)
        let sideBox = CGSize(width: 320, height: 220)
        let aspect: CGFloat = 1.6

        let center = WindowFlowLayout.cardSize(index: 2, at: 2.0, centerBox: centerBox, sideBox: sideBox, aspect: aspect)
        let neighbor = WindowFlowLayout.cardSize(index: 3, at: 2.0, centerBox: centerBox, sideBox: sideBox, aspect: aspect)
        let outer = WindowFlowLayout.cardSize(index: 5, at: 2.0, centerBox: centerBox, sideBox: sideBox, aspect: aspect)

        #expect(abs(center.width / center.height - aspect) < 0.01)
        #expect(center.width > neighbor.width)
        #expect(neighbor.width > outer.width)
    }

    @Test func miniPlayerFilterExcludesPictureInPictureAndTinyPanels() {
        #expect(WindowFlowLayout.isExcludedMiniPlayer(title: "Picture in Picture", size: CGSize(width: 480, height: 270)))
        #expect(WindowFlowLayout.isExcludedMiniPlayer(title: "Picture-in-Picture", size: CGSize(width: 480, height: 270)))
        #expect(WindowFlowLayout.isExcludedMiniPlayer(title: "Palette", size: CGSize(width: 90, height: 60)))
        #expect(!WindowFlowLayout.isExcludedMiniPlayer(title: "Project Notes", size: CGSize(width: 900, height: 640)))
    }

    @Test func bindingMatcherMatchesExactKeyAndModifiers() {
        let ctrlOptS = HotkeyBinding(keyCode: 0x01, modifiers: UInt32(controlKey | optionKey))
        #expect(WindowFlowLayout.matchesBinding(keyCode: 1, flags: [.maskControl, .maskAlternate], binding: ctrlOptS))
        #expect(!WindowFlowLayout.matchesBinding(keyCode: 1, flags: [.maskControl, .maskAlternate, .maskShift], binding: ctrlOptS))
        #expect(!WindowFlowLayout.matchesBinding(keyCode: 2, flags: [.maskControl, .maskAlternate], binding: ctrlOptS))
        #expect(!WindowFlowLayout.matchesBinding(keyCode: 1, flags: [.maskControl, .maskAlternate], binding: .cleared))
    }

    @Test func nameFormatStripsDuplicateAppAffixes() {
        let label = WindowFlowNameFormat.makeLabel(
            appName: "Safari",
            title: "Settings — Safari",
            desktopNumber: 2,
            isFullScreen: false,
            isOnCurrentDesktop: true
        )
        #expect(label.headline == "Settings")
        #expect(label.subtitle == "Safari  ·  Desktop 2 · Current")
        #expect(label.isCurrentDesktop)

        let sameLabel = WindowFlowNameFormat.makeLabel(
            appName: "Notes",
            title: "Notes",
            desktopNumber: 3,
            isFullScreen: false,
            isOnCurrentDesktop: false
        )
        #expect(sameLabel.headline == "Notes")
        #expect(sameLabel.subtitle == "Desktop 3")
    }

    @Test func themesCycleThroughAllFourInOrder() {
        #expect(WindowFlowTheme.azure.next == .dusk)
        #expect(WindowFlowTheme.dusk.next == .night)
        #expect(WindowFlowTheme.night.next == .glass)
        #expect(WindowFlowTheme.glass.next == .azure)
    }

    @Test func windowFlowHotkeyHasNoConflictsInDefaultPresets() {
        for preset in [HotkeyPreset.rapto, HotkeyPreset.vimStyle] {
            let flowBinding = preset.bindings[.openWindowFlow]
            #expect(flowBinding != nil)
            let duplicates = preset.bindings.filter { $0.key != .openWindowFlow && $0.value == flowBinding }
            #expect(duplicates.isEmpty)
        }
    }
}
