//
//  InteractiveTourTests.swift
//  RaptoTests
//
//  Pure state machine tests for the two-part mouse-first interactive tour
//  (Part 1: tiling mode, Part 2: Desktops Bar & Window Flow) and auto-tune summary copy.
//

import Testing
@testable import Rapto

@Suite("Interactive Tour & Auto-Tune Copy Tests")
struct InteractiveTourTests {

    @Test("Part 1 starts with top layout bar before edge snap; Part 2 adds Desktops Bar & Window Flow")
    func dragSnapTwoPartTour() {
        let singleDesktop = InteractiveTourModel(
            mode: .dragSnap,
            hasNotchedHoverBar: false,
            alreadyArranged: false,
            showsSpaceBar: true,
            desktopCount: 1
        )
        #expect(singleDesktop.phase == .mode)
        #expect(singleDesktop.tasks == [.dragToTopPicker, .dragToEdge])
        #expect(singleDesktop.activeTask == .dragToTopPicker)
        #expect(!singleDesktop.isAllDone)
        #expect(TourTaskID.dragToEdge.detail().contains("let go as soon as the highlight appears"))
        #expect(singleDesktop.desktopsTasks == [.addSecondDesktop, .moveAppToDesktop, .openWindowFlow])

        let multiDesktopNotched = InteractiveTourModel(
            mode: .dragSnap,
            hasNotchedHoverBar: true,
            alreadyArranged: false,
            showsSpaceBar: true,
            desktopCount: 3
        )
        #expect(multiDesktopNotched.modeTasks == [.dragToTopPicker, .dragToEdge])
        #expect(multiDesktopNotched.desktopsTasks == [.revealNotchBar, .moveAppToDesktop, .openWindowFlow])
    }

    @Test("Part 2 skips Desktops Bar steps when bar is turned off but still showcases Window Flow")
    func desktopsPhaseWithoutSpaceBar() {
        let model = InteractiveTourModel(
            mode: .dragSnap,
            hasNotchedHoverBar: false,
            alreadyArranged: false,
            showsSpaceBar: false,
            desktopCount: 1
        )
        #expect(model.desktopsTasks == [.openWindowFlow])
    }

    @Test("Auto-tiling and Manual tours skip the Arrange task when windows were already arranged")
    func autoTilingAndManualTasks() {
        let autoFresh = InteractiveTourModel(mode: .autoTiling, hasNotchedHoverBar: false, alreadyArranged: false)
        #expect(autoFresh.modeTasks == [.arrangeWindows, .swapWindows, .resizeSharedBorder])

        let autoArranged = InteractiveTourModel(mode: .autoTiling, hasNotchedHoverBar: true, alreadyArranged: true, desktopCount: 2)
        #expect(autoArranged.modeTasks == [.swapWindows, .resizeSharedBorder])
        #expect(autoArranged.desktopsTasks == [.revealNotchBar, .moveAppToDesktop, .openWindowFlow])

        let manualFresh = InteractiveTourModel(mode: .manualAssignment, hasNotchedHoverBar: false, alreadyArranged: false)
        #expect(manualFresh.modeTasks == [.arrangeWindows, .groupWindows, .switchGroupWindow])

        let manualArranged = InteractiveTourModel(mode: .manualAssignment, hasNotchedHoverBar: false, alreadyArranged: true, desktopCount: 1)
        #expect(manualArranged.modeTasks == [.groupWindows, .switchGroupWindow])
        #expect(manualArranged.desktopsTasks == [.addSecondDesktop, .moveAppToDesktop, .openWindowFlow])
    }

    @Test("Completing Part 1 advances into Part 2 and completes the tour once Window Flow opens")
    func twoPartProgression() {
        var model = InteractiveTourModel(
            mode: .dragSnap,
            hasNotchedHoverBar: true,
            alreadyArranged: false,
            showsSpaceBar: true,
            desktopCount: 1
        )
        #expect(model.completedCount == 0)

        // Task from another mode is ignored
        #expect(model.markCompleted(.swapWindows) == false)
        #expect(model.completedCount == 0)

        // Part 1: Drag to Snap
        #expect(model.markCompleted(.dragToTopPicker) == true)
        #expect(model.markCompleted(.dragToTopPicker) == false)
        #expect(model.activeTask == .dragToEdge)

        #expect(model.markCompleted(.dragToEdge) == true)
        #expect(model.isCurrentPhaseDone == true)
        #expect(model.isAllDone == false)

        // Advance to Part 2: Desktops Bar & Window Flow
        #expect(model.advanceToDesktopsAndFlow() == true)
        #expect(model.advanceToDesktopsAndFlow() == false)
        #expect(model.phase == .desktopsAndFlow)
        #expect(model.activeTask == .revealNotchBar)

        #expect(model.markCompleted(.revealNotchBar) == true)
        #expect(model.activeTask == .addSecondDesktop)

        #expect(model.markCompleted(.addSecondDesktop) == true)
        #expect(model.activeTask == .moveAppToDesktop)

        #expect(model.markCompleted(.moveAppToDesktop) == true)
        #expect(model.activeTask == .openWindowFlow)

        #expect(model.markCompleted(.openWindowFlow) == true)
        #expect(model.activeTask == nil)
        #expect(model.isAllDone == true)
        #expect(model.completedCount == 4)
    }

    @Test("Window Flow task detail embeds live shortcut when bound and falls back cleanly when cleared")
    func windowFlowTaskDetail() {
        #expect(TourTaskID.openWindowFlow.detail(windowFlowShortcut: "⌃⌥S").contains("⌃⌥S"))
        #expect(TourTaskID.openWindowFlow.detail(windowFlowShortcut: nil).contains("Click Open Window Flow"))
    }

    @Test("DisplayProfile auto-tune summary adapts to display count and desktop count")
    func autoTuneSummaryFormatting() {
        #expect(DisplayProfile.compactLaptop.autoTuneSummary(screenCount: 1, desktopCount: 1) == "Compact laptop · tuned for 1–2 windows")
        #expect(DisplayProfile.ultrawide.autoTuneSummary(screenCount: 1, desktopCount: 3) == "Wide display · tuned for 1–5 windows · 3 desktops ready in Desktops Bar")
        #expect(DisplayProfile.standardDesktop.autoTuneSummary(screenCount: 2, desktopCount: 1) == "2 displays · tuned per screen")
    }
}
