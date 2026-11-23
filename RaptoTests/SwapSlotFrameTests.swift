//
//  SwapSlotFrameTests.swift
//  RaptoTests
//
//  Where a swap puts the window that was not dragged.
//

import Testing
import CoreGraphics
import Foundation
@testable import Rapto

@MainActor
struct SwapSlotFrameTests {

    private let slotFrame = CGRect(x: 8, y: 34, width: 1342, height: 753)

    private func state(holding windowID: CGWindowID) -> LayoutState {
        var slot = Slot(id: UUID(), index: 0, frame: slotFrame)
        // The window list shows the window where the drag has already taken it
        slot.addWindow(WindowInfo(
            windowID: windowID, ownerPID: 100, title: "", ownerName: "App", bundleIdentifier: "com.test.app",
            frame: CGRect(x: 380, y: 85, width: 1342, height: 753)
        ))
        var state = LayoutState()
        state.template = PredefinedTemplates.halvesVertical
        state.slots = [slot]
        return state
    }

    @Test("A swap lands on the slot's frame in the modes that keep windows in slots",
          arguments: [TilingMode.manualAssignment, .autoTiling])
    func slotFrameIsUsed(mode: TilingMode) {
        #expect(AppState.swapSlotFrame(holding: 7, on: [(mode: mode, state: state(holding: 7))]) == slotFrame)
    }

    @Test("Without slots the swap falls back to the windows' own frames",
          arguments: [TilingMode.none, .dragSnap])
    func noSlotFrameWithoutSlots(mode: TilingMode) {
        #expect(AppState.swapSlotFrame(holding: 7, on: [(mode: mode, state: state(holding: 7))]) == nil)
    }

    @Test("A window in no slot has no slot frame")
    func unknownWindow() {
        #expect(AppState.swapSlotFrame(holding: 9, on: [(mode: .manualAssignment, state: state(holding: 7))]) == nil)
        #expect(AppState.swapSlotFrame(holding: 7, on: [(mode: .manualAssignment, state: LayoutState())]) == nil)
    }
}
