//
//  Zone.swift
//  Rapto
//
//  Model representing an individual zone within a grid template.
//

import Foundation

/// An individual rectangular area within a grid template where a window can be placed
nonisolated struct Zone: Identifiable, Codable, Equatable {
    let id: UUID
    /// Relative frame with values 0.0-1.0 that adapt to screen dimensions.
    /// Bottom-left origin like AppKit, so y 0.5 with height 0.5 is the top half.
    let relativeFrame: CGRect
    let fillOrder: Int
    
    init(id: UUID = UUID(), relativeFrame: CGRect, fillOrder: Int) {
        self.id = id
        self.relativeFrame = relativeFrame
        self.fillOrder = fillOrder
    }
}
