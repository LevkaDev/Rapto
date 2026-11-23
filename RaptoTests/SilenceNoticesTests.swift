//
//  SilenceNoticesTests.swift
//  RaptoTests
//
//  Tests for messages shown instead of silent no-ops: Auto-tiling overlay notice
//  and live Accessibility warning state propagation.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Silence Notices Tests")
struct SilenceNoticesTests {

    @Test("Opening the overlay on an Auto-tiling desktop returns the explanation notice instead of silent return")
    func overlayToggleOnAutoTilingShowsNotice() {
        #expect(
            AppState.overlayToggleDecision(isOverlayVisible: false, screenMode: .autoTiling) ==
            .showAutoTilingNotice(AppState.autoTilingOverlayNotice)
        )

        #expect(
            AppState.overlayToggleDecision(isOverlayVisible: true, screenMode: .autoTiling) ==
            .toggleVisibility
        )

        for mode: TilingMode in [.manualAssignment, .dragSnap, .none] {
            #expect(
                AppState.overlayToggleDecision(isOverlayVisible: false, screenMode: mode) ==
                .toggleVisibility
            )
        }
    }

    @Test("hasAccessibilityPermission propagates immediately to SpaceBarController")
    @MainActor
    func accessibilityPermissionSyncsToSpaceBarController() {
        let appState = AppState()
        let original = appState.hasAccessibilityPermission
        defer {
            appState.hasAccessibilityPermission = original
        }

        appState.hasAccessibilityPermission = false
        #expect(!appState.spaceBarController.hasAccessibilityPermission)

        appState.hasAccessibilityPermission = true
        #expect(appState.spaceBarController.hasAccessibilityPermission)
    }
}
