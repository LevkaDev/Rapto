//
//  MultiScreenLayoutTests.swift
//  RaptoTests
//
//  Layout changes on a screen other than the one the layout manager treats as active.
//

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import Rapto

@Suite("Multi-Screen Layout Tests")
@MainActor
struct MultiScreenLayoutTests {

    static let secondScreen = "display-test-second"

    private func window(_ id: CGWindowID) -> WindowInfo {
        WindowInfo(windowID: id, ownerPID: pid_t(id), title: "W\(id)", ownerName: "App\(id)", frame: .zero)
    }

    /// The active screen holds windows 1 and 2, the second screen holds 11 and 12
    private func makeManager() -> WindowLayoutManager {
        let manager = WindowLayoutManager(screenManager: ScreenManager())
        manager.existingWindowIDs = { [1, 2, 11, 12] }
        manager.setLayout(template: PredefinedTemplates.halvesVertical, windows: [window(1), window(2)])
        manager.setLayout(template: PredefinedTemplates.halvesVertical, windows: [window(11), window(12)], forScreenID: Self.secondScreen)
        return manager
    }

    private func primaryIDs(_ state: LayoutState) -> [CGWindowID?] {
        state.slots.map { $0.primaryWindow?.windowID }
    }

    @Test("Swapping windows on the second screen updates that screen's layout")
    func swapOnSecondScreen() {
        let manager = makeManager()
        manager.swapWindows(11, 12)

        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [12, 11])
        #expect(primaryIDs(manager.state(forScreenID: manager.activeScreenID)) == [1, 2])
        #expect(primaryIDs(manager.state) == [1, 2])
    }

    @Test("Swapping windows on the active screen works as before")
    func swapOnActiveScreen() {
        let manager = makeManager()
        manager.swapWindows(1, 2)

        #expect(primaryIDs(manager.state) == [2, 1])
        #expect(primaryIDs(manager.state(forScreenID: manager.activeScreenID)) == [2, 1])
        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [11, 12])
    }

    @Test("Windows on different screens are not swapped")
    func swapAcrossScreensRefused() {
        let manager = makeManager()
        manager.swapWindows(1, 11)

        #expect(primaryIDs(manager.state) == [1, 2])
        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [11, 12])
    }

    @Test("Grouped windows on the second screen count as one slot, windows elsewhere don't")
    func sameSlotOnAnyScreen() {
        let manager = makeManager()
        manager.moveWindowToSlot(windowID: 11, targetWindowID: 12, forScreenID: Self.secondScreen)

        #expect(manager.areInSameSlot(11, 12))
        #expect(!manager.areInSameSlot(1, 2))
        // Slot 1 on both screens, but different screens
        #expect(!manager.areInSameSlot(2, 12))
        #expect(!manager.areInSameSlot(1, 99))
    }

    @Test("Snap-back remembers the windows of every screen's layout, not only the active one")
    func snapBackCapturesEveryScreen() {
        let manager = makeManager()
        let windows = [1, 2, 11, 12, 50].map { id in
            WindowInfo(windowID: CGWindowID(id), ownerPID: 1, title: "", ownerName: "", frame: CGRect(x: id, y: 0, width: 100, height: 100))
        }
        let frames = SnapBackService.framesOfSlotWindows(
            in: [manager.state(forScreenID: manager.activeScreenID), manager.state(forScreenID: Self.secondScreen)],
            windows: windows
        )

        #expect(Set(frames.keys) == [1, 2, 11, 12])
        #expect(frames[11]?.origin.x == 11)
    }

    @Test("Recalculating all frames keeps each screen's own slots and windows")
    func recalculateAllFramesKeepsScreensApart() {
        let manager = makeManager()
        let secondBefore = manager.state(forScreenID: Self.secondScreen)
        manager.recalculateAllFrames()

        let active = manager.state(forScreenID: manager.activeScreenID)
        #expect(manager.state.slots.map(\.frame) == active.slots.map(\.frame))
        #expect(primaryIDs(active) == [1, 2])
        // The test screen has no display, so its frames stay as they were
        #expect(manager.state(forScreenID: Self.secondScreen).slots.map(\.frame) == secondBefore.slots.map(\.frame))
    }

    @Test("A window that exists but is not on screen still counts as existing")
    func hiddenWindowStillExists() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        window.orderOut(nil)
        defer { window.close() }
        let windowID = CGWindowID(window.windowNumber)
        try #require(windowID != 0)

        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        #expect(!onScreen.contains { $0[kCGWindowNumber as String] as? CGWindowID == windowID })
        #expect(WindowLayoutManager(screenManager: ScreenManager()).existingWindowIDs().contains(windowID))
    }

    @Test("Moving a window into another slot on the second screen groups it there")
    func moveOnSecondScreen() throws {
        let manager = makeManager()
        let screenID = try #require(manager.findWindowAcrossScreens(11)?.screenID)
        manager.moveWindowToSlot(windowID: 11, targetWindowID: 12, forScreenID: screenID)

        let second = manager.state(forScreenID: Self.secondScreen)
        #expect(second.slots[0].windows.isEmpty)
        #expect(second.slots[1].windows.map(\.windowID) == [11, 12])
        #expect(primaryIDs(manager.state) == [1, 2])
    }

    @Test("A window dropped onto a window of another screen joins its slot and leaves its own layout")
    func moveAcrossScreens() {
        let manager = makeManager()
        let changed = manager.moveWindowAcrossScreens(window(1), toSlotOf: 12)

        #expect(Set(changed) == [manager.activeScreenID, Self.secondScreen])
        #expect(manager.state.slots[0].windows.isEmpty)
        #expect(manager.state(forScreenID: Self.secondScreen).slots[1].windows.map(\.windowID) == [1, 12])
    }

    @Test("A window from no layout dropped into an empty slot of another screen fills it")
    func moveIntoEmptySlotAcrossScreens() {
        let manager = makeManager()
        manager.removeWindow(12, forScreenID: Self.secondScreen)
        let changed = manager.moveWindowAcrossScreens(window(7), toEmptySlot: 1, forScreenID: Self.secondScreen)

        #expect(changed == [Self.secondScreen])
        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [11, 7])
    }

    @Test("A swap across screens gives each window the other's slot")
    func swapAcrossScreens() {
        let manager = makeManager()
        manager.swapWindowsAcrossScreens(dragged: window(1), target: window(12))

        #expect(primaryIDs(manager.state) == [12, 2])
        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [11, 1])
    }

    @Test("A swap with a window from no layout leaves the target outside any layout")
    func swapFromUnmanagedWindow() {
        let manager = makeManager()
        manager.swapWindowsAcrossScreens(dragged: window(7), target: window(12))

        #expect(primaryIDs(manager.state(forScreenID: Self.secondScreen)) == [11, 7])
        #expect(manager.findWindowAcrossScreens(12) == nil)
    }
}
