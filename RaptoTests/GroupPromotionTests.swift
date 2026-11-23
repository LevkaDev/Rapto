import Testing
import CoreGraphics
import Foundation
@testable import Rapto

@Suite("Filling a slot whose windows are all minimized")
struct GroupPromotionTests {
    func window(_ id: CGWindowID) -> WindowInfo {
        WindowInfo(windowID: id, ownerPID: 1, title: "W\(id)", ownerName: "App", frame: .zero)
    }

    func slot(_ index: Int, _ ids: [CGWindowID]) -> Slot {
        Slot(id: UUID(), index: index, frame: .zero, windows: ids.map(window))
    }

    @Test("Takes a visible window from a later group when the first group is minimized")
    func skipsMinimizedGroup() throws {
        // Slot 0: everything minimized (the one to fill), slot 1: group with minimized windows, slot 2: visible group
        let slots = [slot(0, [1, 2]), slot(1, [3, 4]), slot(2, [5, 6])]
        let visible: Set<CGWindowID> = [3, 5, 6]
        let pick = try #require(AppState.groupWindowToPromote(into: 0, slots: slots, visibleWindowIDs: visible))
        #expect(pick.slotIndex == 2)
        #expect(pick.window.windowID == 6)
    }

    @Test("Never takes from the slot being filled")
    func skipsEmptySlotItself() {
        let slots = [slot(0, [1, 2]), slot(1, [3])]
        #expect(AppState.groupWindowToPromote(into: 0, slots: slots, visibleWindowIDs: [3]) == nil)
    }

    @Test("Keeps the front window of the group in place")
    func takesWindowBehindFront() throws {
        let slots = [slot(0, [1]), slot(1, [3, 4])]
        let pick = try #require(AppState.groupWindowToPromote(into: 0, slots: slots, visibleWindowIDs: [3, 4]))
        #expect(pick.slotIndex == 1)
        #expect(pick.window.windowID == 4)
    }
}
