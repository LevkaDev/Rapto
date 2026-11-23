//
//  OnboardingModeCopyTests.swift
//  RaptoTests
//
//  Mode display names and onboarding mode descriptions.
//

import Testing
@testable import Rapto

@Suite("Onboarding Mode Copy Tests")
struct OnboardingModeCopyTests {

    @Test("TilingMode display names match menu labels")
    func tilingModeDisplayNames() {
        #expect(TilingMode.none.displayName == "None")
        #expect(TilingMode.autoTiling.displayName == "Auto-tiling")
        #expect(TilingMode.dragSnap.displayName == "Drag to Snap")
        #expect(TilingMode.manualAssignment.displayName == "Manual")
    }

    @Test("Onboarding mode cards describe all three modes without requiring the overlay in Manual")
    func onboardingModeChoices() {
        let choices = ModeChoice.all(overlayShortcut: "⌃⌥G")
        #expect(choices.map(\.mode) == [.dragSnap, .manualAssignment, .autoTiling])

        let manual = choices.first { $0.mode == .manualAssignment }
        #expect(manual?.title == "Manual")
        #expect(manual?.text.contains("slots") == true)
        #expect(manual?.text.contains("⌃⌥G") == false)
    }
}
