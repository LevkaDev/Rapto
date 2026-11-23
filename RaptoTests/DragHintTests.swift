//
//  DragHintTests.swift
//  RaptoTests
//
//  Unit tests for DragHint copy rules, HintKeyID raw value stability,
//  and HintKeyStore 3-use learning threshold.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Drag Hint Tests")
struct DragHintTests {

    @Test("HintKeyID stored raw values never change")
    func hintKeyRawValuesAreStable() {
        #expect(HintKeyID.swapKey.rawValue == "swapKey")
        #expect(HintKeyID.moveKey.rawValue == "moveKey")
        #expect(HintKeyID.snapFreeKey.rawValue == "snapFreeKey")
        #expect(HintKeyID.spaceBarOptionKey.rawValue == "spaceBarOptionKey")
        #expect(HintKeyID.learnedThreshold == 10)
    }

    @Test("Disabled showsHints suppresses every drag hint")
    func disabledShowsHintsReturnsNil() {
        #expect(DragHint.swapOrMove(
            showsHints: false,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        ) == nil)
        #expect(DragHint.dragSnap(showsHints: false, learnedKeys: []) == nil)
    }

    @Test("Default settings (Move & Group on plain drag, Control to swap) match every table row")
    func defaultModifierSettings() {
        let ontoWindow = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(ontoWindow == DragHint(title: "Move here", detail: "Groups with Safari · Hold ⌃ to swap"))

        let sameApp = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: true),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(sameApp == DragHint(title: "Move here", detail: "Groups with the other Safari window · Hold ⌃ to swap"))

        let emptySlot = DragHint.swapOrMove(
            showsHints: true,
            target: .emptySlot,
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(emptySlot == DragHint(title: "Move here", detail: nil))

        let withControl = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: true,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(withControl == DragHint(title: "Swap", detail: "Release ⌃ to move"))
    }

    @Test("Swap by default (plain drag swaps, Shift moves & groups) matches every table row")
    func swapByDefaultSettings() {
        let plainSwap = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: false,
            moveRequiresShift: true,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(plainSwap == DragHint(title: "Swap", detail: "Hold ⇧ to move here"))

        let shiftMove = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: false,
            moveRequiresShift: true,
            controlPressed: false,
            shiftPressed: true,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(shiftMove == DragHint(title: "Move here", detail: "Groups with Safari · Release ⇧ to swap"))

        let shiftEmpty = DragHint.swapOrMove(
            showsHints: true,
            target: .emptySlot,
            requiresControlForSwap: false,
            moveRequiresShift: true,
            controlPressed: false,
            shiftPressed: true,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(shiftEmpty == DragHint(title: "Move here", detail: nil))
    }

    @Test("Both modifiers required (Control swaps, Shift moves, plain drag does nothing)")
    func bothModifiersRequired() {
        let plain = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: true,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(plain == nil)

        let controlSwap = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: true,
            controlPressed: true,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(controlSwap == DragHint(title: "Swap", detail: "Hold ⇧ instead to move"))

        let shiftMove = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: true,
            controlPressed: false,
            shiftPressed: true,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(shiftMove == DragHint(title: "Move here", detail: "Groups with Safari · Hold ⌃ to swap"))
    }

    @Test("Auto-tiling same-display swap, empty app name, and disabled grouping")
    func autoTilingEmptyNameAndGroupingOff() {
        let autoSwap = DragHint.swapOrMove(
            showsHints: true,
            target: .swapOnlyWindow,
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(autoSwap == DragHint(title: "Swap", detail: nil))

        let emptyOwner = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "   ", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: []
        )
        #expect(emptyOwner == DragHint(title: "Move here", detail: "Hold ⌃ to swap"))

        let groupingOff = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: false,
            learnedKeys: []
        )
        #expect(groupingOff == DragHint(title: "Move here", detail: "Hold ⌃ to swap"))
    }

    @Test("Modifier prompt disappears after 10 completed uses while non-key info stays")
    func tenUseLearningCounter() {
        let store = TestDefaults(prefix: "rapto.draghint.tests")
        defer { store.remove() }

        for expectedBefore in 0..<10 {
            #expect(HintKeyStore.count(for: .swapKey, in: store.defaults) == expectedBefore)
            #expect(!HintKeyStore.learnedKeys(in: store.defaults).contains(.swapKey))

            let hint = DragHint.swapOrMove(
                showsHints: true,
                target: .window(ownerName: "Safari", sameApp: false),
                requiresControlForSwap: true,
                moveRequiresShift: false,
                controlPressed: false,
                shiftPressed: false,
                isGroupingEnabled: true,
                learnedKeys: HintKeyStore.learnedKeys(in: store.defaults)
            )
            #expect(hint?.detail == "Groups with Safari · Hold ⌃ to swap")
            HintKeyStore.recordCompletedUse(of: .swapKey, in: store.defaults)
        }

        // At 10 completed uses, "Hold ⌃ to swap" disappears while "Groups with Safari" stays
        #expect(HintKeyStore.learnedKeys(in: store.defaults).contains(.swapKey))
        let afterTen = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: false,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: HintKeyStore.learnedKeys(in: store.defaults)
        )
        #expect(afterTen == DragHint(title: "Move here", detail: "Groups with Safari"))

        let controlSwapAfterTen = DragHint.swapOrMove(
            showsHints: true,
            target: .window(ownerName: "Safari", sameApp: false),
            requiresControlForSwap: true,
            moveRequiresShift: false,
            controlPressed: true,
            shiftPressed: false,
            isGroupingEnabled: true,
            learnedKeys: HintKeyStore.learnedKeys(in: store.defaults)
        )
        #expect(controlSwapAfterTen == DragHint(title: "Swap", detail: nil))

        #expect(DragHint.dragSnap(showsHints: true, learnedKeys: []) ==
                DragHint(title: "Snap here", detail: "Hold ⌥ to move freely"))
        #expect(DragHint.dragSnap(showsHints: true, learnedKeys: [.snapFreeKey]) ==
                DragHint(title: "Snap here", detail: nil))
    }
}
