import Testing
import AppKit
@testable import Rapto

@MainActor
@Suite("Overlay ESC key")
struct OverlayEscapeTests {
    @Test("The overlay listens for ESC only while it is shown")
    func escapeMonitorFollowsVisibility() {
        let controller = OverlayWindowController(contentView: NSView())
        #expect(!controller.isListeningForEscape)

        controller.show()
        #expect(controller.isListeningForEscape)

        controller.hide()
        #expect(!controller.isListeningForEscape)

        controller.show()
        controller.hide()
        #expect(!controller.isListeningForEscape)
    }
}
