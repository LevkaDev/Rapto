//
//  DragHint.swift
//  Rapto
//
//  In-action hint labels drawn inside the slot / zone highlight while dragging a window,
//  plus persistent usage counters (`hintKeyUses`) so modifier prompts step aside once learned.
//

import Foundation

/// Permanent UserDefaults keys inside the `hintKeyUses` dictionary.
/// Never rename raw values after release.
nonisolated enum HintKeyID: String, CaseIterable, Hashable, Sendable {
    case swapKey = "swapKey"
    case moveKey = "moveKey"
    case snapFreeKey = "snapFreeKey"
    case spaceBarOptionKey = "spaceBarOptionKey"

    /// Number of completed actions with a modifier key before its prompt stops appearing.
    static let learnedThreshold = 10
}

nonisolated enum HintKeyStore {
    static let defaultsKey = "hintKeyUses"

    static func learnedKeys(in defaults: UserDefaults = .standard) -> Set<HintKeyID> {
        guard let raw = defaults.dictionary(forKey: defaultsKey) else { return [] }
        var learned = Set<HintKeyID>()
        for key in HintKeyID.allCases {
            if let count = (raw[key.rawValue] as? NSNumber)?.intValue,
               count >= HintKeyID.learnedThreshold {
                learned.insert(key)
            }
        }
        return learned
    }

    static func count(for key: HintKeyID, in defaults: UserDefaults = .standard) -> Int {
        (defaults.dictionary(forKey: defaultsKey)?[key.rawValue] as? NSNumber)?.intValue ?? 0
    }

    static func recordCompletedUse(of key: HintKeyID, in defaults: UserDefaults = .standard) {
        var counts: [String: Int] = [:]
        if let existing = defaults.dictionary(forKey: defaultsKey) {
            for (k, v) in existing {
                if let n = (v as? NSNumber)?.intValue {
                    counts[k] = n
                }
            }
        }
        let updated = (counts[key.rawValue] ?? 0) + 1
        counts[key.rawValue] = updated
        defaults.set(counts, forKey: defaultsKey)
    }
}

/// Title and optional secondary line drawn centered inside a drag preview highlight.
nonisolated struct DragHint: Equatable, Sendable {
    let title: String
    let detail: String?

    enum Target: Equatable, Sendable {
        case window(ownerName: String, sameApp: Bool)
        case emptySlot
        /// Auto-tiling on the same display, where dropping onto another window always swaps.
        case swapOnlyWindow
    }

    /// Computes the label for `WindowSwapService` (Manual and Auto-tiling drags).
    static func swapOrMove(
        showsHints: Bool,
        target: Target,
        requiresControlForSwap: Bool,
        moveRequiresShift: Bool,
        controlPressed: Bool,
        shiftPressed: Bool,
        isGroupingEnabled: Bool,
        learnedKeys: Set<HintKeyID>
    ) -> DragHint? {
        guard showsHints else { return nil }

        if target == .swapOnlyWindow {
            return DragHint(title: "Swap", detail: nil)
        }

        if requiresControlForSwap && moveRequiresShift {
            if controlPressed {
                return target == .emptySlot
                    ? nil
                    : DragHint(
                        title: "Swap",
                        detail: learnedKeys.contains(.moveKey) ? nil : "Hold ⇧ instead to move"
                    )
            }
            if shiftPressed {
                switch target {
                case .emptySlot:
                    return DragHint(title: "Move here", detail: nil)
                case let .window(ownerName, sameApp):
                    return DragHint(
                        title: "Move here",
                        detail: joinParts(
                            groupDetail(ownerName: ownerName, sameApp: sameApp, isGroupingEnabled: isGroupingEnabled),
                            learnedKeys.contains(.swapKey) ? nil : "Hold ⌃ to swap"
                        )
                    )
                case .swapOnlyWindow:
                    return DragHint(title: "Swap", detail: nil)
                }
            }
            // Plain drag when both modifiers are required does nothing
            return nil
        }

        // Default: Move & Group on plain drag, Control to swap
        if requiresControlForSwap && !moveRequiresShift {
            if controlPressed {
                return target == .emptySlot
                    ? nil
                    : DragHint(
                        title: "Swap",
                        detail: learnedKeys.contains(.swapKey) ? nil : "Release ⌃ to move"
                    )
            }
            switch target {
            case .emptySlot:
                return DragHint(title: "Move here", detail: nil)
            case let .window(ownerName, sameApp):
                return DragHint(
                    title: "Move here",
                    detail: joinParts(
                        groupDetail(ownerName: ownerName, sameApp: sameApp, isGroupingEnabled: isGroupingEnabled),
                        learnedKeys.contains(.swapKey) ? nil : "Hold ⌃ to swap"
                    )
                )
            case .swapOnlyWindow:
                return DragHint(title: "Swap", detail: nil)
            }
        }

        // Swap by default: Swap on plain drag, Shift to move & group
        if !requiresControlForSwap && moveRequiresShift {
            if shiftPressed {
                switch target {
                case .emptySlot:
                    return DragHint(title: "Move here", detail: nil)
                case let .window(ownerName, sameApp):
                    return DragHint(
                        title: "Move here",
                        detail: joinParts(
                            groupDetail(ownerName: ownerName, sameApp: sameApp, isGroupingEnabled: isGroupingEnabled),
                            learnedKeys.contains(.moveKey) ? nil : "Release ⇧ to swap"
                        )
                    )
                case .swapOnlyWindow:
                    return DragHint(title: "Swap", detail: nil)
                }
            }
            return target == .emptySlot
                ? nil
                : DragHint(
                    title: "Swap",
                    detail: learnedKeys.contains(.moveKey) ? nil : "Hold ⇧ to move here"
                )
        }

        return nil
    }

    /// Computes the label for `DragSnapService` snap zone previews.
    static func dragSnap(showsHints: Bool, learnedKeys: Set<HintKeyID>) -> DragHint? {
        guard showsHints else { return nil }
        return DragHint(
            title: "Snap here",
            detail: learnedKeys.contains(.snapFreeKey) ? nil : "Hold ⌥ to move freely"
        )
    }

    private static func groupDetail(ownerName: String, sameApp: Bool, isGroupingEnabled: Bool) -> String? {
        guard isGroupingEnabled else { return nil }
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sameApp
            ? "Groups with the other \(trimmed) window"
            : "Groups with \(trimmed)"
    }

    private static func joinParts(_ first: String?, _ second: String?) -> String? {
        switch (first, second) {
        case let (a?, b?): return "\(a) · \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}
