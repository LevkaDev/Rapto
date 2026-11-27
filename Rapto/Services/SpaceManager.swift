//
//  SpaceManager.swift
//  Rapto
//
//  Service for detecting and monitoring macOS Desktop Spaces.
//

import Foundation
import AppKit
import Combine
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "SpaceManager")

// MARK: - Private CGS API Declarations

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> CFArray?

/// The ID of the active Space (not per display)
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: CGSConnectionID) -> UInt64

/// The desktops the given windows are on, as `id64` values
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: CGSConnectionID, _ selector: Int32, _ windows: CFArray) -> CFArray?

/// Selector for `CGSCopySpacesForWindows`: every desktop the window is on
private let allSpacesSelector: Int32 = 7

struct DisplaySpaceInfo {
    let displayID: String
    let spaceIDs: [String]
    let currentSpaceID: String
    let currentSpaceIndex: Int
}

/// Supports multi-monitor setups where each display can have independent Spaces
@MainActor
class SpaceManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// The current Space ID for the primary display (stable UUID string)
    @Published private(set) var currentSpaceID: String = ""
    
    /// The current Space index on primary display (1-based, for display purposes)
    @Published private(set) var currentSpaceIndex: Int = 1
    
    /// Total number of Spaces on the primary display
    @Published private(set) var totalSpaces: Int = 1
    
    /// All known Space IDs on primary display (in order)
    @Published private(set) var allSpaceIDs: [String] = []
    
    /// Per-display Space info (key: display identifier)
    @Published private(set) var displaySpaces: [String: DisplaySpaceInfo] = [:]
    /// Displays in the order macOS lists them, which is how Mission Control counts desktops
    private var displayOrder: [String] = []
    
    // MARK: - Callbacks
    
    /// Called when the active Space changes (passes primary display's space ID for backward compatibility)
    var onSpaceChanged: ((String) -> Void)?
    
    /// Called when Space changes on any display (passes displayID and new spaceID)
    var onDisplaySpaceChanged: ((String, String) -> Void)?
    
    private var workspaceObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    init(startMonitoring: Bool = true) {
        if startMonitoring {
            updateSpaceInfo()
            setupSpaceChangeObserver()
            logger.info("SpaceManager initialized - current Space: \(self.currentSpaceID) (index \(self.currentSpaceIndex) of \(self.totalSpaces))")
        } else {
            setFallbackSpaceInfo()
        }
    }
    
    nonisolated deinit {
        // The Space observer is never removed: it holds self weakly, and SpaceManager lives as long as the app
    }
    
    // MARK: - Public Methods
    
    func refresh() {
        updateSpaceInfo()
    }
    
    /// Get display name for a Space (e.g., "Desktop 1") with global numbering
    func displayName(forSpaceID spaceID: String) -> String {
        for (displayID, info) in displaySpaces {
            if info.spaceIDs.contains(spaceID) {
                let globalIdx = globalSpaceIndex(forSpaceID: spaceID, onDisplay: displayID)
                if globalIdx > 0 {
                    return "Desktop \(globalIdx)"
                }
            }
        }
        // Fallback: check primary display with local index
        if let index = allSpaceIDs.firstIndex(of: spaceID) {
            return "Desktop \(index + 1)"
        }
        return "Desktop"
    }
    
    var currentSpaceDisplayName: String {
        return displayName(forSpaceID: currentSpaceID)
    }
    
    func currentSpaceID(forDisplayID displayID: String) -> String? {
        return displaySpaces[displayID]?.currentSpaceID
    }
    
    func displayName(forSpaceID spaceID: String, onDisplay displayID: String) -> String {
        // macOS numbers Spaces globally: Display 1 has 1,2,3; Display 2 has 4,5, etc.
        let globalIndex = globalSpaceIndex(forSpaceID: spaceID, onDisplay: displayID)
        if globalIndex > 0 {
            return "Desktop \(globalIndex)"
        }
        return displayName(forSpaceID: spaceID)
    }
    
    /// Calculate global Space index (1-based) across all displays
    /// macOS numbers Spaces globally, so Display 1's spaces are 1,2,3 and Display 2's start at 4
    func globalSpaceIndex(forSpaceID spaceID: String, onDisplay targetDisplayID: String) -> Int {
        let sortedDisplayIDs = displayOrder
        
        var globalIndex = 0
        for displayID in sortedDisplayIDs {
            guard let info = displaySpaces[displayID] else { continue }
            
            if displayID == targetDisplayID {
                if let localIndex = info.spaceIDs.firstIndex(of: spaceID) {
                    return globalIndex + localIndex + 1
                }
                return 0 // Space not found on this display
            } else {
                globalIndex += info.spaceIDs.count
            }
        }
        return 0
    }
    
    var allDisplayIDs: [String] {
        return Array(displaySpaces.keys)
    }
    
    // MARK: - Private Methods
    
    private func setupSpaceChangeObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.handleSpaceChange()
            }
        }
    }
    
    // MARK: - Workaround: the on-screen window list can hold windows of other desktops
    // Cause: While macOS animates between desktops (and in Mission Control), the windows of every
    //        desktop are on screen at once, and `CGWindowListCopyWindowInfo` lists them all.
    // Context: Rapto took them for windows that had just opened on the current desktop, moved them
    //          into its slots and raised them, which also switched the desktop. Ask macOS which
    //          desktop each window is on and leave out the ones no display shows.
    /// The windows among `windowIDs` that are only on desktops no display shows now.
    func windowsOnHiddenDesktops(among windowIDs: Set<CGWindowID>) -> Set<CGWindowID> {
        guard !windowIDs.isEmpty else { return [] }
        let connection = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return [] }
        let shownSpaces = Set(displays.compactMap { display -> UInt64? in
            let current = display["Current Space"] as? [String: Any]
            return (current?["id64"] as? NSNumber)?.uint64Value
        })
        return windowIDs.filter { windowID in
            let windows = [NSNumber(value: windowID)] as CFArray
            let spaces = CGSCopySpacesForWindows(connection, allSpacesSelector, windows) as? [NSNumber] ?? []
            return Self.isOnHiddenDesktop(windowSpaces: spaces.map(\.uint64Value), shownSpaces: shownSpaces)
        }
    }

    /// A window with no known desktop counts as shown: leaving out a real new window is worse
    /// than the rare extra one.
    nonisolated static func isOnHiddenDesktop(windowSpaces: [UInt64], shownSpaces: Set<UInt64>) -> Bool {
        guard !windowSpaces.isEmpty, !shownSpaces.isEmpty else { return false }
        return shownSpaces.isDisjoint(with: windowSpaces)
    }

    // MARK: - Workaround: activeSpaceDidChangeNotification can come a second after the new desktop shows
    /// Reads the live desktop of every display. If one changed, handles it as if the notification had come.
    /// - Returns: true if a desktop changed.
    @discardableResult
    func catchUpWithDesktopChange() -> Bool {
        let connection = CGSMainConnectionID()
        guard let spacesArray = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return false }
        let changed = spacesArray.contains { displayInfo in
            guard let displayID = displayInfo["Display Identifier"] as? String,
                  let current = displayInfo["Current Space"] as? [String: Any],
                  let liveID = Self.spaceKey(from: current),
                  let knownID = displaySpaces[displayID]?.currentSpaceID else { return false }
            return liveID != knownID
        }
        if changed {
            debugLog("SpaceManager", " Desktop changed before macOS reported it, catching up")
            handleSpaceChange()
        }
        return changed
    }

    /// Reads the desktops again and reports any change, for the primary display and per display
    private func handleSpaceChange() {
        let previousSpaceID = currentSpaceID
        let previousDisplaySpaces = displaySpaces
        updateSpaceInfo()
        
        // Check primary display Space change (backward compatibility)
        if currentSpaceID != previousSpaceID {
            logger.info("Space changed: \(previousSpaceID) -> \(self.currentSpaceID) (\(self.currentSpaceDisplayName))")
            onSpaceChanged?(currentSpaceID)
        }
        
        for (displayID, info) in displaySpaces {
            let previousInfo = previousDisplaySpaces[displayID]
            if previousInfo?.currentSpaceID != info.currentSpaceID {
                logger.info("Display \(displayID) Space changed: \(previousInfo?.currentSpaceID ?? "none") -> \(info.currentSpaceID)")
                onDisplaySpaceChanged?(displayID, info.currentSpaceID)
            }
        }
    }
    
    private func updateSpaceInfo() {
        let connection = CGSMainConnectionID()
        debugLog("SpaceManager"," updateSpaceInfo called, connection=\(connection)")
        
        guard let spacesArray = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
            logger.warning("Failed to get managed display spaces")
            debugLog("SpaceManager"," CGSCopyManagedDisplaySpaces returned nil!")
            setFallbackSpaceInfo()
            return
        }
        
        debugLog("SpaceManager"," Got \(spacesArray.count) display(s)")
        
        let activeSpaceID = CGSGetActiveSpace(connection)
        debugLog("SpaceManager"," CGSGetActiveSpace returned: \(activeSpaceID)")
        
        // Structure: [{ "Display Identifier": "...", "Spaces": [...], "Current Space": {...} }, ...]
        var newDisplaySpaces: [String: DisplaySpaceInfo] = [:]
        var primaryDisplayProcessed = false
        
        for (displayIndex, displayInfo) in spacesArray.enumerated() {
            debugLog("SpaceManager"," === Display \(displayIndex) raw keys: \(displayInfo.keys.sorted()) ===")
            if let dispID = displayInfo["Display Identifier"] {
                debugLog("SpaceManager"," Display Identifier: \(dispID)")
            }
            
            guard let spaces = displayInfo["Spaces"] as? [[String: Any]],
                  let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any] else {
                debugLog("SpaceManager"," Display \(displayIndex): Failed to parse spaces/currentSpaceInfo")
                debugLog("SpaceManager"," Spaces type: \(type(of: displayInfo["Spaces"]))")
                debugLog("SpaceManager"," Current Space type: \(type(of: displayInfo["Current Space"]))")
                continue
            }
            
            let displayID = displayInfo["Display Identifier"] as? String ?? "display-\(displayIndex)"
            debugLog("SpaceManager"," Processing display: \(displayID), spaces count: \(spaces.count)")
            debugLog("SpaceManager"," Current Space raw: \(currentSpaceInfo)")
            
            let displayCurrentSpaceID = extractSpaceID(from: currentSpaceInfo, fallbackID: activeSpaceID) ?? "space-\(activeSpaceID)"
            
            var displaySpaceIDs: [String] = []
            for space in spaces {
                // Type 0 = regular desktop, Type 4 = fullscreen app
                let spaceType = space["type"] as? Int ?? 0
                guard spaceType == 0 else { continue }
                
                if let spaceID = extractSpaceID(from: space, fallbackID: nil) {
                    displaySpaceIDs.append(spaceID)
                }
            }
            
            if displaySpaceIDs.isEmpty {
                displaySpaceIDs = [displayCurrentSpaceID]
            }
            
            let displayCurrentIndex = displaySpaceIDs.firstIndex(of: displayCurrentSpaceID).map { $0 + 1 } ?? 1
            
            let info = DisplaySpaceInfo(
                displayID: displayID,
                spaceIDs: displaySpaceIDs,
                currentSpaceID: displayCurrentSpaceID,
                currentSpaceIndex: displayCurrentIndex
            )
            newDisplaySpaces[displayID] = info
            
            debugLog("SpaceManager"," Display \(displayID): \(displaySpaceIDs.count) spaces, current=\(displayCurrentSpaceID) (index \(displayCurrentIndex))")
            
            // First display is primary - update backward-compatible properties
            if !primaryDisplayProcessed {
                allSpaceIDs = displaySpaceIDs
                totalSpaces = displaySpaceIDs.count
                currentSpaceID = displayCurrentSpaceID
                currentSpaceIndex = displayCurrentIndex
                primaryDisplayProcessed = true
            }
        }
        
        displayOrder = spacesArray.enumerated()
            .map { $0.element["Display Identifier"] as? String ?? "display-\($0.offset)" }
            .filter { newDisplaySpaces[$0] != nil }
        displaySpaces = newDisplaySpaces
        
        if !primaryDisplayProcessed {
            setFallbackSpaceInfo()
        }
        
        logger.debug("Updated Space info: \(newDisplaySpaces.count) displays, primary has \(self.totalSpaces) spaces")
        debugLog("SpaceManager"," Final: \(newDisplaySpaces.count) displays, primarySpaces=\(totalSpaces), currentSpaceIndex=\(currentSpaceIndex)")
    }
    
    /// Returns nil only if fallbackID is nil and no ID found in spaceInfo
    private func extractSpaceID(from spaceInfo: [String: Any], fallbackID: UInt64?) -> String? {
        if let key = Self.spaceKey(from: spaceInfo) {
            return key
        } else if let fallback = fallbackID {
            return "space-\(fallback)"
        }
        return nil
    }

    /// The key Rapto stores a desktop's mode and layout under.
    nonisolated static func spaceKey(from spaceInfo: [String: Any]) -> String? {
        // uuid may exist but be empty string for the first Space
        if let uuid = spaceInfo["uuid"] as? String, !uuid.isEmpty {
            return uuid
        } else if let managedID = spaceInfo["ManagedSpaceID"] as? Int {
            return "space-\(managedID)"
        } else if let id64 = spaceInfo["id64"] as? Int {
            return "space-\(id64)"
        }
        return nil
    }
    
    /// Set fallback values when CGS APIs fail
    private func setFallbackSpaceInfo() {
        if currentSpaceID.isEmpty {
            currentSpaceID = "default-space"
            allSpaceIDs = [currentSpaceID]
        }
        currentSpaceIndex = 1
        totalSpaces = 1
    }
}
