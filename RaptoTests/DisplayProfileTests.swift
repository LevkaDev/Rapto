//
//  DisplayProfileTests.swift
//  RaptoTests
//
//  Display profile classification, auto-tuned Auto-tiling defaults, migration safety,
//  and ultrawide template partitioning.
//

import CoreGraphics
import Foundation
import Testing
@testable import Rapto

@Suite("Display Profile Auto-Tuning Tests")
struct DisplayProfileTests {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let store = TestDefaults(prefix: "rapto.displayprofile.tests")
        defer { store.remove() }
        body(store.defaults)
    }

    @Test("Classifies common MacBooks, regular desktop monitors, and ultrawide displays accurately")
    func displayClassification() {
        // 13" MacBook Air (1440x900, 1470x956) and 14" MacBook Pro (1512x982)
        #expect(DisplayProfile.classify(size: CGSize(width: 1440, height: 900), isBuiltin: true) == .compactLaptop)
        #expect(DisplayProfile.classify(size: CGSize(width: 1512, height: 982), isBuiltin: true) == .compactLaptop)

        // 15" MacBook Air (1710x1107) and 16" MacBook Pro (1728x1117)
        #expect(DisplayProfile.classify(size: CGSize(width: 1710, height: 1107), isBuiltin: true) == .largeLaptop)
        #expect(DisplayProfile.classify(size: CGSize(width: 1728, height: 1117), isBuiltin: true) == .largeLaptop)

        // 24" iMac (2240x1260), 1080p/4K scaled (1920x1080), 27" 5K Studio Display (2560x1440)
        #expect(DisplayProfile.classify(size: CGSize(width: 1920, height: 1080), isBuiltin: false) == .standardDesktop)
        #expect(DisplayProfile.classify(size: CGSize(width: 2240, height: 1260), isBuiltin: false) == .standardDesktop)
        #expect(DisplayProfile.classify(size: CGSize(width: 2560, height: 1440), isBuiltin: false) == .standardDesktop)

        // 21:9 2560x1080 ultrawide (aspect >= 2.0), 34" 3440x1440, 38" 3840x1600, 32" 6K (3008x1692)
        #expect(DisplayProfile.classify(size: CGSize(width: 2560, height: 1080), isBuiltin: false) == .ultrawide)
        #expect(DisplayProfile.classify(size: CGSize(width: 3440, height: 1440), isBuiltin: false) == .ultrawide)
        #expect(DisplayProfile.classify(size: CGSize(width: 3840, height: 1600), isBuiltin: false) == .ultrawide)
        #expect(DisplayProfile.classify(size: CGSize(width: 3008, height: 1692), isBuiltin: false) == .ultrawide)
    }

    @Test("Recommendations match display size: Full for laptops/desktops, Center Focus & Auto-tiling for ultrawide")
    func profileRecommendations() {
        #expect(DisplayProfile.compactLaptop.suggestedMaxWindows == 2)
        #expect(DisplayProfile.compactLaptop.suggestedSingleWindowTemplateID == PredefinedTemplates.full.id)
        #expect(DisplayProfile.compactLaptop.suggestedManualTemplate.id == PredefinedTemplates.halvesVertical.id)
        #expect(DisplayProfile.compactLaptop.recommendedStarterMode == .dragSnap)
        #expect(DisplayProfile.compactLaptop.prefersUltrawideLayouts == false)

        #expect(DisplayProfile.largeLaptop.suggestedMaxWindows == 3)
        #expect(DisplayProfile.largeLaptop.suggestedSingleWindowTemplateID == PredefinedTemplates.full.id)
        #expect(DisplayProfile.largeLaptop.recommendedStarterMode == .dragSnap)

        #expect(DisplayProfile.standardDesktop.suggestedMaxWindows == 4)
        #expect(DisplayProfile.standardDesktop.suggestedSingleWindowTemplateID == PredefinedTemplates.full.id)
        #expect(DisplayProfile.standardDesktop.suggestedManualTemplate.id == PredefinedTemplates.onePlusTwoLeft.id)
        #expect(DisplayProfile.standardDesktop.recommendedStarterMode == .dragSnap)

        #expect(DisplayProfile.ultrawide.suggestedMaxWindows == 5)
        #expect(DisplayProfile.ultrawide.suggestedSingleWindowTemplateID == PredefinedTemplates.centerFocus.id)
        #expect(DisplayProfile.ultrawide.suggestedManualTemplate.id == PredefinedTemplates.centerFocus.id)
        #expect(DisplayProfile.ultrawide.recommendedStarterMode == .autoTiling)
        #expect(DisplayProfile.ultrawide.prefersUltrawideLayouts == true)
    }

    @Test("Dominant profile selects the highest-capacity connected screen")
    func dominantProfileSelection() {
        #expect(DisplayProfile.dominant(in: [.compactLaptop, .ultrawide]) == .ultrawide)
        #expect(DisplayProfile.dominant(in: [.compactLaptop, .standardDesktop]) == .standardDesktop)
        #expect(DisplayProfile.dominant(in: [.compactLaptop]) == .compactLaptop)
        #expect(DisplayProfile.dominant(in: []) == .standardDesktop)
    }

    @Test("New install settles display-tuned Auto-tiling defaults while existing installs keep legacy defaults")
    func autoTilingDefaultsMigration() {
        withDefaults { defaults in
            AutoTilingPreferencesStorage.settleUnsaved(in: defaults, for: .compactLaptop)
            let loaded = AutoTilingPreferencesStorage.load(from: defaults)
            #expect(loaded.templateFor1Window == PredefinedTemplates.full.id)
            #expect(loaded.maxWindows == 2)

            // Finishing onboarding does not overwrite already-settled defaults
            defaults.set(true, forKey: "hasCompletedOnboarding")
            AutoTilingPreferencesStorage.settleUnsaved(in: defaults, for: .ultrawide)
            let reloaded = AutoTilingPreferencesStorage.load(from: defaults)
            #expect(reloaded.templateFor1Window == PredefinedTemplates.full.id)
            #expect(reloaded.maxWindows == 2)
        }

        withDefaults { defaults in
            defaults.set(true, forKey: "hasCompletedOnboarding")
            AutoTilingPreferencesStorage.settleUnsaved(in: defaults, for: .compactLaptop)
            let existing = AutoTilingPreferencesStorage.load(from: defaults)
            #expect(existing.templateFor1Window == PredefinedTemplates.centerFocus.id)
            #expect(existing.maxWindows == 4)
        }
    }

    @Test("PredefinedTemplates cleanly separates standard and ultrawide layouts without losing any")
    func predefinedTemplatePartitioning() {
        #expect(PredefinedTemplates.standard.count == 7)
        #expect(PredefinedTemplates.ultrawide.count == 7)
        #expect(PredefinedTemplates.all.count == 14)
        #expect(PredefinedTemplates.ultrawideIDs.contains(PredefinedTemplates.centerFocus.id))
        #expect(!PredefinedTemplates.ultrawideIDs.contains(PredefinedTemplates.halvesVertical.id))
    }
}
