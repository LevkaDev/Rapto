//
//  ShortcutResizeTests.swift
//  RaptoTests
//
//  Which border of a slot a resize shortcut moves.
//

import Testing
import CoreGraphics
@testable import Rapto

@MainActor
struct ShortcutResizeTests {

    // Two slots stacked on the left, one tall slot on the right, 12 pt between them
    private let topLeft = CGRect(x: 8, y: 34, width: 1342, height: 753)
    private let bottomLeft = CGRect(x: 8, y: 799, width: 1342, height: 787)
    private let right = CGRect(x: 1362, y: 34, width: 2470, height: 1552)

    private var slots: [Int: CGRect] { [0: topLeft, 1: bottomLeft, 2: right] }

    private func stepped(_ index: Int, _ direction: HotkeyManager.ResizeDirection) -> CGRect? {
        WindowResizeService.steppedFrame(ofSlot: index, direction: direction, step: 50, slotFrames: slots)
    }

    @Test("With a neighbour on the right, the right border moves")
    func rightBorderMoves() {
        #expect(stepped(0, .growWidth) == CGRect(x: 8, y: 34, width: 1392, height: 753))
        #expect(stepped(0, .shrinkWidth) == CGRect(x: 8, y: 34, width: 1292, height: 753))
    }

    @Test("In the rightmost slot the left border moves, and the right edge stays at the screen edge")
    func leftBorderMovesInTheRightmostSlot() {
        #expect(stepped(2, .growWidth) == CGRect(x: 1312, y: 34, width: 2520, height: 1552))
        #expect(stepped(2, .shrinkWidth) == CGRect(x: 1412, y: 34, width: 2420, height: 1552))
    }

    @Test("With a neighbour below, the bottom border moves")
    func bottomBorderMoves() {
        #expect(stepped(0, .growHeight) == CGRect(x: 8, y: 34, width: 1342, height: 803))
        #expect(stepped(0, .shrinkHeight) == CGRect(x: 8, y: 34, width: 1342, height: 703))
    }

    @Test("In the bottom slot the top border moves")
    func topBorderMovesInTheBottomSlot() {
        #expect(stepped(1, .growHeight) == CGRect(x: 8, y: 749, width: 1342, height: 837))
        #expect(stepped(1, .shrinkHeight) == CGRect(x: 8, y: 849, width: 1342, height: 737))
    }

    @Test("A slot with no neighbour above or below keeps its height")
    func noNeighbourOnThatAxis() {
        #expect(stepped(2, .growHeight) == nil)
        #expect(stepped(2, .shrinkHeight) == nil)
    }

    @Test("A single slot can't be resized")
    func singleSlot() {
        let frame = WindowResizeService.steppedFrame(ofSlot: 0, direction: .growWidth, step: 50, slotFrames: [0: right])
        #expect(frame == nil)
    }
}
