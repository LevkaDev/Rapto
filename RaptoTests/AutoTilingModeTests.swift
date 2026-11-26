import CoreGraphics
import Foundation
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

    @Test("Waking unresponsive window from saved Auto-tiling layout is preserved instead of collapsing slots")
    func unresponsiveSavedLayoutWindowIsPreserved() {
        let saved = SavedLayoutInfo(
            templateID: UUID(),
            slots: [
                SavedLayoutInfo.SavedSlotInfo(
                    slotID: UUID(), index: 0, ownerName: "Simplenote",
                    bundleIdentifier: "com.automattic.SimplenoteMac",
                    frame: CGRect(x: 8, y: 34, width: 1342, height: 753),
                    groupBundleIDs: nil, groupPIDs: [41401]
                ),
                SavedLayoutInfo.SavedSlotInfo(
                    slotID: UUID(), index: 1, ownerName: "Maps",
                    bundleIdentifier: "com.apple.Maps",
                    frame: CGRect(x: 9, y: 805, width: 1341, height: 782),
                    groupBundleIDs: nil, groupPIDs: [67214]
                ),
                SavedLayoutInfo.SavedSlotInfo(
                    slotID: UUID(), index: 2, ownerName: "Dia",
                    bundleIdentifier: "company.thebrowser.dia",
                    frame: CGRect(x: 1374, y: 34, width: 2461, height: 1544),
                    groupBundleIDs: nil, groupPIDs: [60288]
                )
            ]
        )
        let mapsWindow = WindowInfo(
            windowID: 6104,
            ownerPID: 67214,
            title: "Maps",
            ownerName: "Maps",
            bundleIdentifier: "com.apple.Maps",
            frame: CGRect(x: 9, y: 805, width: 1341, height: 782)
        )
        // Maps waking from App Nap (not responding yet) matches saved layout -> preserved
        #expect(AutoTilingService.shouldPreserveUnresponsiveWindow(
            mapsWindow,
            isResponding: false,
            knownWindowIDs: [],
            savedLayout: saved
        ))
        // Once Maps answers again, normal AX classification/accessibility checks apply
        #expect(!AutoTilingService.shouldPreserveUnresponsiveWindow(
            mapsWindow,
            isResponding: true,
            knownWindowIDs: [6104],
            savedLayout: saved
        ))
        // Already-tiled window stays preserved even without a saved layout
        #expect(AutoTilingService.shouldPreserveUnresponsiveWindow(
            mapsWindow,
            isResponding: false,
            knownWindowIDs: [6104],
            savedLayout: nil
        ))
        // Unrelated unresponsive app not in known or saved layout is NOT preserved
        let stranger = WindowInfo(
            windowID: 9999,
            ownerPID: 99999,
            title: "Other",
            ownerName: "Other",
            bundleIdentifier: "com.example.other",
            frame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        #expect(!AutoTilingService.shouldPreserveUnresponsiveWindow(
            stranger,
            isResponding: false,
            knownWindowIDs: [6104],
            savedLayout: saved
        ))
        // Small dialog from an unresponsive app is never preserved
        let smallDialog = WindowInfo(
            windowID: 6105,
            ownerPID: 67214,
            title: "Alert",
            ownerName: "Maps",
            bundleIdentifier: "com.apple.Maps",
            frame: CGRect(x: 500, y: 400, width: 240, height: 180)
        )
        #expect(!AutoTilingService.shouldPreserveUnresponsiveWindow(
            smallDialog,
            isResponding: false,
            knownWindowIDs: [6105],
            savedLayout: saved
        ))
    }
}
