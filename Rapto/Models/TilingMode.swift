//
//  TilingMode.swift
//  Rapto
//
//  Enum representing the three tiling modes available in Rapto.
//

import Foundation

enum TilingMode: String, Codable, CaseIterable, Identifiable {
    /// None: No tiling or window management on this desktop
    case none
    
    /// Auto-tiling: Switches layouts automatically as windows open and close
    case autoTiling
    
    /// Drag to Snap: Windows stay free until dragged to screen edges, the top layout bar or a desktop layout
    case dragSnap
    
    /// Manual: Keeps windows in the slots of the layout chosen for the desktop
    case manualAssignment
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .autoTiling:
            return "Auto-tiling"
        case .dragSnap:
            return "Drag to Snap"
        case .manualAssignment:
            return "Manual"
        }
    }
    
}
