//
//  SetupGuideTests.swift
//  RaptoTests
//
//  Tests for Guide tab ordering, AppSuggestionScanner filtering and built-in exclusion hygiene,
//  and live GuideGestureCopy shortcut & modifier generation.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Setup Guide Tests")
struct SetupGuideTests {

    @Test("Guide is the first Settings tab")
    func guideIsFirstTab() {
        #expect(SettingsTab.allCases.first == .guide)
    }

    @Test("AppSuggestionScanner excludes utilities already handled by WindowClassifier or default ignored apps")
    func scannerCandidateHygiene() {
        let allCandidateIDs = Set(
            AppSuggestionScanner.optionalIgnoredCandidates.map(\.bundleIdentifier) +
            AppSuggestionScanner.passthroughCandidates.map(\.bundleIdentifier)
        )

        // Built-in WindowClassifier / default ignored utilities must never be offered in Smart App Scanner
        let alreadyFilteredByRapto: Set<String> = [
            "com.apple.calculator",
            "com.apple.Stickies",
            "com.apple.systempreferences",
            "com.apple.Spotlight",
            "pl.maketheweb.cleanshotx"
        ]

        #expect(allCandidateIDs.isDisjoint(with: alreadyFilteredByRapto))
    }

    @Test("AppSuggestionScanner filters by installed bundle IDs and respects dismissedAppSuggestions")
    func scannerFilteringAndDismissal() {
        let installed: [String: String] = [
            "com.mitchellh.ghostty": "Ghostty",
            "org.vim.MacVim": "",
            "com.spotify.client": "Spotify",
            "ru.keepcoder.Telegram": "Telegram",
            "com.apple.Safari": "Safari"
        ]

        let passthrough = AppSuggestionScanner.filterCandidates(
            AppSuggestionScanner.passthroughCandidates,
            installedByBundleID: installed,
            dismissed: ["org.vim.MacVim"]
        )
        #expect(passthrough.map(\.bundleIdentifier) == ["com.mitchellh.ghostty"])
        #expect(passthrough.first?.name == "Ghostty")

        // Fallback name is used when localizedName is empty
        let passthroughNoneDismissed = AppSuggestionScanner.filterCandidates(
            AppSuggestionScanner.passthroughCandidates,
            installedByBundleID: installed,
            dismissed: []
        )
        #expect(passthroughNoneDismissed.map(\.bundleIdentifier) == ["com.mitchellh.ghostty", "org.vim.MacVim"])
        #expect(passthroughNoneDismissed.last?.name == "MacVim")

        let optionalIgnored = AppSuggestionScanner.filterCandidates(
            AppSuggestionScanner.optionalIgnoredCandidates,
            installedByBundleID: installed,
            dismissed: ["com.spotify.client"]
        )
        #expect(optionalIgnored.map(\.bundleIdentifier) == ["ru.keepcoder.Telegram"])
    }

    @Test("GuideGestureCopy reflects all DragModifierMode states and live HotkeyPreset bindings")
    func liveGestureCopyReflectsSettings() {
        var snapshot = GuideGestureCopy.Snapshot(
            dragMode: .moveByDefault,
            isGroupingEnabled: true,
            enableScrollToSwitch: true,
            focusModeEnabled: true,
            focusModeDoubleTapEnabled: true,
            focusModeDoubleTapModifier: .option,
            hasCustomFocusZone: false,
            floatingDoubleTapEnabled: false,
            floatingDoubleTapModifier: .optionCommand,
            spaceBarMoveFollowsWindow: false,
            bindings: HotkeyPreset.rapto.bindings
        )

        let moveCard = GuideGestureCopy.draggingCard(for: snapshot)
        #expect(moveCard.badges == ["⌃"])
        #expect(moveCard.detail.contains("plain drag moves into a slot"))
        #expect(moveCard.detail.contains("Auto-tiling"))

        snapshot.dragMode = .swapByDefault
        let swapCard = GuideGestureCopy.draggingCard(for: snapshot)
        #expect(swapCard.badges == ["⇧"])
        #expect(swapCard.detail.contains("plain drag swaps slots"))

        snapshot.dragMode = .modifiersOnly
        let bothCard = GuideGestureCopy.draggingCard(for: snapshot)
        #expect(bothCard.badges == ["⌃", "⇧"])
        #expect(bothCard.detail.contains("plain drag is ignored"))

        let raptoCards = GuideGestureCopy.cards(for: snapshot)
        let raptoSwitcher = raptoCards.first { $0.id == "switcherResize" }
        let raptoGroup = raptoCards.first { $0.id == "grouping" }
        #expect(raptoSwitcher?.detail.contains("⌃⌥W") == true)
        #expect(raptoGroup?.badges == ["⌃Tab"])

        snapshot.bindings = HotkeyPreset.vimStyle.bindings
        snapshot.spaceBarMoveFollowsWindow = true
        let vimCards = GuideGestureCopy.cards(for: snapshot)
        let vimSwitcher = vimCards.first { $0.id == "switcherResize" }
        let vimGroup = vimCards.first { $0.id == "grouping" }
        let barCard = vimCards.first { $0.id == "desktopsBar" }
        #expect(vimSwitcher?.detail.contains("⌥W") == true)
        #expect(vimGroup?.badges == ["⌥]"])
        #expect(barCard?.detail.contains("switches to that desktop by default") == true)
    }
}
