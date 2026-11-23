import Testing
import Carbon.HIToolbox
@testable import Rapto

@Suite("Shortcut conflicts with Rapto's own shortcuts")
struct HotkeyConflictTests {
    let ctrlOptLeft = HotkeyBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey))
    let ctrlOptRight = HotkeyBinding(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey))

    var shortcuts: [RaptoShortcut] {
        [
            RaptoShortcut(rowID: "action-focus_left", name: "Focus Left", binding: ctrlOptLeft),
            RaptoShortcut(rowID: "template-1", name: "Two Columns", binding: ctrlOptRight),
        ]
    }

    @Test("A row may take its own shortcut again")
    func ownShortcut() {
        #expect(HotkeyConflictDetector.raptoConflict(for: ctrlOptLeft, rowID: "action-focus_left", in: shortcuts) == nil)
    }

    @Test("Another row's shortcut names that row")
    func otherRowShortcut() {
        let conflict = HotkeyConflictDetector.raptoConflict(for: ctrlOptRight, rowID: "action-focus_left", in: shortcuts)
        #expect(conflict?.name == "Two Columns")
    }

    @Test("A shortcut Rapto doesn't use is no conflict")
    func freeShortcut() {
        let free = HotkeyBinding(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(HotkeyConflictDetector.raptoConflict(for: free, rowID: "action-focus_left", in: shortcuts) == nil)
    }
}
