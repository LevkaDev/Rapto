//
//  HotkeyConflictDetector.swift
//  Rapto
//
//  Detects real hotkey conflicts by attempting registration.
//

import Foundation
import Carbon

struct ConflictCheckResult {
    let isAvailable: Bool
    let errorCode: OSStatus?
    
    var warningMessage: String? {
        guard !isAvailable else { return nil }
        
        if let code = errorCode {
            switch code {
            case -9878: // hotKeyExistsErr
                return "This shortcut is already in use by another application"
            case -9879: // hotKeyInvalidErr  
                return "Invalid shortcut combination"
            default:
                return "This shortcut is unavailable (error: \(code))"
            }
        }
        return "This shortcut is already in use"
    }
}

/// A shortcut Rapto itself uses: one row of the Shortcuts settings
struct RaptoShortcut: Equatable {
    let rowID: String
    let name: String
    let binding: HotkeyBinding
}

/// Detects real hotkey conflicts by attempting Carbon API registration
class HotkeyConflictDetector {
    /// Another Rapto shortcut that already uses `binding`. Rapto's own shortcuts are registered
    /// in this process, so the Carbon check fails for them and can't tell whose they are.
    nonisolated static func raptoConflict(for binding: HotkeyBinding, rowID: String, in shortcuts: [RaptoShortcut]) -> RaptoShortcut? {
        shortcuts.first { $0.rowID != rowID && $0.binding == binding }
    }
    
    static let shared = HotkeyConflictDetector()
    
    private var testHotkeyID: UInt32 = 99999
    
    private init() {}
    
    func checkAvailability(for binding: HotkeyBinding) -> ConflictCheckResult {
        if isSystemCritical(binding) {
            return ConflictCheckResult(isAvailable: false, errorCode: -9878)
        }
        
        var hotkeyRef: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: OSType(0x5250544F), id: testHotkeyID) // "RPTO"
        
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        
        if status == noErr, let ref = hotkeyRef {
            // Only a test registration, so release it right away
            UnregisterEventHotKey(ref)
            return ConflictCheckResult(isAvailable: true, errorCode: nil)
        } else {
            return ConflictCheckResult(isAvailable: false, errorCode: status)
        }
    }
    
    func isSystemCritical(_ binding: HotkeyBinding) -> Bool {
        let cmd = UInt32(cmdKey)
        
        let criticalShortcuts: [(UInt32, UInt32)] = [
            (0x0C, cmd),  // Cmd+Q (Quit)
            (0x0D, cmd),  // Cmd+W (Close window)
            (0x30, cmd),  // Cmd+Tab (Switch apps)
        ]
        
        return criticalShortcuts.contains { $0.0 == binding.keyCode && $0.1 == binding.modifiers }
    }
}
