//
//  AppSuggestionScanner.swift
//  Rapto
//
//  Local scanner matching installed and running macOS apps against two curated lists
//  for Settings → Guide:
//  1) `optionalIgnoredCandidates` — resizable (>= 300 pt) chat, call, media and note apps
//     that are NOT already filtered by WindowClassifier, offered purely opt-in.
//  2) `passthroughCandidates` — terminals, modal editors, virtual machines, remote desktop
//     and 3D tools with dense Control/Option shortcuts.
//

import Foundation
import AppKit

struct AppSuggestionCandidate: Equatable, Sendable {
    let bundleIdentifier: String
    let fallbackName: String
}

struct DetectedAppSuggestion: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
}

enum AppSuggestionScanner {

    /// Resizable (>= 300 pt) applications some users prefer to keep free-floating.
    /// Deliberately omits small/fixed-size utilities and system panels (`Calculator`, `Stickies`,
    /// `System Settings`, `Spotlight`, `CleanShot X`, dialogs, DMG installers) that Rapto's
    /// `WindowClassifier` and `SettingsWindowDetector` already exclude automatically.
    nonisolated static let optionalIgnoredCandidates: [AppSuggestionCandidate] = [
        AppSuggestionCandidate(bundleIdentifier: "com.apple.FaceTime", fallbackName: "FaceTime"),
        AppSuggestionCandidate(bundleIdentifier: "us.zoom.xos", fallbackName: "Zoom"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.MobileSMS", fallbackName: "Messages"),
        AppSuggestionCandidate(bundleIdentifier: "ru.keepcoder.Telegram", fallbackName: "Telegram"),
        AppSuggestionCandidate(bundleIdentifier: "com.tdesktop.Telegram", fallbackName: "Telegram Desktop"),
        AppSuggestionCandidate(bundleIdentifier: "net.whatsapp.WhatsApp", fallbackName: "WhatsApp"),
        AppSuggestionCandidate(bundleIdentifier: "com.hnc.Discord", fallbackName: "Discord"),
        AppSuggestionCandidate(bundleIdentifier: "com.tinyspeck.slackmacgap", fallbackName: "Slack"),
        AppSuggestionCandidate(bundleIdentifier: "com.spotify.client", fallbackName: "Spotify"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.Music", fallbackName: "Music"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.podcasts", fallbackName: "Podcasts"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.TV", fallbackName: "TV"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.QuickTimePlayerX", fallbackName: "QuickTime Player"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.reminders", fallbackName: "Reminders"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.Notes", fallbackName: "Notes")
    ]

    /// Apps with heavy Control / Option keyboard shortcuts where pausing Rapto's shortcuts while
    /// focused avoids key collisions (windows still tile normally unless also in Ignored Apps).
    nonisolated static let passthroughCandidates: [AppSuggestionCandidate] = [
        AppSuggestionCandidate(bundleIdentifier: "com.mitchellh.ghostty", fallbackName: "Ghostty"),
        AppSuggestionCandidate(bundleIdentifier: "com.googlecode.iterm2", fallbackName: "iTerm2"),
        AppSuggestionCandidate(bundleIdentifier: "dev.warp.Warp-Stable", fallbackName: "Warp"),
        AppSuggestionCandidate(bundleIdentifier: "net.kovidgoyal.kitty", fallbackName: "kitty"),
        AppSuggestionCandidate(bundleIdentifier: "io.alacritty", fallbackName: "Alacritty"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.Terminal", fallbackName: "Terminal"),
        AppSuggestionCandidate(bundleIdentifier: "org.vim.MacVim", fallbackName: "MacVim"),
        AppSuggestionCandidate(bundleIdentifier: "com.neovide.neovide", fallbackName: "Neovide"),
        AppSuggestionCandidate(bundleIdentifier: "com.qvacua.VimR", fallbackName: "VimR"),
        AppSuggestionCandidate(bundleIdentifier: "org.gnu.Emacs", fallbackName: "Emacs"),
        AppSuggestionCandidate(bundleIdentifier: "com.parallels.desktop.console", fallbackName: "Parallels Desktop"),
        AppSuggestionCandidate(bundleIdentifier: "com.vmware.fusion", fallbackName: "VMware Fusion"),
        AppSuggestionCandidate(bundleIdentifier: "com.utmapp.UTM", fallbackName: "UTM"),
        AppSuggestionCandidate(bundleIdentifier: "com.microsoft.rdc.macos", fallbackName: "Windows App"),
        AppSuggestionCandidate(bundleIdentifier: "com.apple.ScreenSharing", fallbackName: "Screen Sharing"),
        AppSuggestionCandidate(bundleIdentifier: "com.teamviewer.TeamViewer", fallbackName: "TeamViewer"),
        AppSuggestionCandidate(bundleIdentifier: "com.philandro.anydesk", fallbackName: "AnyDesk"),
        AppSuggestionCandidate(bundleIdentifier: "com.moonlight-stream.Moonlight", fallbackName: "Moonlight"),
        AppSuggestionCandidate(bundleIdentifier: "org.blenderfoundation.blender", fallbackName: "Blender")
    ]

    struct ScanResult: Equatable {
        let passthrough: [DetectedAppSuggestion]
        let optionalIgnored: [DetectedAppSuggestion]
    }

    /// Pure filtering over a map of installed bundle IDs (`bundleID -> localizedName`) for testing and UI.
    nonisolated static func filterCandidates(
        _ candidates: [AppSuggestionCandidate],
        installedByBundleID: [String: String],
        dismissed: Set<String>
    ) -> [DetectedAppSuggestion] {
        candidates.compactMap { candidate in
            guard !dismissed.contains(candidate.bundleIdentifier),
                  let installedName = installedByBundleID[candidate.bundleIdentifier] else {
                return nil
            }
            let displayName = installedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return DetectedAppSuggestion(
                bundleIdentifier: candidate.bundleIdentifier,
                name: displayName.isEmpty ? candidate.fallbackName : displayName
            )
        }
    }

    /// Scans installed and currently running regular apps on this Mac without any network access.
    static func scan(dismissed: Set<String>) async -> ScanResult {
        let installedApps = await InstalledApp.scanInstalledApps()
        var byBundleID: [String: String] = [:]

        for app in installedApps {
            byBundleID[app.bundleIdentifier] = app.name
        }

        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let bundleID = running.bundleIdentifier,
                  byBundleID[bundleID] == nil else { continue }
            byBundleID[bundleID] = running.localizedName ?? bundleID
        }

        return ScanResult(
            passthrough: filterCandidates(passthroughCandidates, installedByBundleID: byBundleID, dismissed: dismissed),
            optionalIgnored: filterCandidates(optionalIgnoredCandidates, installedByBundleID: byBundleID, dismissed: dismissed)
        )
    }

    static func icon(for bundleIdentifier: String) -> NSImage? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let icon = running.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
