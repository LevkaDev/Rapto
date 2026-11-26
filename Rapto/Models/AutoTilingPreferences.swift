//
//  AutoTilingPreferences.swift
//  Rapto
//
//  Preferences for dynamic auto-tiling based on window count.
//  Allows users to customize which template is used for each number of windows.
//

import Foundation

nonisolated struct AutoTilingPreferences: Codable, Equatable, Sendable {
    
    // MARK: - Template Assignments
    
    var templateFor1Window: UUID?
    
    var templateFor2Windows: UUID?
    
    var templateFor3Windows: UUID?
    
    var templateFor4Windows: UUID?
    
    var templateFor5Windows: UUID?
    
    var templateFor6Windows: UUID?
    
    var templateFor7Windows: UUID?
    
    var templateFor8Windows: UUID?
    
    /// Maximum number of windows before grouping starts (default: 4)
    /// Windows beyond this count will be grouped into existing slots
    var maxWindows: Int
    
    /// Values the Settings and onboarding pickers offer
    static let maxWindowsRange = 2...8
    
    // MARK: - Initialization
    
    init(
        templateFor1Window: UUID? = nil,
        templateFor2Windows: UUID? = nil,
        templateFor3Windows: UUID? = nil,
        templateFor4Windows: UUID? = nil,
        templateFor5Windows: UUID? = nil,
        templateFor6Windows: UUID? = nil,
        templateFor7Windows: UUID? = nil,
        templateFor8Windows: UUID? = nil,
        maxWindows: Int = 4
    ) {
        self.templateFor1Window = templateFor1Window
        self.templateFor2Windows = templateFor2Windows
        self.templateFor3Windows = templateFor3Windows
        self.templateFor4Windows = templateFor4Windows
        self.templateFor5Windows = templateFor5Windows
        self.templateFor6Windows = templateFor6Windows
        self.templateFor7Windows = templateFor7Windows
        self.templateFor8Windows = templateFor8Windows
        self.maxWindows = maxWindows
    }
    
    static var `default`: AutoTilingPreferences {
        AutoTilingPreferences(
            templateFor1Window: PredefinedTemplates.centerFocus.id,  // Centered for ultrawide monitors
            templateFor2Windows: PredefinedTemplates.halvesVertical.id,
            templateFor3Windows: PredefinedTemplates.onePlusTwoLeft.id,
            templateFor4Windows: PredefinedTemplates.quarters.id,
            templateFor5Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor6Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor7Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor8Windows: PredefinedTemplates.centerSplitSidebars.id,
            maxWindows: 4
        )
    }
    
    // MARK: - Template Selection
    
    func templateID(for windowCount: Int) -> UUID? {
        switch windowCount {
        case 0:
            return nil
        case 1:
            return templateFor1Window
        case 2:
            return templateFor2Windows
        case 3:
            return templateFor3Windows
        case 4:
            return templateFor4Windows
        case 5:
            return templateFor5Windows
        case 6:
            return templateFor6Windows
        case 7:
            return templateFor7Windows
        case 8:
            return templateFor8Windows
        default:
            // 9+ windows use the 8-window template
            return templateFor8Windows
        }
    }
    
    mutating func setTemplateID(_ templateID: UUID?, for windowCount: Int) {
        switch windowCount {
        case 1:
            templateFor1Window = templateID
        case 2:
            templateFor2Windows = templateID
        case 3:
            templateFor3Windows = templateID
        case 4:
            templateFor4Windows = templateID
        case 5:
            templateFor5Windows = templateID
        case 6:
            templateFor6Windows = templateID
        case 7:
            templateFor7Windows = templateID
        case 8:
            templateFor8Windows = templateID
        default:
            break
        }
    }
}

// MARK: - Storage

enum AutoTilingPreferencesStorage {
    static let key = "autoTilingPreferences"

    static func save(_ preferences: AutoTilingPreferences, to store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(preferences) {
            store.set(data, forKey: key)
        }
    }

    /// Saves display-tuned defaults for a new install that has no stored preferences yet,
    /// while preserving the legacy `.default` (Center Focus + max 4) for existing installs.
    static func settleUnsaved(in store: UserDefaults = .standard, for profile: DisplayProfile) {
        guard store.data(forKey: key) == nil else { return }
        let hasCompletedOnboarding = store.bool(forKey: "hasCompletedOnboarding")
        let initial = hasCompletedOnboarding ? AutoTilingPreferences.default : profile.autoTilingPreferences
        save(initial, to: store)
    }
    
    /// Load preferences from UserDefaults with migration for new fields
    static func load(from store: UserDefaults = .standard) -> AutoTilingPreferences {
        guard let data = store.data(forKey: key),
              var preferences = try? JSONDecoder().decode(AutoTilingPreferences.self, from: data) else {
            return .default
        }
        
        // Data saved without the 5-8 window fields decodes them as nil; those get the defaults
        let defaults = AutoTilingPreferences.default
        if preferences.templateFor5Windows == nil {
            preferences.templateFor5Windows = defaults.templateFor5Windows
        }
        if preferences.templateFor6Windows == nil {
            preferences.templateFor6Windows = defaults.templateFor6Windows
        }
        if preferences.templateFor7Windows == nil {
            preferences.templateFor7Windows = defaults.templateFor7Windows
        }
        if preferences.templateFor8Windows == nil {
            preferences.templateFor8Windows = defaults.templateFor8Windows
        }
        
        // An imported or hand-edited file can hold any number; Settings builds a list from it
        let range = AutoTilingPreferences.maxWindowsRange
        preferences.maxWindows = min(max(preferences.maxWindows, range.lowerBound), range.upperBound)
        
        return preferences
    }
}
