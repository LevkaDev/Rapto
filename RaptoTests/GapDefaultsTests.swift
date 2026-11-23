//
//  GapDefaultsTests.swift
//  RaptoTests
//
//  Default 4 px window and screen edge gaps, and preserving an explicit 0 px setting.
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Gap Defaults Tests")
struct GapDefaultsTests {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let store = TestDefaults(prefix: "rapto.gaps.tests")
        defer { store.remove() }
        body(store.defaults)
    }

    @Test("Unset gap keys fall back to 4 px")
    func unsetKeysUseFourPixels() {
        withDefaults { defaults in
            #expect(AppState.defaultGap == 4)
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 4)
            #expect(AppState.loadedGap(forKey: "screenEdgeGap", from: defaults) == 4)
        }
    }

    @Test("Explicitly saved 0 px is preserved instead of reverting to default")
    func savedZeroIsPreserved() {
        withDefaults { defaults in
            defaults.set(0, forKey: "windowGap")
            defaults.set(0.0, forKey: "screenEdgeGap")
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 0)
            #expect(AppState.loadedGap(forKey: "screenEdgeGap", from: defaults) == 0)
        }
    }

    @Test("An install set up before the 4 px default keeps 0 px, and the answer is saved")
    func existingInstallKeepsZero() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasCompletedOnboarding")
            AppState.settleUnsavedGap(forKey: "windowGap", in: defaults)
            AppState.settleUnsavedGap(forKey: "screenEdgeGap", in: defaults)
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 0)
            #expect(AppState.loadedGap(forKey: "screenEdgeGap", from: defaults) == 0)
        }
    }

    @Test("A new install gets 4 px and keeps it after onboarding is finished")
    func newInstallKeepsFourAfterOnboarding() {
        withDefaults { defaults in
            AppState.settleUnsavedGap(forKey: "windowGap", in: defaults)
            defaults.set(true, forKey: "hasCompletedOnboarding")
            AppState.settleUnsavedGap(forKey: "windowGap", in: defaults)
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 4)
        }
    }

    @Test("A saved gap is not replaced")
    func savedGapIsNotReplaced() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(12, forKey: "windowGap")
            AppState.settleUnsavedGap(forKey: "windowGap", in: defaults)
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 12)
        }
    }

    @Test("Positive saved values are read as stored, invalid values fall back to default")
    func positiveAndInvalidValues() {
        withDefaults { defaults in
            defaults.set(12, forKey: "windowGap")
            defaults.set(-4, forKey: "screenEdgeGap")
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 12)
            #expect(AppState.loadedGap(forKey: "screenEdgeGap", from: defaults) == 4)

            defaults.set("invalid", forKey: "windowGap")
            #expect(AppState.loadedGap(forKey: "windowGap", from: defaults) == 4)
        }
    }
}
