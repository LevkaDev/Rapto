//
//  SpaceBarAppMenuTests.swift
//  RaptoTests
//
//  Tests for Desktops Bar app-icon hit-testing, `<App Name>` submenu items
//  (`Always Ignore` + `Pause Shortcuts`, without `Float Window`), and immediate
//  slot eviction / passthrough state updates.
//

import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import Rapto

@Suite("Desktops Bar App Submenu Tests")
struct SpaceBarAppMenuTests {

    @Test("hitGlyphPID returns the app PID on an icon and nil on the desktop number or another space")
    func glyphHitTesting() {
        let frames: [SpaceBarGlyphKey: CGRect] = [
            SpaceBarGlyphKey(spaceID: 101, pid: 501): CGRect(x: 28, y: 3, width: 20, height: 18),
            SpaceBarGlyphKey(spaceID: 101, pid: 502): CGRect(x: 52, y: 3, width: 20, height: 18),
            SpaceBarGlyphKey(spaceID: 202, pid: 777): CGRect(x: 112, y: 3, width: 20, height: 18)
        ]

        // Click on Desktop 1 number (left of glyphs) -> nil
        #expect(SpaceBarController.hitGlyphPID(at: CGPoint(x: 10, y: 12), in: 101, glyphFrames: frames) == nil)

        // Click directly on first and second app icons on Desktop 1
        #expect(SpaceBarController.hitGlyphPID(at: CGPoint(x: 36, y: 12), in: 101, glyphFrames: frames) == 501)
        #expect(SpaceBarController.hitGlyphPID(at: CGPoint(x: 60, y: 12), in: 101, glyphFrames: frames) == 502)

        // Icon coordinates belonging to Desktop 2 never match when querying Desktop 1
        #expect(SpaceBarController.hitGlyphPID(at: CGPoint(x: 120, y: 12), in: 101, glyphFrames: frames) == nil)
        #expect(SpaceBarController.hitGlyphPID(at: CGPoint(x: 120, y: 12), in: 202, glyphFrames: frames) == 777)
    }

    @Test("canManageAppRules allows regular apps and excludes Rapto itself and System Settings")
    func manageableBundleIDs() {
        #expect(AppState.canManageAppRules(forBundleIdentifier: "com.mitchellh.ghostty", ownBundleIdentifier: "app.rapto.mac"))
        #expect(AppState.canManageAppRules(forBundleIdentifier: "com.apple.Safari", ownBundleIdentifier: "app.rapto.mac"))
        #expect(!AppState.canManageAppRules(forBundleIdentifier: nil, ownBundleIdentifier: "app.rapto.mac"))
        #expect(!AppState.canManageAppRules(forBundleIdentifier: "", ownBundleIdentifier: "app.rapto.mac"))
        #expect(!AppState.canManageAppRules(forBundleIdentifier: "app.rapto.mac", ownBundleIdentifier: "app.rapto.mac"))
        #expect(!AppState.canManageAppRules(forBundleIdentifier: "com.apple.systempreferences", ownBundleIdentifier: "app.rapto.mac"))
    }

    @Test("App submenu contains exactly Always Ignore and Pause Shortcuts, reflecting live state")
    @MainActor
    func appRulesSubmenuStructureAndToggle() {
        let appState = AppState()
        let savedIgnored = appState.ignoredApps
        let savedPassthrough = appState.passthroughApps
        let testBundleID = "com.example.rapto-submenu-test"
        defer {
            appState.ignoredApps = savedIgnored
            appState.passthroughApps = savedPassthrough
            appState.checkPassthroughState()
        }

        appState.removeIgnoredApp(testBundleID)
        appState.removePassthroughApp(testBundleID)

        let glyph = SpaceBarGlyph(
            pid: 99991,
            bundleIdentifier: testBundleID,
            appName: "Ghostty",
            icon: NSImage(),
            windows: []
        )

        guard let item = appState.appRulesSubmenuItem(for: glyph),
              let submenu = item.submenu else {
            Issue.record("Expected an app rules submenu item for a regular app glyph")
            return
        }

        #expect(item.title == "Ghostty")
        #expect(submenu.items.count == 2)
        #expect(submenu.items.map(\.title) == [
            "Always Ignore Ghostty",
            "Pause Shortcuts in Ghostty"
        ])
        #expect(submenu.items[0].state == .off)
        #expect(submenu.items[1].state == .off)

        appState.addIgnoredApp(testBundleID)
        appState.addPassthroughApp(testBundleID)

        let updatedSubmenu = appState.appRulesSubmenuItem(for: glyph)?.submenu
        #expect(updatedSubmenu?.items[0].state == .on)
        #expect(updatedSubmenu?.items[1].state == .on)
    }

    @Test("addIgnoredApp immediately evicts that app's windows from Manual layout slots")
    @MainActor
    func addIgnoredAppEvictsManualSlotsImmediately() {
        let appState = AppState()
        let savedIgnored = appState.ignoredApps
        let targetBundle = "com.example.evict-test-app"
        let keepBundle = "com.example.keep-test-app"
        let testScreen = "display-test-evict"
        defer {
            appState.layoutManager.clearLayout(forScreenID: testScreen)
            appState.ignoredApps = savedIgnored
        }

        appState.removeIgnoredApp(targetBundle)

        let w1 = WindowInfo(
            windowID: 9101,
            ownerPID: 9101,
            title: "Chat",
            ownerName: "TestChat",
            bundleIdentifier: targetBundle,
            frame: CGRect(x: 0, y: 0, width: 600, height: 600)
        )
        let w2 = WindowInfo(
            windowID: 9102,
            ownerPID: 9102,
            title: "Browser",
            ownerName: "TestBrowser",
            bundleIdentifier: keepBundle,
            frame: CGRect(x: 600, y: 0, width: 600, height: 600)
        )

        appState.layoutManager.setLayout(
            template: PredefinedTemplates.halvesVertical,
            windows: [w1, w2],
            forScreenID: testScreen
        )
        #expect(appState.layoutManager.state(forScreenID: testScreen).slots[0].primaryWindow?.windowID == 9101)
        #expect(appState.layoutManager.state(forScreenID: testScreen).slots[1].primaryWindow?.windowID == 9102)

        appState.addIgnoredApp(targetBundle)

        #expect(appState.layoutManager.state(forScreenID: testScreen).slots[0].isEmpty)
        #expect(appState.layoutManager.state(forScreenID: testScreen).slots[1].primaryWindow?.windowID == 9102)
    }

    @Test("addPassthroughApp and removePassthroughApp update hotkey suspension immediately for the frontmost app")
    @MainActor
    func passthroughUpdatesHotkeySuspensionImmediately() {
        guard let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return
        }
        let appState = AppState()
        let savedPassthrough = appState.passthroughApps
        let wasRecording = appState.isRecordingShortcut
        defer {
            appState.isRecordingShortcut = wasRecording
            appState.passthroughApps = savedPassthrough
            appState.checkPassthroughState()
        }

        appState.isRecordingShortcut = false
        appState.removePassthroughApp(frontBundleID)
        #expect(!appState.hotkeyManager.isSuspended)

        appState.addPassthroughApp(frontBundleID)
        #expect(appState.hotkeyManager.isSuspended)

        appState.removePassthroughApp(frontBundleID)
        #expect(!appState.hotkeyManager.isSuspended)
    }
}
