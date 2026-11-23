//
//  ReleaseNotes.swift
//  Rapto
//
//  What's New: release notes bundled with the app, by version.
//

import Foundation

struct ReleaseNote: Identifiable {
    struct Section: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    let version: String
    let sections: [Section]
    var id: String { version }
}

enum ReleaseNotes {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Notes for this version and older ones, newest first.
    /// The top block of RELEASE_NOTES.md may already describe the next version during development.
    static let all: [ReleaseNote] = {
        guard let url = Bundle.main.url(forResource: "RELEASE_NOTES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let current = currentVersion
        return parse(text).filter { $0.version.compare(current, options: .numeric) != .orderedDescending }
    }()

    /// Reads `## Version X`, `### Section` and `- item` lines. Placeholder `- ` items and empty
    /// sections are skipped, so versions without notes don't show up.
    static func parse(_ text: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var version: String?
        var sections: [ReleaseNote.Section] = []
        var sectionTitle: String?
        var items: [String] = []

        func closeSection() {
            if let title = sectionTitle, !items.isEmpty {
                sections.append(.init(title: title, items: items))
            }
            sectionTitle = nil
            items = []
        }
        func closeVersion() {
            closeSection()
            if let version, !sections.isEmpty {
                notes.append(.init(version: version, sections: sections))
            }
            version = nil
            sections = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeVersion()
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                version = title.hasPrefix("Version ") ? String(title.dropFirst(8)) : title
            } else if line.hasPrefix("### ") {
                closeSection()
                sectionTitle = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line == "-" {
                let item = line.dropFirst(1).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty, sectionTitle != nil { items.append(item) }
            } else if line == "---" {
                closeVersion()
            } else if !line.isEmpty, sectionTitle != nil, let last = items.popLast() {
                items.append(last + " " + line)
            }
        }
        closeVersion()
        return notes
    }

    private static let shownVersionKey = "whatsNewShownVersion"

    /// Opens What's New once after Rapto was updated. Fresh installs get onboarding instead.
    @MainActor
    static func showIfUpdated(appState: AppState) {
        let current = currentVersion
        let shown = UserDefaults.standard.string(forKey: shownVersionKey)
        UserDefaults.standard.set(current, forKey: shownVersionKey)
        guard shown != current,
              appState.hasCompletedOnboarding,
              all.first?.version == current else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !appState.isOnboardingVisible else { return }
            debugLog("ReleaseNotes", "Showing What's New for \(current), last shown: \(shown ?? "never")")
            SettingsWindowController.shared.showSettings(appState: appState, tab: .whatsNew)
        }
    }
}
