//
//  SettingsReorgTests.swift
//  RaptoTests
//
//  Tests for DragModifierMode flag mapping and SettingsSearch synonym matching.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Settings Reorganization Tests")
struct SettingsReorgTests {

    @Test("DragModifierMode maps every valid (swapRequiresOption, moveRequiresShift) pair")
    func dragModifierModeMapping() {
        #expect(DragModifierMode.from(swapRequiresControl: true, moveRequiresShift: false) == .moveByDefault)
        #expect(DragModifierMode.from(swapRequiresControl: false, moveRequiresShift: true) == .swapByDefault)
        #expect(DragModifierMode.from(swapRequiresControl: true, moveRequiresShift: true) == .modifiersOnly)
        // Disallowed (false, false) safely normalizes to the standard default
        #expect(DragModifierMode.from(swapRequiresControl: false, moveRequiresShift: false) == .moveByDefault)

        for mode in DragModifierMode.allCases {
            let flags = mode.flags
            #expect(DragModifierMode.from(swapRequiresControl: flags.swapRequiresControl, moveRequiresShift: flags.moveRequiresShift) == mode)
        }
    }

    @Test("Applying every DragModifierMode transition lands on the exact target flags")
    @MainActor
    func dragModifierModeTransitions() {
        let appState = AppState()
        let originalSwap = appState.swapRequiresOption
        let originalMove = appState.moveRequiresShift
        defer {
            // Restore original flags so test runs leave the developer's defaults untouched
            if originalSwap { appState.swapRequiresOption = true }
            if originalMove { appState.moveRequiresShift = true }
            appState.swapRequiresOption = originalSwap
            appState.moveRequiresShift = originalMove
        }

        for start in DragModifierMode.allCases {
            for target in DragModifierMode.allCases {
                start.apply(to: appState)
                target.apply(to: appState)
                #expect(appState.swapRequiresOption == target.flags.swapRequiresControl)
                #expect(appState.moveRequiresShift == target.flags.moveRequiresShift)
            }
        }
    }

    @Test("SettingsSearch finds target tabs by common user synonyms")
    func settingsSearchSynonyms() {
        #expect(SettingsSearch.filter(query: "").isEmpty)
        #expect(SettingsSearch.filter(query: "   ").isEmpty)

        let bounce = SettingsSearch.filter(query: "bounce")
        #expect(bounce.first?.id == "behavior.snapBack")
        #expect(bounce.first?.tab == .behavior)

        let jumpBack = SettingsSearch.filter(query: "jump back")
        #expect(jumpBack.contains { $0.id == "behavior.snapBack" })

        let zoom = SettingsSearch.filter(query: "zoom")
        #expect(zoom.first?.id == "behavior.focusMode")
        #expect(zoom.first?.tab == .behavior)

        let pin = SettingsSearch.filter(query: "pin")
        #expect(pin.first?.id == "behavior.floatingWindows")
        #expect(pin.first?.tab == .behavior)

        let border = SettingsSearch.filter(query: "border")
        #expect(border.first?.id == "appearance.activeHighlight")
        #expect(border.first?.tab == .appearance)

        let padding = SettingsSearch.filter(query: "padding")
        #expect(padding.first?.id == "appearance.windowGaps")
        #expect(padding.first?.tab == .appearance)

        let exclude = SettingsSearch.filter(query: "exclude")
        #expect(exclude.first?.id == "apps.ignoredApps")
        #expect(exclude.first?.tab == .apps)

        let ghostty = SettingsSearch.filter(query: "ghostty")
        #expect(ghostty.first?.id == "apps.passthroughApps")
        #expect(ghostty.first?.tab == .apps)

        let vim = SettingsSearch.filter(query: "vim")
        #expect(vim.contains { $0.id == "apps.passthroughApps" })
        #expect(vim.contains { $0.id == "shortcuts.presets" })
    }
}
