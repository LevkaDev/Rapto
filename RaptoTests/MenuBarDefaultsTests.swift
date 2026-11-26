//
//  MenuBarDefaultsTests.swift
//  RaptoTests
//
//  Default menu bar icon visibility for new installs while preserving existing installs.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Menu Bar Icon Defaults Tests")
struct MenuBarDefaultsTests {

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let store = TestDefaults(prefix: "rapto.menubar.tests")
        defer { store.remove() }
        body(store.defaults)
    }

    @Test("A new install enables the menu bar icon and keeps it after onboarding finishes")
    func newInstallShowsMenuBarIcon() {
        withDefaults { defaults in
            AppState.settleUnsavedMenuBarIcon(in: defaults)
            #expect(defaults.bool(forKey: "showsMenuBarIcon") == true)

            defaults.set(true, forKey: "hasCompletedOnboarding")
            AppState.settleUnsavedMenuBarIcon(in: defaults)
            #expect(defaults.bool(forKey: "showsMenuBarIcon") == true)
        }
    }

    @Test("An existing install without a saved preference keeps the menu bar icon hidden")
    func existingInstallKeepsMenuBarIconHidden() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasCompletedOnboarding")
            AppState.settleUnsavedMenuBarIcon(in: defaults)
            #expect(defaults.bool(forKey: "showsMenuBarIcon") == false)
        }
    }

    @Test("Explicitly saved menu bar icon preferences are never overwritten")
    func explicitPreferenceIsPreserved() {
        withDefaults { defaults in
            defaults.set(false, forKey: "showsMenuBarIcon")
            AppState.settleUnsavedMenuBarIcon(in: defaults)
            #expect(defaults.bool(forKey: "showsMenuBarIcon") == false)

            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(true, forKey: "showsMenuBarIcon")
            AppState.settleUnsavedMenuBarIcon(in: defaults)
            #expect(defaults.bool(forKey: "showsMenuBarIcon") == true)
        }
    }
}
