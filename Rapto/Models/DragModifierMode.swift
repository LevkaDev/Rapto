//
//  DragModifierMode.swift
//  Rapto
//
//  The three valid combinations of modifier keys when dragging a window onto another slot.
//  Backed by the existing `swapRequiresOption` (Control for swap) and `moveRequiresShift`
//  booleans in UserDefaults so saved settings and backups stay compatible.
//

import Foundation

enum DragModifierMode: String, CaseIterable, Identifiable, Equatable {
    /// Plain drag moves & groups into the target slot; holding Control swaps slots.
    case moveByDefault
    /// Plain drag swaps slots; holding Shift moves & groups into the target slot.
    case swapByDefault
    /// Plain drag is ignored by Rapto; Control swaps and Shift moves & groups.
    case modifiersOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveByDefault:
            return "Move & Group by default"
        case .swapByDefault:
            return "Swap by default"
        case .modifiersOnly:
            return "Require a key for both"
        }
    }

    var subtitle: String {
        switch self {
        case .moveByDefault:
            return "Plain drag moves into the slot (grouping if occupied) · Hold ⌃ Control to swap"
        case .swapByDefault:
            return "Plain drag swaps slots · Hold ⇧ Shift to move & group into the slot"
        case .modifiersOnly:
            return "Hold ⌃ Control to swap · Hold ⇧ Shift to move & group (plain drag does neither)"
        }
    }

    var keyBadges: [String] {
        switch self {
        case .moveByDefault: return ["⌃"]
        case .swapByDefault: return ["⇧"]
        case .modifiersOnly: return ["⌃", "⇧"]
        }
    }

    nonisolated static func from(swapRequiresControl: Bool, moveRequiresShift: Bool) -> DragModifierMode {
        switch (swapRequiresControl, moveRequiresShift) {
        case (true, false):
            return .moveByDefault
        case (false, true):
            return .swapByDefault
        case (true, true):
            return .modifiersOnly
        case (false, false):
            // Both disabled is disallowed by AppState; treat as the standard default.
            return .moveByDefault
        }
    }

    nonisolated var flags: (swapRequiresControl: Bool, moveRequiresShift: Bool) {
        switch self {
        case .moveByDefault: return (true, false)
        case .swapByDefault: return (false, true)
        case .modifiersOnly: return (true, true)
        }
    }

    /// Writes both flags in an order that never transiently hits `(false, false)`,
    /// avoiding AppState's mutual auto-enable guard.
    func apply(to appState: AppState) {
        switch self {
        case .moveByDefault:
            if !appState.swapRequiresOption { appState.swapRequiresOption = true }
            if appState.moveRequiresShift { appState.moveRequiresShift = false }
        case .swapByDefault:
            if !appState.moveRequiresShift { appState.moveRequiresShift = true }
            if appState.swapRequiresOption { appState.swapRequiresOption = false }
        case .modifiersOnly:
            if !appState.swapRequiresOption { appState.swapRequiresOption = true }
            if !appState.moveRequiresShift { appState.moveRequiresShift = true }
        }
    }
}
