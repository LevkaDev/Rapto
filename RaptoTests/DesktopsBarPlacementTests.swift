//
//  DesktopsBarPlacementTests.swift
//  RaptoTests
//
//  Which slot a window gets when the Desktops Bar moves it to a Manual desktop.
//

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

    @Test func storedSlotOutOfRangeIsReturnedUnchanged() {
        #expect(AppState.slotForRememberedWindow(remembered: 7, isFromThisSession: false, otherWindowCounts: [1, 0, 1]) == 7)
    }
}
