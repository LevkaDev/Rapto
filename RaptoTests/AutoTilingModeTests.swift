import CoreGraphics
import Testing
@testable import Rapto

@MainActor
@Suite("Auto-tiling operation mode")
struct AutoTilingModeTests {
    @Test("Redistributing for a display that is gone leaves the layout idle")
    func missingScreenKeepsIdle() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        let service = AutoTilingService(
            accessibilityService: AccessibilityService(),
            screenManager: screenManager,
            windowManager: WindowManager(),
            layoutManager: layoutManager
        )
        let missingScreenID = "display-missing-test"
        service.startDynamic(forScreenID: missingScreenID, skipInitialRedistribute: true)
        defer { service.stop() }

        service.redistributeWindows(forScreenID: missingScreenID)
        #expect(layoutManager.operationMode == .idle)
        #expect(layoutManager.canPerform(operation: .redistributing))
    }

    @Test("Two quick Space changes: only the second one ends the pause")
    func overlappingSpaceChanges() async throws {
        let screenManager = ScreenManager()
        let service = AutoTilingService(
            accessibilityService: AccessibilityService(),
            screenManager: screenManager,
            windowManager: WindowManager(),
            layoutManager: WindowLayoutManager(screenManager: screenManager)
        )
        // Wide margins: with 100 ms ones the sleeps overran on a busy machine and the test failed
        service.pauseUntilSpaceSettles(nanoseconds: 1_000_000_000)
        try await Task.sleep(nanoseconds: 600_000_000)
        service.pauseUntilSpaceSettles(nanoseconds: 1_000_000_000)

        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(service.isPausedForSpaceChange)

        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!service.isPausedForSpaceChange)
    }

    @Test("After a Space change, a window outside the screen's layout stays new, so it gets tiled")
    func windowOutsideLayoutStaysNew() {
        let onScreen: Set<CGWindowID> = [1, 2, 3, 4]
        #expect(AutoTilingService.knownWindowIDs(onScreen: onScreen, laidOut: [1, 2, 3]) == [1, 2, 3])
        #expect(AutoTilingService.knownWindowIDs(onScreen: onScreen, laidOut: [1, 2, 3, 4, 9]) == onScreen)
    }

    @Test("A screen without a layout yet keeps all its windows as known")
    func screenWithoutLayoutKnowsAll() {
        let onScreen: Set<CGWindowID> = [5, 6]
        #expect(AutoTilingService.knownWindowIDs(onScreen: onScreen, laidOut: nil) == onScreen)
    }
}
