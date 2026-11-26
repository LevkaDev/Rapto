//
//  PredefinedTemplates.swift
//  Rapto
//
//  Predefined grid layout templates for common window arrangements.
//

import Foundation
import CoreGraphics

nonisolated enum PredefinedTemplates {
    // MARK: - Fixed UUIDs for predefined templates (must be stable across app launches)
    private static let fullID = UUID(uuidString: "00000001-0000-0000-0000-000000000001")!
    private static let halvesVerticalID = UUID(uuidString: "00000001-0000-0000-0000-000000000002")!
    private static let halvesHorizontalID = UUID(uuidString: "00000001-0000-0000-0000-000000000003")!
    private static let thirdsVerticalID = UUID(uuidString: "00000001-0000-0000-0000-000000000004")!
    private static let onePlusTwoLeftID = UUID(uuidString: "00000001-0000-0000-0000-000000000005")!
    private static let onePlusTwoRightID = UUID(uuidString: "00000001-0000-0000-0000-000000000006")!
    private static let quartersID = UUID(uuidString: "00000001-0000-0000-0000-000000000007")!
    private static let centerFocusID = UUID(uuidString: "00000001-0000-0000-0000-000000000008")!
    private static let centerSplitSidebarsID = UUID(uuidString: "00000001-0000-0000-0000-000000000009")!
    private static let centerWideID = UUID(uuidString: "00000001-0000-0000-0000-00000000000A")!
    private static let centerLeftSplitID = UUID(uuidString: "00000001-0000-0000-0000-00000000000B")!
    private static let centerRightSplitID = UUID(uuidString: "00000001-0000-0000-0000-00000000000C")!
    private static let columns4ID = UUID(uuidString: "00000001-0000-0000-0000-00000000000D")!

    /// Retired duplicate of `centerSplitSidebars` (had identical 20% / 60% / 20% zones and fill order).
    /// Kept so saved preferences, layouts, workspaces, shortcuts, and scripts resolve cleanly.
    static let retiredTwoOneTwoID = UUID(uuidString: "00000001-0000-0000-0000-00000000000E")!

    /// Resolves retired built-in layout IDs to their active replacement.
    static func canonicalID(for id: UUID) -> UUID {
        id == retiredTwoOneTwoID ? centerSplitSidebarsID : id
    }

    static func canonicalOptionalID(for id: UUID?) -> UUID? {
        id.map(canonicalID(for:))
    }
    
    static let full = GridTemplate(
        id: fullID,
        name: "Full",
        icon: "rectangle",
        zones: [Zone(relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1), fillOrder: 0)]
    )
    
    static let halvesVertical = GridTemplate(
        id: halvesVerticalID,
        name: "Halves Vertical",
        icon: "rectangle.split.2x1",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), fillOrder: 1)
        ]
    )
    
    static let halvesHorizontal = GridTemplate(
        id: halvesHorizontalID,
        name: "Halves Horizontal",
        icon: "rectangle.split.1x2",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 0.5), fillOrder: 1)
        ]
    )
    
    static let thirdsVertical = GridTemplate(
        id: thirdsVerticalID,
        name: "Thirds",
        icon: "rectangle.split.3x1",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 1.0/3.0, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 1.0/3.0, y: 0, width: 1.0/3.0, height: 1), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 2.0/3.0, y: 0, width: 1.0/3.0, height: 1), fillOrder: 2)
        ]
    )
    
    static let onePlusTwoLeft = GridTemplate(
        id: onePlusTwoLeftID,
        name: "1+2 Left",
        icon: "rectangle.split.2x1.fill",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), fillOrder: 2)
        ]
    )
    
    static let onePlusTwoRight = GridTemplate(
        id: onePlusTwoRightID,
        name: "1+2 Right",
        icon: "rectangle.split.2x1.fill",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), fillOrder: 2)
        ]
    )
    
    static let quarters = GridTemplate(
        id: quartersID,
        name: "Quarters",
        icon: "square.grid.2x2",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), fillOrder: 2),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), fillOrder: 3)
        ]
    )
    
    // MARK: - Ultrawide Monitor Templates
    
    /// Center takes ~60% (simulating 27" on ultrawide), sidebars ~20% each
    static let centerFocus = GridTemplate(
        id: centerFocusID,
        name: "Center Focus",
        icon: "rectangle.center.inset.filled",
        zones: [
            Zone(relativeFrame: CGRect(x: 0.2, y: 0, width: 0.6, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.2, height: 1), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.8, y: 0, width: 0.2, height: 1), fillOrder: 2)
        ]
    )
    
    static let centerSplitSidebars = GridTemplate(
        id: centerSplitSidebarsID,
        name: "Center + Split Sides",
        icon: "rectangle.split.3x1.fill",
        zones: [
            Zone(relativeFrame: CGRect(x: 0.2, y: 0, width: 0.6, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0.5, width: 0.2, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.2, height: 0.5), fillOrder: 2),
            Zone(relativeFrame: CGRect(x: 0.8, y: 0.5, width: 0.2, height: 0.5), fillOrder: 3),
            Zone(relativeFrame: CGRect(x: 0.8, y: 0, width: 0.2, height: 0.5), fillOrder: 4)
        ]
    )
    
    static let centerWide = GridTemplate(
        id: centerWideID,
        name: "Center Wide",
        icon: "rectangle.inset.filled",
        zones: [
            Zone(relativeFrame: CGRect(x: 0.15, y: 0, width: 0.7, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.15, height: 1), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.85, y: 0, width: 0.15, height: 1), fillOrder: 2)
        ]
    )
    
    static let centerLeftSplit = GridTemplate(
        id: centerLeftSplitID,
        name: "Center + Left Split",
        icon: "rectangle.leadinghalf.inset.filled",
        zones: [
            Zone(relativeFrame: CGRect(x: 0.25, y: 0, width: 0.75, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.25, height: 0.5), fillOrder: 2)
        ]
    )
    
    static let centerRightSplit = GridTemplate(
        id: centerRightSplitID,
        name: "Center + Right Split",
        icon: "rectangle.trailinghalf.inset.filled",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.75, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5), fillOrder: 2)
        ]
    )
    
    static let columns4 = GridTemplate(
        id: columns4ID,
        name: "4 Columns",
        icon: "rectangle.split.3x1",
        zones: [
            Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.25, height: 1), fillOrder: 0),
            Zone(relativeFrame: CGRect(x: 0.25, y: 0, width: 0.25, height: 1), fillOrder: 1),
            Zone(relativeFrame: CGRect(x: 0.5, y: 0, width: 0.25, height: 1), fillOrder: 2),
            Zone(relativeFrame: CGRect(x: 0.75, y: 0, width: 0.25, height: 1), fillOrder: 3)
        ]
    )
    
    static let standard: [GridTemplate] = [
        full,
        halvesVertical,
        halvesHorizontal,
        thirdsVertical,
        onePlusTwoLeft,
        onePlusTwoRight,
        quarters
    ]

    static let ultrawide: [GridTemplate] = [
        centerFocus,
        centerSplitSidebars,
        centerWide,
        centerLeftSplit,
        centerRightSplit,
        columns4
    ]

    static let ultrawideIDs: Set<UUID> = Set(ultrawide.map(\.id))

    static let all: [GridTemplate] = standard + ultrawide
}
