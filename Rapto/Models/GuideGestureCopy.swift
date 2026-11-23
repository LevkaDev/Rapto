//
//  GuideGestureCopy.swift
//  Rapto
//
//  Live descriptions for the Essential Gestures & Shortcuts cards in Settings → Guide,
//  built directly from the user's active HotkeyPreset and modifier settings.
//

import Foundation

struct GuideGestureCardModel: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let badges: [String]
    let detail: String
    let targetTab: SettingsTab
    let targetLabel: String
}

enum GuideGestureCopy {

    struct Snapshot: Equatable {
        var dragMode: DragModifierMode
        var isGroupingEnabled: Bool
        var enableScrollToSwitch: Bool
        var focusModeEnabled: Bool
        var focusModeDoubleTapEnabled: Bool
        var focusModeDoubleTapModifier: FocusModeModifierKey
        var hasCustomFocusZone: Bool
        var floatingDoubleTapEnabled: Bool
        var floatingDoubleTapModifier: FloatingModifierKey
        var spaceBarMoveFollowsWindow: Bool
        var bindings: [HotkeyAction: HotkeyBinding]
    }

    static func cards(for snapshot: Snapshot) -> [GuideGestureCardModel] {
        [
            draggingCard(for: snapshot),
            groupingCard(for: snapshot),
            focusCard(for: snapshot),
            floatingCard(for: snapshot),
            desktopsBarCard(for: snapshot),
            switcherAndResizeCard(for: snapshot)
        ]
    }

    static func draggingCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let manualRule: String
        switch snapshot.dragMode {
        case .moveByDefault:
            manualRule = "Manual: plain drag moves into a slot (grouping if occupied); hold ⌃ Control to swap."
        case .swapByDefault:
            manualRule = "Manual: plain drag swaps slots; hold ⇧ Shift to move & group into a slot."
        case .modifiersOnly:
            manualRule = "Manual: hold ⌃ Control to swap or ⇧ Shift to move & group (plain drag is ignored)."
        }

        return GuideGestureCardModel(
            id: "dragging",
            icon: "hand.draw",
            title: "Dragging Onto Another Window",
            badges: snapshot.dragMode.keyBadges,
            detail: "\(manualRule) Auto-tiling: dragging onto another window on the same display always swaps. Change anytime in Behavior.",
            targetTab: .behavior,
            targetLabel: "Behavior"
        )
    }

    static func groupingCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let cycle = shortcut(.cycleGroupForward, in: snapshot.bindings)
        let scrollPhrase = snapshot.enableScrollToSwitch ? ", scroll on the badge," : ""
        let cyclePhrase = cycle.map { " or press \($0)" } ?? ""
        let statusPrefix = snapshot.isGroupingEnabled ? "" : "Grouping is currently off. When enabled: "

        return GuideGestureCardModel(
            id: "grouping",
            icon: "rectangle.stack",
            title: "Window Groups (All Modes)",
            badges: cycle.map { [$0] } ?? [],
            detail: "\(statusPrefix)Click an app icon in the corner badge\(scrollPhrase)\(cyclePhrase) to switch grouped windows. Drag the badge to nudge it aside; drag an icon out to ungroup.",
            targetTab: .behavior,
            targetLabel: "Behavior"
        )
    }

    static func focusCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let hotkey = shortcut(.toggleFullscreen, in: snapshot.bindings)
        let doubleClick = snapshot.focusModeDoubleTapEnabled
            ? "\(shortSymbol(for: snapshot.focusModeDoubleTapModifier))+Double-click"
            : nil

        var badges: [String] = []
        if let doubleClick { badges.append(doubleClick) }
        if let hotkey { badges.append(hotkey) }

        let triggerText: String
        switch (doubleClick, hotkey) {
        case let (_?, hk?):
            triggerText = "Hold \(shortSymbol(for: snapshot.focusModeDoubleTapModifier)) and double-click a window, or press \(hk)"
        case let (nil, hk?):
            triggerText = "Press \(hk)"
        case let (dc?, nil):
            triggerText = "Use \(dc)"
        case (nil, nil):
            triggerText = "Assign a shortcut or enable double-click in Behavior"
        }

        let areaNote = snapshot.hasCustomFocusZone
            ? "expands to your custom Focus Zone (set in the Layout Overlay)."
            : "expands to full screen, or set a custom Focus Zone in the Layout Overlay."
        let disabledPrefix = snapshot.focusModeEnabled ? "" : "Focus Mode is currently off. "

        return GuideGestureCardModel(
            id: "focus",
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Focus Mode",
            badges: badges,
            detail: "\(disabledPrefix)\(triggerText) — temporarily \(areaNote)",
            targetTab: .behavior,
            targetLabel: "Behavior"
        )
    }

    static func floatingCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let hotkey = shortcut(.toggleFloat, in: snapshot.bindings)
        let doubleClickSymbol = snapshot.floatingDoubleTapEnabled
            ? "\(shortSymbol(for: snapshot.floatingDoubleTapModifier))+Double-click"
            : nil

        var badges: [String] = []
        if let hotkey { badges.append(hotkey) }
        if let doubleClickSymbol { badges.append(doubleClickSymbol) }

        let triggerText: String
        switch (hotkey, snapshot.floatingDoubleTapEnabled) {
        case let (hk?, true):
            triggerText = "Press \(hk) or \(shortSymbol(for: snapshot.floatingDoubleTapModifier)) + double-click"
        case let (hk?, false):
            triggerText = "Press \(hk) (optional modifier + double-click is available in Behavior)"
        case (nil, true):
            triggerText = "Hold \(shortSymbol(for: snapshot.floatingDoubleTapModifier)) and double-click"
        case (nil, false):
            triggerText = "Set a Toggle Float shortcut or enable modifier + double-click"
        }

        return GuideGestureCardModel(
            id: "floating",
            icon: "pin",
            title: "Float a Window",
            badges: badges,
            detail: "\(triggerText) to keep a single window above and outside tiling without ignoring the whole app.",
            targetTab: .behavior,
            targetLabel: "Behavior"
        )
    }

    static func desktopsBarCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let followNote = snapshot.spaceBarMoveFollowsWindow
            ? "switches to that desktop by default; hold ⌥ Option on drop to stay here"
            : "stays on the current desktop by default; hold ⌥ Option on drop to follow it"

        return GuideGestureCardModel(
            id: "desktopsBar",
            icon: "menubar.rectangle",
            title: "Desktops Bar & Custom Layouts",
            badges: ["Right-click", "⌥"],
            detail: "Right-click any desktop in the bar for Mode, Layout, Workspaces, or Create Layout from Windows. Drag an app icon onto another desktop or + (\(followNote)).",
            targetTab: .general,
            targetLabel: "General"
        )
    }

    static func switcherAndResizeCard(for snapshot: Snapshot) -> GuideGestureCardModel {
        let switcher = shortcut(.openWindowSwitcher, in: snapshot.bindings)
        let restore = shortcut(.restoreLayout, in: snapshot.bindings)
        let shrinkW = shortcut(.resizeShrinkWidth, in: snapshot.bindings)
        let growW = shortcut(.resizeGrowWidth, in: snapshot.bindings)

        var badges: [String] = []
        if let switcher { badges.append(switcher) }
        if let restore { badges.append(restore) }

        let switcherClause = switcher.map { "Press \($0) and type initials (e.g. “tg” for Telegram) or press Return for the last window." }
            ?? "Bind Window Switcher in Shortcuts to jump to any window by typing initials."
        let resizeClause: String
        if let shrinkW, let growW {
            resizeClause = "Drag shared slot borders with the mouse or resize via \(shrinkW) / \(growW)"
        } else {
            resizeClause = "Drag shared slot borders with the mouse to resize neighbor windows together"
        }
        let restoreClause = restore.map { "; \($0) restores slot positions." } ?? "."

        return GuideGestureCardModel(
            id: "switcherResize",
            icon: "magnifyingglass.circle",
            title: "Window Switcher & Neighbor Resize",
            badges: badges,
            detail: "\(switcherClause) \(resizeClause)\(restoreClause)",
            targetTab: .shortcuts,
            targetLabel: "Shortcuts"
        )
    }

    // MARK: - Helpers

    private static func shortcut(_ action: HotkeyAction, in bindings: [HotkeyAction: HotkeyBinding]) -> String? {
        bindings[action]?.displayString
    }

    static func shortSymbol(for modifier: FocusModeModifierKey) -> String {
        switch modifier {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .command: return "⌘"
        case .optionCommand: return "⌥⌘"
        }
    }

    static func shortSymbol(for modifier: FloatingModifierKey) -> String {
        switch modifier {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .command: return "⌘"
        case .optionCommand: return "⌥⌘"
        }
    }
}
