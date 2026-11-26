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

    @Test("Moving a zone snaps flush to a neighboring zone edge and screen fractions")
    func moveSnapsToNeighborAndFractions() {
        let neighbor = CGRect(x: 0, y: 0, width: 400, height: 500)
        let movedNearNeighbor = CGRect(x: 407, y: 120, width: 300, height: 200)

        let snapped = ZoneEditorGeometry.snapMovedFrame(
            movedNearNeighbor,
            containerSize: editor,
            otherFrames: [neighbor]
        )

        #expect(snapped.frame.minX == 400)
        #expect(snapped.frame.minY == 125) // snaps top edge to 1/4 of 500
        #expect(snapped.guides.contains { $0.axis == .vertical && $0.position == 400 && $0.kind == .neighbor })
        #expect(snapped.guides.contains { $0.axis == .horizontal && $0.position == 125 && $0.kind == .fraction("1/4") })
    }

    @Test("Moving a zone near screen center snaps its midpoint to 1/2")
    func moveSnapsCenterToHalf() {
        let centered = CGRect(x: 344, y: 155, width: 300, height: 200) // midX=494 (within 12 of 500), midY=255 (within 12 of 250)

        let snapped = ZoneEditorGeometry.snapMovedFrame(
            centered,
            containerSize: editor,
            otherFrames: []
        )

        #expect(snapped.frame.midX == 500)
        #expect(snapped.frame.midY == 250)
        #expect(snapped.guides.contains { $0.axis == .vertical && $0.kind == .fraction("1/2") })
        #expect(snapped.guides.contains { $0.axis == .horizontal && $0.kind == .fraction("1/2") })
    }

    @Test("Resizing an edge snaps only the dragged edge and keeps the opposite edge fixed")
    func resizeSnapsDraggedEdgeOnly() {
        let neighbor = CGRect(x: 600, y: 0, width: 400, height: 500)
        let draggedRight = CGRect(x: 100, y: 10, width: 493, height: 482) // maxX=593 (within 12 of 600), maxY=492 (within 12 of 500)

        let snapped = ZoneEditorGeometry.snapResizedFrame(
            draggedRight,
            edges: [.right, .bottom],
            minSize: 100,
            containerSize: editor,
            otherFrames: [neighbor]
        )

        #expect(snapped.frame.minX == 100)
        #expect(snapped.frame.maxX == 600)
        #expect(snapped.frame.minY == 10)
        #expect(snapped.frame.maxY == 500)
        #expect(snapped.guides.contains { $0.axis == .vertical && $0.position == 600 && $0.kind == .neighbor })
        #expect(snapped.guides.contains { $0.axis == .horizontal && $0.position == 500 && $0.kind == .screenEdge })
    }

    @Test("Holding Option bypasses snapping completely")
    func snappingDisabledLeavesCoordinatesUntouched() {
        let moved = CGRect(x: 406, y: 121, width: 300, height: 200)
        let neighbor = CGRect(x: 0, y: 0, width: 400, height: 500)

        let result = ZoneEditorGeometry.snapMovedFrame(
            moved,
            containerSize: editor,
            otherFrames: [neighbor],
            enabled: false
        )

        #expect(result.frame == moved)
        #expect(result.guides.isEmpty)
    }

    @Test("Splitting a zone vertically and horizontally produces flush halves and respects minSize")
    func splitZoneProducesFlushHalves() {
        let full = CGRect(x: 0, y: 0, width: 1000, height: 500)

        let vertical = ZoneEditorGeometry.split(full, axis: .vertical, minSize: 100)
        #expect(vertical?.first == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(vertical?.second == CGRect(x: 500, y: 0, width: 500, height: 500))

        let horizontal = ZoneEditorGeometry.split(full, axis: .horizontal, minSize: 100)
        #expect(horizontal?.first == CGRect(x: 0, y: 0, width: 1000, height: 250))
        #expect(horizontal?.second == CGRect(x: 0, y: 250, width: 1000, height: 250))

        // Relative conversion puts top half at y=0.5 (AppKit origin at bottom-left) so top fills first
        let topRel = ZoneCreatorView.relativeFrame(from: horizontal!.first, in: editor)
        let bottomRel = ZoneCreatorView.relativeFrame(from: horizontal!.second, in: editor)
        #expect(topRel == CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        #expect(bottomRel == CGRect(x: 0, y: 0, width: 1, height: 0.5))

        let tooNarrow = CGRect(x: 0, y: 0, width: 180, height: 500)
        #expect(ZoneEditorGeometry.split(tooNarrow, axis: .vertical, minSize: 100) == nil)
        #expect(ZoneEditorGeometry.split(tooNarrow, axis: .horizontal, minSize: 100) != nil)
    }

    @Test("Splitting a draft zone places the first half and moves the live draft to the second half")
    func splitDraftPlacesFirstAndMovesDraftToSecond() {
        let draft = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let vertical = ZoneEditorGeometry.splitDraft(currentFrame: draft, axis: .vertical, minSize: 100)
        #expect(vertical?.placed == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(vertical?.nextDraft == CGRect(x: 500, y: 0, width: 500, height: 500))

        // Splitting the remaining right-half draft horizontally yields top-right placed and bottom-right live
        let nested = ZoneEditorGeometry.splitDraft(currentFrame: vertical!.nextDraft, axis: .horizontal, minSize: 100)
        #expect(nested?.placed == CGRect(x: 500, y: 0, width: 500, height: 250))
        #expect(nested?.nextDraft == CGRect(x: 500, y: 250, width: 500, height: 250))
    }

    @Test("Zone controls stay clear of top and bottom overlay bars while remaining inside the zone")
    func controlsStayClearOfOverlayBars() {
        let screen = CGSize(width: 1440, height: 900)

        // Full-screen zone stays centered
        let fullScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(ZoneEditorGeometry.controlsCenterY(for: fullScreen, containerSize: screen) == 450)

        // Short top strip nudges controls down below the top toolbar
        let topStrip = CGRect(x: 0, y: 0, width: 1440, height: 170)
        let topY = ZoneEditorGeometry.controlsCenterY(for: topStrip, containerSize: screen)
        #expect(topY == 114)
        #expect(topY <= topStrip.maxY - 46)

        // Short bottom strip nudges controls up above the bottom hint bar
        let bottomStrip = CGRect(x: 0, y: 730, width: 1440, height: 170)
        let bottomY = ZoneEditorGeometry.controlsCenterY(for: bottomStrip, containerSize: screen)
        #expect(bottomY == 786)
        #expect(bottomY >= bottomStrip.minY + 34)
    }

    @Test("New draft frame centers on tap within bounds and prefers open canvas space")
    func newDraftFramePlacement() {
        // Tap near top-left corner clamps cleanly inside editor
        let nearCorner = ZoneEditorGeometry.draftFrame(centeredAt: CGPoint(x: 20, y: 15), in: editor)
        #expect(nearCorner == CGRect(x: 0, y: 0, width: 300, height: 200))

        // With left half occupied, default draft picks an open spot on the right side
        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 500)
        let nextDraft = ZoneEditorGeometry.defaultDraftFrame(in: editor, existingFrames: [leftHalf])
        #expect(nextDraft.minX >= 500)
        #expect(nextDraft.intersection(leftHalf).isEmpty)
    }
}
