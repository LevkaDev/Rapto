import AppKit
import Testing
@testable import Rapto

@Suite("Option + click on another app")
struct OptionClickTests {
    typealias Window = DoubleClickGuard.WindowUnderPoint

    static let own: pid_t = 1
    static let front: pid_t = 10
    static let other: pid_t = 20
    static let point = CGPoint(x: 100, y: 100)
    static let area = CGRect(x: 0, y: 0, width: 500, height: 500)

    func activates(_ windows: [Window]) -> Bool {
        DoubleClickGuard.activatesOtherApp(at: Self.point, windowsFrontToBack: windows,
                                           frontmostPID: Self.front, ownPID: Self.own)
    }

    @Test("A window of a background app activates it")
    func otherApp() {
        #expect(activates([Window(pid: Self.other, layer: 0, bounds: Self.area)]))
    }

    @Test("A window of the front app doesn't")
    func frontApp() {
        #expect(!activates([Window(pid: Self.front, layer: 0, bounds: Self.area)]))
    }

    @Test("Rapto's own border or badge on top is looked through")
    func ownOverlayOnTop() {
        #expect(activates([
            Window(pid: Self.own, layer: 25, bounds: Self.area),
            Window(pid: Self.other, layer: 0, bounds: Self.area)
        ]))
    }

    @Test("The Dock, the menu bar or another overlay on top is left alone")
    func otherLayerOnTop() {
        #expect(!activates([
            Window(pid: Self.other, layer: 20, bounds: Self.area),
            Window(pid: Self.other, layer: 0, bounds: Self.area)
        ]))
    }

    @Test("Only the window under the point counts")
    func windowElsewhere() {
        #expect(!activates([
            Window(pid: Self.other, layer: 0, bounds: CGRect(x: 600, y: 600, width: 100, height: 100)),
            Window(pid: Self.front, layer: 0, bounds: Self.area)
        ]))
    }

    @Test("A marked click gets Option back, other clicks keep their modifiers")
    func markedClickKeepsOption() throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let marked = try #require(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                          mouseCursorPosition: Self.point, mouseButton: .left))
        marked.flags = []
        marked.setIntegerValueField(.eventSourceUserData, value: DoubleClickGuard.strippedOptionMarker)
        let plain = try #require(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                         mouseCursorPosition: Self.point, mouseButton: .left))
        plain.flags = []

        #expect(DoubleClickGuard.heldModifiers(of: try #require(NSEvent(cgEvent: marked))).contains(.option))
        #expect(!DoubleClickGuard.heldModifiers(of: try #require(NSEvent(cgEvent: plain))).contains(.option))
    }
}

@Suite("Double-click guard lifetime")
struct DoubleClickGuardLifetimeTests {

    @Test("The tap context does not keep the guard alive and loses it when it goes away")
    @MainActor
    func contextLosesTheGuard() {
        var clickGuard: DoubleClickGuard? = DoubleClickGuard()
        let context = clickGuard!.context
        context.owner = clickGuard
        #expect(context.owner != nil)

        clickGuard = nil

        #expect(context.owner == nil)
        #expect(!context.isWatching)
    }
}
