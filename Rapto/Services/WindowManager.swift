//
//  WindowManager.swift
//  Rapto
//
//  Enumerates windows and generates thumbnails using Core Graphics and ScreenCaptureKit APIs.
//

import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

class WindowManager {
    
    /// Minimum width and height for a listed window; smaller ones are UI elements
    private let minimumWindowSize: CGFloat = 100
    
    /// Minimum window size for auto-tiling (larger to filter dialogs)
    nonisolated static let minimumTilableSize: CGFloat = 300
    
    /// Bundle identifiers of apps to ignore (set by AppState)
    var ignoredBundleIdentifiers: Set<String> = []
    
    // MARK: - Window Enumeration
    
    /// Fresh WindowInfo for a window whose stored WindowInfo may have a stale position.
    /// Includes ignored apps; nil if the window is not on screen.
    func refreshWindowInfo(for windowID: CGWindowID) -> WindowInfo? {
        return enumerateWindows(includeIgnored: true).first { $0.windowID == windowID }
    }
    
    /// Current bounds of one window (CG coordinates), or nil if it's gone.
    /// Cheap enough for every mouse-drag event, unlike `enumerateWindows()`,
    /// which lists all windows and looks up the app of each one.
    func frame(of windowID: CGWindowID) -> CGRect? {
        // Several services ask about the same window for the same mouse event;
        // each query is a round trip to the window server
        let now = CACurrentMediaTime()
        if let recent = recentFrameQuery, recent.windowID == windowID, now - recent.time < 0.008 {
            return recent.frame
        }
        
        var frame: CGRect?
        if let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
           let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: bounds),
           rect.width > 0, rect.height > 0 {
            frame = rect
        }
        recentFrameQuery = (windowID, frame, now)
        return frame
    }
    
    private var recentFrameQuery: (windowID: CGWindowID, frame: CGRect?, time: CFTimeInterval)?

    /// Whether the window still exists, also when it is minimized or on another desktop.
    func windowExists(_ windowID: CGWindowID) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
        return info?.isEmpty == false
    }
    
    /// Once the pointer is this far from where the button went down and the window
    /// still hasn't moved or resized, the drag isn't moving the window (e.g. text selection)
    static let windowDragGiveUpDistance: CGFloat = 40
    
    static func pointerMovedPastGiveUpDistance(from start: CGPoint) -> Bool {
        let current = NSEvent.mouseLocation
        return hypot(current.x - start.x, current.y - start.y) > windowDragGiveUpDistance
    }
    
    /// On-screen windows of layer 0 from other apps, larger than `minimumWindowSize`, in front-to-back order.
    /// On first call, may trigger screen recording permission dialog. After user responds,
    /// macOS remembers the choice and won't show the dialog again.
    func enumerateWindows(includeIgnored: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        
        return windowList.compactMap { dict -> WindowInfo? in
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = dict[kCGWindowLayer as String] as? Int else {
                return nil
            }
            
            guard layer == 0 else { return nil }
            
            guard ownerPID != ownPID || TourSandboxWindows.contains(windowID) else { return nil }
            
            let title = dict[kCGWindowName as String] as? String ?? ""
            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""
            
            let runningApp = NSRunningApplication(processIdentifier: ownerPID)
            let bundleIdentifier = AppBundleLookup.bundleIdentifier(for: runningApp)
            
            guard let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }
            
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            
            guard frame.width > minimumWindowSize && frame.height > minimumWindowSize else {
                return nil
            }
            
            if !includeIgnored, let bundleID = bundleIdentifier, ignoredBundleIdentifiers.contains(bundleID) {
                return nil
            }
            
            return WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                title: title,
                ownerName: ownerName,
                bundleIdentifier: bundleIdentifier,
                frame: frame,
                thumbnail: nil
            )
        }
    }
}
