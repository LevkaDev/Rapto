import Testing
import CoreGraphics
@testable import Rapto

@Suite("Drag to Snap live gap updates")
struct DragSnapLiveGapsTests {

    let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let leftHalf = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
    let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0)

    private func cgFrame(for relativeFrame: CGRect, windowGap: CGFloat, edgeGap: CGFloat) -> CGRect {
        let manager = ScreenManager()
        manager.windowGap = windowGap
        manager.screenEdgeGap = edgeGap
        let abs = manager.calculateAbsoluteFrame(relativeFrame: relativeFrame, in: visibleFrame)
        return CGRect(x: abs.origin.x, y: visibleFrame.height - abs.origin.y - abs.height, width: abs.width, height: abs.height)
    }

    @Test("Snapped windows on the active desktop recompute frames when gaps change")
    func snappedWindowsUpdateForNewGaps() {
        let initialLeft = cgFrame(for: leftHalf, windowGap: 0, edgeGap: 0)
        let initialRight = cgFrame(for: rightHalf, windowGap: 0, edgeGap: 0)
        let candidates = [
            DragSnapService.SnappedGapCandidate(
                windowID: 10, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            ),
            DragSnapService.SnappedGapCandidate(
                windowID: 20, screenID: "screen-1", snappedFrame: initialRight, zoneFrame: initialRight, relativeFrame: rightHalf
            ),
        ]

        let updates = DragSnapService.gapRepositionTargets(
            forScreenID: "screen-1",
            snapped: candidates,
            visibleFrames: [10: initialLeft, 20: initialRight]
        ) { relative in
            cgFrame(for: relative, windowGap: 12, edgeGap: 8)
        }

        let expectedLeft = cgFrame(for: leftHalf, windowGap: 12, edgeGap: 8)
        let expectedRight = cgFrame(for: rightHalf, windowGap: 12, edgeGap: 8)
        #expect(updates.count == 2)
        #expect(updates.first(where: { $0.windowID == 10 })?.targetFrame == expectedLeft)
        #expect(updates.first(where: { $0.windowID == 20 })?.targetFrame == expectedRight)
    }

    @Test("A 4 px gap step still triggers an update even though each edge moves by 2 px")
    func smallGapStepStillUpdates() {
        let initialLeft = cgFrame(for: leftHalf, windowGap: 0, edgeGap: 0)
        let candidates = [
            DragSnapService.SnappedGapCandidate(
                windowID: 10, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            )
        ]

        let updates = DragSnapService.gapRepositionTargets(
            forScreenID: "screen-1",
            snapped: candidates,
            visibleFrames: [10: initialLeft]
        ) { relative in
            cgFrame(for: relative, windowGap: 4, edgeGap: 0)
        }

        #expect(updates.count == 1)
        #expect(updates[0].targetFrame == cgFrame(for: leftHalf, windowGap: 4, edgeGap: 0))
    }

    @Test("Off-desktop, manually moved, manually resized, and other-screen windows are skipped")
    func skipsIneligibleWindows() {
        let initialLeft = cgFrame(for: leftHalf, windowGap: 0, edgeGap: 0)
        let movedFrame = initialLeft.offsetBy(dx: 80, dy: 0)
        let candidates = [
            // On another desktop (absent from visibleFrames)
            DragSnapService.SnappedGapCandidate(
                windowID: 1, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            ),
            // Moved away by the user
            DragSnapService.SnappedGapCandidate(
                windowID: 2, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            ),
            // Manually resized group (relativeFrame cleared)
            DragSnapService.SnappedGapCandidate(
                windowID: 3, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: nil
            ),
            // Belongs to another screen
            DragSnapService.SnappedGapCandidate(
                windowID: 4, screenID: "screen-2", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            ),
        ]

        let updates = DragSnapService.gapRepositionTargets(
            forScreenID: "screen-1",
            snapped: candidates,
            visibleFrames: [2: movedFrame, 3: initialLeft, 4: initialLeft]
        ) { relative in
            cgFrame(for: relative, windowGap: 16, edgeGap: 8)
        }

        #expect(updates.isEmpty)
    }

    @Test("Unchanged gaps produce no updates")
    func skipsUnchangedTargetFrame() {
        let initialLeft = cgFrame(for: leftHalf, windowGap: 8, edgeGap: 4)
        let candidates = [
            DragSnapService.SnappedGapCandidate(
                windowID: 10, screenID: "screen-1", snappedFrame: initialLeft, zoneFrame: initialLeft, relativeFrame: leftHalf
            )
        ]

        let updates = DragSnapService.gapRepositionTargets(
            forScreenID: "screen-1",
            snapped: candidates,
            visibleFrames: [10: initialLeft]
        ) { relative in
            cgFrame(for: relative, windowGap: 8, edgeGap: 4)
        }

        #expect(updates.isEmpty)
    }

    @Test("Gap reapply plan covers every connected display regardless of which screen is active")
    func gapReapplyPlanCoversAllDisplays() {
        let plan = AppState.gapReapplyPlan(screenModes: [
            ("screen-none", .none),
            ("screen-manual", .manualAssignment),
            ("screen-auto", .autoTiling),
            ("screen-drag", .dragSnap),
        ])

        #expect(plan.manualScreens == ["screen-manual"])
        #expect(plan.autoTilingScreens == ["screen-auto"])
        #expect(plan.dragSnapScreens == ["screen-drag"])
    }
}
