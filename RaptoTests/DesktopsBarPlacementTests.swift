//
//  DesktopsBarPlacementTests.swift
//  RaptoTests
//
//  Which slot a window gets when the Desktops Bar moves it to a Manual desktop.
//

import CoreGraphics
import Foundation
import Testing
@testable import Rapto

struct DesktopsBarPlacementTests {

    @Test func windowSharingASlotTakesTheFirstEmptyOne() {
        // It landed in slot 2 next to another window; slot 1 is empty
        #expect(AppState.emptySlotInsteadOfShared(current: 2, windowCounts: [1, 0, 2]) == 1)
        #expect(AppState.emptySlotInsteadOfShared(current: 0, windowCounts: [3, 1, 0, 0]) == 2)
    }

    @Test func windowAloneInItsSlotStays() {
        #expect(AppState.emptySlotInsteadOfShared(current: 2, windowCounts: [1, 0, 1]) == nil)
    }

    @Test func windowStaysWhenNoSlotIsEmpty() {
        #expect(AppState.emptySlotInsteadOfShared(current: 2, windowCounts: [1, 2, 2]) == nil)
    }

    @Test func slotOutOfRangeChangesNothing() {
        #expect(AppState.emptySlotInsteadOfShared(current: 5, windowCounts: [1, 0, 2]) == nil)
        #expect(AppState.emptySlotInsteadOfShared(current: -1, windowCounts: [1, 0, 2]) == nil)
        #expect(AppState.emptySlotInsteadOfShared(current: 0, windowCounts: []) == nil)
    }

    private func slot(_ index: Int, bundle: String?, group: [String]? = nil, pids: [Int32]? = nil) -> SavedLayoutInfo.SavedSlotInfo {
        SavedLayoutInfo.SavedSlotInfo(slotID: UUID(), index: index, ownerName: nil, bundleIdentifier: bundle,
                                      frame: nil, groupBundleIDs: group, groupPIDs: pids)
    }

    @Test func savedSlotIsFoundByProcessFirst() {
        let slots = [
            slot(0, bundle: "a", group: ["a", "x"], pids: [10, 11]),
            slot(1, bundle: "b", group: ["b"], pids: [20]),
            slot(2, bundle: "c", group: ["c", "x"], pids: [30, 31])
        ]
        // Two slots hold a window of app "x"; the process tells which one it was
        #expect(AppState.savedSlotIndex(pid: 31, bundleID: "x", in: slots) == 2)
        #expect(AppState.savedSlotIndex(pid: 11, bundleID: "x", in: slots) == 0)
    }

    @Test func savedSlotIsFoundByAppAfterARestart() {
        let slots = [
            slot(0, bundle: "a", group: ["a"], pids: [10]),
            slot(2, bundle: "c", group: ["c", "x"], pids: [30, 31])
        ]
        #expect(AppState.savedSlotIndex(pid: 999, bundleID: "x", in: slots) == 2)
        // Saved before groups were stored
        #expect(AppState.savedSlotIndex(pid: 999, bundleID: "a", in: [slot(1, bundle: "a")]) == 1)
    }

    @Test func appThatWasNotInTheLayoutHasNoSavedSlot() {
        let slots = [slot(0, bundle: "a", group: ["a"], pids: [10])]
        #expect(AppState.savedSlotIndex(pid: 999, bundleID: "z", in: slots) == nil)
        #expect(AppState.savedSlotIndex(pid: 999, bundleID: nil, in: slots) == nil)
    }

    @Test func windowThatLeftInThisSessionGoesBackToItsSlot() {
        // Its old group is still there and another slot is empty: it rejoins the group
        #expect(AppState.slotForRememberedWindow(remembered: 2, isFromThisSession: true, otherWindowCounts: [1, 0, 2]) == 2)
        #expect(AppState.slotForRememberedWindow(remembered: 2, isFromThisSession: true, otherWindowCounts: [1, 1, 0]) == 2)
    }

    @Test func storedSlotIsTakenWhileItIsFree() {
        #expect(AppState.slotForRememberedWindow(remembered: 2, isFromThisSession: false, otherWindowCounts: [1, 0, 0]) == 2)
    }

    @Test func storedSlotThatIsTakenGivesWayToAnEmptyOne() {
        #expect(AppState.slotForRememberedWindow(remembered: 2, isFromThisSession: false, otherWindowCounts: [1, 0, 1]) == 1)
    }

    @Test func storedSlotIsUsedWhenNoSlotIsEmpty() {
        #expect(AppState.slotForRememberedWindow(remembered: 2, isFromThisSession: false, otherWindowCounts: [1, 2, 1]) == 2)
    }

    @Test("Stale stored slot does not yank a moved window out of a matching slot when all slots are occupied")
    func storedSlotYieldsToCurrentSlotWhenAllSlotsAreOccupied() {
        // Hark arrived in big slot 2 matching its size; old UserDefaults memory points to occupied small slot 0.
        #expect(
            AppState.slotForRememberedWindow(
                remembered: 0,
                isFromThisSession: false,
                otherWindowCounts: [1, 1, 1],
                current: 2
            ) == 2
        )
        // A same-session return still wins over current even when all slots are occupied.
        #expect(
            AppState.slotForRememberedWindow(
                remembered: 0,
                isFromThisSession: true,
                otherWindowCounts: [1, 1, 1],
                current: 2
            ) == 0
        )
        // If an empty slot exists, the empty slot still wins over both stale memory and occupied current.
        #expect(
            AppState.slotForRememberedWindow(
                remembered: 0,
                isFromThisSession: false,
                otherWindowCounts: [1, 0, 1],
                current: 2
            ) == 1
        )
    }

    @Test func storedSlotOutOfRangeIsReturnedUnchanged() {
        #expect(AppState.slotForRememberedWindow(remembered: 7, isFromThisSession: false, otherWindowCounts: [1, 0, 1]) == 7)
    }

    // MARK: - Unassigned windows after Manual restore

    @Test("Unassigned window over an occupied slot takes an empty slot instead of piling up")
    func unassignedOverOccupiedSlotPrefersEmptySlot() {
        // Reproduces switching Auto-tiling -> Manual: slot 2 has Dia, slots 0 and 1 are empty.
        // Antigravity sits over empty slot 1; Simplenote sits over occupied slot 2.
        let result = AppState.unassignedRestoreSlots(
            containingSlots: [1, 2],
            initialWindowCounts: [0, 0, 1]
        )
        #expect(result == [1, 0])
    }

    @Test("Pass 1 reserves empty slots for windows already sitting over them regardless of order")
    func unassignedSittingOverEmptySlotIsNotStolenByEarlierWindow() {
        // Window 0 sits over occupied slot 0; Window 1 sits over empty slot 1; slot 2 is also empty.
        // Window 1 must keep slot 1, and Window 0 takes remaining empty slot 2.
        let result = AppState.unassignedRestoreSlots(
            containingSlots: [0, 1],
            initialWindowCounts: [1, 0, 0]
        )
        #expect(result == [2, 1])
    }

    @Test("When every slot is already occupied, an unassigned window joins the slot it sits over")
    func unassignedJoinsContainingSlotWhenNoSlotIsEmpty() {
        let result = AppState.unassignedRestoreSlots(
            containingSlots: [2, 0],
            initialWindowCounts: [1, 2, 1]
        )
        #expect(result == [2, 0])
    }

    @Test("Unassigned window over no slot returns nil so auto-grouping places it")
    func unassignedOutsideSlotsDelegatesToAutoGrouping() {
        let result = AppState.unassignedRestoreSlots(
            containingSlots: [nil, 2],
            initialWindowCounts: [0, 1, 1]
        )
        #expect(result == [nil, 0])
    }

    @Test("Multiple unassigned windows over occupied slots fill remaining empty slots then group")
    func multipleUnassignedFillEmptySlotsBeforeGrouping() {
        let result = AppState.unassignedRestoreSlots(
            containingSlots: [2, 2, 1],
            initialWindowCounts: [0, 1, 1]
        )
        // First takes empty slot 0; once full, second joins slot 2 and third joins slot 1
        #expect(result == [0, 2, 1])
    }

    // MARK: - Calm layout transitions

    @Test("Switching from active Auto-tiling to Manual inherits live grid even when an older snapshot exists")
    func manualModePrefersLiveAutoTilingOverStaleSnapshot() {
        #expect(
            AppState.manualModeRestoreSource(
                hasActiveAutoTiling: true,
                hasManualSnapshot: true,
                hasSavedLayout: true
            ) == .inheritAutoTiling
        )
        #expect(
            AppState.manualModeRestoreSource(
                hasActiveAutoTiling: false,
                hasManualSnapshot: true,
                hasSavedLayout: true
            ) == .restoreManualSnapshot
        )
        #expect(
            AppState.manualModeRestoreSource(
                hasActiveAutoTiling: false,
                hasManualSnapshot: false,
                hasSavedLayout: true
            ) == .restoreSavedLayout
        )
        #expect(
            AppState.manualModeRestoreSource(
                hasActiveAutoTiling: false,
                hasManualSnapshot: false,
                hasSavedLayout: false
            ) == .applyTemplate
        )
    }

    @Test("framesMatch skips windows already in place within tolerance")
    func framesMatchRespectsTolerance() {
        let target = CGRect(x: 100, y: 50, width: 800, height: 600)
        #expect(AccessibilityService.framesMatch(target, CGRect(x: 101, y: 49, width: 801.5, height: 599)))
        #expect(!AccessibilityService.framesMatch(target, CGRect(x: 102, y: 50, width: 800, height: 600)))
        #expect(!AccessibilityService.framesMatch(target, CGRect(x: 100, y: 50, width: 805, height: 600)))
    }

    @Test("groupTargetsByPID splits distinct apps for parallel dispatch while keeping same-app order")
    func groupTargetsByPIDPreservesPerAppOrder() {
        let buckets = AccessibilityService.groupTargetsByPID([
            (index: 0, pid: 10),
            (index: 1, pid: 20),
            (index: 2, pid: 10),
            (index: 3, pid: 30),
            (index: 4, pid: 20)
        ])
        #expect(buckets == [[0, 2], [1, 4], [3]])
    }

    @Test("Highlight fade-in duration shortens when Reduce Motion is enabled")
    func highlightFadeInRespectsReduceMotion() {
        let normal = WindowHighlightService.fadeInDuration(reduceMotion: false)
        let reduced = WindowHighlightService.fadeInDuration(reduceMotion: true)
        #expect(normal > reduced)
        #expect(reduced > 0)
    }
}
