//
//  OneTimeHintsTests.swift
//  RaptoTests
//
//  Unit tests for HintID stability, OneTimeHintScheduler 10-display limit,
//  cross-hint cooldown and deferral rules, and live copy builders.
//

import Foundation
import Testing
@testable import Rapto

@Suite("Contextual Hints Tests")
struct OneTimeHintsTests {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "app.rapto.tests.onetimehints.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test("HintID stored raw values and display thresholds never change unexpectedly")
    func hintIDRawValuesAreStable() {
        #expect(HintID.manualNeedsLayout.rawValue == "manualNeedsLayout")
        #expect(HintID.snapBack.rawValue == "snapBack")
        #expect(HintID.groupBadge.rawValue == "groupBadge")
        #expect(HintID.focusMode.rawValue == "focusMode")
        #expect(HintID.notchDesktopsBar.rawValue == "notchDesktopsBar")
        #expect(HintID.secondDesktopCreated.rawValue == "secondDesktopCreated")
        #expect(HintID.manyWindowsFlow.rawValue == "manyWindowsFlow")
        #expect(HintID.workspacesTip.rawValue == "workspacesTip")
        #expect(HintID.allCases.count == 8)
        #expect(OneTimeHintScheduler.maxDisplays == 10)
        #expect(HintID.notchDesktopsBar.maxDisplays == 2)
        #expect(HintID.secondDesktopCreated.maxDisplays == 2)
        #expect(HintID.manyWindowsFlow.maxDisplays == 2)
        #expect(HintID.workspacesTip.maxDisplays == 2)
    }

    @Test("Progressive discovery policy gates Desktops Bar, Window Flow, and Workspaces tips cleanly")
    func progressiveDiscoveryPolicyRules() {
        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestDesktopsBar(desktopCount: 1, showsSpaceBar: true))
        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestDesktopsBar(desktopCount: 2, showsSpaceBar: false))
        #expect(ProgressiveDiscoveryPolicy.shouldSuggestDesktopsBar(desktopCount: 2, showsSpaceBar: true))

        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestWindowFlow(tilableWindowCount: 3))
        #expect(ProgressiveDiscoveryPolicy.shouldSuggestWindowFlow(tilableWindowCount: 4))

        let start = Date(timeIntervalSince1970: 10_000)
        let afterOneDay = start.addingTimeInterval(24 * 3600)
        let afterTwoDays = start.addingTimeInterval(48 * 3600)

        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestWorkspaces(
            distinctAppCount: 3, savedWorkspaceCount: 0, completedOnboardingAt: nil, now: afterTwoDays
        ))
        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestWorkspaces(
            distinctAppCount: 2, savedWorkspaceCount: 0, completedOnboardingAt: start, now: afterTwoDays
        ))
        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestWorkspaces(
            distinctAppCount: 4, savedWorkspaceCount: 1, completedOnboardingAt: start, now: afterTwoDays
        ))
        #expect(!ProgressiveDiscoveryPolicy.shouldSuggestWorkspaces(
            distinctAppCount: 4, savedWorkspaceCount: 0, completedOnboardingAt: start, now: afterOneDay
        ))
        #expect(ProgressiveDiscoveryPolicy.shouldSuggestWorkspaces(
            distinctAppCount: 3, savedWorkspaceCount: 0, completedOnboardingAt: start, now: afterTwoDays
        ))
    }

    @Test("Progressive discovery hint cards carry clear copy and handle unbound shortcuts")
    func progressiveDiscoveryHintCopy() {
        #expect(OneTimeHintCopy.secondDesktopCreated == HintCardContent(
            icon: "menubar.rectangle",
            title: "Switch Desktops Faster",
            detail: "Use the Desktops Bar to jump between desktops or drag apps across"
        ))
        #expect(OneTimeHintCopy.manyWindowsFlow(shortcut: "⌥⇥") == HintCardContent(
            icon: "rectangle.stack.badge.play",
            title: "Lots of Windows Open?",
            detail: "Press ⌥⇥ to flip through every window visually"
        ))
        #expect(OneTimeHintCopy.manyWindowsFlow(shortcut: nil) == HintCardContent(
            icon: "rectangle.stack.badge.play",
            title: "Lots of Windows Open?",
            detail: "Open Settings → Shortcuts to set a key for Window Flow"
        ))
        #expect(OneTimeHintCopy.workspacesTip == HintCardContent(
            icon: "square.stack.3d.up",
            title: "Save This Setup as a Workspace",
            detail: "Open the Rapto menu → Workspaces to reopen these apps in one click"
        ))
    }

    @Test("Progressive discovery hints retire early when user uses the feature")
    func progressiveDiscoveryHintsRetireEarly() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scheduler = OneTimeHintScheduler(defaults: defaults)
        for hint in [HintID.secondDesktopCreated, .manyWindowsFlow, .workspacesTip] {
            #expect(scheduler.request(hint, showsHints: true) == .showNow(count: 1))
            scheduler.markCompleted(hint)
            #expect(scheduler.isExhausted(hint))
            #expect(scheduler.request(hint, showsHints: true) == .exhausted)
        }
    }

    @Test("Notch Desktops Bar hint caps at 2 displays and retires immediately once user reveals the bar")
    func notchDesktopsBarLimitAndEarlyCompletion() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scheduler = OneTimeHintScheduler(defaults: defaults)
        #expect(scheduler.request(.notchDesktopsBar, showsHints: true) == .showNow(count: 1))
        scheduler.didHideCurrentHint()
        #expect(scheduler.request(.notchDesktopsBar, showsHints: true) == .showNow(count: 2))
        scheduler.didHideCurrentHint()
        #expect(scheduler.isExhausted(.notchDesktopsBar))
        #expect(scheduler.request(.notchDesktopsBar, showsHints: true) == .exhausted)

        // Reset and verify early completion after a single display
        defaults.removeObject(forKey: OneTimeHintScheduler.countsDefaultsKey)
        scheduler.resetState()

        #expect(scheduler.request(.notchDesktopsBar, showsHints: true) == .showNow(count: 1))
        scheduler.markCompleted(.notchDesktopsBar)
        #expect(scheduler.currentlyShowing == nil)
        #expect(scheduler.isExhausted(.notchDesktopsBar))
        #expect(scheduler.request(.notchDesktopsBar, showsHints: true) == .exhausted)
    }

    @Test("Notch Desktops Bar and Auto-tiling snap-back hint cards carry expected copy")
    func notchDesktopsBarAndAutoTilingCopy() {
        let card = OneTimeHintCopy.notchDesktopsBar
        #expect(card.showsUpwardPointer == true)
        #expect(card.title == "Desktops Bar Is Up Here")
        #expect(card.detail?.contains("notch") == true)

        let autoSnapBack = OneTimeHintCopy.autoTilingSnapBack
        #expect(autoSnapBack.showsUpwardPointer == false)
        #expect(autoSnapBack.title == "Auto-tiling Keeps Windows in Place")
        #expect(autoSnapBack.detail?.contains("swap") == true)
        #expect(autoSnapBack.detail?.contains("pause") == true)
    }

    @Test("Scheduler shows each HintID 10 times before retiring and allows immediate repeat after hide")
    func showsTenTimesThenRetires() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var clock = Date(timeIntervalSince1970: 1_000)
        let scheduler = OneTimeHintScheduler(defaults: defaults, now: { clock })

        for expected in 1...10 {
            #expect(scheduler.request(.focusMode, showsHints: true) == .showNow(count: expected))
            // Duplicate trigger while still visible does not burn an extra count
            #expect(scheduler.request(.focusMode, showsHints: true) == .alreadyVisible)
            #expect(scheduler.displayCount(for: .focusMode) == expected)
            clock.addTimeInterval(2)
            scheduler.didHideCurrentHint()
        }

        #expect(scheduler.isExhausted(.focusMode))
        #expect(scheduler.request(.focusMode, showsHints: true) == .exhausted)
    }

    @Test("Legacy shownHints array migrates cleanly as 1 of 10 displays")
    func legacyShownHintsCountsAsOne() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["snapBack"], forKey: OneTimeHintScheduler.legacyDefaultsKey)
        let scheduler = OneTimeHintScheduler(defaults: defaults)
        #expect(scheduler.displayCount(for: .snapBack) == 1)
        #expect(!scheduler.isExhausted(.snapBack))
        #expect(scheduler.request(.snapBack, showsHints: true) == .showNow(count: 2))
    }

    @Test("Disabled showsHints suppresses without incrementing shownHintCounts")
    func suppressedWhenShowsHintsOff() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scheduler = OneTimeHintScheduler(defaults: defaults)
        #expect(scheduler.request(.snapBack, showsHints: false) == .suppressed)
        #expect(scheduler.displayCount(for: .snapBack) == 0)

        #expect(scheduler.request(.snapBack, showsHints: true) == .showNow(count: 1))
        #expect(scheduler.displayCount(for: .snapBack) == 1)
    }

    @Test("New user action replaces an older tip immediately; simultaneous side-effect skips without counting")
    func immediateActionReplacementAndSimultaneousGuard() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var clock = Date(timeIntervalSince1970: 1_000)
        let scheduler = OneTimeHintScheduler(defaults: defaults, now: { clock })

        #expect(scheduler.request(.manualNeedsLayout, showsHints: true) == .showNow(count: 1))

        // 0.1s later (same composite action): skipped without burning a count
        clock.addTimeInterval(0.1)
        #expect(scheduler.request(.groupBadge, showsHints: true) == .simultaneousSkipped)
        #expect(scheduler.displayCount(for: .groupBadge) == 0)

        // 2s later (distinct user action, e.g. dragging a window into a group right after SnapBack):
        // shows immediately with zero 20s delay!
        clock.addTimeInterval(2.0)
        #expect(scheduler.request(.groupBadge, showsHints: true) == .showNow(count: 1))
        scheduler.didHideCurrentHint()

        // Duplicate indicator update 0.5s later does not burn another count
        clock.addTimeInterval(0.5)
        #expect(scheduler.request(.groupBadge, showsHints: true) == .cooldownSkipped)
        #expect(scheduler.displayCount(for: .groupBadge) == 1)

        clock.addTimeInterval(3.0)
        #expect(scheduler.request(.groupBadge, showsHints: true) == .showNow(count: 2))
    }

    @Test("Clearing shownHintCounts and shownHints resets counts back to zero")
    func resetRestoresEligibility() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let scheduler = OneTimeHintScheduler(defaults: defaults, maxDisplayCount: 2)
        #expect(scheduler.request(.focusMode, showsHints: true) == .showNow(count: 1))
        scheduler.didHideCurrentHint()
        #expect(scheduler.request(.focusMode, showsHints: true) == .showNow(count: 2))
        scheduler.didHideCurrentHint()
        #expect(scheduler.request(.focusMode, showsHints: true) == .exhausted)

        // Simulate "Show Hints Again"
        defaults.removeObject(forKey: OneTimeHintScheduler.countsDefaultsKey)
        defaults.removeObject(forKey: OneTimeHintScheduler.legacyDefaultsKey)
        scheduler.resetState()

        #expect(scheduler.displayCount(for: .focusMode) == 0)
        #expect(scheduler.request(.focusMode, showsHints: true) == .showNow(count: 1))
    }

    @Test("OneTimeHintCopy builds structured HUD cards with live shortcuts and omits cleared ones")
    func oneTimeHintCopyFormatting() {
        #expect(
            OneTimeHintCopy.manualNeedsLayout(overlayShortcut: "⌃⌥G")
                == HintCardContent(
                    icon: "rectangle.3.group",
                    title: "Choose a Layout",
                    detail: "Right-click this desktop → Layout, or press ⌃⌥G"
                )
        )
        #expect(
            OneTimeHintCopy.manualNeedsLayout(overlayShortcut: nil)
                == HintCardContent(
                    icon: "rectangle.3.group",
                    title: "Choose a Layout",
                    detail: "Right-click this desktop in the bar → Layout"
                )
        )

        #expect(
            OneTimeHintCopy.groupBadge(enableScroll: true, cycleShortcut: "⌃⇥")
                == HintCardContent(
                    icon: "rectangle.stack.fill",
                    title: "Window Group",
                    detail: "Scroll the badge or press ⌃⇥ to switch"
                )
        )
        #expect(
            OneTimeHintCopy.groupBadge(enableScroll: false, cycleShortcut: "⌃⇥")
                == HintCardContent(
                    icon: "rectangle.stack.fill",
                    title: "Window Group",
                    detail: "Click an icon in the badge or press ⌃⇥ to switch"
                )
        )
        #expect(
            OneTimeHintCopy.groupBadge(enableScroll: true, cycleShortcut: nil)
                == HintCardContent(
                    icon: "rectangle.stack.fill",
                    title: "Window Group",
                    detail: "Scroll or click the badge to switch windows"
                )
        )

        #expect(
            OneTimeHintCopy.focusMode(doubleTapEnabled: true, modifierSymbol: "⌥", shortcut: "⌃⌥F")
                == HintCardContent(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Focus Mode",
                    detail: "⌥ double-click or press ⌃⌥F to restore"
                )
        )
        #expect(
            OneTimeHintCopy.focusMode(doubleTapEnabled: false, modifierSymbol: "⌥", shortcut: "⌃⌥F")
                == HintCardContent(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Focus Mode",
                    detail: "Press ⌃⌥F to restore"
                )
        )
        #expect(
            OneTimeHintCopy.focusMode(doubleTapEnabled: true, modifierSymbol: "⇧", shortcut: nil)
                == HintCardContent(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Focus Mode",
                    detail: "⇧ double-click to restore"
                )
        )
    }

    @Test("Desktops Bar drag cards reflect desktop number, + button, follow setting, ⌥ state, and learned counter")
    func spaceBarDragCopyFormatting() {
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: 3,
                movesFollowWindow: false,
                optionPressed: false,
                learnedKeys: []
            ) == HintCardContent(
                icon: "arrow.right.square.fill",
                title: "Move to Desktop 3",
                detail: "Hold ⌥ to go there too"
            )
        )
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: 3,
                movesFollowWindow: false,
                optionPressed: true,
                learnedKeys: []
            ) == HintCardContent(
                icon: "arrow.right.square.fill",
                title: "Move to Desktop 3",
                detail: "Going there too · ⌥"
            )
        )
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: nil,
                movesFollowWindow: true,
                optionPressed: false,
                learnedKeys: []
            ) == HintCardContent(
                icon: "plus.rectangle.on.rectangle",
                title: "Move to New Desktop",
                detail: "Hold ⌥ to stay here"
            )
        )
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: nil,
                movesFollowWindow: true,
                optionPressed: true,
                learnedKeys: []
            ) == HintCardContent(
                icon: "plus.rectangle.on.rectangle",
                title: "Move to New Desktop",
                detail: "Staying on this desktop · ⌥"
            )
        )
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: 2,
                movesFollowWindow: false,
                optionPressed: false,
                learnedKeys: [.spaceBarOptionKey]
            ) == HintCardContent(
                icon: "arrow.right.square.fill",
                title: "Move to Desktop 2",
                detail: nil
            )
        )
        #expect(
            OneTimeHintCopy.spaceBarDrag(
                targetDesktopNumber: 2,
                movesFollowWindow: false,
                optionPressed: true,
                learnedKeys: [.spaceBarOptionKey]
            ) == HintCardContent(
                icon: "arrow.right.square.fill",
                title: "Move to Desktop 2",
                detail: "Going there too · ⌥"
            )
        )
    }

    @Test("HintTextSegment tokenizes inline keycaps while preserving menu arrows and prose")
    func keycapSegmentation() {
        #expect(
            HintTextSegment.parse("Scroll the badge or press ⌃⇥ to switch") == [
                .text("Scroll the badge or press"),
                .keycap("⌃⇥"),
                .text("to switch")
            ]
        )
        #expect(
            HintTextSegment.parse("Right-click this desktop → Layout, or press ⌃⌥G") == [
                .text("Right-click this desktop → Layout, or press"),
                .keycap("⌃⌥G")
            ]
        )
        #expect(
            HintTextSegment.parse("⌥ double-click or press ⌃⌥F to restore") == [
                .keycap("⌥"),
                .text("double-click or press"),
                .keycap("⌃⌥F"),
                .text("to restore")
            ]
        )

        let autoNotice = HintCardContent.fromNotice("Auto Tiling arranges this desktop itself. Switch to Manual to pick a layout")
        #expect(autoNotice == HintCardContent(
            icon: "wand.and.stars",
            title: "Auto Tiling arranges this desktop itself",
            detail: "Switch to Manual to pick a layout",
            isWarning: false
        ))
    }
}
