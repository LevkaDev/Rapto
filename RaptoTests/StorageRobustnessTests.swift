//
//  StorageRobustnessTests.swift
//  RaptoTests
//
//  Stored settings that are out of range, from an older or newer build, or damaged.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Storage Robustness Tests")
struct StorageRobustnessTests {

    /// A private defaults domain, removed when `body` returns
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let store = TestDefaults(prefix: "rapto.storage.tests")
        defer { store.remove() }
        try body(store.defaults)
    }

    // MARK: - Auto-tiling preferences

    @Test("Stored max windows outside 2...8 is brought into range", arguments: [
        (stored: 0, loaded: 2), (stored: -3, loaded: 2), (stored: 1, loaded: 2),
        (stored: 5, loaded: 5), (stored: 99, loaded: 8),
    ])
    @MainActor func maxWindowsIsClamped(stored: Int, loaded: Int) throws {
        try withDefaults { defaults in
            var preferences = AutoTilingPreferences.default
            preferences.maxWindows = stored
            defaults.set(try JSONEncoder().encode(preferences), forKey: "autoTilingPreferences")

            #expect(AutoTilingPreferencesStorage.load(from: defaults).maxWindows == loaded)
        }
    }

    @Test("Missing auto-tiling preferences load the defaults")
    @MainActor func missingPreferencesLoadDefaults() {
        withDefaults { defaults in
            #expect(AutoTilingPreferencesStorage.load(from: defaults) == .default)
        }
    }

    // MARK: - Custom shortcuts

    @Test("Custom shortcuts survive a save and load unchanged")
    func customBindingsRoundTrip() {
        withDefaults { defaults in
            let storage = HotkeyPresetStorage(userDefaults: defaults)
            let bindings: [HotkeyAction: HotkeyBinding] = [
                HotkeyAction.allCases[0]: HotkeyBinding(keyCode: 0x0F, modifiers: 2048),
                HotkeyAction.allCases[1]: .cleared,
            ]
            storage.saveCustomBindings(bindings)

            #expect(storage.loadCustomBindings() == bindings)
            #expect(defaults.data(forKey: "customHotkeyBindings_backup") == nil)
        }
    }

    @Test("An action from another app version is skipped, the other shortcuts stay")
    func unknownActionSkipped() throws {
        try withDefaults { defaults in
            let known = HotkeyAction.allCases[0]
            let json = #"["\#(known.rawValue)",{"keyCode":15,"modifiers":2048},"actionFromTheFuture",{"keyCode":1,"modifiers":256}]"#
            let data = Data(json.utf8)
            defaults.set(data, forKey: "customHotkeyBindings")

            let loaded = try #require(HotkeyPresetStorage(userDefaults: defaults).loadCustomBindings())
            #expect(loaded == [known: HotkeyBinding(keyCode: 15, modifiers: 2048)])
            #expect(defaults.data(forKey: "customHotkeyBindings_backup") == data)
        }
    }

    @Test("A damaged shortcut value is skipped, the other shortcuts stay")
    func damagedBindingSkipped() throws {
        try withDefaults { defaults in
            let first = HotkeyAction.allCases[0], second = HotkeyAction.allCases[1]
            let json = #"["\#(first.rawValue)",{"keyCode":"x"},"\#(second.rawValue)",{"keyCode":2,"modifiers":256}]"#
            defaults.set(Data(json.utf8), forKey: "customHotkeyBindings")

            let loaded = try #require(HotkeyPresetStorage(userDefaults: defaults).loadCustomBindings())
            #expect(loaded == [second: HotkeyBinding(keyCode: 2, modifiers: 256)])
        }
    }

    @Test("Unreadable shortcut data is kept as a backup")
    func unreadableBindingsBackedUp() {
        withDefaults { defaults in
            let data = Data("not json".utf8)
            defaults.set(data, forKey: "customHotkeyBindings")

            #expect(HotkeyPresetStorage(userDefaults: defaults).loadCustomBindings() == nil)
            #expect(defaults.data(forKey: "customHotkeyBindings_backup") == data)
        }
    }

    // MARK: - Space configurations

    @Test("A Space with a mode from another app version is skipped, the other Spaces stay")
    func unknownTilingModeSkipped() {
        withDefaults { defaults in
            let json = #"{"space-1":{"mode":"none"},"space-2":{"mode":"modeFromTheFuture"}}"#
            let data = Data(json.utf8)
            defaults.set(data, forKey: "spaceConfigurations")

            let loaded = SpaceConfigurationStorage.load(from: defaults)
            #expect(loaded == ["space-1": SpaceConfiguration(mode: .none)])
            #expect(defaults.data(forKey: "spaceConfigurations_backup") == data)
        }
    }
}
