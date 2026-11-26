//
//  LayoutGeometryTests.swift
//  RaptoTests
//
//  Comprehensive tests for all predefined layouts:
//  - Geometry validation (zones must tile correctly)
//  - Gap application (window gaps and screen edge gaps)
//  - Resize symmetry (changes should be symmetric)
//  - Swap operations (window swaps should preserve geometry)
//  - Grouping (windows can be grouped in slots)
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

// MARK: - Geometry Validation Tests

@Suite("Layout Geometry Tests")
struct LayoutGeometryTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    // MARK: - Zone Coverage Tests
    
    /// Verify the zone areas of a template add up to the whole screen (overlap is checked separately)
    @Test("All templates zones tile correctly without gaps", arguments: PredefinedTemplates.all)
    func zonesTileCorrectly(template: GridTemplate) {
        var totalCoverage: CGFloat = 0
        
        for zone in template.zones {
            let area = zone.relativeFrame.width * zone.relativeFrame.height
            totalCoverage += area
        }
        
        let tolerance: CGFloat = 0.001
        #expect(abs(totalCoverage - 1.0) < tolerance, 
               "Template '\(template.name)' coverage is \(totalCoverage), expected 1.0")
    }
    
    @Test("Zones don't overlap", arguments: PredefinedTemplates.all)
    func zonesDoNotOverlap(template: GridTemplate) {
        let zones = template.zones
        
        for i in 0..<zones.count {
            for j in (i+1)..<zones.count {
                let zone1 = zones[i].relativeFrame
                let zone2 = zones[j].relativeFrame
                
                let intersection = zone1.intersection(zone2)
                let intersectionArea = intersection.width * intersection.height
                
                let epsilon: CGFloat = 0.0001
                #expect(intersectionArea < epsilon,
                       "Zones \(i) and \(j) overlap in template '\(template.name)'")
            }
        }
    }
    
    @Test("All zones have valid relative bounds", arguments: PredefinedTemplates.all)
    func zonesHaveValidBounds(template: GridTemplate) {
        for (index, zone) in template.zones.enumerated() {
            let frame = zone.relativeFrame
            
            #expect(frame.origin.x >= 0 && frame.origin.x <= 1,
                   "Zone \(index) x origin out of bounds in '\(template.name)'")
            #expect(frame.origin.y >= 0 && frame.origin.y <= 1,
                   "Zone \(index) y origin out of bounds in '\(template.name)'")
            #expect(frame.width > 0 && frame.width <= 1,
                   "Zone \(index) width invalid in '\(template.name)'")
            #expect(frame.height > 0 && frame.height <= 1,
                   "Zone \(index) height invalid in '\(template.name)'")
            #expect(frame.maxX <= 1.0 + 0.001,
                   "Zone \(index) extends beyond right edge in '\(template.name)'")
            #expect(frame.maxY <= 1.0 + 0.001,
                   "Zone \(index) extends beyond top edge in '\(template.name)'")
        }
    }
    
    @Test("Fill orders are valid", arguments: PredefinedTemplates.all)
    func fillOrdersAreValid(template: GridTemplate) {
        let fillOrders = template.zones.map { $0.fillOrder }.sorted()
        let expectedOrders = Array(0..<template.zones.count)
        
        #expect(fillOrders == expectedOrders,
               "Fill orders \(fillOrders) don't match expected \(expectedOrders) in '\(template.name)'")
    }
}

// MARK: - Gap Application Tests

@Suite("Gap Application Tests")
struct GapApplicationTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    @Test("Gaps applied symmetrically for vertical halves")
    func gapsAppliedSymmetricallyForHalves() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 20
        screenManager.screenEdgeGap = 10
        
        let template = PredefinedTemplates.halvesVertical
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let leftFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: sortedZones[0].relativeFrame,
            in: screenFrame
        )
        let rightFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: sortedZones[1].relativeFrame,
            in: screenFrame
        )
        
        #expect(abs(leftFrame.width - rightFrame.width) < 1,
               "Left and right widths should be equal: \(leftFrame.width) vs \(rightFrame.width)")
        
        let gap = rightFrame.minX - leftFrame.maxX
        #expect(abs(gap - 20) < 1, "Gap between windows should be 20, got \(gap)")
        
        #expect(abs(leftFrame.minX - 10) < 1, "Left edge gap should be 10, got \(leftFrame.minX)")
        
        let rightEdgeGap = screenFrame.width - rightFrame.maxX
        #expect(abs(rightEdgeGap - 10) < 1, "Right edge gap should be 10, got \(rightEdgeGap)")
    }
    
    @Test("Full width zones get symmetric horizontal gaps")
    func fullWidthZonesGetSymmetricGaps() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let template = PredefinedTemplates.halvesHorizontal
        
        for zone in template.zones {
            let frame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            
            let leftGap = frame.minX
            let rightGap = screenFrame.width - frame.maxX
            
            #expect(abs(leftGap - 8) < 1, "Left gap should be 8, got \(leftGap)")
            #expect(abs(rightGap - 8) < 1, "Right gap should be 8, got \(rightGap)")
        }
    }
    
    @Test("Full height zones get symmetric vertical gaps")
    func fullHeightZonesGetSymmetricGaps() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let template = PredefinedTemplates.halvesVertical
        
        for zone in template.zones {
            let frame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            
            let bottomGap = frame.minY
            let topGap = screenFrame.height - frame.maxY
            
            #expect(abs(bottomGap - 8) < 1, "Bottom gap should be 8, got \(bottomGap)")
            #expect(abs(topGap - 8) < 1, "Top gap should be 8, got \(topGap)")
        }
    }
    
    @Test("Gaps applied correctly for all templates", arguments: PredefinedTemplates.all)
    func gapsAppliedForAllTemplates(template: GridTemplate) {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        var frames: [CGRect] = []
        
        for zone in template.zones {
            let frame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: screenFrame
            )
            frames.append(frame)
            
            #expect(frame.minX >= 0, "Frame extends past left edge in '\(template.name)'")
            #expect(frame.minY >= 0, "Frame extends past bottom edge in '\(template.name)'")
            #expect(frame.maxX <= screenFrame.width, "Frame extends past right edge in '\(template.name)'")
            #expect(frame.maxY <= screenFrame.height, "Frame extends past top edge in '\(template.name)'")
            
            #expect(frame.width > 0, "Frame width should be positive in '\(template.name)'")
            #expect(frame.height > 0, "Frame height should be positive in '\(template.name)'")
        }
        
        // Only the overlap check below is asserted; the adjacency gaps are computed but not checked
        for i in 0..<frames.count {
            for j in (i+1)..<frames.count {
                let frame1 = frames[i]
                let frame2 = frames[j]
                
                let horizontalGap1 = frame2.minX - frame1.maxX
                let horizontalGap2 = frame1.minX - frame2.maxX
                
                let verticalGap1 = frame2.minY - frame1.maxY
                let verticalGap2 = frame1.minY - frame2.maxY
                
                // If frames are horizontally adjacent (gap should be windowGap)
                if abs(horizontalGap1 - 16) < 1 || abs(horizontalGap2 - 16) < 1 {
                    // Valid horizontal gap
                }
                
                // If frames are vertically adjacent (gap should be windowGap)
                if abs(verticalGap1 - 16) < 1 || abs(verticalGap2 - 16) < 1 {
                    // Valid vertical gap
                }
                
                let intersection = frame1.intersection(frame2)
                #expect(intersection.isEmpty || intersection.width < 1 || intersection.height < 1,
                       "Frames \(i) and \(j) overlap in '\(template.name)'")
            }
        }
    }
    
    @Test("Gap changes are applied when settings change")
    func gapChangesApplied() {
        let screenManager = ScreenManager()
        let zone = PredefinedTemplates.full.zones[0]
        
        screenManager.windowGap = 0
        screenManager.screenEdgeGap = 0
        let frame1 = screenManager.calculateAbsoluteFrame(
            relativeFrame: zone.relativeFrame,
            in: screenFrame
        )
        
        screenManager.windowGap = 20
        screenManager.screenEdgeGap = 10
        let frame2 = screenManager.calculateAbsoluteFrame(
            relativeFrame: zone.relativeFrame,
            in: screenFrame
        )
        
        #expect(frame2.width < frame1.width, "Width should decrease with edge gaps")
        #expect(frame2.height < frame1.height, "Height should decrease with edge gaps")
        #expect(frame2.minX > frame1.minX, "Left position should increase with edge gaps")
        #expect(frame2.minY > frame1.minY, "Bottom position should increase with edge gaps")
    }
}

// MARK: - Thirds Layout Specific Tests

@Suite("Thirds Layout Tests")
struct ThirdsLayoutTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    @Test("Thirds template has equal column widths")
    func thirdsHaveEqualWidths() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let template = PredefinedTemplates.thirdsVertical
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let frames = sortedZones.map {
            screenManager.calculateAbsoluteFrame(relativeFrame: $0.relativeFrame, in: screenFrame)
        }
        
        let widths = frames.map { $0.width }
        let avgWidth = widths.reduce(0, +) / CGFloat(widths.count)
        
        for (index, width) in widths.enumerated() {
            #expect(abs(width - avgWidth) < 2,
                   "Column \(index) width \(width) differs from average \(avgWidth)")
        }
    }
    
    @Test("Thirds template has correct gaps between columns")
    func thirdsHaveCorrectGaps() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 20
        screenManager.screenEdgeGap = 10
        
        let template = PredefinedTemplates.thirdsVertical
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let frames = sortedZones.map {
            screenManager.calculateAbsoluteFrame(relativeFrame: $0.relativeFrame, in: screenFrame)
        }
        
        let gap01 = frames[1].minX - frames[0].maxX
        #expect(abs(gap01 - 20) < 1, "Gap between columns 0-1 should be 20, got \(gap01)")
        
        let gap12 = frames[2].minX - frames[1].maxX
        #expect(abs(gap12 - 20) < 1, "Gap between columns 1-2 should be 20, got \(gap12)")
        
        #expect(abs(frames[0].minX - 10) < 1, "Left edge gap should be 10")
        
        let rightEdgeGap = screenFrame.width - frames[2].maxX
        #expect(abs(rightEdgeGap - 10) < 1, "Right edge gap should be 10, got \(rightEdgeGap)")
    }
}

// MARK: - Quarters Layout Tests

@Suite("Quarters Layout Tests")
struct QuartersLayoutTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    @Test("Quarters have equal sizes")
    func quartersHaveEqualSizes() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let template = PredefinedTemplates.quarters
        
        let frames = template.zones.map {
            screenManager.calculateAbsoluteFrame(relativeFrame: $0.relativeFrame, in: screenFrame)
        }
        
        let firstSize = frames[0].size
        
        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.width - firstSize.width) < 2,
                   "Quarter \(index) width differs from first")
            #expect(abs(frame.height - firstSize.height) < 2,
                   "Quarter \(index) height differs from first")
        }
    }
    
    @Test("Quarters have horizontal symmetry")
    func quartersHaveHorizontalSymmetry() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let template = PredefinedTemplates.quarters
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        let frames = sortedZones.map {
            screenManager.calculateAbsoluteFrame(relativeFrame: $0.relativeFrame, in: screenFrame)
        }
        
        let leftGap = frames[0].minX
        let rightGap = screenFrame.width - frames[1].maxX
        #expect(abs(leftGap - rightGap) < 1, "Left and right edge gaps should be equal")
        
        let topGap = screenFrame.height - max(frames[0].maxY, frames[1].maxY)
        let bottomGap = min(frames[2].minY, frames[3].minY)
        #expect(abs(topGap - bottomGap) < 1, "Top and bottom edge gaps should be equal")
    }
}

// MARK: - Window Slot Tests

@Suite("Window Slot Tests")
struct WindowSlotTests {
    
    @Test("Slot can hold multiple windows")
    func slotCanHoldMultipleWindows() {
        var slot = Slot(id: UUID(), index: 0, frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        
        let window1 = WindowInfo(
            windowID: 1,
            ownerPID: 100,
            title: "Window 1",
            ownerName: "TestApp",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window2 = WindowInfo(
            windowID: 2,
            ownerPID: 100,
            title: "Window 2",
            ownerName: "TestApp",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        
        slot.addWindow(window1)
        slot.addWindow(window2)
        
        #expect(slot.windowCount == 2, "Slot should have 2 windows")
        #expect(slot.hasGroup == true, "Slot should have a group")
        #expect(slot.primaryWindow?.windowID == window1.windowID, "Primary window should be first added")
    }
    
    @Test("Cycling changes active window in group")
    func cyclingChangesActiveWindow() {
        var slot = Slot(id: UUID(), index: 0, frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        
        let window1 = WindowInfo(windowID: 1, ownerPID: 100, title: "W1", ownerName: "App", frame: .zero)
        let window2 = WindowInfo(windowID: 2, ownerPID: 100, title: "W2", ownerName: "App", frame: .zero)
        let window3 = WindowInfo(windowID: 3, ownerPID: 100, title: "W3", ownerName: "App", frame: .zero)
        
        slot.addWindow(window1)
        slot.addWindow(window2)
        slot.addWindow(window3)
        
        #expect(slot.primaryWindow?.windowID == 1, "Initial primary should be window 1")
        
        slot.cycleForward()
        #expect(slot.primaryWindow?.windowID == 2, "After forward cycle, primary should be window 2")
        
        slot.cycleForward()
        #expect(slot.primaryWindow?.windowID == 3, "After second forward cycle, primary should be window 3")
        
        slot.cycleForward()
        #expect(slot.primaryWindow?.windowID == 1, "Cycling should wrap around to window 1")
        
        slot.cycleBackward()
        #expect(slot.primaryWindow?.windowID == 3, "Backward cycle should go to window 3")
    }
    
    @Test("Removing window from group preserves others")
    func removingWindowPreservesOthers() {
        var slot = Slot(id: UUID(), index: 0, frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        
        let window1 = WindowInfo(windowID: 1, ownerPID: 100, title: "W1", ownerName: "App", frame: .zero)
        let window2 = WindowInfo(windowID: 2, ownerPID: 100, title: "W2", ownerName: "App", frame: .zero)
        let window3 = WindowInfo(windowID: 3, ownerPID: 100, title: "W3", ownerName: "App", frame: .zero)
        
        slot.addWindow(window1)
        slot.addWindow(window2)
        slot.addWindow(window3)
        
        slot.removeWindow(withID: 2)
        
        #expect(slot.windowCount == 2, "Should have 2 windows after removal")
        #expect(slot.windows.contains { $0.windowID == 1 }, "Window 1 should remain")
        #expect(slot.windows.contains { $0.windowID == 3 }, "Window 3 should remain")
        #expect(!slot.windows.contains { $0.windowID == 2 }, "Window 2 should be removed")
    }
}

// MARK: - Layout Manager Swap Tests

@Suite("Layout Manager Swap Tests")
struct LayoutManagerSwapTests {
    
    @Test("Swapping slots preserves frame geometry")
    @MainActor
    func swappingSlotsPreservesGeometry() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        layoutManager.existingWindowIDs = { [1, 2] }
        
        let frame1 = CGRect(x: 0, y: 0, width: 960, height: 1080)
        let frame2 = CGRect(x: 960, y: 0, width: 960, height: 1080)
        
        layoutManager.setLayout(template: PredefinedTemplates.halvesVertical, windows: [])
        
        let window1 = WindowInfo(windowID: 1, ownerPID: 100, title: "W1", ownerName: "App1", frame: frame1)
        let window2 = WindowInfo(windowID: 2, ownerPID: 200, title: "W2", ownerName: "App2", frame: frame2)
        
        layoutManager.assignWindow(window1, to: 0)
        layoutManager.assignWindow(window2, to: 1)
        
        let slot0FrameBefore = layoutManager.state.slots[0].frame
        let slot1FrameBefore = layoutManager.state.slots[1].frame
        
        layoutManager.swapSlotContents(slot1Index: 0, slot2Index: 1)
        
        #expect(layoutManager.state.slots[0].frame == slot0FrameBefore, "Slot 0 frame should be unchanged")
        #expect(layoutManager.state.slots[1].frame == slot1FrameBefore, "Slot 1 frame should be unchanged")
        
        #expect(layoutManager.state.slots[0].primaryWindow?.windowID == 2, "Window 2 should now be in slot 0")
        #expect(layoutManager.state.slots[1].primaryWindow?.windowID == 1, "Window 1 should now be in slot 1")
    }
    
    @Test("Expected frame returns correct slot geometry")
    @MainActor
    func expectedFrameReturnsCorrectGeometry() {
        let screenManager = ScreenManager()
        let layoutManager = WindowLayoutManager(screenManager: screenManager)
        layoutManager.existingWindowIDs = { [1] }
        
        layoutManager.setLayout(template: PredefinedTemplates.quarters, windows: [])
        
        let window = WindowInfo(windowID: 1, ownerPID: 100, title: "W1", ownerName: "App", frame: .zero)
        layoutManager.assignWindow(window, to: 0)
        
        let expectedFrame = layoutManager.expectedFrame(for: 1)
        let slotFrame = layoutManager.state.slots[0].frame
        
        #expect(expectedFrame == slotFrame, "Expected frame should match slot frame")
    }
}

// MARK: - Ultrawide Templates Tests

@Suite("Ultrawide Template Tests")
struct UltrawideTemplateTests {
    
    let ultrawideScreenFrame = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    
    @Test("Center Focus has 60% center and 20% sidebars")
    func centerFocusProportions() {
        let template = PredefinedTemplates.centerFocus
        let sortedZones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
        
        #expect(abs(sortedZones[0].relativeFrame.width - 0.6) < 0.001, "Center should be 60% width")
        #expect(abs(sortedZones[0].relativeFrame.minX - 0.2) < 0.001, "Center should start at 20%")
        
        #expect(abs(sortedZones[1].relativeFrame.width - 0.2) < 0.001, "Left sidebar should be 20% width")
        #expect(abs(sortedZones[1].relativeFrame.minX) < 0.001, "Left sidebar should start at 0%")
        
        #expect(abs(sortedZones[2].relativeFrame.width - 0.2) < 0.001, "Right sidebar should be 20% width")
        #expect(abs(sortedZones[2].relativeFrame.minX - 0.8) < 0.001, "Right sidebar should start at 80%")
    }
    
    @Test("4 Columns have equal widths")
    func fourColumnsEqualWidths() {
        let template = PredefinedTemplates.columns4
        
        for zone in template.zones {
            #expect(abs(zone.relativeFrame.width - 0.25) < 0.001, "Each column should be 25% width")
        }
    }
    
    @Test("Ultrawide templates work with gaps", arguments: [
        PredefinedTemplates.centerFocus,
        PredefinedTemplates.centerSplitSidebars,
        PredefinedTemplates.centerWide,
        PredefinedTemplates.centerLeftSplit,
        PredefinedTemplates.centerRightSplit,
        PredefinedTemplates.columns4
    ])
    func ultrawideTemplatesWithGaps(template: GridTemplate) {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        var maxRight: CGFloat = 0
        var minLeft: CGFloat = ultrawideScreenFrame.width
        
        for zone in template.zones {
            let frame = screenManager.calculateAbsoluteFrame(
                relativeFrame: zone.relativeFrame,
                in: ultrawideScreenFrame
            )
            
            minLeft = min(minLeft, frame.minX)
            maxRight = max(maxRight, frame.maxX)
            
            #expect(frame.minX >= 0, "Frame extends past left edge")
            #expect(frame.maxX <= ultrawideScreenFrame.width, "Frame extends past right edge")
            #expect(frame.minY >= 0, "Frame extends past bottom edge")
            #expect(frame.maxY <= ultrawideScreenFrame.height, "Frame extends past top edge")
        }
        
        #expect(minLeft >= 8, "Should have screen edge gap on left")
        
        #expect(ultrawideScreenFrame.width - maxRight >= 8, "Should have screen edge gap on right")
    }
}

// MARK: - Coordinate Conversion Tests

@Suite("Coordinate Conversion Tests")
struct CoordinateConversionTests {
    
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    @Test("Coordinate conversion is reversible")
    func coordinateConversionIsReversible() {
        let screenManager = ScreenManager()
        
        let originalFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
        
        let cgFrame = screenManager.convertToCGCoordinates(frame: originalFrame)
        let backToAppKit = screenManager.convertFromCGCoordinates(frame: cgFrame)
        
        #expect(abs(originalFrame.origin.x - backToAppKit.origin.x) < 0.001, "X should be preserved")
        #expect(abs(originalFrame.origin.y - backToAppKit.origin.y) < 0.001, "Y should be preserved")
        #expect(abs(originalFrame.width - backToAppKit.width) < 0.001, "Width should be preserved")
        #expect(abs(originalFrame.height - backToAppKit.height) < 0.001, "Height should be preserved")
    }
}
