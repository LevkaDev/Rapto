//
//  WorkspaceSessionTests.swift
//  RaptoTests
//
//  Which open windows count as the ones a workspace placed.
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Workspace Session")
@MainActor
struct WorkspaceSessionTests {

    private func entry(_ id: CGWindowID, app: String) -> WindowSwitcherEntry {
        WindowSwitcherEntry(
            window: SpaceBarWindowRef(windowID: id, pid: pid_t(id), title: "", ownerName: app),
            appName: app,
            spaceID: 1,
            displayID: "display",
            desktopNumber: 1,
            isFullScreen: false,
            isOnCurrentDesktop: true,
            displayName: nil
        )
    }

    @Test("A recorded id now used by another app's window is not closed")
    func recordedIDOfAnotherApp() {
        let entries = [entry(10, app: "Safari"), entry(11, app: "Telegram"), entry(12, app: "Notes")]
        let windows = WorkspaceSession.recordedWindows(
            in: entries, recorded: [10, 11, 99], appKeys: ["Safari", "Xcode"], appKey: \.appName
        )
        #expect(windows.map(\.id) == [10])
    }

    @Test("Windows of the workspace's apps that it did not place are not closed")
    func unrecordedWindowOfTheSameApp() {
        let entries = [entry(10, app: "Safari"), entry(20, app: "Safari")]
        let windows = WorkspaceSession.recordedWindows(
            in: entries, recorded: [10], appKeys: ["Safari"], appKey: \.appName
        )
        #expect(windows.map(\.id) == [10])
    }
}
