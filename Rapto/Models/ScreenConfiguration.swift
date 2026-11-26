//
//  ScreenConfiguration.swift
//  Rapto
//
//  Configuration for a specific monitor/display.
//  Allows independent tiling modes per monitor in multi-monitor setups.
//

import Foundation
import AppKit

struct ScreenConfiguration: Codable, Equatable {
    var mode: TilingMode
    
    /// The template ID for auto-tiling/manual mode (nil uses default)
    var templateID: UUID?
    
    /// The layout Drag to Snap snaps windows into (nil uses the standard halves, quarters and thirds)
    var dragSnapTemplateID: UUID?
    
    /// Auto-tiling max windows (depth) for this screen (nil uses global setting)
    /// Windows beyond this count will be grouped into existing slots
    var autoTilingMaxWindows: Int?
    
    static var userDefault: ScreenConfiguration {
        let defaults = UserDefaults.standard
        var mode: TilingMode = .none
        
        if let savedModeRaw = defaults.string(forKey: "defaultModeForNewSpaces"),
           let savedMode = TilingMode(rawValue: savedModeRaw) {
            mode = savedMode
        }
        
        let savedTemplateID = PredefinedTemplates.canonicalOptionalID(
            for: defaults.string(forKey: "defaultTemplateForNewSpaces").flatMap(UUID.init(uuidString:))
        )
        var config = ScreenConfiguration(mode: mode, templateID: mode == .manualAssignment ? savedTemplateID : nil, autoTilingMaxWindows: nil)
        if mode == .dragSnap {
            config.dragSnapTemplateID = savedTemplateID
        }
        return config
    }

    /// Resolves any retired built-in layout IDs in this configuration to their active replacement.
    func normalized() -> ScreenConfiguration {
        var copy = self
        copy.templateID = PredefinedTemplates.canonicalOptionalID(for: templateID)
        copy.dragSnapTemplateID = PredefinedTemplates.canonicalOptionalID(for: dragSnapTemplateID)
        return copy
    }
    
    init(mode: TilingMode, templateID: UUID? = nil, autoTilingMaxWindows: Int? = nil) {
        self.mode = mode
        self.templateID = templateID
        self.autoTilingMaxWindows = autoTilingMaxWindows
    }
}

// MARK: - Screen Identifier Helper

struct ScreenIdentifier {
    
    /// A stable identifier for a screen, built from the display's UUID because its number
    /// (`NSScreenNumber`) can change after a restart or reconnect.
    static func identifier(for screen: NSScreen) -> String {
        if let displayID = displayNumber(of: screen) {
            guard let uuid = displayUUID(displayID) else { return legacyIdentifier(displayID) }
            // Identical displays without a serial number can share a UUID
            let twins = NSScreen.screens.compactMap { displayNumber(of: $0) }.filter { displayUUID($0) == uuid }
            return twins.count > 1 ? "display-\(uuid)-\(displayID)" : "display-\(uuid)"
        }
        
        // Fallback: use screen index (less stable but works)
        if let index = NSScreen.screens.firstIndex(of: screen) {
            return "screen-\(index)"
        }
        
        return "screen-unknown"
    }

    static func displayNumber(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The number-based identifier of earlier versions, kept to migrate saved settings.
    static func legacyIdentifier(_ displayID: CGDirectDisplayID) -> String {
        "display-\(displayID)"
    }

    static func isLegacy(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("display-") else { return false }
        return identifier.dropFirst("display-".count).allSatisfy(\.isNumber)
    }

    private static func displayUUID(_ displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
    
    /// Identifier of `NSScreen.main`, the screen with the key window (not necessarily the primary display)
    static var mainScreenID: String {
        guard let main = NSScreen.main else { return "screen-main" }
        return identifier(for: main)
    }

    static func screen(for identifier: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if self.identifier(for: screen) == identifier {
                return screen
            }
        }
        return nil
    }
}

// MARK: - Composite Key Helper

struct ConfigurationKey {
    
    /// Create a composite key for Space + Screen configuration
    /// Format: "space:{spaceID}|screen:{screenID}"
    static func make(spaceID: String, screenID: String) -> String {
        return "space:\(spaceID)|screen:\(screenID)"
    }
    
    static func parse(_ key: String) -> (spaceID: String, screenID: String)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2 else { return nil }
        
        let spacePart = parts[0]
        let screenPart = parts[1]
        
        guard spacePart.hasPrefix("space:"),
              screenPart.hasPrefix("screen:") else { return nil }
        
        let spaceID = String(spacePart.dropFirst("space:".count))
        let screenID = String(screenPart.dropFirst("screen:".count))
        
        return (spaceID, screenID)
    }
}

// MARK: - Storage

struct ScreenConfigurationStorage {
    private static let key = "screenConfigurations_v1"
    
    static func load(from store: UserDefaults = .standard) -> [String: ScreenConfiguration] {
        guard let data = store.data(forKey: key) else {
            return [:]
        }
        
        do {
            let entries = try JSONDecoder().decode([String: LossyDecodable<ScreenConfiguration>].self, from: data)
            let configs = entries.compactMapValues { $0.value?.normalized() }
            if configs.count < entries.count {
                // The next save drops the entries that failed; keep the data as it was
                store.set(data, forKey: key + "_backup")
                debugLog("ScreenConfigurationStorage", "Skipped \(entries.count - configs.count) configurations that could not be read")
            }
            return configs
        } catch {
            debugLog("ScreenConfigurationStorage", "Failed to decode configurations: \(error)")
            store.set(data, forKey: key + "_backup")
            return [:]
        }
    }
    
    static func save(_ configurations: [String: ScreenConfiguration]) {
        do {
            let data = try JSONEncoder().encode(configurations)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            debugLog("ScreenConfigurationStorage", "Failed to encode configurations: \(error)")
        }
    }
    
    /// Returns user-customizable default if not set
    static func configuration(
        forSpaceID spaceID: String,
        screenID: String,
        in configurations: [String: ScreenConfiguration]
    ) -> ScreenConfiguration {
        let key = ConfigurationKey.make(spaceID: spaceID, screenID: screenID)
        return configurations[key] ?? .userDefault
    }
    
    /// Sets the configuration for a Space + Screen combination and saves all configurations
    static func setConfiguration(
        _ config: ScreenConfiguration,
        forSpaceID spaceID: String,
        screenID: String,
        in configurations: inout [String: ScreenConfiguration]
    ) {
        let key = ConfigurationKey.make(spaceID: spaceID, screenID: screenID)
        configurations[key] = config
        save(configurations)
    }
    
}
