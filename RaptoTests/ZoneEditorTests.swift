import Testing
import CoreGraphics
@testable import Rapto

@Suite("Zone editor keeps zones inside the visible area")
struct ZoneEditorTests {
    let editor = CGSize(width: 1000, height: 500)

    @Test("A corner dragged past the top-left edge stops at the edge")
    func resizePastTopLeft() {
        let dragged = CGRect(x: -40, y: -30, width: 340, height: 230)
        #expect(ResizableZoneWindow.clamped(dragged, to: editor) == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test("A zone inside the editor is unchanged")
    func insideUnchanged() {
        let zone = CGRect(x: 100, y: 50, width: 300, height: 200)
        #expect(ResizableZoneWindow.clamped(zone, to: editor) == zone)
    }

    @Test("A handle dragged past the opposite edge is left for the minimum size check")
    func invertedLeftAlone() {
        let inverted = CGRect(x: 400, y: 50, width: -20, height: 200)
        #expect(ResizableZoneWindow.clamped(inverted, to: editor) == inverted)
    }

    @Test("The saved zone never reaches past the visible area")
    func savedFrameWithinUnitSquare() {
        let frame = ZoneCreatorView.relativeFrame(from: CGRect(x: 900, y: -50, width: 200, height: 300), in: editor)
        #expect(frame == CGRect(x: 0.9, y: 0.5, width: 0.1, height: 0.5))
    }
}
