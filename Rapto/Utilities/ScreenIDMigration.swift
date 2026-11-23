import AppKit

// MARK: - Workaround: display numbers change after a restart
// Settings used to be stored under "display-<number>", and macOS can give the same
// display another number after a restart or reconnect. This moves them to the
// UUID-based identifier. Runs on every launch so a display that was not connected
// the first time is moved once it is back with its old number.
enum ScreenIDMigration {
    private static let firstRunKey = "screenIDMigration_v1"
    private static let layoutPrefix = "savedLayoutInfo_v4_"
    private static let slotMemoryKey = "spaceBarSlotMemory"
    private static let workspacesKey = "workspaces.v1"

    static func run() {
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: firstRunKey)
        let mapping = legacyMapping(firstRun: firstRun)
        defer { defaults.set(true, forKey: firstRunKey) }

        let rank = priority(of: mapping)
        let moved = migrateConfigurations(mapping, rank: rank)
            + migrateLayouts(mapping, rank: rank)
            + migrateSlotMemory(mapping, rank: rank)
            + migrateWorkspaces(mapping)
        if moved > 0 {
            debugLog("ScreenIDMigration", "Moved \(moved) saved settings to stable display ids: \(mapping)")
        }
    }

    /// Old "display-<number>" ids and the stable id each one now belongs to.
    private static func legacyMapping(firstRun: Bool) -> [String: String] {
        let connected = NSScreen.screens.compactMap { screen -> (legacyID: String, stableID: String)? in
            guard let number = ScreenIdentifier.displayNumber(of: screen) else { return nil }
            return (ScreenIdentifier.legacyIdentifier(number), ScreenIdentifier.identifier(for: screen))
        }
        let onlyDisplay = firstRun && NSScreen.screens.count == 1 ? connected.first?.stableID : nil
        return legacyMapping(
            connected: connected,
            workspaceScreens: storedWorkspaceScreens(),
            legacyIDsForOnlyDisplay: onlyDisplay == nil ? [] : storedLegacyIDs(),
            onlyDisplay: onlyDisplay
        )
    }

    /// - Parameters:
    ///   - connected: each connected display's current old id and its stable id
    ///   - workspaceScreens: stored workspace screens, which recorded both ids
    ///   - onlyDisplay: the stable id of the only display, on the first run only
    static func legacyMapping(
        connected: [(legacyID: String, stableID: String)],
        workspaceScreens: [[String: Any]],
        legacyIDsForOnlyDisplay: Set<String>,
        onlyDisplay: String?
    ) -> [String: String] {
        var mapping: [String: String] = [:]

        // Workspaces stored both ids, which tells where an old number belonged. This beats the guess
        // below: another display can have that number now.
        for screen in workspaceScreens {
            guard let old = screen["screenID"] as? String, ScreenIdentifier.isLegacy(old),
                  let uuid = screen["displayUUID"] as? String, !uuid.isEmpty, mapping[old] == nil else { continue }
            mapping[old] = "display-\(uuid)"
        }

        for display in connected where display.stableID != display.legacyID && mapping[display.legacyID] == nil {
            mapping[display.legacyID] = display.stableID
        }

        // With one display, everything saved under older numbers was for it.
        if let onlyDisplay {
            for old in legacyIDsForOnlyDisplay where mapping[old] == nil {
                mapping[old] = onlyDisplay
            }
        }
        return mapping
    }

    /// When two old ids hold settings for the same place, the display's current
    /// number wins, then the higher (more recent) number.
    private static func priority(of mapping: [String: String]) -> (String) -> Int {
        let current = Set(NSScreen.screens.compactMap { ScreenIdentifier.displayNumber(of: $0) }.map { ScreenIdentifier.legacyIdentifier($0) })
        return { id in
            guard ScreenIdentifier.isLegacy(id) else { return Int.max }
            if current.contains(id) { return Int.max - 1 }
            return Int(id.dropFirst("display-".count)) ?? 0
        }
    }

    private static func storedLegacyIDs() -> Set<String> {
        let defaults = UserDefaults.standard
        var ids = Set<String>()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(layoutPrefix) {
            if let screenID = key.split(separator: "_").last.map(String.init), ScreenIdentifier.isLegacy(screenID) {
                ids.insert(screenID)
            }
        }
        for key in ScreenConfigurationStorage.load().keys {
            if let screenID = ConfigurationKey.parse(key)?.screenID, ScreenIdentifier.isLegacy(screenID) {
                ids.insert(screenID)
            }
        }
        return ids
    }

    private static func migrateConfigurations(_ mapping: [String: String], rank: (String) -> Int) -> Int {
        let configurations = ScreenConfigurationStorage.load()
        var result: [String: ScreenConfiguration] = [:]
        var moved = 0
        let ordered = configurations.sorted {
            rank(ConfigurationKey.parse($0.key)?.screenID ?? "") > rank(ConfigurationKey.parse($1.key)?.screenID ?? "")
        }
        for (key, configuration) in ordered {
            guard let parts = ConfigurationKey.parse(key), let stable = mapping[parts.screenID] else {
                result[key] = result[key] ?? configuration
                continue
            }
            let newKey = ConfigurationKey.make(spaceID: parts.spaceID, screenID: stable)
            if result[newKey] == nil { result[newKey] = configuration }
            moved += 1
        }
        if moved > 0 { ScreenConfigurationStorage.save(result) }
        return moved
    }

    private static func migrateLayouts(_ mapping: [String: String], rank: (String) -> Int) -> Int {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(layoutPrefix) }
        var moved = 0
        let legacy = keys.compactMap { key -> (key: String, spaceID: String, screenID: String)? in
            guard let separator = key.lastIndex(of: "_") else { return nil }
            let screenID = String(key[key.index(after: separator)...])
            let spaceID = String(key[key.index(key.startIndex, offsetBy: layoutPrefix.count)..<separator])
            return mapping[screenID] == nil ? nil : (key, spaceID, screenID)
        }
        for entry in legacy.sorted(by: { rank($0.screenID) > rank($1.screenID) }) {
            guard let stable = mapping[entry.screenID] else { continue }
            let newKey = "\(layoutPrefix)\(entry.spaceID)_\(stable)"
            if defaults.object(forKey: newKey) == nil {
                defaults.set(defaults.object(forKey: entry.key), forKey: newKey)
            }
            defaults.removeObject(forKey: entry.key)
            moved += 1
        }
        return moved
    }

    private static func migrateSlotMemory(_ mapping: [String: String], rank: (String) -> Int) -> Int {
        let defaults = UserDefaults.standard
        guard let memory = defaults.dictionary(forKey: slotMemoryKey) as? [String: Int] else { return 0 }
        var result: [String: Int] = [:]
        var moved = 0
        let ordered = memory.sorted { rank(screenPart($0.key)) > rank(screenPart($1.key)) }
        for (key, slot) in ordered {
            var parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let stable = mapping[parts[1]] else {
                result[key] = result[key] ?? slot
                continue
            }
            parts[1] = stable
            let newKey = parts.joined(separator: "|")
            if result[newKey] == nil { result[newKey] = slot }
            moved += 1
        }
        if moved > 0 { defaults.set(result, forKey: slotMemoryKey) }
        return moved
    }

    private static func screenPart(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 ? String(parts[1]) : ""
    }

    private static func migrateWorkspaces(_ mapping: [String: String]) -> Int {
        var workspaces = WorkspaceStorage.load()
        var moved = 0
        for w in workspaces.indices {
            for s in workspaces[w].screens.indices {
                let screen = workspaces[w].screens[s]
                guard ScreenIdentifier.isLegacy(screen.screenID) else { continue }
                if let uuid = screen.displayUUID, !uuid.isEmpty {
                    workspaces[w].screens[s].screenID = "display-\(uuid)"
                } else if let stable = mapping[screen.screenID] {
                    workspaces[w].screens[s].screenID = stable
                } else {
                    continue
                }
                moved += 1
            }
        }
        if moved > 0 { WorkspaceStorage.save(workspaces) }
        return moved
    }

    private static func storedWorkspaceScreens() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: workspacesKey),
              let workspaces = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return workspaces.flatMap { $0["screens"] as? [[String: Any]] ?? [] }
    }
}
