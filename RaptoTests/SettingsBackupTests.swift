//
//  SettingsBackupTests.swift
//  RaptoTests
//
//  Export and import of settings: what travels, what stays, and old or broken files.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Settings Backup Tests")
struct SettingsBackupTests {

    /// A private defaults domain and folder, removed when `body` returns
    private func withStore(_ body: (UserDefaults, URL) throws -> Void) rethrows {
        let store = TestDefaults(prefix: "rapto.backup.tests")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(store.name)
        defer {
            store.remove()
            try? FileManager.default.removeItem(at: folder)
        }
        try body(store.defaults, folder.appendingPathComponent("custom_templates.json"))
    }

    @Test("Every kind of stored value comes back unchanged")
    func roundTrip() throws {
        try withStore { source, sourceTemplates in
            // A fraction that reading and rewriting JSON would change in the last digit
            let blob = Data(#"{"zones":[0.04039062499999996,1]}"#.utf8)
            let color = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x00, 0xFF])
            source.set(true, forKey: "showsSpaceBar")
            source.set(8.5, forKey: "windowGap")
            source.set("glass", forKey: "spaceBarStyle")
            source.set(["com.apple.Terminal", "com.apple.Safari"], forKey: "ignoredApps")
            source.set(["x": 0.1, "width": 0.8], forKey: "focusModeZone")
            source.set(blob, forKey: "customHotkeyBindings")
            source.set(color, forKey: "highlightColor")
            let templates = Data(#"[{"name":"Mine","frame":0.040390624999999958}]"#.utf8)
            try FileManager.default.createDirectory(at: sourceTemplates.deletingLastPathComponent(), withIntermediateDirectories: true)
            try templates.write(to: sourceTemplates)

            let file = try SettingsBackup.export(from: source, templatesFile: sourceTemplates, appVersion: "5.70")
            let archive = try SettingsBackup.read(file)
            #expect(archive.appVersion == "5.70")
            #expect(archive.exportedAt != nil)

            try withStore { target, targetTemplates in
                try SettingsBackup.apply(archive, to: target, templatesFile: targetTemplates)
                #expect(target.object(forKey: "showsSpaceBar") as? Bool == true)
                #expect(target.double(forKey: "windowGap") == 8.5)
                #expect(target.string(forKey: "spaceBarStyle") == "glass")
                #expect(target.stringArray(forKey: "ignoredApps") == ["com.apple.Terminal", "com.apple.Safari"])
                #expect(target.dictionary(forKey: "focusModeZone") as? [String: Double] == ["x": 0.1, "width": 0.8])
                #expect(target.data(forKey: "customHotkeyBindings") == blob)
                #expect(target.data(forKey: "highlightColor") == color)
                #expect(try Data(contentsOf: targetTemplates) == templates)
            }
        }
    }

    @Test("Only listed settings travel, and only they are replaced")
    func unlistedKeysStay() throws {
        try withStore { source, templates in
            source.set(true, forKey: "hasCompletedOnboarding")
            source.set(true, forKey: "hasCompletedSetupGuide")
            source.set(["com.spotify.client"], forKey: "dismissedAppSuggestions")
            source.set(["swap_hint"], forKey: "shownHints")
            source.set(["control": 3], forKey: "hintKeyUses")
            source.set(false, forKey: "showsHints")
            source.set("secret", forKey: "com.rapto.licenseKey")
            source.set("plain", forKey: "spaceBarStyle")
            let file = try SettingsBackup.export(from: source, templatesFile: templates, appVersion: "5.70")
            let text = String(decoding: file, as: UTF8.self)
            #expect(!text.contains("hasCompletedOnboarding"))
            #expect(!text.contains("hasCompletedSetupGuide"))
            #expect(!text.contains("dismissedAppSuggestions"))
            #expect(!text.contains("shownHints"))
            #expect(!text.contains("hintKeyUses"))
            #expect(!text.contains("secret"))
            #expect(text.contains("showsHints"))

            try withStore { target, targetTemplates in
                target.set("5.60", forKey: "whatsNewShownVersion")
                target.set(true, forKey: "hasCompletedSetupGuide")
                try SettingsBackup.apply(SettingsBackup.read(file), to: target, templatesFile: targetTemplates)
                #expect(target.string(forKey: "whatsNewShownVersion") == "5.60")
                #expect(target.bool(forKey: "hasCompletedSetupGuide") == true)
                #expect(target.object(forKey: "showsHints") as? Bool == false)
                #expect(target.string(forKey: "spaceBarStyle") == "plain")
            }
        }
    }

    @Test("A file from an older version: missing settings go back to default, unknown ones are ignored")
    func olderAndNewerSettings() throws {
        let file = Data(#"{"app":"Rapto","format":1,"appVersion":"5.70","settings":{"windowGap":4,"settingFromTheFuture":true}}"#.utf8)
        let archive = try SettingsBackup.read(file)
        #expect(archive.customTemplates == nil)
        try withStore { target, templates in
            target.set("glass", forKey: "spaceBarStyle")
            try SettingsBackup.apply(archive, to: target, templatesFile: templates)
            #expect(target.double(forKey: "windowGap") == 4)
            #expect(target.object(forKey: "spaceBarStyle") == nil)
            #expect(target.object(forKey: "settingFromTheFuture") == nil)
            // The file says nothing about custom layouts, so they are left as they were
            #expect(!FileManager.default.fileExists(atPath: templates.path))
        }
    }

    @Test("Files Rapto cannot use are refused")
    func refusedFiles() {
        #expect(throws: SettingsBackup.ImportError.newerFormat) {
            try SettingsBackup.read(Data(#"{"app":"Rapto","format":2,"settings":{}}"#.utf8))
        }
        for text in ["", "not json", "[1,2]", "{}", #"{"app":"Other","format":1,"settings":{}}"#, #"{"app":"Rapto","settings":{}}"#] {
            #expect(throws: SettingsBackup.ImportError.notASettingsFile) {
                try SettingsBackup.read(Data(text.utf8))
            }
        }
    }

    @Test("Values that cannot be read are dropped")
    func brokenValues() throws {
        let file = Data(#"{"app":"Rapto","format":1,"settings":{"windowGap":null,"highlightColor":{"$data":"***"},"templateHotkeys":{"$json":"{broken"},"ignoredApps":["a"]},"customTemplates":"{}"}"#.utf8)
        let archive = try SettingsBackup.read(file)
        #expect(Array(archive.settings.keys) == ["ignoredApps"])
        #expect(archive.customTemplates == nil)
    }
}
