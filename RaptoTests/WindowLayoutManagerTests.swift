//
//  WindowLayoutManagerTests.swift
//  RaptoTests
//
//  Unit tests for WindowLayoutManager - unified state manager
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("WindowLayoutManager Tests")
struct WindowLayoutManagerTests {
    
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
    
    private func makeZone(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        order: Int
    ) -> Zone {
        Zone(
            relativeFrame: CGRect(x: x, y: y, width: width, height: height),
            fillOrder: order
        )
    }
    
    private func makeHalvesTemplate() -> GridTemplate {
        GridTemplate(
            id: UUID(),
            name: "Halves",
            icon: "square.split.2x1",
            zones: [
                makeZone(x: 0, y: 0, width: 0.5, height: 1.0, order: 0),
                makeZone(x: 0.5, y: 0, width: 0.5, height: 1.0, order: 1)
            ]
        )
    }
    
    private func makeThreeColumnTemplate() -> GridTemplate {
        GridTemplate(
            id: UUID(),
            name: "3 Columns",
            icon: "square.split.3x1",
            zones: [
                makeZone(x: 0, y: 0, width: 0.333, height: 1.0, order: 0),
                makeZone(x: 0.333, y: 0, width: 0.334, height: 1.0, order: 1),
                makeZone(x: 0.667, y: 0, width: 0.333, height: 1.0, order: 2)
            ]
        )
    }
    
    // MARK: - LayoutState Tests
    
    @Test("Empty layout state")
    func testEmptyLayoutState() {
        let state = LayoutState()
        
        #expect(state.isActive == false)
        #expect(state.slotCount == 0)
        #expect(state.managedWindowIDs.isEmpty)
        #expect(state.allWindows.isEmpty)
        #expect(state.hasGroups == false)
    }
    
    @Test("Layout state with template and slots")
    func testLayoutStateWithSlots() {
        var state = LayoutState()
        let template = makeHalvesTemplate()
        state.template = template
        
        let slot1 = Slot(
            id: template.zones[0].id,
            index: 0,
            frame: CGRect(x: 0, y: 0, width: 960, height: 1080),
            windows: [makeWindow(id: 1)]
        )
        let slot2 = Slot(
            id: template.zones[1].id,
            index: 1,
            frame: CGRect(x: 960, y: 0, width: 960, height: 1080),
            windows: [makeWindow(id: 2)]
        )
        state.slots = [slot1, slot2]
        
        #expect(state.isActive == true)
        #expect(state.slotCount == 2)
        #expect(state.managedWindowIDs.count == 2)
        #expect(state.allWindows.count == 2)
    }
    
    @Test("Layout state slot lookup by window ID")
    func testSlotLookupByWindowID() {
        var state = LayoutState()
        let template = makeHalvesTemplate()
        state.template = template
        
        let window = makeWindow(id: 42)
        var slot = Slot(
            id: template.zones[0].id,
            index: 0,
            frame: CGRect(x: 0, y: 0, width: 960, height: 1080)
        )
        slot.addWindow(window)
        state.slots = [slot]
        
        let foundSlot = state.slot(for: 42)
        #expect(foundSlot != nil)
        #expect(foundSlot?.index == 0)
        
        let notFound = state.slot(for: 999)
        #expect(notFound == nil)
    }
    
    @Test("Layout state find slot for grouping")
    func testFindSlotForGrouping() {
        var state = LayoutState()
        let template = makeHalvesTemplate()
        state.template = template
        
        var slot = Slot(
            id: template.zones[0].id,
            index: 0,
            frame: CGRect(x: 0, y: 0, width: 960, height: 1080)
        )
        slot.addWindow(makeWindow(id: 1, bundleID: "com.apple.Safari"))
        state.slots = [slot, Slot(id: template.zones[1].id, index: 1, frame: .zero)]
        
        let safariWindow = makeWindow(id: 2, bundleID: "com.apple.Safari")
        let result = state.findSlotForGrouping(window: safariWindow)
        
        #expect(result != nil)
        #expect(result?.index == 0)
    }
    
    @Test("Layout state has groups detection")
    func testHasGroupsDetection() {
        var state = LayoutState()
        let template = makeHalvesTemplate()
        state.template = template
        
        var slot1 = Slot(id: template.zones[0].id, index: 0, frame: .zero)
        slot1.addWindow(makeWindow(id: 1))
        state.slots = [slot1]
        
        #expect(state.hasGroups == false)
        
        state.slots[0].addWindow(makeWindow(id: 2))
        
        #expect(state.hasGroups == true)
    }
    
    @Test("Layout state empty slots")
    func testEmptySlots() {
        var state = LayoutState()
        let template = makeThreeColumnTemplate()
        state.template = template
        
        var slot1 = Slot(id: template.zones[0].id, index: 0, frame: .zero)
        slot1.addWindow(makeWindow(id: 1))
        let slot2 = Slot(id: template.zones[1].id, index: 1, frame: .zero)
        let slot3 = Slot(id: template.zones[2].id, index: 2, frame: .zero)
        state.slots = [slot1, slot2, slot3]
        
        #expect(state.emptySlots.count == 2)
        
        let firstEmpty = state.firstEmptySlot()
        #expect(firstEmpty?.index == 1)
    }
}

// MARK: - AssignWindowsToSlots Tests

@Suite("Window Assignment Logic Tests")
struct WindowAssignmentTests {
    
    private func makeWindow(
        id: CGWindowID,
        bundleID: String,
        owner: String
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            ownerPID: pid_t(100 + id),
            title: "Window \(id)",
            ownerName: owner,
            bundleIdentifier: bundleID,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }
    
    @Test("Single window per app distribution")
    @MainActor
    func testSingleWindowPerApp() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        
        let windows = [
            makeWindow(id: 1, bundleID: "com.apple.Safari", owner: "Safari"),
            makeWindow(id: 2, bundleID: "com.apple.Terminal", owner: "Terminal"),
            makeWindow(id: 3, bundleID: "com.apple.Finder", owner: "Finder")
        ]
        
        let result = layoutManager.assignWindowsToSlots(windows: windows, slotCount: 3)
        
        #expect(result.count == 3)
        #expect(result[0].count == 1)
        #expect(result[1].count == 1)
        #expect(result[2].count == 1)
    }
    
    @Test("Windows of one app take the free slots, the rest group up")
    @MainActor
    func testSameAppWindowsGrouped() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        
        let windows = [
            makeWindow(id: 1, bundleID: "com.apple.Safari", owner: "Safari"),
            makeWindow(id: 2, bundleID: "com.apple.Safari", owner: "Safari"),
            makeWindow(id: 3, bundleID: "com.apple.Safari", owner: "Safari")
        ]
        
        let result = layoutManager.assignWindowsToSlots(windows: windows, slotCount: 2)
        
        let totalWindows = result.reduce(0) { $0 + $1.count }
        #expect(totalWindows == 3)
        #expect(result.map(\.count).sorted() == [1, 2])
    }
    
    @Test("More apps than slots causes overflow grouping")
    @MainActor
    func testOverflowGrouping() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        
        let windows = [
            makeWindow(id: 1, bundleID: "com.app1", owner: "App1"),
            makeWindow(id: 2, bundleID: "com.app2", owner: "App2"),
            makeWindow(id: 3, bundleID: "com.app3", owner: "App3"),
            makeWindow(id: 4, bundleID: "com.app4", owner: "App4")
        ]
        
        let result = layoutManager.assignWindowsToSlots(windows: windows, slotCount: 2)
        
        #expect(result.count == 2)
        
        let totalWindows = result.reduce(0) { $0 + $1.count }
        #expect(totalWindows == 4)
    }
    
    @Test("Empty window list returns empty slots")
    @MainActor
    func testEmptyWindowList() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        
        let result = layoutManager.assignWindowsToSlots(windows: [], slotCount: 3)
        
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.isEmpty })
    }
    
    @Test("Zero slots returns empty result")
    @MainActor
    func testZeroSlots() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        
        let windows = [
            makeWindow(id: 1, bundleID: "com.test", owner: "Test")
        ]
        
        let result = layoutManager.assignWindowsToSlots(windows: windows, slotCount: 0)
        
        #expect(result.isEmpty)
    }
}

// MARK: - LayoutOperationMode Tests

@Suite("Layout Operation Mode Tests")
struct LayoutOperationModeTests {
    
    @Test("Mode descriptions are correct")
    func testModeDescriptions() {
        let idle: LayoutOperationMode = .idle
        let resizing: LayoutOperationMode = .resizing
        let applyingLayout: LayoutOperationMode = .applyingLayout
        let snappingBack: LayoutOperationMode = .snappingBack
        let swapping: LayoutOperationMode = .swapping
        
        #expect(idle.description == "idle")
        #expect(resizing.description == "resizing")
        #expect(applyingLayout.description == "applyingLayout")
        #expect(snappingBack.description == "snappingBack")
        #expect(swapping.description == "swapping")
    }
    
    @Test("Modes are equatable")
    func testModeEquatable() {
        let idle1: LayoutOperationMode = .idle
        let idle2: LayoutOperationMode = .idle
        let resizing: LayoutOperationMode = .resizing
        
        #expect(idle1 == idle2)
        #expect(idle1 != resizing)
    }
}

// MARK: - CycleDirection Tests

@Suite("Cycle Direction Tests")
struct CycleDirectionTests {
    
    @Test("Direction descriptions are correct")
    func testDirectionDescriptions() {
        #expect(CycleDirection.forward.description == "forward")
        #expect(CycleDirection.backward.description == "backward")
    }

    @Test("Two windows of one app side by side: the slot nearest to the window's corner is found")
    func testFindSlotNearestToWindowOrigin() {
        func window(_ id: CGWindowID) -> WindowInfo {
            WindowInfo(windowID: id, ownerPID: 100, title: "Window", ownerName: "App", bundleIdentifier: "com.test.app", frame: .zero)
        }
        var state = LayoutState()
        state.slots = [
            Slot(id: UUID(), index: 0, frame: CGRect(x: 0, y: 25, width: 720, height: 875), windows: [window(1)]),
            Slot(id: UUID(), index: 1, frame: CGRect(x: 720, y: 25, width: 720, height: 875), windows: [window(2)])
        ]
        
        // The right window's corner is also inside the left slot widened by the tolerance
        #expect(state.findSlotIndex(forPID: 100, windowOrigin: CGPoint(x: 720, y: 25)) == 1)
        #expect(state.findSlotIndex(forPID: 100, windowOrigin: CGPoint(x: 0, y: 25)) == 0)
        #expect(state.findSlotIndex(forPID: 999, windowOrigin: CGPoint(x: 720, y: 25)) == nil)
        #expect(state.findSlotIndex(forPID: 100, windowOrigin: CGPoint(x: 2000, y: 25)) == nil)
    }
}
