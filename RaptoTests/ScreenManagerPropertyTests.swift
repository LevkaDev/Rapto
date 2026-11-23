//
//  ScreenManagerPropertyTests.swift
//  RaptoTests
//
//  Property-based tests for ScreenManager frame calculations.
//

import Testing
import Foundation
import CoreGraphics
@testable import Rapto

// MARK: - Test Data Generators

struct RandomCGFloat {
    static func generate(in range: ClosedRange<CGFloat> = 0.0...1.0) -> CGFloat {
        return CGFloat.random(in: range)
    }
}

/// Generates random relative frames (values 0.0-1.0) that are valid zones
struct RandomRelativeFrame {
    static func generate() -> CGRect {
        // Generate origin in range that allows for non-zero width/height
        let x = CGFloat.random(in: 0.0...0.9)
        let y = CGFloat.random(in: 0.0...0.9)
        let maxWidth = 1.0 - x
        let maxHeight = 1.0 - y
        let width = CGFloat.random(in: 0.1...maxWidth)
        let height = CGFloat.random(in: 0.1...maxHeight)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct RandomScreenFrame {
    static func generate() -> CGRect {
        // Realistic screen dimensions (origin can vary for multi-monitor setups)
        let originX = CGFloat.random(in: -2000...2000)
        let originY = CGFloat.random(in: -2000...2000)
        let width = CGFloat.random(in: 800...3840)  // From small to 4K
        let height = CGFloat.random(in: 600...2160) // From small to 4K
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}

struct FrameCalculationTestCase: CustomStringConvertible, Sendable {
    let relativeFrame: CGRect
    let screenFrame: CGRect
    
    var description: String {
        "relative: \(relativeFrame), screen: \(screenFrame)"
    }
    
    static func generate() -> FrameCalculationTestCase {
        return FrameCalculationTestCase(
            relativeFrame: RandomRelativeFrame.generate(),
            screenFrame: RandomScreenFrame.generate()
        )
    }
}

// MARK: - Property Tests

struct ScreenManagerPropertyTests {
    
    static let testCases: [FrameCalculationTestCase] = (0..<100).map { _ in
        FrameCalculationTestCase.generate()
    }
    
    /// *For any* Zone with relativeFrame R and screen visibleFrame S, the calculated absolute frame SHALL equal:
    /// - x = S.origin.x + (R.origin.x * S.width)
    /// - y = S.origin.y + (R.origin.y * S.height)
    /// - width = R.width * S.width
    /// - height = R.height * S.height
    @Test("Property 12: Relative to Absolute Frame Calculation", arguments: testCases)
    func relativeToAbsoluteFrameCalculation(testCase: FrameCalculationTestCase) {
        // Both gaps default to 0, so the frame is the plain proportional one
        let screenManager = ScreenManager()
        let relativeFrame = testCase.relativeFrame
        let screenFrame = testCase.screenFrame
        
        let absoluteFrame = screenManager.calculateAbsoluteFrame(
            relativeFrame: relativeFrame,
            in: screenFrame
        )
        
        let expectedX = screenFrame.origin.x + (relativeFrame.origin.x * screenFrame.width)
        let expectedY = screenFrame.origin.y + (relativeFrame.origin.y * screenFrame.height)
        let expectedWidth = relativeFrame.width * screenFrame.width
        let expectedHeight = relativeFrame.height * screenFrame.height
        
        let tolerance: CGFloat = 0.0001
        
        #expect(
            abs(absoluteFrame.origin.x - expectedX) < tolerance,
            "X coordinate mismatch: got \(absoluteFrame.origin.x), expected \(expectedX)"
        )
        #expect(
            abs(absoluteFrame.origin.y - expectedY) < tolerance,
            "Y coordinate mismatch: got \(absoluteFrame.origin.y), expected \(expectedY)"
        )
        #expect(
            abs(absoluteFrame.width - expectedWidth) < tolerance,
            "Width mismatch: got \(absoluteFrame.width), expected \(expectedWidth)"
        )
        #expect(
            abs(absoluteFrame.height - expectedHeight) < tolerance,
            "Height mismatch: got \(absoluteFrame.height), expected \(expectedHeight)"
        )
    }
}

// MARK: - Following Visible Area Changes

struct ScreenRescaleTests {

    @Test("A zone frame moved to another resolution is that zone's frame there, gaps included")
    func zoneFrameFollowsResolution() {
        let screenManager = ScreenManager()
        screenManager.windowGap = 8
        screenManager.screenEdgeGap = 12
        let old = CGRect(x: 0, y: 25, width: 3840, height: 1595)
        let new = CGRect(x: 0, y: 25, width: 5120, height: 2135)
        let zones = PredefinedTemplates.all.flatMap(\.zones).map(\.relativeFrame)

        for zone in zones {
            let before = screenManager.calculateAbsoluteFrame(relativeFrame: zone, in: old)
            let expected = screenManager.calculateAbsoluteFrame(relativeFrame: zone, in: new)
            let moved = screenManager.rescale(before, from: old, to: new)
            #expect(abs(moved.minX - expected.minX) < 0.01 && abs(moved.minY - expected.minY) < 0.01
                && abs(moved.width - expected.width) < 0.01 && abs(moved.height - expected.height) < 0.01,
                "Zone \(zone): got \(moved), expected \(expected)")
        }
    }

    @Test("A resized slot keeps its share of the screen")
    func resizedSlotKeepsItsShare() {
        let screenManager = ScreenManager()
        let old = CGRect(x: 0, y: 0, width: 3840, height: 1600)
        let new = CGRect(x: 0, y: 0, width: 5120, height: 2400)
        let moved = screenManager.rescale(CGRect(x: 0, y: 0, width: 2304, height: 1600), from: old, to: new)
        #expect(moved == CGRect(x: 0, y: 0, width: 3072, height: 2400))
    }

    @Test("A slot ending a point short of the screen edge comes back the same after other resolutions")
    func roundTripKeepsFrame() {
        let screenManager = ScreenManager()
        screenManager.screenEdgeGap = 4
        let sizes = [CGSize(width: 3840, height: 1590), CGSize(width: 5120, height: 2130), CGSize(width: 2560, height: 1050),
                     CGSize(width: 3200, height: 1320), CGSize(width: 3840, height: 1590)]
        let original = CGRect(x: 1374.4609375, y: 34, width: 2460.52734375, height: 1544.26953125)
        var frame = original
        for (old, new) in zip(sizes, sizes.dropFirst()) {
            frame = screenManager.rescale(frame, from: CGRect(origin: CGPoint(x: 0, y: 30), size: old),
                                          to: CGRect(origin: CGPoint(x: 0, y: 30), size: new))
        }
        #expect(abs(frame.minX - original.minX) < 0.01 && abs(frame.minY - original.minY) < 0.01
            && abs(frame.width - original.width) < 0.01 && abs(frame.height - original.height) < 0.01, "Got \(frame)")
    }

    @Test("Saved layouts are stamped with a visible area in the shape CGRect decodes from")
    @MainActor func stampedVisibleAreaDecodes() throws {
        let visible = CGRect(x: 10, y: 25, width: 3840, height: 1595)
        let stamp: [String: Any] = [
            "templateID": UUID().uuidString,
            "slots": [],
            "visibleFrame": [[visible.minX, visible.minY], [visible.width, visible.height]],
        ]
        let data = try JSONSerialization.data(withJSONObject: stamp)
        #expect(try JSONDecoder().decode(SavedLayoutInfo.self, from: data).visibleFrame == visible)
    }
}
