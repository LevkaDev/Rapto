//
//  TemplateHotkeyStorage.swift
//  Rapto
//
//  Service for persisting template hotkey assignments to UserDefaults.
//

import Foundation

class TemplateHotkeyStorage {
    private let storageKey = "templateHotkeys"
    
    /// Empty when nothing is stored or the stored data can't be decoded
    func loadHotkeys() -> [TemplateHotkey] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        
        do {
            let hotkeys = try JSONDecoder().decode([TemplateHotkey].self, from: data)
            return Self.migratedHotkeys(hotkeys)
        } catch {
            debugLog("TemplateHotkeyStorage", "Failed to decode hotkeys: \(error)")
            return []
        }
    }

    /// Rewrites shortcuts targeting retired built-in layout IDs to their active replacement,
    /// without overriding a shortcut already assigned to the replacement layout.
    static func migratedHotkeys(_ hotkeys: [TemplateHotkey]) -> [TemplateHotkey] {
        let existingCanonical = Set(
            hotkeys
                .filter { PredefinedTemplates.canonicalID(for: $0.templateID) == $0.templateID }
                .map(\.templateID)
        )
        var seen = Set<UUID>()
        var result: [TemplateHotkey] = []
        for hotkey in hotkeys {
            let canonical = PredefinedTemplates.canonicalID(for: hotkey.templateID)
            if canonical == hotkey.templateID {
                if seen.insert(canonical).inserted {
                    result.append(hotkey)
                }
            } else if !existingCanonical.contains(canonical), seen.insert(canonical).inserted {
                let replacementName = PredefinedTemplates.all.first(where: { $0.id == canonical })?.name ?? hotkey.templateName
                result.append(TemplateHotkey(
                    templateID: canonical,
                    templateName: replacementName,
                    keyCode: hotkey.keyCode,
                    modifiers: hotkey.modifiers
                ))
            }
        }
        return result
    }
    
    func saveHotkeys(_ hotkeys: [TemplateHotkey]) {
        do {
            let data = try JSONEncoder().encode(hotkeys)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            debugLog("TemplateHotkeyStorage", "Failed to encode hotkeys: \(error)")
        }
    }
    
    /// Replaces the template's previous hotkey and takes the key combination from any other
    /// template that had it. Saves and returns the updated list.
    func setHotkey(_ hotkey: TemplateHotkey, in hotkeys: [TemplateHotkey]) -> [TemplateHotkey] {
        var updated = hotkeys
        
        updated.removeAll { $0.templateID == hotkey.templateID }
        
        updated.removeAll { $0.keyCode == hotkey.keyCode && $0.modifiers == hotkey.modifiers }
        
        updated.append(hotkey)
        
        saveHotkeys(updated)
        return updated
    }
    
    /// Saves and returns the updated list
    func removeHotkey(forTemplateID templateID: UUID, from hotkeys: [TemplateHotkey]) -> [TemplateHotkey] {
        var updated = hotkeys
        updated.removeAll { $0.templateID == templateID }
        saveHotkeys(updated)
        return updated
    }
    
    func hotkey(forTemplateID templateID: UUID, in hotkeys: [TemplateHotkey]) -> TemplateHotkey? {
        return hotkeys.first { $0.templateID == templateID }
    }
    
}
