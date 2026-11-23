//
//  TemplateHotkey.swift
//  Rapto
//
//  Model for storing template-to-hotkey assignments.
//

import Foundation

struct TemplateHotkey: Codable, Identifiable, Equatable {
    let id: UUID
    let templateID: UUID
    let templateName: String  // For display purposes
    let keyCode: UInt32
    let modifiers: UInt32
    
    init(id: UUID = UUID(), templateID: UUID, templateName: String, keyCode: UInt32, modifiers: UInt32) {
        self.id = id
        self.templateID = templateID
        self.templateName = templateName
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    
}
