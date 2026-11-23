//
//  HiddenDesktopWindowsTests.swift
//  RaptoTests
//
//  Windows of desktops no display shows are not taken for newly opened ones.
//

import Testing
@testable import Rapto

@Suite("Hidden Desktop Windows Tests")
struct HiddenDesktopWindowsTests {

    @Test("A window of another desktop is hidden")
    func otherDesktopIsHidden() {
        #expect(SpaceManager.isOnHiddenDesktop(windowSpaces: [3], shownSpaces: [1]))
    }

    @Test("A window of the shown desktop is not hidden")
    func shownDesktopIsNotHidden() {
        #expect(!SpaceManager.isOnHiddenDesktop(windowSpaces: [1], shownSpaces: [1]))
    }

    @Test("A window of the desktop another display shows is not hidden")
    func desktopOfSecondDisplayIsNotHidden() {
        #expect(!SpaceManager.isOnHiddenDesktop(windowSpaces: [7], shownSpaces: [1, 7]))
    }

    @Test("A window on all desktops is not hidden")
    func windowOnAllDesktopsIsNotHidden() {
        #expect(!SpaceManager.isOnHiddenDesktop(windowSpaces: [1, 3, 4, 5], shownSpaces: [4]))
    }

    @Test("A window with no known desktop counts as shown")
    func unknownDesktopCountsAsShown() {
        #expect(!SpaceManager.isOnHiddenDesktop(windowSpaces: [], shownSpaces: [1]))
        #expect(!SpaceManager.isOnHiddenDesktop(windowSpaces: [3], shownSpaces: []))
    }
}
