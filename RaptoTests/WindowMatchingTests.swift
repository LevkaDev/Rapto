import Testing
import CoreGraphics
@testable import Rapto

@Suite("Finding the right window of an app")
struct WindowMatchingTests {
    @Test("A title only identifies a window when no other window of the app has it")
    func titleMatching() {
        #expect(AccessibilityService.titleIdentifiesWindow("Notes", among: ["Notes", "zsh"]))
        #expect(!AccessibilityService.titleIdentifiesWindow("zsh", among: ["zsh", "zsh", "Notes"]))
        #expect(!AccessibilityService.titleIdentifiesWindow("", among: ["", "Notes"]))
        #expect(!AccessibilityService.titleIdentifiesWindow("Gone", among: ["Notes", nil]))
    }

    @Test("Z-order counts only the windows at the same place")
    func zIndexAmongColocated() {
        // Front to back: A in slot 1, then B and C grouped in slot 2
        let windows: [(id: CGWindowID, origin: CGPoint)] = [
            (1, CGPoint(x: 0, y: 25)),
            (2, CGPoint(x: 960, y: 25)),
            (3, CGPoint(x: 962, y: 25)),
        ]
        let slot2 = CGPoint(x: 960, y: 25)
        #expect(AccessibilityService.zIndex(of: 2, among: windows, near: slot2, tolerance: 50) == 0)
        #expect(AccessibilityService.zIndex(of: 3, among: windows, near: slot2, tolerance: 50) == 1)
        #expect(AccessibilityService.zIndex(of: 1, among: windows, near: CGPoint(x: 0, y: 25), tolerance: 50) == 0)
        #expect(AccessibilityService.zIndex(of: 9, among: windows, near: slot2, tolerance: 50) == nil)
    }
}
