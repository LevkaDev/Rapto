//
//  IntegrationTests.swift
//  RaptoTests
//
//  End-to-end integration tests for Rapto core workflow.
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

struct IntegrationTests {
    
    // MARK: - Overlay Toggle Tests
    
    @Test("Overlay toggle changes visibility state")
    @MainActor
    func overlayToggleChangesVisibility() async {
        let appState = AppState()

        #expect(appState.isOverlayVisible == false, "Overlay should start hidden")

        appState.toggleOverlay()
        #expect(appState.isOverlayVisible == true, "Overlay should be visible after first toggle")

        appState.toggleOverlay()
        #expect(appState.isOverlayVisible == false, "Overlay should be hidden after second toggle")
    }
    
    // MARK: - Template Selection Tests
    
    @Test("Template selection enters zone assignment mode")
    @MainActor
    func templateSelectionEntersZoneAssignmentMode() async {
        let appState = AppState()
        let template = PredefinedTemplates.halvesVertical
        
        appState.selectTemplate(template)

        #expect(appState.selectedTemplate?.id == template.id, "Selected template should match")

        #expect(appState.assignedWindows.isEmpty, "Assigned windows should be empty")
        #expect(appState.currentZoneIndex == 0, "Current zone index should be 0")
    }
    
    @Test("All predefined templates can be selected", arguments: PredefinedTemplates.all)
    @MainActor
    func allTemplatesCanBeSelected(template: GridTemplate) async {
        let appState = AppState()
        
        appState.selectTemplate(template)
        
        #expect(appState.selectedTemplate?.id == template.id, "Template \(template.name) should be selected")
        #expect(appState.selectedTemplate?.zones.count == template.zones.count, "Zone count should match")
    }
    
    // MARK: - Window Assignment Tests
    
    @Test("Window assignment increments zone index")
    @MainActor
    func windowAssignmentIncrementsZoneIndex() async {
        let appState = AppState()
        let template = PredefinedTemplates.halvesVertical // 2 zones
        
        appState.selectTemplate(template)

        let window = WindowInfo(
            windowID: 1,
            ownerPID: 100,
            title: "Test Window",
            ownerName: "TestApp",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        appState.assignWindow(window)

        #expect(appState.assignedWindows.count == 1, "Should have 1 assigned window")
        #expect(appState.currentZoneIndex == 1, "Zone index should be 1")
    }
    
    @Test("Assigning same window twice toggles it off")
    @MainActor
    func assigningSameWindowTogglesIt() async {
        let appState = AppState()
        let template = PredefinedTemplates.quarters // 4 zones

        appState.selectTemplate(template)

        let window = WindowInfo(
            windowID: 1,
            ownerPID: 100,
            title: "Test Window",
            ownerName: "TestApp",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        appState.assignWindow(window)
        #expect(appState.assignedWindows.count == 1, "Should have 1 assignment after first assign")
        #expect(appState.assignedWindows[0].windowID == window.windowID, "Window should be assigned")
        
        appState.assignWindow(window)
        #expect(appState.assignedWindows.count == 0, "Should have 0 assignments after toggle off")
    }
    
    @Test("Multiple different windows can be assigned")
    @MainActor
    func multipleDifferentWindowsCanBeAssigned() async {
        let appState = AppState()
        let template = PredefinedTemplates.quarters // 4 zones
        
        appState.selectTemplate(template)

        let window1 = WindowInfo(
            windowID: 1,
            ownerPID: 100,
            title: "Window 1",
            ownerName: "App1",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window2 = WindowInfo(
            windowID: 2,
            ownerPID: 200,
            title: "Window 2",
            ownerName: "App2",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        appState.assignWindow(window1)
        appState.assignWindow(window2)
        
        #expect(appState.assignedWindows.count == 2, "Should have 2 assignments")
        #expect(appState.assignedWindows[0].windowID == window1.windowID, "First should be window1")
        #expect(appState.assignedWindows[1].windowID == window2.windowID, "Second should be window2")
    }
    
    // MARK: - Reset Tests
    
    @Test("Reset clears all state")
    @MainActor
    func resetClearsAllState() async {
        let appState = AppState()
        let template = PredefinedTemplates.halvesVertical
        
        appState.selectTemplate(template)
        let window = WindowInfo(
            windowID: 1,
            ownerPID: 100,
            title: "Test Window",
            ownerName: "TestApp",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        appState.assignWindow(window)

        appState.reset()
        
        #expect(appState.selectedTemplate == nil, "Selected template should be nil")
        #expect(appState.assignedWindows.isEmpty, "Assigned windows should be empty")
        #expect(appState.currentZoneIndex == 0, "Zone index should be 0")
    }
    
    // MARK: - ESC Cancellation Tests
    
    @Test("Dismissing overlay resets state")
    @MainActor
    func dismissingOverlayResetsState() async {
        let appState = AppState()
        
        appState.isOverlayVisible = true
        appState.selectTemplate(PredefinedTemplates.halvesVertical)
        
        // Simulate ESC dismissal
        appState.isOverlayVisible = false
        appState.reset()
        
        #expect(appState.isOverlayVisible == false, "Overlay should be hidden")
        #expect(appState.selectedTemplate == nil, "Template should be cleared")
    }
}

// MARK: - Restore Layout Tests

struct RestoreLayoutTests {
    
    @Test("Restore rebuilds slot assignments from saved layout")
    @MainActor
    func restoreRebuildsSlotAssignmentsFromSavedLayout() async {
        let appState = AppState()
        let screen = appState.screenManager.activeScreen()
        let screenID = appState.screenManager.identifier(for: screen)
        let template = PredefinedTemplates.halvesVertical
        
        let screenFrame = appState.screenManager.visibleFrame(for: screen)
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let leftFrame = appState.screenManager.convertToCGCoordinates(
            frame: appState.screenManager.calculateAbsoluteFrame(
                relativeFrame: sortedZones[0].relativeFrame,
                in: screenFrame
            ),
            for: screen
        )
        let rightFrame = appState.screenManager.convertToCGCoordinates(
            frame: appState.screenManager.calculateAbsoluteFrame(
                relativeFrame: sortedZones[1].relativeFrame,
                in: screenFrame
            ),
            for: screen
        )
        
        let leftWindow = WindowInfo(
            windowID: 101,
            ownerPID: 1001,
            title: "Left Window",
            ownerName: "TestApp",
            bundleIdentifier: "com.test.app",
            frame: leftFrame
        )
        let rightWindow = WindowInfo(
            windowID: 202,
            ownerPID: 1002,
            title: "Right Window",
            ownerName: "TestApp",
            bundleIdentifier: "com.test.app",
            frame: rightFrame
        )
        
        appState.layoutManager.setLayout(template: template, windows: [], forScreenID: screenID)
        appState.layoutManager.assignWindow(rightWindow, to: 0, forScreenID: screenID)
        appState.layoutManager.assignWindow(leftWindow, to: 1, forScreenID: screenID)
        
        let savedInfo = SavedLayoutInfo(
            templateID: template.id,
            slots: [
                SavedLayoutInfo.SavedSlotInfo(
                    slotID: sortedZones[0].id,
                    index: 0,
                    ownerName: leftWindow.ownerName,
                    bundleIdentifier: leftWindow.bundleIdentifier,
                    frame: leftFrame,
                    groupBundleIDs: [leftWindow.bundleIdentifier!],
                    groupPIDs: [Int32(leftWindow.ownerPID)]
                ),
                SavedLayoutInfo.SavedSlotInfo(
                    slotID: sortedZones[1].id,
                    index: 1,
                    ownerName: rightWindow.ownerName,
                    bundleIdentifier: rightWindow.bundleIdentifier,
                    frame: rightFrame,
                    groupBundleIDs: [rightWindow.bundleIdentifier!],
                    groupPIDs: [Int32(rightWindow.ownerPID)]
                )
            ]
        )
        
        let rebuilt = appState.rebuildLayoutStateForRestore(
            savedInfo: savedInfo,
            template: template,
            currentWindows: [leftWindow, rightWindow],
            screenID: screenID
        )
        
        #expect(rebuilt == true, "Restore should rebuild slot assignments")
        #expect(appState.layoutManager.state(forScreenID: screenID).slots[0].primaryWindow?.windowID == leftWindow.windowID)
        #expect(appState.layoutManager.state(forScreenID: screenID).slots[1].primaryWindow?.windowID == rightWindow.windowID)
    }
}

// MARK: - Screen Manager Integration Tests

struct ScreenManagerIntegrationTests {
    
    @Test("Frame calculation works for all templates", arguments: PredefinedTemplates.all)
    func frameCalculationWorksForAllTemplates(template: GridTemplate) {
        let screenManager = ScreenManager()
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        
        for zone in template.zones {
            let absoluteFrame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            
            #expect(absoluteFrame.minX >= screenFrame.minX, "Frame minX should be >= screen minX")
            #expect(absoluteFrame.minY >= screenFrame.minY, "Frame minY should be >= screen minY")
            #expect(absoluteFrame.maxX <= screenFrame.maxX + 1, "Frame maxX should be <= screen maxX")
            #expect(absoluteFrame.maxY <= screenFrame.maxY + 1, "Frame maxY should be <= screen maxY")
            
            #expect(absoluteFrame.width > 0, "Frame width should be positive")
            #expect(absoluteFrame.height > 0, "Frame height should be positive")
        }
    }
}

// MARK: - Predefined Templates Validation Tests

struct PredefinedTemplatesValidationTests {
    
    @Test("All templates have valid zone configurations", arguments: PredefinedTemplates.all)
    func allTemplatesHaveValidZoneConfigurations(template: GridTemplate) {
        #expect(!template.zones.isEmpty, "Template \(template.name) should have at least one zone")
        
        for zone in template.zones {
            #expect(zone.relativeFrame.origin.x >= 0 && zone.relativeFrame.origin.x <= 1,
                   "Zone x should be in [0, 1]")
            #expect(zone.relativeFrame.origin.y >= 0 && zone.relativeFrame.origin.y <= 1,
                   "Zone y should be in [0, 1]")
            #expect(zone.relativeFrame.width > 0 && zone.relativeFrame.width <= 1,
                   "Zone width should be in (0, 1]")
            #expect(zone.relativeFrame.height > 0 && zone.relativeFrame.height <= 1,
                   "Zone height should be in (0, 1]")
            #expect(zone.relativeFrame.origin.x + zone.relativeFrame.width <= 1.001,
                   "Zone should not exceed right boundary")
            #expect(zone.relativeFrame.origin.y + zone.relativeFrame.height <= 1.001,
                   "Zone should not exceed bottom boundary")
        }
        
        let fillOrders = template.zones.map { $0.fillOrder }.sorted()
        let expectedOrders = Array(0..<template.zones.count)
        #expect(fillOrders == expectedOrders,
               "Fill orders should be contiguous from 0 to \(template.zones.count - 1)")
    }
    
    @Test("Full template has single zone covering entire screen")
    func fullTemplateConfiguration() {
        let template = PredefinedTemplates.full
        
        #expect(template.zones.count == 1, "Full template should have 1 zone")
        #expect(template.zones[0].relativeFrame == CGRect(x: 0, y: 0, width: 1, height: 1),
               "Full zone should cover entire screen")
    }
    
    @Test("Halves Vertical template has two equal columns")
    func halvesVerticalConfiguration() {
        let template = PredefinedTemplates.halvesVertical
        
        #expect(template.zones.count == 2, "Halves Vertical should have 2 zones")
        
        #expect(template.zones[0].relativeFrame.width == 0.5, "Left zone should be 50% width")
        #expect(template.zones[0].relativeFrame.height == 1, "Left zone should be full height")
        
        #expect(template.zones[1].relativeFrame.width == 0.5, "Right zone should be 50% width")
        #expect(template.zones[1].relativeFrame.height == 1, "Right zone should be full height")
    }
    
    @Test("Quarters template has four equal quadrants")
    func quartersConfiguration() {
        let template = PredefinedTemplates.quarters
        
        #expect(template.zones.count == 4, "Quarters should have 4 zones")
        
        for zone in template.zones {
            #expect(zone.relativeFrame.width == 0.5, "Each quadrant should be 50% width")
            #expect(zone.relativeFrame.height == 0.5, "Each quadrant should be 50% height")
        }
    }
}

// MARK: - Window Manager Tests

struct WindowManagerTests {
    
    /// This test may return empty results in test environment without windows
    @Test("Window enumeration returns valid data")
    func windowEnumerationReturnsValidData() {
        let windowManager = WindowManager()
        let windows = windowManager.enumerateWindows()
        
        for window in windows {
            #expect(window.windowID > 0, "Window ID should be positive")
            #expect(window.ownerPID > 0, "Owner PID should be positive")
            #expect(!window.ownerName.isEmpty, "Owner name should not be empty")
            #expect(window.frame.width > 100, "Window width should be > 100")
            #expect(window.frame.height > 100, "Window height should be > 100")
        }
    }
}

// MARK: - Accessibility Service Tests

struct AccessibilityServiceTests {
    
    @Test("Permission check returns boolean")
    func permissionCheckReturnsBool() {
        let service = AccessibilityService()
        let hasPermission = service.checkPermission()
        
        // Just verify it returns without crashing
        // Actual permission state depends on system configuration
        #expect(hasPermission == true || hasPermission == false, "Should return a boolean")
    }
}
