//
//  WindowInfo.swift
//  Rapto
//
//  Model representing information about a window.
//

import Foundation
import CoreGraphics

struct WindowInfo: Identifiable, Equatable, Codable {
    let id: UUID
    let windowID: CGWindowID
    let ownerPID: pid_t
    let title: String
    let ownerName: String
    let bundleIdentifier: String?
    let frame: CGRect
    var thumbnail: CGImage?
    
    init(
        id: UUID = UUID(),
        windowID: CGWindowID,
        ownerPID: pid_t,
        title: String,
        ownerName: String,
        bundleIdentifier: String? = nil,
        frame: CGRect,
        thumbnail: CGImage? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.title = title
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
        self.thumbnail = thumbnail
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.windowID == rhs.windowID
    }
    
    func with(frame newFrame: CGRect) -> WindowInfo {
        WindowInfo(
            id: id,
            windowID: windowID,
            ownerPID: ownerPID,
            title: title,
            ownerName: ownerName,
            bundleIdentifier: bundleIdentifier,
            frame: newFrame,
            thumbnail: thumbnail
        )
    }
}

extension WindowInfo {
    enum CodingKeys: String, CodingKey {
        case id, windowID, ownerPID, title, ownerName, bundleIdentifier, frame
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        windowID = try container.decode(CGWindowID.self, forKey: .windowID)
        ownerPID = try container.decode(pid_t.self, forKey: .ownerPID)
        title = try container.decode(String.self, forKey: .title)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        frame = try container.decode(CGRect.self, forKey: .frame)
        thumbnail = nil // CGImage is not Codable, will be regenerated if needed
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(ownerPID, forKey: .ownerPID)
        try container.encode(title, forKey: .title)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(frame, forKey: .frame)
    }
}
