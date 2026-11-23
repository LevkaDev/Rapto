//
//  MacOSTiling.swift
//  Rapto
//
//  macOS's own window tiling (System Settings → Desktop & Dock → Windows) and Stage Manager
//  (Desktop & Dock → Desktop & Stage Manager) fight Rapto over where windows go.
//

import AppKit

enum MacOSTiling {
    enum Option: String, CaseIterable, Identifiable {
        case edgeDrag = "EnableTilingByEdgeDrag"
        case menuBarDrag = "EnableTopTilingByEdgeDrag"
        case optionKeyDrag = "EnableTilingOptionAccelerator"
        case stageManager = "GloballyEnabled"

        var id: String { rawValue }

        /// The switch's label in System Settings, in the language System Settings shows it
        var title: String {
            switch self {
            case .edgeDrag: return localized("Drag windows to left or right edge of screen to tile")
            case .menuBarDrag: return localized("Drag windows to menu bar to fill screen")
            case .optionKeyDrag: return localized("Hold ⌥ key while dragging windows to tile")
            case .stageManager: return localized("Stage Manager")
            }
        }

        /// The section of Desktop & Dock the switch is in
        var section: String {
            self == .stageManager ? localized("Desktop & Stage Manager") : localized("Windows")
        }

        /// On a new Mac tiling is on and Stage Manager is off
        fileprivate var isOnByDefault: Bool { self != .stageManager }
    }

    private static let domain = "com.apple.WindowManager" as CFString

    static var paneName: String { localized("CFBundleDisplayName", table: "InfoPlist", english: "Desktop & Dock") }

    /// The sections holding these switches, in System Settings order
    static func sections(of options: [Option]) -> [String] {
        Option.allCases.filter(options.contains).map(\.section).reduce(into: []) { sections, section in
            if !sections.contains(section) { sections.append(section) }
        }
    }

    /// A headline for the switches that are on
    static func headline(for options: [Option]) -> String {
        let tiling = options.contains { $0 != .stageManager }
        let stageManager = options.contains(.stageManager)
        switch (tiling, stageManager) {
        case (true, true): return "macOS window tiling and Stage Manager are on"
        case (false, true): return "Stage Manager is on"
        default: return "macOS window tiling is on"
        }
    }

    /// "In Desktop & Dock → Windows, turn off: “…”." for each section with switches that are on
    static func instructions(for options: [Option]) -> String {
        sections(of: options).map { section in
            let titles = Option.allCases.filter { options.contains($0) && $0.section == section }.map { "“\($0.title)”" }
            return "In \(paneName) → \(section), turn off: \(titles.joined(separator: ", "))."
        }.joined(separator: " ")
    }

    // MARK: - Workaround: Labels in the user's language
    // Rapto itself is English only, so Bundle would hand out the English strings of System Settings.
    // Its .loctable holds every language at once (keys are the English labels), so the language is
    // picked from the user's preferred languages directly. Falls back to English if Apple moves it.
    private static let resources = "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex/Contents/Resources/"

    private static let tables: [String: [String: [String: Any]]] = {
        var tables: [String: [String: [String: Any]]] = [:]
        for name in ["Localizable", "InfoPlist"] {
            guard let data = FileManager.default.contents(atPath: resources + name + ".loctable"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { continue }
            tables[name] = plist
        }
        return tables
    }()

    private static func localized(_ key: String, table: String = "Localizable", english: String? = nil) -> String {
        let fallback = english ?? key
        guard let languages = tables[table],
              let language = Bundle.preferredLocalizations(from: Array(languages.keys), forPreferences: Locale.preferredLanguages).first
        else { return fallback }
        return languages[language]?[key] as? String ?? fallback
    }

    /// A switch that was never touched has no value and is as on a new Mac
    static func isEnabled(_ option: Option) -> Bool {
        CFPreferencesCopyAppValue(option.rawValue as CFString, domain) as? Bool ?? option.isOnByDefault
    }

    /// Options that are on right now, re-read from disk so a change in System Settings shows up at once
    static func enabledOptions() -> [Option] {
        CFPreferencesAppSynchronize(domain)
        return Option.allCases.filter { isEnabled($0) }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
