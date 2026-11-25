//
//  SettingsSearch.swift
//  Rapto
//
//  Search catalog for the Settings window, matching setting titles, descriptions and common synonyms.
//

import Foundation

struct SettingsSearchEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let section: String
    let tab: SettingsTab
    let keywords: [String]
}

enum SettingsSearch {

    static let entries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "guide.starterProfiles",
            title: "Operating Modes & Starter Profiles",
            subtitle: "Compare Drag to Snap, Manual and Auto-tiling and apply recommended 4 px defaults in one click",
            section: "Guide",
            tab: .guide,
            keywords: ["guide", "quick setup", "starter", "profile", "recommended", "modes", "how it works"]
        ),
        SettingsSearchEntry(
            id: "guide.smartAppScanner",
            title: "Smart App Scanner",
            subtitle: "Detect installed terminals, modal editors, VMs and chat/media apps to configure rules quickly",
            section: "Fine-Tune for Your Mac",
            tab: .guide,
            keywords: ["scanner", "detect apps", "recommended apps", "setup", "checklist"]
        ),
        SettingsSearchEntry(
            id: "guide.gesturesAndHints",
            title: "Essential Gestures, Cheat Sheet & In-Action Hints",
            subtitle: "Live modifier keys and shortcuts for your setup, plus Show In-Action Hints and Show Hints Again",
            section: "Essential Gestures & Shortcuts",
            tab: .guide,
            keywords: ["hints", "tips", "cheat sheet", "gestures", "reset hints", "show hints again", "help"]
        ),

        SettingsSearchEntry(
            id: "general.launchAtLogin",
            title: "Launch at Login",
            subtitle: "Start Rapto automatically when you log in",
            section: "Startup",
            tab: .general,
            keywords: ["startup", "autostart", "boot", "login"]
        ),
        SettingsSearchEntry(
            id: "general.desktopsBar",
            title: "Desktops Bar",
            subtitle: "Show your desktops and open apps in the menu bar",
            section: "Menu Bar",
            tab: .general,
            keywords: ["space bar", "spaces", "pill", "notch", "menubar", "auto-hide", "always on"]
        ),
        SettingsSearchEntry(
            id: "general.menuBarIcon",
            title: "Menu Bar Icon",
            subtitle: "Show the Rapto icon alongside the Desktops Bar",
            section: "Menu Bar",
            tab: .general,
            keywords: ["status bar", "tray", "hide icon", "menubar"]
        ),
        SettingsSearchEntry(
            id: "general.goWithMovedWindow",
            title: "Go With Moved Window",
            subtitle: "Switch to the target desktop when moving a window, or hold Option for the opposite",
            section: "Menu Bar",
            tab: .general,
            keywords: ["follow", "move desktop", "option", "space switch"]
        ),
        SettingsSearchEntry(
            id: "general.multiMonitor",
            title: "Multi-Monitor Modes",
            subtitle: "Choose a separate tiling mode for each connected display",
            section: "Multi-Monitor",
            tab: .general,
            keywords: ["display", "screen", "external monitor", "dual monitor"]
        ),
        SettingsSearchEntry(
            id: "general.newSpaceDefaults",
            title: "New Space Defaults",
            subtitle: "Default mode and layout for newly created Desktop Spaces",
            section: "New Space Defaults",
            tab: .general,
            keywords: ["new desktop", "default mode", "default template", "none"]
        ),
        SettingsSearchEntry(
            id: "general.settingsBackup",
            title: "Export & Import Settings",
            subtitle: "Save settings, shortcuts, layouts and workspaces to a file or load them back",
            section: "Settings File",
            tab: .general,
            keywords: ["backup", "restore", "json", "export", "import", "sync", "transfer"]
        ),
        SettingsSearchEntry(
            id: "general.updates",
            title: "Software Updates",
            subtitle: "Check for new Rapto versions automatically or manually",
            section: "Updates",
            tab: .general,
            keywords: ["update", "upgrade", "sparkle", "version"]
        ),

        SettingsSearchEntry(
            id: "behavior.draggingWindows",
            title: "Dragging Windows (Move & Group vs Swap)",
            subtitle: "Choose whether plain drag moves & groups or swaps slots, and which Control / Shift keys apply",
            section: "Dragging Windows",
            tab: .behavior,
            keywords: ["swap", "move", "control", "shift", "drag", "modifier", "slot", "drop"]
        ),
        SettingsSearchEntry(
            id: "behavior.windowGrouping",
            title: "Window Grouping & Group Badge",
            subtitle: "Stack multiple windows in one zone, auto-group same app, scroll badge to cycle",
            section: "Window Grouping",
            tab: .behavior,
            keywords: ["group", "stack", "tabs", "badge", "indicator", "scroll", "cycle", "same app", "follow monitor"]
        ),
        SettingsSearchEntry(
            id: "behavior.focusMode",
            title: "Focus Mode",
            subtitle: "Temporarily expand a window to full screen or a custom Focus Zone (⌥ + double-click or shortcut)",
            section: "Focus Mode",
            tab: .behavior,
            keywords: ["zoom", "maximize", "expand", "fullscreen", "double click", "double-click", "focus zone", "option"]
        ),
        SettingsSearchEntry(
            id: "behavior.floatingWindows",
            title: "Floating Windows",
            subtitle: "Keep a window above and outside tiling via shortcut or modifier + double-click",
            section: "Floating Windows",
            tab: .behavior,
            keywords: ["float", "pin", "always on top", "ontop", "unmanaged", "double click", "double-click"]
        ),
        SettingsSearchEntry(
            id: "behavior.snapBack",
            title: "Snap Back",
            subtitle: "Return windows to their assigned slot after dragging in Manual mode",
            section: "Manual Mode",
            tab: .behavior,
            keywords: ["bounce", "jump back", "return", "slot", "stuck", "manual", "snap back"]
        ),
        SettingsSearchEntry(
            id: "behavior.minimizeOthers",
            title: "Minimize Others",
            subtitle: "Minimize unassigned windows after applying a layout from the overlay",
            section: "Manual Mode",
            tab: .behavior,
            keywords: ["minimize", "hide others", "unassigned", "overlay", "manual"]
        ),
        SettingsSearchEntry(
            id: "behavior.autoTiling",
            title: "Auto-tiling Layouts & Max Windows",
            subtitle: "Pick the layout for 1–8 open windows and set per-display depth limits",
            section: "Auto-tiling",
            tab: .behavior,
            keywords: ["auto tiling", "autotiling", "dynamic", "max windows", "depth", "yabai", "aerospace", "amethyst"]
        ),

        SettingsSearchEntry(
            id: "appearance.theme",
            title: "Settings Window Theme",
            subtitle: "System, Light or Dark appearance for Rapto Settings",
            section: "Theme",
            tab: .appearance,
            keywords: ["dark mode", "light mode", "theme", "appearance"]
        ),
        SettingsSearchEntry(
            id: "appearance.desktopsBarStyle",
            title: "Desktops Bar Style",
            subtitle: "Dark pill, translucent Glass pill or Plain menu bar items",
            section: "Desktops Bar",
            tab: .appearance,
            keywords: ["dark", "glass", "plain", "pill", "bar look", "style"]
        ),
        SettingsSearchEntry(
            id: "appearance.windowGaps",
            title: "Window Gap & Screen Edge Gap",
            subtitle: "Breathing room between tiled windows and from screen edges (0–24 px)",
            section: "Window Gaps",
            tab: .appearance,
            keywords: ["gap", "gaps", "padding", "margin", "spacing", "edge", "pixels", "px", "flush"]
        ),
        SettingsSearchEntry(
            id: "appearance.activeHighlight",
            title: "Active Window Highlight Border",
            subtitle: "Colored border around the focused window and matching outline in the Desktops Bar",
            section: "Active Window Highlight",
            tab: .appearance,
            keywords: ["border", "outline", "color", "width", "highlight", "active", "focused", "frame"]
        ),

        SettingsSearchEntry(
            id: "apps.ignoredApps",
            title: "Ignored Apps",
            subtitle: "Applications Rapto never tiles, snaps or manages",
            section: "Ignored Apps",
            tab: .apps,
            keywords: ["ignore", "exclude", "skip", "blacklist", "untiled", "leave alone", "app"]
        ),
        SettingsSearchEntry(
            id: "apps.passthroughApps",
            title: "Passthrough Apps (Pause Shortcuts)",
            subtitle: "Disable Rapto's keyboard shortcuts while terminals, Vim, VMs or games are focused",
            section: "Passthrough Apps",
            tab: .apps,
            keywords: ["passthrough", "pause", "disable shortcuts", "hotkeys", "vim", "terminal", "iterm", "ghostty", "kitty", "warp", "vm", "parallels", "game"]
        ),

        SettingsSearchEntry(
            id: "shortcuts.presets",
            title: "Shortcut Style (Rapto vs Vim Style)",
            subtitle: "Switch between ⌃⌥ + Arrows and ⌥ + H/J/K/L, or customize any key",
            section: "Shortcut Style",
            tab: .shortcuts,
            keywords: ["preset", "vim", "hjkl", "arrows", "hotkeys", "keyboard"]
        ),
        SettingsSearchEntry(
            id: "shortcuts.windowSwitcher",
            title: "Window Switcher & Focus Shortcuts",
            subtitle: "Search open windows across desktops (⌃⌥W) and move focus between slots",
            section: "Window Focus",
            tab: .shortcuts,
            keywords: ["switcher", "search window", "focus left", "focus right", "alt tab"]
        ),
        SettingsSearchEntry(
            id: "shortcuts.windowFlow",
            title: "Window Flow",
            subtitle: "Visual 3D window strip across all desktops of the active display",
            section: "Window Focus",
            tab: .shortcuts,
            keywords: ["window flow", "visual switcher", "carousel", "strip", "cover flow", "preview", "alt tab"]
        ),
        SettingsSearchEntry(
            id: "shortcuts.templateShortcuts",
            title: "Template Shortcuts",
            subtitle: "Apply any built-in or custom layout in Manual mode with one shortcut",
            section: "Template Shortcuts",
            tab: .shortcuts,
            keywords: ["template", "layout shortcut", "apply layout", "custom layout"]
        ),

        SettingsSearchEntry(
            id: "workspaces.saved",
            title: "Saved Workspaces",
            subtitle: "Save a desktop's apps and slot positions, then launch and restore them in one click",
            section: "Saved Workspaces",
            tab: .workspaces,
            keywords: ["workspace", "session", "reopen apps", "close workspace", "save desktop"]
        ),
        SettingsSearchEntry(
            id: "whatsNew.notes",
            title: "What's New & Release Notes",
            subtitle: "See what changed in each Rapto update",
            section: "What's New",
            tab: .whatsNew,
            keywords: ["changelog", "release notes", "whats new", "version history"]
        ),
        SettingsSearchEntry(
            id: "about.openSource",
            title: "Source Code & GitHub",
            subtitle: "Rapto is free and open source: read the code or star it on GitHub",
            section: "Open Source",
            tab: .about,
            keywords: ["open source", "github", "source", "code", "star", "license", "contribute", "repository", "acknowledgements", "credits", "third party", "gpl"]
        ),
        SettingsSearchEntry(
            id: "about.reportProblem",
            title: "Report a Problem",
            subtitle: "Send a bug report on GitHub or by email, with your setup filled in",
            section: "Troubleshooting",
            tab: .about,
            keywords: ["bug", "report", "issue", "feedback", "support", "contact", "email", "problem", "help"]
        ),
        SettingsSearchEntry(
            id: "about.troubleshooting",
            title: "Debug Logging & Log Folder",
            subtitle: "Record diagnostic logs in ~/Library/Logs/Rapto to troubleshoot issues",
            section: "Troubleshooting",
            tab: .about,
            keywords: ["debug", "log", "logs", "bug", "troubleshooting", "diagnostics"]
        ),
        SettingsSearchEntry(
            id: "about.onboarding",
            title: "Show Onboarding",
            subtitle: "Replay the first-launch walkthrough and permissions check",
            section: "Help",
            tab: .about,
            keywords: ["onboarding", "welcome", "tutorial", "walkthrough", "permissions", "accessibility", "screen recording"]
        ),
    ]

    /// Filters `entries` by matching every whitespace-separated word of `query` against title,
    /// section, tab name, subtitle, or synonym keywords, ranked with title matches first.
    static func filter(query: String) -> [SettingsSearchEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        let scored: [(entry: SettingsSearchEntry, score: Int)] = entries.compactMap { entry in
            let title = normalize(entry.title)
            let titleWords = splitWords(title)
            let section = normalize(entry.section)
            let tab = normalize(entry.tab.rawValue)
            let subtitle = normalize(entry.subtitle)
            let keywords = entry.keywords.map { normalize($0) }
            let keywordWords = keywords.flatMap { splitWords($0) }

            var totalScore = 0
            for token in tokens {
                if titleWords.contains(token) {
                    totalScore += 14
                } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
                    totalScore += 11
                } else if keywords.contains(token) || keywordWords.contains(token) {
                    totalScore += 10
                } else if keywordWords.contains(where: { $0.hasPrefix(token) }) {
                    totalScore += 8
                } else if splitWords(section).contains(where: { $0.hasPrefix(token) }) ||
                          splitWords(tab).contains(where: { $0.hasPrefix(token) }) {
                    totalScore += 7
                } else if title.contains(token) {
                    totalScore += 4
                } else if section.contains(token) || tab.contains(token) || keywords.contains(where: { $0.contains(token) }) {
                    totalScore += 3
                } else if subtitle.contains(token) {
                    totalScore += 2
                } else {
                    return nil
                }
            }
            return (entry, totalScore)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.title < rhs.entry.title
            }
            .map(\.entry)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func splitWords(_ normalizedText: String) -> [String] {
        normalizedText
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
