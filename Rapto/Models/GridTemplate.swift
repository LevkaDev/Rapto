//
//  GridTemplate.swift
//  Rapto
//
//  Model representing a grid layout template.
//

import Foundation

nonisolated struct GridTemplate: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let icon: String  // SF Symbol name
    let zones: [Zone]
    
    init(id: UUID = UUID(), name: String, icon: String, zones: [Zone]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.zones = zones
    }
}
