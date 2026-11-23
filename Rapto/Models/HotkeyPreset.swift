//
//  HotkeyPreset.swift
//  Rapto
//
//  Hotkey presets for migration from popular tiling managers.
//

import Foundation
import Carbon

// MARK: - Hotkey Action

enum HotkeyAction: String, CaseIterable, Codable {
    case focusLeft = "focus_left"
    case focusRight = "focus_right"
    case focusUp = "focus_up"
    case focusDown = "focus_down"
    
    case swapLeft = "swap_left"
    case swapRight = "swap_right"
    case swapUp = "swap_up"
    case swapDown = "swap_down"
    
    case moveLeft = "move_left"
    case moveRight = "move_right"
    case moveUp = "move_up"
    case moveDown = "move_down"
    
    case resizeShrinkWidth = "resize_shrink_width"
    case resizeGrowWidth = "resize_grow_width"
    case resizeShrinkHeight = "resize_shrink_height"
    case resizeGrowHeight = "resize_grow_height"
    
    case cycleLayout = "cycle_layout"
    case switchToManual = "switch_to_manual"
    case switchToAuto = "switch_to_auto"
    case switchToDragSnap = "switch_to_drag_snap"
    case toggleFloat = "toggle_float"
    case toggleFullscreen = "toggle_fullscreen"
    case openOverlay = "open_overlay"
    
    case focusSlot1 = "focus_slot_1"
    case focusSlot2 = "focus_slot_2"
    case focusSlot3 = "focus_slot_3"
    case focusSlot4 = "focus_slot_4"
    case focusSlot5 = "focus_slot_5"
    case focusSlot6 = "focus_slot_6"
    case focusSlot7 = "focus_slot_7"
    case focusSlot8 = "focus_slot_8"
    case focusSlot9 = "focus_slot_9"
    
    case applyTemplate1 = "apply_template_1"
    case applyTemplate2 = "apply_template_2"
    case applyTemplate3 = "apply_template_3"
    case applyTemplate4 = "apply_template_4"
    case applyTemplate5 = "apply_template_5"
    case applyTemplate6 = "apply_template_6"
    case applyTemplate7 = "apply_template_7"
    case applyTemplate8 = "apply_template_8"
    case applyTemplate9 = "apply_template_9"
    
    case cycleGroupForward = "cycle_group_forward"
    case cycleGroupBackward = "cycle_group_backward"
    case toggleGroupIndicators = "toggle_group_indicators"
    case toggleGroupWindows = "toggle_group_windows"
    
    case moveToScreenLeft = "move_to_screen_left"
    case moveToScreenRight = "move_to_screen_right"
    
    case restoreLayout = "restore_layout"
    
    case openWindowSwitcher = "open_window_switcher"
    
    case moveToPreviousDesktop = "move_to_previous_desktop"
    case moveToNextDesktop = "move_to_next_desktop"
    case moveToDesktop1 = "move_to_desktop_1"
    case moveToDesktop2 = "move_to_desktop_2"
    case moveToDesktop3 = "move_to_desktop_3"
    case moveToDesktop4 = "move_to_desktop_4"
    case moveToDesktop5 = "move_to_desktop_5"
    case moveToDesktop6 = "move_to_desktop_6"
    case moveToDesktop7 = "move_to_desktop_7"
    case moveToDesktop8 = "move_to_desktop_8"
    case moveToDesktop9 = "move_to_desktop_9"
    
    static let moveToDesktopNumbered: [HotkeyAction] = [
        .moveToDesktop1, .moveToDesktop2, .moveToDesktop3, .moveToDesktop4, .moveToDesktop5,
        .moveToDesktop6, .moveToDesktop7, .moveToDesktop8, .moveToDesktop9
    ]
    
    var displayName: String {
        switch self {
        case .focusLeft: return "Focus Left"
        case .focusRight: return "Focus Right"
        case .focusUp: return "Focus Up"
        case .focusDown: return "Focus Down"
        case .swapLeft: return "Swap Left"
        case .swapRight: return "Swap Right"
        case .swapUp: return "Swap Up"
        case .swapDown: return "Swap Down"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .resizeShrinkWidth: return "Shrink Width"
        case .resizeGrowWidth: return "Grow Width"
        case .resizeShrinkHeight: return "Shrink Height"
        case .resizeGrowHeight: return "Grow Height"
        case .cycleLayout: return "Cycle Layout Mode"
        case .switchToManual: return "Switch to Manual"
        case .switchToAuto: return "Switch to Auto-tiling"
        case .switchToDragSnap: return "Switch to Drag-to-Snap"
        case .toggleFloat: return "Toggle Float"
        case .toggleFullscreen: return "Toggle Focus Mode"
        case .openOverlay: return "Open Overlay"
        case .focusSlot1: return "Focus Slot 1"
        case .focusSlot2: return "Focus Slot 2"
        case .focusSlot3: return "Focus Slot 3"
        case .focusSlot4: return "Focus Slot 4"
        case .focusSlot5: return "Focus Slot 5"
        case .focusSlot6: return "Focus Slot 6"
        case .focusSlot7: return "Focus Slot 7"
        case .focusSlot8: return "Focus Slot 8"
        case .focusSlot9: return "Focus Slot 9"
        case .applyTemplate1: return "Apply Template 1"
        case .applyTemplate2: return "Apply Template 2"
        case .applyTemplate3: return "Apply Template 3"
        case .applyTemplate4: return "Apply Template 4"
        case .applyTemplate5: return "Apply Template 5"
        case .applyTemplate6: return "Apply Template 6"
        case .applyTemplate7: return "Apply Template 7"
        case .applyTemplate8: return "Apply Template 8"
        case .applyTemplate9: return "Apply Template 9"
        case .cycleGroupForward: return "Cycle Group"
        case .cycleGroupBackward: return "Cycle Group (unused)"
        case .toggleGroupIndicators: return "Toggle Group Indicators"
        case .toggleGroupWindows: return "Group/Ungroup Windows"
        case .moveToScreenLeft: return "Move to Left Screen"
        case .moveToScreenRight: return "Move to Right Screen"
        case .restoreLayout: return "Restore Layout"
        case .openWindowSwitcher: return "Window Switcher"
        case .moveToPreviousDesktop: return "Move to Previous Desktop"
        case .moveToNextDesktop: return "Move to Next Desktop"
        case .moveToDesktop1: return "Move to Desktop 1"
        case .moveToDesktop2: return "Move to Desktop 2"
        case .moveToDesktop3: return "Move to Desktop 3"
        case .moveToDesktop4: return "Move to Desktop 4"
        case .moveToDesktop5: return "Move to Desktop 5"
        case .moveToDesktop6: return "Move to Desktop 6"
        case .moveToDesktop7: return "Move to Desktop 7"
        case .moveToDesktop8: return "Move to Desktop 8"
        case .moveToDesktop9: return "Move to Desktop 9"
        }
    }
    
}

extension HotkeyPreset {
    /// The shortcuts of one four-direction family (swap, move). A direction the user cleared is
    /// left out, and the other three keep working.
    func directionBindings(
        left: HotkeyAction, right: HotkeyAction, up: HotkeyAction, down: HotkeyAction
    ) -> [(keyCode: UInt32, modifiers: UInt32, direction: HotkeyManager.SwapDirection)] {
        let directions: [(HotkeyAction, HotkeyManager.SwapDirection)] = [(left, .left), (right, .right), (up, .up), (down, .down)]
        return directions.compactMap { action, direction in
            guard let binding = bindings[action] else { return nil }
            return (binding.keyCode, binding.modifiers, direction)
        }
    }
}

// MARK: - Hotkey Binding

nonisolated struct HotkeyBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    
    /// Saved in custom bindings when the user clears a shortcut the base preset has
    static let cleared = HotkeyBinding(keyCode: .max, modifiers: 0)
    var isCleared: Bool { self == .cleared }
    
    var displayString: String {
        var parts: [String] = []
        
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        
        parts.append(Self.keyCodeToString(keyCode))
        return parts.joined()
    }
    
    /// Keys that work as a shortcut on their own, without a modifier.
    static let functionKeyCodes: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
    ]

    private static let specialKeyNames: [UInt32: String] = [
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",
        0x30: "Tab", 0x31: "Space", 0x24: "Return", 0x4C: "Enter",
        0x33: "Delete", 0x75: "⌦", 0x35: "Esc",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x52: "Num 0", 0x53: "Num 1", 0x54: "Num 2", 0x55: "Num 3", 0x56: "Num 4",
        0x57: "Num 5", 0x58: "Num 6", 0x59: "Num 7", 0x5B: "Num 8", 0x5C: "Num 9",
        0x41: "Num .", 0x43: "Num *", 0x45: "Num +", 0x4B: "Num /",
        0x4E: "Num -", 0x51: "Num =", 0x47: "Clear"
    ]

    static func keyCodeToString(_ keyCode: UInt32) -> String {
        if let name = specialKeyNames[keyCode] { return name }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// The character a key types in the user's Latin keyboard layout, so the
    /// label is right on any layout and stays readable with a non-Latin one active.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Hotkey Preset Type

enum HotkeyPresetType: String, CaseIterable, Codable, Identifiable {
    case rapto = "Rapto"
    case vimStyle = "Vim Style"
    case custom = "Custom"
    
    var id: String { rawValue }
    
}

// MARK: - Hotkey Preset

struct HotkeyPreset: Codable {
    let type: HotkeyPresetType
    var bindings: [HotkeyAction: HotkeyBinding]
    
    // MARK: - Predefined Presets
    
    /// Key codes of the number row, 1 to 9
    private static let digitKeyCodes: [UInt32] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
    
    /// Rapto default preset (Ctrl+Option + arrows)
    static let rapto: HotkeyPreset = {
        let ctrlOpt = UInt32(controlKey | optionKey)
        let ctrlShift = UInt32(controlKey | shiftKey)
        let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)
        
        var bindings: [HotkeyAction: HotkeyBinding] = [:]
        
        // Focus: Ctrl+Option + arrows
        bindings[.focusLeft] = HotkeyBinding(keyCode: 0x7B, modifiers: ctrlOpt)   // Ctrl+Opt+←
        bindings[.focusDown] = HotkeyBinding(keyCode: 0x7D, modifiers: ctrlOpt)   // Ctrl+Opt+↓
        bindings[.focusUp] = HotkeyBinding(keyCode: 0x7E, modifiers: ctrlOpt)     // Ctrl+Opt+↑
        bindings[.focusRight] = HotkeyBinding(keyCode: 0x7C, modifiers: ctrlOpt)  // Ctrl+Opt+→
        
        // Swap: Ctrl+Shift + arrows
        bindings[.swapLeft] = HotkeyBinding(keyCode: 0x7B, modifiers: ctrlShift)
        bindings[.swapDown] = HotkeyBinding(keyCode: 0x7D, modifiers: ctrlShift)
        bindings[.swapUp] = HotkeyBinding(keyCode: 0x7E, modifiers: ctrlShift)
        bindings[.swapRight] = HotkeyBinding(keyCode: 0x7C, modifiers: ctrlShift)
        
        // Move: Option+Shift + arrows (move without swap)
        let optShift = UInt32(optionKey | shiftKey)
        bindings[.moveLeft] = HotkeyBinding(keyCode: 0x7B, modifiers: optShift)
        bindings[.moveDown] = HotkeyBinding(keyCode: 0x7D, modifiers: optShift)
        bindings[.moveUp] = HotkeyBinding(keyCode: 0x7E, modifiers: optShift)
        bindings[.moveRight] = HotkeyBinding(keyCode: 0x7C, modifiers: optShift)
        
        // Resize: Ctrl+Option + h/j/k/l
        bindings[.resizeShrinkWidth] = HotkeyBinding(keyCode: 0x04, modifiers: ctrlOpt)  // Ctrl+Opt+H
        bindings[.resizeGrowHeight] = HotkeyBinding(keyCode: 0x26, modifiers: ctrlOpt)   // Ctrl+Opt+J
        bindings[.resizeShrinkHeight] = HotkeyBinding(keyCode: 0x28, modifiers: ctrlOpt) // Ctrl+Opt+K
        bindings[.resizeGrowWidth] = HotkeyBinding(keyCode: 0x25, modifiers: ctrlOpt)    // Ctrl+Opt+L
        
        // Layout
        bindings[.openOverlay] = HotkeyBinding(keyCode: 0x05, modifiers: ctrlOpt)    // Ctrl+Opt+G
        bindings[.toggleFloat] = HotkeyBinding(keyCode: 0x11, modifiers: ctrlOpt)    // Ctrl+Opt+T
        bindings[.toggleFullscreen] = HotkeyBinding(keyCode: 0x03, modifiers: ctrlOpt) // Ctrl+Opt+F
        bindings[.cycleLayout] = HotkeyBinding(keyCode: 0x2E, modifiers: ctrlOpt)    // Ctrl+Opt+M
        
        // Focus slots: Ctrl+Shift + 1-9
        bindings[.focusSlot1] = HotkeyBinding(keyCode: 0x12, modifiers: ctrlShift)
        bindings[.focusSlot2] = HotkeyBinding(keyCode: 0x13, modifiers: ctrlShift)
        bindings[.focusSlot3] = HotkeyBinding(keyCode: 0x14, modifiers: ctrlShift)
        bindings[.focusSlot4] = HotkeyBinding(keyCode: 0x15, modifiers: ctrlShift)
        bindings[.focusSlot5] = HotkeyBinding(keyCode: 0x17, modifiers: ctrlShift)
        bindings[.focusSlot6] = HotkeyBinding(keyCode: 0x16, modifiers: ctrlShift)
        bindings[.focusSlot7] = HotkeyBinding(keyCode: 0x1A, modifiers: ctrlShift)
        bindings[.focusSlot8] = HotkeyBinding(keyCode: 0x1C, modifiers: ctrlShift)
        bindings[.focusSlot9] = HotkeyBinding(keyCode: 0x19, modifiers: ctrlShift)
        
        // Groups: Ctrl+Tab, Ctrl+Opt+I, Ctrl+Shift+G
        bindings[.cycleGroupForward] = HotkeyBinding(keyCode: 0x30, modifiers: UInt32(controlKey))
        bindings[.toggleGroupIndicators] = HotkeyBinding(keyCode: 0x22, modifiers: ctrlOpt) // Ctrl+Opt+I
        bindings[.toggleGroupWindows] = HotkeyBinding(keyCode: 0x05, modifiers: ctrlShift)   // Ctrl+Shift+G
        
        // Multi-monitor: Ctrl+Option+Cmd + arrows
        bindings[.moveToScreenLeft] = HotkeyBinding(keyCode: 0x7B, modifiers: ctrlOptCmd)
        bindings[.moveToScreenRight] = HotkeyBinding(keyCode: 0x7C, modifiers: ctrlOptCmd)
        
        // Restore layout: Ctrl+Option+R
        bindings[.restoreLayout] = HotkeyBinding(keyCode: 0x0F, modifiers: ctrlOpt)
        
        // Window switcher: Ctrl+Option+W
        bindings[.openWindowSwitcher] = HotkeyBinding(keyCode: 0x0D, modifiers: ctrlOpt)
        
        // Move to desktop: Ctrl+Option+Shift + ←/→ and 1-9
        let ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)
        bindings[.moveToPreviousDesktop] = HotkeyBinding(keyCode: 0x7B, modifiers: ctrlOptShift)
        bindings[.moveToNextDesktop] = HotkeyBinding(keyCode: 0x7C, modifiers: ctrlOptShift)
        for (action, keyCode) in zip(HotkeyAction.moveToDesktopNumbered, digitKeyCodes) {
            bindings[action] = HotkeyBinding(keyCode: keyCode, modifiers: ctrlOptShift)
        }
        
        return HotkeyPreset(type: .rapto, bindings: bindings)
    }()
    
    /// Vim-style preset (Option + vim keys h/j/k/l)
    static let vimStyle: HotkeyPreset = {
        let alt = UInt32(optionKey)
        let altShift = UInt32(optionKey | shiftKey)
        let altCtrl = UInt32(optionKey | controlKey)
        
        var bindings: [HotkeyAction: HotkeyBinding] = [:]
        
        // Focus: Alt + h/j/k/l (vim-style navigation)
        bindings[.focusLeft] = HotkeyBinding(keyCode: 0x04, modifiers: alt)   // Alt+H
        bindings[.focusDown] = HotkeyBinding(keyCode: 0x26, modifiers: alt)   // Alt+J
        bindings[.focusUp] = HotkeyBinding(keyCode: 0x28, modifiers: alt)     // Alt+K
        bindings[.focusRight] = HotkeyBinding(keyCode: 0x25, modifiers: alt)  // Alt+L
        
        // Swap: Alt+Shift + h/j/k/l
        bindings[.swapLeft] = HotkeyBinding(keyCode: 0x04, modifiers: altShift)
        bindings[.swapDown] = HotkeyBinding(keyCode: 0x26, modifiers: altShift)
        bindings[.swapUp] = HotkeyBinding(keyCode: 0x28, modifiers: altShift)
        bindings[.swapRight] = HotkeyBinding(keyCode: 0x25, modifiers: altShift)
        
        // Move: Alt+Ctrl+Shift + h/j/k/l (move without swap)
        let altCtrlShift = UInt32(optionKey | controlKey | shiftKey)
        bindings[.moveLeft] = HotkeyBinding(keyCode: 0x04, modifiers: altCtrlShift)
        bindings[.moveDown] = HotkeyBinding(keyCode: 0x26, modifiers: altCtrlShift)
        bindings[.moveUp] = HotkeyBinding(keyCode: 0x28, modifiers: altCtrlShift)
        bindings[.moveRight] = HotkeyBinding(keyCode: 0x25, modifiers: altCtrlShift)
        
        // Resize: Alt+Ctrl + h/j/k/l
        bindings[.resizeShrinkWidth] = HotkeyBinding(keyCode: 0x04, modifiers: altCtrl)  // Alt+Ctrl+H
        bindings[.resizeGrowHeight] = HotkeyBinding(keyCode: 0x26, modifiers: altCtrl)   // Alt+Ctrl+J
        bindings[.resizeShrinkHeight] = HotkeyBinding(keyCode: 0x28, modifiers: altCtrl) // Alt+Ctrl+K
        bindings[.resizeGrowWidth] = HotkeyBinding(keyCode: 0x25, modifiers: altCtrl)    // Alt+Ctrl+L
        
        // Layout: Alt + f/t/g/m
        bindings[.toggleFloat] = HotkeyBinding(keyCode: 0x11, modifiers: alt)       // Alt+T
        bindings[.toggleFullscreen] = HotkeyBinding(keyCode: 0x03, modifiers: alt)  // Alt+F
        bindings[.openOverlay] = HotkeyBinding(keyCode: 0x05, modifiers: alt)       // Alt+G
        bindings[.cycleLayout] = HotkeyBinding(keyCode: 0x2E, modifiers: alt)       // Alt+M (Mode)
        
        // Focus slots: Alt + 1-9
        bindings[.focusSlot1] = HotkeyBinding(keyCode: 0x12, modifiers: alt)
        bindings[.focusSlot2] = HotkeyBinding(keyCode: 0x13, modifiers: alt)
        bindings[.focusSlot3] = HotkeyBinding(keyCode: 0x14, modifiers: alt)
        bindings[.focusSlot4] = HotkeyBinding(keyCode: 0x15, modifiers: alt)
        bindings[.focusSlot5] = HotkeyBinding(keyCode: 0x17, modifiers: alt)
        bindings[.focusSlot6] = HotkeyBinding(keyCode: 0x16, modifiers: alt)
        bindings[.focusSlot7] = HotkeyBinding(keyCode: 0x1A, modifiers: alt)
        bindings[.focusSlot8] = HotkeyBinding(keyCode: 0x1C, modifiers: alt)
        bindings[.focusSlot9] = HotkeyBinding(keyCode: 0x19, modifiers: alt)
        
        // Groups: Alt+], Alt+I, Alt+Shift+G (Alt+G opens the overlay)
        bindings[.cycleGroupForward] = HotkeyBinding(keyCode: 0x1E, modifiers: alt)  // Alt+]
        bindings[.toggleGroupIndicators] = HotkeyBinding(keyCode: 0x22, modifiers: alt) // Alt+I
        bindings[.toggleGroupWindows] = HotkeyBinding(keyCode: 0x05, modifiers: altShift) // Alt+Shift+G
        
        // Multi-monitor: Alt+Ctrl + arrows
        bindings[.moveToScreenLeft] = HotkeyBinding(keyCode: 0x7B, modifiers: altCtrl)
        bindings[.moveToScreenRight] = HotkeyBinding(keyCode: 0x7C, modifiers: altCtrl)
        
        // Restore layout: Alt+R
        bindings[.restoreLayout] = HotkeyBinding(keyCode: 0x0F, modifiers: alt)  // Alt+R
        
        // Window switcher: Alt+W
        bindings[.openWindowSwitcher] = HotkeyBinding(keyCode: 0x0D, modifiers: alt)
        
        // Move to desktop: Alt+Ctrl+Shift + ←/→, Alt+Ctrl + 1-9
        bindings[.moveToPreviousDesktop] = HotkeyBinding(keyCode: 0x7B, modifiers: altCtrlShift)
        bindings[.moveToNextDesktop] = HotkeyBinding(keyCode: 0x7C, modifiers: altCtrlShift)
        for (action, keyCode) in zip(HotkeyAction.moveToDesktopNumbered, digitKeyCodes) {
            bindings[action] = HotkeyBinding(keyCode: keyCode, modifiers: altCtrl)
        }
        
        return HotkeyPreset(type: .vimStyle, bindings: bindings)
    }()
    
    static func preset(for type: HotkeyPresetType) -> HotkeyPreset {
        switch type {
        case .rapto: return .rapto
        case .vimStyle: return .vimStyle
        case .custom: return .rapto // Start with Rapto defaults for custom
        }
    }
}

// MARK: - Preset Storage

class HotkeyPresetStorage {
    private let userDefaults: UserDefaults
    private let presetTypeKey = "hotkeyPresetType"
    private let basePresetTypeKey = "hotkeyBasePresetType"  // Tracks which preset custom bindings are based on
    private let customBindingsKey = "customHotkeyBindings"
    
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
    
    /// Load current preset type (with migration from old presets)
    func loadPresetType() -> HotkeyPresetType {
        guard let rawValue = userDefaults.string(forKey: presetTypeKey) else {
            return .rapto
        }
        
        if let type = HotkeyPresetType(rawValue: rawValue) {
            return type
        }
        
        // Preset names saved by earlier versions
        switch rawValue {
        case "Yabai", "Aerospace", "Amethyst":
            savePresetType(.vimStyle)
            return .vimStyle
        case "Rapto Default", "gridsnap":
            savePresetType(.rapto)
            return .rapto
        default:
            return .rapto
        }
    }
    
    func savePresetType(_ type: HotkeyPresetType) {
        userDefaults.set(type.rawValue, forKey: presetTypeKey)
    }
    
    /// Load base preset type (the preset that custom bindings are based on)
    func loadBasePresetType() -> HotkeyPresetType {
        guard let rawValue = userDefaults.string(forKey: basePresetTypeKey),
              let type = HotkeyPresetType(rawValue: rawValue) else {
            return .rapto
        }
        return type
    }

    func saveBasePresetType(_ type: HotkeyPresetType) {
        userDefaults.set(type.rawValue, forKey: basePresetTypeKey)
    }
    
    func loadCustomBindings() -> [HotkeyAction: HotkeyBinding]? {
        guard let data = userDefaults.data(forKey: customBindingsKey) else { return nil }
        guard let entries = try? JSONDecoder().decode(LossyBindingList.self, from: data) else {
            debugLog("HotkeyPresetStorage", "Failed to decode custom bindings")
            userDefaults.set(data, forKey: customBindingsKey + "_backup")
            return nil
        }
        if entries.skipped > 0 {
            // The next save drops the entries that failed; keep the data as it was
            userDefaults.set(data, forKey: customBindingsKey + "_backup")
            debugLog("HotkeyPresetStorage", "Skipped \(entries.skipped) custom bindings that could not be read")
        }
        return entries.bindings
    }
    
    /// `[HotkeyAction: HotkeyBinding]` is stored as a flat array of keys and values. An action from
    /// another app version is skipped instead of failing the whole list.
    private struct LossyBindingList: Decodable {
        var bindings: [HotkeyAction: HotkeyBinding] = [:]
        var skipped = 0
        
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd {
                let rawAction = try container.decode(String.self)
                guard !container.isAtEnd else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Key without a value") }
                let binding = try container.decode(LossyDecodable<HotkeyBinding>.self).value
                if let action = HotkeyAction(rawValue: rawAction), let binding {
                    bindings[action] = binding
                } else {
                    skipped += 1
                }
            }
        }
    }
    
    func saveCustomBindings(_ bindings: [HotkeyAction: HotkeyBinding]) {
        if let data = try? JSONEncoder().encode(bindings) {
            userDefaults.set(data, forKey: customBindingsKey)
        }
    }
    
    func loadCurrentPreset() -> HotkeyPreset {
        let type = loadPresetType()
        
        if type == .custom {
            return loadCustomPreset()
        }
        
        return HotkeyPreset.preset(for: type)
    }
    
    /// The base preset the user customized, with their overrides; a cleared shortcut is left out
    func loadCustomPreset() -> HotkeyPreset {
        var bindings = HotkeyPreset.preset(for: loadBasePresetType()).bindings
        for (action, binding) in loadCustomBindings() ?? [:] {
            bindings[action] = binding.isCleared ? nil : binding
        }
        return HotkeyPreset(type: .custom, bindings: bindings)
    }
    
}

