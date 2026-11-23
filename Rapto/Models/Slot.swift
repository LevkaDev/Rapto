//
//  Slot.swift
//  Rapto
//
//  Unified tiling unit that combines zone, frame, and windows.
//  This is the core data structure for the refactored architecture.
//

import Foundation
import CoreGraphics

/// A slot represents a single position in a grid layout.
/// It combines the zone definition, current frame, and all windows assigned to it.
/// Multiple windows in a slot form a "group" that can be cycled through.
struct Slot: Identifiable, Equatable {
    /// Unique identifier (matches the zone's UUID)
    let id: UUID
    
    /// Index in the fill order (0-based)
    let index: Int
    
    /// Current absolute frame in CG coordinates (top-left origin)
    var frame: CGRect
    
    /// All windows assigned to this slot. First window is the "active" one.
    /// When count > 1, this forms a window group.
    var windows: [WindowInfo]
    
    /// Original bundle identifier of the first window assigned (for restoration after minimize)
    var originalBundleID: String?
    
    /// Original owner name (fallback identifier for apps without bundle ID)
    var originalOwnerName: String?
    
    // MARK: - Computed Properties
    
    var primaryWindow: WindowInfo? {
        windows.first
    }
    
    var hasGroup: Bool {
        windows.count > 1
    }
    
    var isEmpty: Bool {
        windows.isEmpty
    }

    nonisolated var windowCount: Int {
        windows.count
    }
    
    var hasMixedApps: Bool {
        guard windows.count > 1 else { return false }
        
        let uniqueApps = Set(windows.compactMap { $0.bundleIdentifier ?? $0.ownerName })
        return uniqueApps.count > 1
    }
    
    nonisolated var secondaryWindows: [WindowInfo] {
        guard windows.count > 1 else { return [] }
        return Array(windows.dropFirst())
    }
    
    /// Bundle identifier of the primary window, else of the first window the slot was given
    var bundleIdentifier: String? {
        primaryWindow?.bundleIdentifier ?? originalBundleID
    }

    /// Owner name of the primary window, else of the first window the slot was given
    var ownerName: String? {
        primaryWindow?.ownerName ?? originalOwnerName
    }
    
    // MARK: - Initialization
    
    init(
        id: UUID,
        index: Int,
        frame: CGRect,
        windows: [WindowInfo] = [],
        originalBundleID: String? = nil,
        originalOwnerName: String? = nil
    ) {
        self.id = id
        self.index = index
        self.frame = frame
        self.windows = windows
        self.originalBundleID = originalBundleID ?? windows.first?.bundleIdentifier
        self.originalOwnerName = originalOwnerName ?? windows.first?.ownerName
    }
    
    // MARK: - Window Management
    
    mutating func addWindow(_ window: WindowInfo) {
        guard !windows.contains(where: { $0.windowID == window.windowID }) else { return }
        windows.append(window)
        
        if windows.count == 1 {
            originalBundleID = window.bundleIdentifier
            originalOwnerName = window.ownerName
        }
    }
    
    @discardableResult
    mutating func removeWindow(withID windowID: CGWindowID) -> WindowInfo? {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }) else {
            return nil
        }
        return windows.remove(at: index)
    }
    
    mutating func setActiveWindow(_ windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowID == windowID }),
              index != 0 else { return }
        
        let window = windows.remove(at: index)
        windows.insert(window, at: 0)
    }
    
    mutating func cycleForward() {
        guard windows.count > 1 else { return }
        let first = windows.removeFirst()
        windows.append(first)
    }
    
    mutating func cycleBackward() {
        guard windows.count > 1 else { return }
        let last = windows.removeLast()
        windows.insert(last, at: 0)
    }
    
    func contains(windowID: CGWindowID) -> Bool {
        windows.contains { $0.windowID == windowID }
    }
    
    /// Check if a window can be grouped with this slot (same app)
    func canGroup(with window: WindowInfo) -> Bool {
        guard let primary = primaryWindow else { return true }
        
        if let slotBundle = primary.bundleIdentifier,
           let windowBundle = window.bundleIdentifier,
           slotBundle == windowBundle {
            return true
        }
        
        if primary.ownerPID == window.ownerPID {
            return true
        }
        
        // Fallback: match by owner name (for Electron apps)
        if primary.ownerName == window.ownerName {
            return true
        }
        
        return false
    }
    
    static func == (lhs: Slot, rhs: Slot) -> Bool {
        lhs.id == rhs.id &&
        lhs.index == rhs.index &&
        lhs.frame == rhs.frame &&
        lhs.windows.map(\.windowID) == rhs.windows.map(\.windowID)
    }
}

// MARK: - Codable Extension

extension Slot: Codable {
    enum CodingKeys: String, CodingKey {
        case id, index, frame, windows, originalBundleID, originalOwnerName
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        frame = try container.decode(CGRect.self, forKey: .frame)
        windows = try container.decodeIfPresent([WindowInfo].self, forKey: .windows) ?? []
        originalBundleID = try container.decodeIfPresent(String.self, forKey: .originalBundleID)
        originalOwnerName = try container.decodeIfPresent(String.self, forKey: .originalOwnerName)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(frame, forKey: .frame)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(originalBundleID, forKey: .originalBundleID)
        try container.encodeIfPresent(originalOwnerName, forKey: .originalOwnerName)
    }
}

extension Slot: CustomDebugStringConvertible {
    var debugDescription: String {
        let windowDesc = windows.isEmpty ? "empty" : windows.map { "'\($0.title)'" }.joined(separator: ", ")
        return "Slot[\(index)](\(windowCount) windows: \(windowDesc))"
    }
}
