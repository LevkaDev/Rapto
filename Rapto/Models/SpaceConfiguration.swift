//
//  SpaceConfiguration.swift
//  Rapto
//
//  Configuration for a specific macOS Desktop Space.
//

import Foundation

struct SpaceConfiguration: Codable, Equatable {
    var mode: TilingMode
    
    /// The template ID for auto-tiling mode (nil uses default)
    var templateID: UUID?
    
    static let `default` = SpaceConfiguration(mode: .none, templateID: nil)
    
    init(mode: TilingMode, templateID: UUID? = nil) {
        self.mode = mode
        self.templateID = templateID
    }
}

struct SpaceConfigurationStorage {
    private static let key = "spaceConfigurations"
    
    static func load(from store: UserDefaults = .standard) -> [String: SpaceConfiguration] {
        guard let data = store.data(forKey: key) else {
            return [:]
        }
        
        do {
            let entries = try JSONDecoder().decode([String: LossyDecodable<SpaceConfiguration>].self, from: data)
            let configs = entries.compactMapValues(\.value)
            if configs.count < entries.count {
                // The next save drops the entries that failed; keep the data as it was
                store.set(data, forKey: key + "_backup")
                debugLog("SpaceConfigurationStorage", "Skipped \(entries.count - configs.count) configurations that could not be read")
            }
            return configs
        } catch {
            debugLog("SpaceConfigurationStorage", "Failed to decode configurations: \(error)")
            store.set(data, forKey: key + "_backup")
            return [:]
        }
    }
    
    static func save(_ configurations: [String: SpaceConfiguration]) {
        do {
            let data = try JSONEncoder().encode(configurations)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            debugLog("SpaceConfigurationStorage", "Failed to encode configurations: \(error)")
        }
    }
    
}
