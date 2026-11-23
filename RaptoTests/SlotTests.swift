//
//  SlotTests.swift
//  RaptoTests
//
//  Unit tests for the Slot model - core tiling unit
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Slot Tests")
struct SlotTests {
    
    // MARK: - Helper Functions
    
    private func makeWindow(
        id: CGWindowID = 1,
        pid: pid_t = 100,
        title: String = "Test Window",
        owner: String = "TestApp",
        bundleID: String? = "com.test.app"
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerPID: pid,
            title: title,
            ownerName: owner,
            bundleIdentifier: bundleID,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
    
    private func makeSlot(index: Int = 0) -> Slot {
        Slot(
            id: UUID(),
            index: index,
            frame: CGRect(x: 0, y: 0, width: 960, height: 1080)
        )
    }
    
    // MARK: - Initialization Tests
    
    @Test("Empty slot initialization")
    func testEmptySlotInit() {
        let slot = makeSlot()
        
        #expect(slot.isEmpty == true)
        #expect(slot.windowCount == 0)
        #expect(slot.primaryWindow == nil)
        #expect(slot.hasGroup == false)
    }
    
    @Test("Slot initialization with window")
    func testSlotInitWithWindow() {
        let window = makeWindow()
        let slot = Slot(
            id: UUID(),
            index: 0,
            frame: CGRect(x: 0, y: 0, width: 960, height: 1080),
            windows: [window]
        )
        
        #expect(slot.isEmpty == false)
        #expect(slot.windowCount == 1)
        #expect(slot.primaryWindow?.windowID == window.windowID)
        #expect(slot.hasGroup == false)
        #expect(slot.originalBundleID == window.bundleIdentifier)
        #expect(slot.originalOwnerName == window.ownerName)
    }
    
    // MARK: - Window Management Tests
    
    @Test("Add window to empty slot")
    func testAddWindowToEmptySlot() {
        var slot = makeSlot()
        let window = makeWindow()
        
        slot.addWindow(window)
        
        #expect(slot.windowCount == 1)
        #expect(slot.primaryWindow?.windowID == window.windowID)
        #expect(slot.originalBundleID == window.bundleIdentifier)
    }
    
    @Test("Add multiple windows creates group")
    func testAddMultipleWindowsCreatesGroup() {
        var slot = makeSlot()
        let window1 = makeWindow(id: 1, title: "Window 1")
        let window2 = makeWindow(id: 2, title: "Window 2")
        let window3 = makeWindow(id: 3, title: "Window 3")
        
        slot.addWindow(window1)
        slot.addWindow(window2)
        slot.addWindow(window3)
        
        #expect(slot.windowCount == 3)
        #expect(slot.hasGroup == true)
        #expect(slot.primaryWindow?.windowID == 1)
        #expect(slot.secondaryWindows.count == 2)
    }
    
    @Test("Adding duplicate window is ignored")
    func testAddDuplicateWindowIgnored() {
        var slot = makeSlot()
        let window = makeWindow(id: 1)
        
        slot.addWindow(window)
        slot.addWindow(window) // Duplicate
        
        #expect(slot.windowCount == 1)
    }
    
    @Test("Remove window from slot")
    func testRemoveWindow() {
        var slot = makeSlot()
        let window1 = makeWindow(id: 1)
        let window2 = makeWindow(id: 2)
        
        slot.addWindow(window1)
        slot.addWindow(window2)
        
        let removed = slot.removeWindow(withID: 1)
        
        #expect(removed?.windowID == 1)
        #expect(slot.windowCount == 1)
        #expect(slot.primaryWindow?.windowID == 2)
    }
    
    @Test("Remove non-existent window returns nil")
    func testRemoveNonExistentWindow() {
        var slot = makeSlot()
        let window = makeWindow(id: 1)
        slot.addWindow(window)
        
        let removed = slot.removeWindow(withID: 999)
        
        #expect(removed == nil)
        #expect(slot.windowCount == 1)
    }
    
    // MARK: - Window Cycling Tests
    
    @Test("Cycle forward moves first window to end")
    func testCycleForward() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, title: "A"))
        slot.addWindow(makeWindow(id: 2, title: "B"))
        slot.addWindow(makeWindow(id: 3, title: "C"))
        
        slot.cycleForward()
        
        #expect(slot.primaryWindow?.windowID == 2)
        #expect(slot.windows.last?.windowID == 1)
    }
    
    @Test("Cycle backward moves last window to front")
    func testCycleBackward() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, title: "A"))
        slot.addWindow(makeWindow(id: 2, title: "B"))
        slot.addWindow(makeWindow(id: 3, title: "C"))
        
        slot.cycleBackward()
        
        #expect(slot.primaryWindow?.windowID == 3)
        #expect(slot.windows.last?.windowID == 2)
    }
    
    @Test("Cycle on single window does nothing")
    func testCycleSingleWindow() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1))
        
        slot.cycleForward()
        #expect(slot.primaryWindow?.windowID == 1)
        
        slot.cycleBackward()
        #expect(slot.primaryWindow?.windowID == 1)
    }
    
    @Test("Set active window moves it to front")
    func testSetActiveWindow() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1))
        slot.addWindow(makeWindow(id: 2))
        slot.addWindow(makeWindow(id: 3))
        
        slot.setActiveWindow(3)
        
        #expect(slot.primaryWindow?.windowID == 3)
        #expect(slot.windowCount == 3)
    }
    
    // MARK: - Contains Tests
    
    @Test("Contains returns true for existing window")
    func testContainsExistingWindow() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1))
        slot.addWindow(makeWindow(id: 2))
        
        #expect(slot.contains(windowID: 1) == true)
        #expect(slot.contains(windowID: 2) == true)
    }
    
    @Test("Contains returns false for non-existing window")
    func testContainsNonExistingWindow() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1))
        
        #expect(slot.contains(windowID: 999) == false)
    }
    
    // MARK: - Mixed Apps Tests
    
    @Test("Single window is not mixed apps")
    func testSingleWindowNotMixedApps() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, bundleID: "com.app1"))
        
        #expect(slot.hasMixedApps == false)
    }
    
    @Test("Same app windows are not mixed apps")
    func testSameAppNotMixedApps() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, bundleID: "com.app1"))
        slot.addWindow(makeWindow(id: 2, bundleID: "com.app1"))
        
        #expect(slot.hasMixedApps == false)
    }
    
    @Test("Different app windows are mixed apps")
    func testDifferentAppsMixedApps() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, bundleID: "com.app1"))
        slot.addWindow(makeWindow(id: 2, bundleID: "com.app2"))
        
        #expect(slot.hasMixedApps == true)
    }
    
    // MARK: - Can Group Tests
    
    @Test("Can group with empty slot")
    func testCanGroupWithEmptySlot() {
        let slot = makeSlot()
        let window = makeWindow()
        
        #expect(slot.canGroup(with: window) == true)
    }
    
    @Test("Can group same bundle ID")
    func testCanGroupSameBundleID() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, bundleID: "com.test"))
        let window = makeWindow(id: 2, bundleID: "com.test")
        
        #expect(slot.canGroup(with: window) == true)
    }
    
    @Test("Can group same PID")
    func testCanGroupSamePID() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, pid: 100, bundleID: nil))
        let window = makeWindow(id: 2, pid: 100, bundleID: nil)
        
        #expect(slot.canGroup(with: window) == true)
    }
    
    @Test("Can group same owner name")
    func testCanGroupSameOwnerName() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, pid: 100, owner: "Electron", bundleID: nil))
        let window = makeWindow(id: 2, pid: 200, owner: "Electron", bundleID: nil)
        
        #expect(slot.canGroup(with: window) == true)
    }
    
    @Test("Cannot group different apps")
    func testCannotGroupDifferentApps() {
        var slot = makeSlot()
        slot.addWindow(makeWindow(id: 1, pid: 100, owner: "App1", bundleID: "com.app1"))
        let window = makeWindow(id: 2, pid: 200, owner: "App2", bundleID: "com.app2")
        
        #expect(slot.canGroup(with: window) == false)
    }
    
    // MARK: - Codable Tests
    
    @Test("Slot encodes and decodes correctly")
    @MainActor func testSlotCodable() throws {
        var original = makeSlot(index: 2)
        original.addWindow(makeWindow(id: 1, title: "Test"))
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Slot.self, from: data)
        
        #expect(decoded.id == original.id)
        #expect(decoded.index == original.index)
        #expect(decoded.frame == original.frame)
        #expect(decoded.windowCount == original.windowCount)
        #expect(decoded.primaryWindow?.windowID == original.primaryWindow?.windowID)
    }
}

