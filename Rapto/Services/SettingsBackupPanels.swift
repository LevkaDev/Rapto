//
//  SettingsBackupPanels.swift
//  Rapto
//
//  The Export and Import buttons in Settings: file panels, the safety copy made
//  before an import, and the restart that loads the imported settings.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum SettingsBackupPanels {

    private static let keptSafetyCopies = 5

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rapto", isDirectory: true)
    }

    /// The same file `CustomTemplateStorage` reads
    private static var templatesFile: URL {
        supportDirectory.appendingPathComponent("custom_templates.json")
    }

    static var safetyCopiesDirectory: URL {
        supportDirectory.appendingPathComponent("Settings Backups", isDirectory: true)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static func currentSettings() throws -> Data {
        try SettingsBackup.export(from: .standard, templatesFile: templatesFile, appVersion: appVersion)
    }

    // MARK: - Export

    static func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Rapto Settings \(dayStamp()).json"
        panel.message = "Saves your settings, shortcuts, layouts and workspaces to one file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try currentSettings().write(to: url, options: .atomic)
            debugLog("SettingsBackup", "Exported settings to \(url.lastPathComponent)")
            // The save panel closes without a word, so show the file where it landed
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showAlert(title: "Could Not Save the File", message: error.localizedDescription)
        }
    }

    // MARK: - Import

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a settings file exported from Rapto"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let archive: SettingsBackup.Archive
        do {
            archive = try SettingsBackup.read(Data(contentsOf: url))
        } catch {
            showAlert(title: "Could Not Import Settings", message: error.localizedDescription)
            return
        }
        guard confirmImport(of: archive) else { return }

        do {
            // Nothing else runs between here and the restart, so the running app
            // cannot write its own values over the imported ones
            try saveSafetyCopy()
            try SettingsBackup.apply(archive, to: .standard, templatesFile: templatesFile)
        } catch {
            showAlert(title: "Could Not Import Settings", message: error.localizedDescription)
            return
        }
        debugLog("SettingsBackup", "Imported \(archive.settings.count) settings from Rapto \(archive.appVersion), restarting")
        UserDefaults.standard.synchronize()
        relaunch()
    }

    private static func confirmImport(of archive: SettingsBackup.Archive) -> Bool {
        var source = archive.appVersion.isEmpty ? "" : "Saved by Rapto \(archive.appVersion)"
        if let date = archive.exportedAt {
            let when = date.formatted(date: .abbreviated, time: .shortened)
            source = source.isEmpty ? "Saved \(when)" : "\(source), \(when)"
        }
        let alert = NSAlert()
        alert.messageText = "Replace Your Settings?"
        alert.informativeText = [
            source,
            "Your settings, shortcuts, layouts and workspaces will be replaced with the ones in this file. "
                + "Rapto keeps a copy of the current ones and restarts.",
            "If this file comes from another Mac, choose a layout for each desktop after the restart."
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Import and Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The settings as they are now, in a file that Import reads, so an import can be undone.
    private static func saveSafetyCopy() throws {
        let directory = safetyCopiesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let file = directory.appendingPathComponent("\(safetyCopyPrefix)\(formatter.string(from: Date())).json")
        try currentSettings().write(to: file, options: .atomic)

        // Names sort by date, so the oldest come first
        let copies = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(safetyCopyPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in copies.dropLast(keptSafetyCopies) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static let safetyCopyPrefix = "Before Import "

    /// Whether an import has left a copy of earlier settings to go back to
    static var hasSafetyCopies: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: safetyCopiesDirectory.path)) ?? []
        return names.contains { $0.hasPrefix(safetyCopyPrefix) }
    }

    static func showSafetyCopies() {
        NSWorkspace.shared.open(safetyCopiesDirectory)
    }

    // MARK: - Restart

    /// Starts Rapto again once this copy is gone. Leaving without the usual quit keeps
    /// the running app from saving anything on the way out.
    private static func relaunch() -> Never {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Right after an app exits, `open` can fail with -600 while macOS still lists it as running
        let script = "sleep 0.5; for i in 1 2 3 4 5 6 7 8; do /usr/bin/open \"$0\" && exit 0; sleep 0.5; done"
        task.arguments = ["-c", script, Bundle.main.bundlePath]
        try? task.run()
        exit(0)
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
