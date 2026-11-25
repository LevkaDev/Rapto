//
//  AppBundleLookup.swift
//  Rapto
//
//  The app a process belongs to when the process has no bundle identifier of its own.
//

import AppKit

// MARK: - Workaround: Windows of a process without a bundle identifier
// Cause: Apps that run Windows software through Wine (MetaTrader 5, CrossOver bottles) show
//        their windows from a helper executable deep inside the app bundle. macOS gives that
//        process no bundle identifier, so the app could not be ignored, kept out of shortcuts
//        or matched to its saved slot: all of these go by bundle identifier.
// Context: Such a process counts as the app whose bundle its executable lies in.
// Limits: A Wine installed on its own (Homebrew) lies in no app bundle, so its windows stay
//         without an identifier. A launcher that runs several Windows programs (CrossOver)
//         is one app here: its programs cannot be told apart and are ignored together.
nonisolated enum AppBundleLookup {

    /// The bundle identifier of the process, or of the app bundle its executable lies in.
    static func bundleIdentifier(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        if let identifier = app.bundleIdentifier { return identifier }
        guard let path = app.executableURL?.path else { return nil }
        return enclosingBundle(ofExecutableAt: path)?.identifier
    }

    /// The name to show for the process: its own, or the enclosing app's when it has no bundle
    /// identifier (the helper is called "wine", which says nothing to the user).
    static func displayName(for app: NSRunningApplication) -> String {
        if app.bundleIdentifier == nil, let path = app.executableURL?.path,
           let name = enclosingBundle(ofExecutableAt: path)?.name {
            return name
        }
        return app.localizedName ?? "Unknown"
    }

    /// The `.app` folders a file lies in, innermost first.
    static func enclosingAppPaths(of path: String) -> [String] {
        let components = (path as NSString).pathComponents
        var result: [String] = []
        // The last component is the file itself
        for index in components.indices.dropLast() where components[index].hasSuffix(".app") {
            result.append(NSString.path(withComponents: Array(components[...index])))
        }
        return result.reversed()
    }

    private static let lock = NSLock()
    /// By executable path. A path that led nowhere is remembered too: windows are listed often.
    nonisolated(unsafe) private static var known: [String: (identifier: String, name: String)?] = [:]

    private static func enclosingBundle(ofExecutableAt path: String) -> (identifier: String, name: String)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = known[path] { return cached }
        var found: (identifier: String, name: String)?
        for appPath in enclosingAppPaths(of: path) {
            if let identifier = Bundle(path: appPath)?.bundleIdentifier {
                found = (identifier, FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: ""))
                break
            }
        }
        known[path] = .some(found)
        return found
    }
}
