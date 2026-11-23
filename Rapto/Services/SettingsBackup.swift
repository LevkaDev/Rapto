//
//  SettingsBackup.swift
//  Rapto
//
//  Saves the user's settings to one JSON file and puts them back from it.
//
//  An import replaces the stored settings and Rapto restarts, so the file goes
//  through the same loading and migration code as settings after an update.
//
//  Rules that keep old files readable:
//  - a new setting gets a key in `settingKeys`; a file without it leaves the default
//  - keys the app does not know are ignored
//  - the meaning of a stored key never changes; if it must, raise `formatVersion`
//    and convert older files in `SettingsBackup.read`
//

import Foundation

enum SettingsBackup {

    /// Raised only when files of the previous format need converting on import.
    static let formatVersion = 1

    static let appName = "Rapto"

    /// Everything a file carries. Anything not listed stays on this Mac: window positions
    /// remembered per desktop, onboarding and What's New marks, update checks, logging.
    static let settingKeys: [String] = [
        // General
        "showsMenuBarIcon", "showsHints", "windowGap", "screenEdgeGap", "redirectNewWindowsToAppMonitor",
        "defaultModeForNewSpaces", "defaultTemplateForNewSpaces",
        "isGroupingEnabled", "enableScrollToSwitch", "autoGroupSameApp",
        "groupIndicatorSize", "groupIndicatorPosition", "groupIndicatorsHidden",
        "swapRequiresOption", "moveRequiresShift", "minimizeOthersOnApply",
        "autoTilingPreferences", "SUEnableAutomaticChecks",
        // Appearance
        "settingsTheme", "showsSpaceBar", "spaceBarPresentation", "spaceBarStyle", "spaceBarMoveFollowsWindow",
        "highlightActiveWindow", "highlightColor", "highlightBorderWidth", "disableHighlightInDragSnapMode",
        "focusModeEnabled", "focusModeZone", "focusModeDoubleTapEnabled", "focusModeDoubleTapModifier",
        "floatingDoubleTapEnabled", "floatingDoubleTapModifier",
        // Shortcuts
        "hotkeyPresetType", "hotkeyBasePresetType", "customHotkeyBindings", "templateHotkeys",
        // Apps
        "ignoredApps", "passthroughApps",
        // Layouts
        "hiddenStandardTemplateIDs",
        // Tied to this Mac's displays and desktops. On another Mac they match nothing
        // and the defaults for new desktops apply.
        "screenConfigurations_v1", "workspaces.v1"
    ]

    struct Archive {
        var appVersion: String
        var exportedAt: Date?
        /// Values ready for UserDefaults, only for keys in `settingKeys`
        var settings: [String: Any]
        /// Contents of the custom layouts file. Nil when the file says nothing about them.
        var customTemplates: Data?
    }

    enum ImportError: LocalizedError, Equatable {
        case notASettingsFile
        case newerFormat

        var errorDescription: String? {
            switch self {
            case .notASettingsFile:
                return "This is not a Rapto settings file"
            case .newerFormat:
                return "This file was saved by a newer version of Rapto. Update Rapto and try again"
            }
        }
    }

    private static let maxFileSize = 10 * 1024 * 1024

    // MARK: - Export

    static func export(from defaults: UserDefaults, templatesFile: URL, appVersion: String, date: Date = Date()) throws -> Data {
        var settings: [String: Any] = [:]
        for key in settingKeys {
            guard let value = defaults.object(forKey: key), let json = jsonValue(from: value) else { continue }
            settings[key] = json
        }
        var root: [String: Any] = [
            "app": appName,
            "format": formatVersion,
            "appVersion": appVersion,
            "exportedAt": ISO8601DateFormatter().string(from: date),
            "settings": settings
        ]
        root["customTemplates"] = (try? Data(contentsOf: templatesFile)).flatMap { jsonText($0) } ?? "[]"
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Import

    static func read(_ data: Data) throws -> Archive {
        guard data.count <= maxFileSize,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["app"] as? String == appName,
              let format = root["format"] as? Int, format >= 1,
              let stored = root["settings"] as? [String: Any] else {
            throw ImportError.notASettingsFile
        }
        guard format <= formatVersion else { throw ImportError.newerFormat }

        var settings: [String: Any] = [:]
        for key in settingKeys {
            guard let json = stored[key], let value = defaultsValue(from: json) else { continue }
            settings[key] = value
        }
        var templates: Data?
        if let text = root["customTemplates"] as? String, let data = jsonData(from: text),
           (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            templates = data
        }
        return Archive(
            appVersion: root["appVersion"] as? String ?? "",
            exportedAt: (root["exportedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            settings: settings,
            customTemplates: templates
        )
    }

    /// Replaces the stored settings with the archive's. A listed setting the archive
    /// does not have goes back to its default.
    static func apply(_ archive: Archive, to defaults: UserDefaults, templatesFile: URL) throws {
        if let templates = archive.customTemplates {
            try FileManager.default.createDirectory(
                at: templatesFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try templates.write(to: templatesFile, options: .atomic)
        }
        for key in settingKeys {
            if let value = archive.settings[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Values

    private static let jsonMarker = "$json"
    private static let dataMarker = "$data"

    // MARK: - Workaround: stored JSON is kept as text
    // Reading JSON and writing it again changes some fractions in the last digit
    // (0.04039062499999996 comes back as 0.040390624999999958), so data that is
    // already JSON travels as its own text, byte for byte, not as nested JSON.

    /// The text of data that is JSON, nil for anything else
    private static func jsonText(_ data: Data) -> String? {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonData(from text: String) -> Data? {
        let data = Data(text.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) != nil ? data : nil
    }

    /// A UserDefaults value as JSON. Stored data that is JSON goes in as text,
    /// other data (an archived color) as base64.
    static func jsonValue(from value: Any) -> Any? {
        switch value {
        case let data as Data:
            if let text = jsonText(data) {
                return [jsonMarker: text]
            }
            return [dataMarker: data.base64EncodedString()]
        case let list as [Any]:
            let converted = list.compactMap { jsonValue(from: $0) }
            return converted.count == list.count ? converted : nil
        case let dictionary as [String: Any]:
            let converted = dictionary.compactMapValues { jsonValue(from: $0) }
            return converted.count == dictionary.count ? converted : nil
        case is String, is NSNumber:
            return value
        default:
            return nil
        }
    }

    static func defaultsValue(from json: Any) -> Any? {
        switch json {
        case let dictionary as [String: Any]:
            if dictionary.count == 1, let text = dictionary[jsonMarker] {
                return (text as? String).flatMap { jsonData(from: $0) }
            }
            if dictionary.count == 1, let encoded = dictionary[dataMarker] {
                return (encoded as? String).flatMap { Data(base64Encoded: $0) }
            }
            let converted = dictionary.compactMapValues { defaultsValue(from: $0) }
            return converted.count == dictionary.count ? converted : nil
        case let list as [Any]:
            let converted = list.compactMap { defaultsValue(from: $0) }
            return converted.count == list.count ? converted : nil
        case is String, is NSNumber:
            return json
        default:
            return nil
        }
    }
}
