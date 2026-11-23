//
//  CustomTemplateStorage.swift
//  Rapto
//
//  Handles persistence of custom grid templates.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "CustomTemplateStorage")

/// Stores custom templates in Application Support/Rapto/custom_templates.json
class CustomTemplateStorage {
    
    private let storageDirectory: URL
    
    private let templatesFileName = "custom_templates.json"
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDirectory = appSupport.appendingPathComponent("Rapto", isDirectory: true)
        
        moveLegacyDirectoryIfNeeded(from: appSupport.appendingPathComponent("GridSnap", isDirectory: true))
        
        createStorageDirectoryIfNeeded()
    }
    
    // MARK: - Public Methods
    
    /// Templates that fail to decode are skipped. When any are, or the file can't be read at all,
    /// it is copied to `.backup`, since the next save drops what could not be read.
    func loadTemplates() -> [GridTemplate] {
        let fileURL = storageDirectory.appendingPathComponent(templatesFileName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No custom templates file found")
            return []
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try JSONDecoder().decode([LossyDecodable<GridTemplate>].self, from: data)
            let templates = entries.compactMap(\.value)
            if templates.count < entries.count {
                // The next save drops the entries that failed; keep the file as it was
                try? data.write(to: fileURL.appendingPathExtension("backup"))
                logger.error("Skipped \(entries.count - templates.count) custom templates that could not be read")
            }
            logger.info("Loaded \(templates.count) custom templates")
            return templates
        } catch {
            logger.error("Failed to load custom templates: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("backup"))
            try? FileManager.default.copyItem(at: fileURL, to: fileURL.appendingPathExtension("backup"))
            return []
        }
    }
    
    func saveTemplates(_ templates: [GridTemplate]) {
        let fileURL = storageDirectory.appendingPathComponent(templatesFileName)
        
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(templates.count) custom templates")
        } catch {
            logger.error("Failed to save custom templates: \(error.localizedDescription)")
        }
    }
    
    /// Saves and returns the updated list
    func addTemplate(_ template: GridTemplate, to existingTemplates: [GridTemplate]) -> [GridTemplate] {
        var templates = existingTemplates
        templates.append(template)
        saveTemplates(templates)
        return templates
    }
    
    /// Saves and returns the updated list
    func deleteTemplate(withID templateID: UUID, from existingTemplates: [GridTemplate]) -> [GridTemplate] {
        var templates = existingTemplates
        templates.removeAll { $0.id == templateID }
        saveTemplates(templates)
        return templates
    }
    
    // MARK: - Private Methods
    
    /// Templates used to live in a folder named after the app's old name
    private func moveLegacyDirectoryIfNeeded(from legacyDirectory: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDirectory.path),
              !fileManager.fileExists(atPath: storageDirectory.path) else { return }
        
        do {
            try fileManager.moveItem(at: legacyDirectory, to: storageDirectory)
            logger.info("Moved custom templates to \(self.storageDirectory.path)")
        } catch {
            logger.error("Failed to move custom templates: \(error.localizedDescription)")
        }
    }
    
    private func createStorageDirectoryIfNeeded() {
        guard !FileManager.default.fileExists(atPath: storageDirectory.path) else { return }
        
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            logger.info("Created storage directory at \(self.storageDirectory.path)")
        } catch {
            logger.error("Failed to create storage directory: \(error.localizedDescription)")
        }
    }
}
