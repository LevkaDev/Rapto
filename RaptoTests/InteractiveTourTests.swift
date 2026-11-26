//
//  InteractiveTourTests.swift
//  RaptoTests
//
//  Pure state machine tests for the mouse-first interactive tour and auto-tune summary copy.
//

import Testing
@testable import Rapto

@Suite("Interactive Tour & Auto-Tune Copy Tests")
struct InteractiveTourTests {

    @Test("Drag to Snap tour stays mouse-first and appends notch hint only on notched laptops")
    func dragSnapTasks() {
        let regular = InteractiveTourModel(mode: .dragSnap, hasNotchedHoverBar: false, alreadyArranged: false)
        #expect(regular.tasks == [.dragToEdge, .dragToTopPicker])
        #expect(regular.activeTask == .dragToEdge)
        #expect(!regular.isAllDone)

        let notched = InteractiveTourModel(mode: .dragSnap, hasNotchedHoverBar: true, alreadyArranged: false)
        #expect(notched.tasks == [.dragToEdge, .dragToTopPicker, .revealNotchBar])
    }

    @Test("Auto-tiling and Manual tours skip the Arrange task when windows were already arranged")
    func autoTilingAndManualTasks() {
        let autoFresh = InteractiveTourModel(mode: .autoTiling, hasNotchedHoverBar: false, alreadyArranged: false)
        #expect(autoFresh.tasks == [.arrangeWindows, .swapWindows, .resizeSharedBorder])

        let autoArranged = InteractiveTourModel(mode: .autoTiling, hasNotchedHoverBar: true, alreadyArranged: true)
        #expect(autoArranged.tasks == [.swapWindows, .resizeSharedBorder, .revealNotchBar])

        let manualFresh = InteractiveTourModel(mode: .manualAssignment, hasNotchedHoverBar: false, alreadyArranged: false)
        #expect(manualFresh.tasks == [.arrangeWindows, .groupWindows, .switchGroupWindow])

        let manualArranged = InteractiveTourModel(mode: .manualAssignment, hasNotchedHoverBar: true, alreadyArranged: true)
        #expect(manualArranged.tasks == [.groupWindows, .switchGroupWindow, .revealNotchBar])
    }

    @Test("Completing tasks advances activeTask and ignores tasks outside the active mode")
    func taskCompletionProgression() {
        var model = InteractiveTourModel(mode: .dragSnap, hasNotchedHoverBar: true, alreadyArranged: false)
        #expect(model.completedCount == 0)

        // Task from another mode is ignored
        #expect(model.markCompleted(.swapWindows) == false)
        #expect(model.completedCount == 0)

        #expect(model.markCompleted(.dragToEdge) == true)
        #expect(model.markCompleted(.dragToEdge) == false)
        #expect(model.activeTask == .dragToTopPicker)

        #expect(model.markCompleted(.dragToTopPicker) == true)
        #expect(model.activeTask == .revealNotchBar)

        #expect(model.markCompleted(.revealNotchBar) == true)
        #expect(model.activeTask == nil)
        #expect(model.isAllDone == true)
        #expect(model.completedCount == 3)
    }

    @Test("DisplayProfile auto-tune summary adapts to display count and desktop count")
    func autoTuneSummaryFormatting() {
        #expect(DisplayProfile.compactLaptop.autoTuneSummary(screenCount: 1, desktopCount: 1) == "Compact laptop · tuned for 1–2 windows")
        #expect(DisplayProfile.ultrawide.autoTuneSummary(screenCount: 1, desktopCount: 3) == "Wide display · tuned for 1–5 windows · 3 desktops ready in Desktops Bar")
        #expect(DisplayProfile.standardDesktop.autoTuneSummary(screenCount: 2, desktopCount: 1) == "2 displays · tuned per screen")
    }
}
