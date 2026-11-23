//
//  ScreenManagerGapsTest.swift
//  RaptoTests
//
//  Test for window gap functionality
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("ScreenManager Gap Tests")
struct ScreenManagerGapsTests {
    
    @Test("Window gaps are applied correctly for two halves")
    func testWindowGapsForHalves() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        
        let leftRelativeFrame = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let leftAbsoluteFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: leftRelativeFrame,
            in: screenFrame
        )
        
        let rightRelativeFrame = CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0)
        let rightAbsoluteFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: rightRelativeFrame,
            in: screenFrame
        )
        
        print("Left frame: \\(leftAbsoluteFrame)")
        print("Right frame: \\(rightAbsoluteFrame)")
        
        let gapBetween = rightAbsoluteFrame.origin.x - (leftAbsoluteFrame.origin.x + leftAbsoluteFrame.width)
        print("Gap between windows: \\(gapBetween)px")
        
        #expect(gapBetween == 16.0, "Expected 16px gap between windows, got \\(gapBetween)px")
    }
    
    @Test("Screen edge gaps are applied correctly")
    func testScreenEdgeGaps() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 16
        screenManager.screenEdgeGap = 8
        
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        
        let leftFrame = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let leftResult = screenManager.calculateAbsoluteFrame(
            relativeFrame: leftFrame,
            in: screenFrame
        )
        
        print("Left window x: \\(leftResult.origin.x)")
        #expect(leftResult.origin.x == 8.0, "Expected 8px from left edge")
        
        let rightFrame = CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0)
        let rightResult = screenManager.calculateAbsoluteFrame(
            relativeFrame: rightFrame,
            in: screenFrame
        )
        
        let distanceFromRightEdge = screenFrame.width - (rightResult.origin.x + rightResult.width)
        print("Distance from right edge: \\(distanceFromRightEdge)")
        #expect(distanceFromRightEdge == 8.0, "Expected 8px from right edge")
    }
}
