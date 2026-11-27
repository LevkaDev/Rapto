//
//  ScreenManager.swift
//  Rapto
//
//  Handles screen geometry and coordinate calculations.
//  Supports multi-monitor setups with per-screen operations.
//

import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "ScreenManager")

enum ScreenDirection {
    case left
    case right
    case up
    case down
    case next      // Cycle through screens
    case previous  // Cycle through screens (reverse)
}

class ScreenManager {
    
    // MARK: - Screen Change Callback
    
    var onScreensChanged: (() -> Void)?
    
    private var screenChangeObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    init(startMonitoring: Bool = true) {
        if startMonitoring {
            setupScreenChangeObserver()
        }
    }
    
    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            logger.info("Screen parameters changed - \(NSScreen.screens.count) screens detected")
            self?.onScreensChanged?()
        }
    }
    
    // MARK: - Gap Settings
    
    /// Gap between windows (in pixels)
    var windowGap: CGFloat = 0 {
        didSet {
            logger.info("windowGap updated to \(self.windowGap)px")
        }
    }
    
    /// Gap from screen edges (in pixels)
    var screenEdgeGap: CGFloat = 0 {
        didSet {
            logger.info("screenEdgeGap updated to \(self.screenEdgeGap)px")
        }
    }
    
    // MARK: - Screen Access Methods
    
    /// `NSScreen.main`, or the primary screen if main is nil.
    /// - Note: Crashes when no screen is connected at all.
    func activeScreen() -> NSScreen {
        if let main = NSScreen.main {
            return main
        }
        guard let firstScreen = NSScreen.screens.first else {
            logger.error("No screens available - this should never happen on macOS")
            fatalError("No screens available on macOS system")
        }
        return firstScreen
    }
    
    func allScreens() -> [NSScreen] {
        return NSScreen.screens
    }
    
    var screenCount: Int {
        return NSScreen.screens.count
    }
    
    var isMultiMonitor: Bool {
        return NSScreen.screens.count > 1
    }
    
    /// The visible frame (without menu bar and Dock) in AppKit coordinates. Defaults to the active screen.
    func visibleFrame(for screen: NSScreen? = nil) -> CGRect {
        let targetScreen = screen ?? activeScreen()
        return targetScreen.visibleFrame
    }
    
    // MARK: - Screen Identification
    
    func identifier(for screen: NSScreen) -> String {
        return ScreenIdentifier.identifier(for: screen)
    }
    
    func screen(for identifier: String) -> NSScreen? {
        return ScreenIdentifier.screen(for: identifier)
    }
    
    /// The display UUID, which matches the Display Identifier from CGSCopyManagedDisplaySpaces.
    /// Empty when it is not available.
    func displayIdentifier(for screen: NSScreen) -> String {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return ""
        }
        
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            let uuidString = CFUUIDCreateString(nil, uuid) as String? ?? ""
            return uuidString
        }
        
        return ""
    }
    
    /// Finds a screen by its CGS display identifier (the UUID SpaceManager uses)
    func screen(forDisplayID displayID: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if displayIdentifier(for: screen) == displayID {
                return screen
            }
        }
        return nil
    }
    
    // MARK: - Window-to-Screen Mapping
    
    /// The screen containing the window's center, or the closest screen to it
    func screen(for window: WindowInfo) -> NSScreen {
        let windowCenter = CGPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        return screen(at: windowCenter) ?? activeScreen()
    }
    
    /// The screen at a point in CG coordinates (origin top-left), or the closest screen to it
    func screen(at point: CGPoint) -> NSScreen? {
        // CG has origin at top-left of primary screen, AppKit at bottom-left
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: point.x, y: primaryScreenHeight - point.y)
        
        for screen in NSScreen.screens {
            if screen.frame.contains(appKitPoint) {
                return screen
            }
        }
        
        return closestScreen(to: appKitPoint)
    }
    
    /// The screen at a point in AppKit coordinates (origin bottom-left), or the closest screen to it
    func screenAppKit(at point: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return closestScreen(to: point)
    }
    
    /// Measured to each screen's center
    private func closestScreen(to point: CGPoint) -> NSScreen? {
        var closest: NSScreen?
        var minDistance: CGFloat = .greatestFiniteMagnitude
        
        for screen in NSScreen.screens {
            let screenCenter = CGPoint(
                x: screen.frame.midX,
                y: screen.frame.midY
            )
            let distance = hypot(point.x - screenCenter.x, point.y - screenCenter.y)
            if distance < minDistance {
                minDistance = distance
                closest = screen
            }
        }
        
        return closest
    }
    
    // MARK: - Screen Navigation
    
    /// Nil when there is a single screen or none lies in that direction
    func nextScreen(from current: NSScreen, direction: ScreenDirection) -> NSScreen? {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return nil }
        
        switch direction {
        case .next:
            return cycleScreen(from: current, forward: true)
        case .previous:
            return cycleScreen(from: current, forward: false)
        case .left:
            return adjacentScreen(from: current, direction: .left)
        case .right:
            return adjacentScreen(from: current, direction: .right)
        case .up:
            return adjacentScreen(from: current, direction: .up)
        case .down:
            return adjacentScreen(from: current, direction: .down)
        }
    }
    
    private func cycleScreen(from current: NSScreen, forward: Bool) -> NSScreen? {
        let screens = NSScreen.screens
        guard let currentIndex = screens.firstIndex(of: current) else {
            return screens.first
        }
        
        if forward {
            let nextIndex = (currentIndex + 1) % screens.count
            return screens[nextIndex]
        } else {
            let prevIndex = (currentIndex - 1 + screens.count) % screens.count
            return screens[prevIndex]
        }
    }
    
    /// The nearest screen whose center lies in that direction, favouring the direction's own axis
    private func adjacentScreen(from current: NSScreen, direction: ScreenDirection) -> NSScreen? {
        let screens = NSScreen.screens.filter { $0 != current }
        guard !screens.isEmpty else { return nil }
        
        let currentCenter = CGPoint(x: current.frame.midX, y: current.frame.midY)
        var bestCandidate: NSScreen?
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        
        for screen in screens {
            let screenCenter = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            
            let isInDirection: Bool
            switch direction {
            case .left:
                isInDirection = screenCenter.x < currentCenter.x
            case .right:
                isInDirection = screenCenter.x > currentCenter.x
            case .up:
                // In AppKit coordinates, up means higher Y
                isInDirection = screenCenter.y > currentCenter.y
            case .down:
                isInDirection = screenCenter.y < currentCenter.y
            default:
                isInDirection = false
            }
            
            guard isInDirection else { continue }
            
            let dx = abs(screenCenter.x - currentCenter.x)
            let dy = abs(screenCenter.y - currentCenter.y)
            let distance: CGFloat
            
            switch direction {
            case .left, .right:
                distance = dx + dy * 0.5
            case .up, .down:
                distance = dy + dx * 0.5
            default:
                distance = hypot(dx, dy)
            }
            
            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = screen
            }
        }
        
        return bestCandidate
    }
    
    // MARK: - Screen Display Names
    
    /// The screen's localized name, or "Main Display" / "Display N" when it has none
    func displayName(for screen: NSScreen) -> String {
        let name = screen.localizedName
        if !name.isEmpty {
            return name
        }
        
        let screens = NSScreen.screens
        if let index = screens.firstIndex(of: screen) {
            if screen == NSScreen.main {
                return "Main Display"
            } else {
                return "Display \(index + 1)"
            }
        }
        
        return "Display"
    }
    
    func allScreenInfo() -> [(id: String, name: String, screen: NSScreen)] {
        return NSScreen.screens.map { screen in
            (identifier(for: screen), displayName(for: screen), screen)
        }
    }

    
    // MARK: - Frame Calculation Methods
    
    /// Converts a relative (0-1) frame to an absolute one and applies window gaps and screen edge gaps.
    /// - Parameters:
    ///   - relativeFrame: A CGRect with values in range 0.0-1.0
    ///   - screenFrame: The screen frame to calculate within (typically visibleFrame)
    /// - Returns: The absolute frame in screen coordinates (AppKit coordinate system)
    func calculateAbsoluteFrame(relativeFrame: CGRect, in screenFrame: CGRect) -> CGRect {
        logger.debug("calculateAbsoluteFrame: windowGap=\(self.windowGap), screenEdgeGap=\(self.screenEdgeGap)")
        let rawFrame = CGRect(
            x: screenFrame.origin.x + (relativeFrame.origin.x * screenFrame.width),
            y: screenFrame.origin.y + (relativeFrame.origin.y * screenFrame.height),
            width: relativeFrame.width * screenFrame.width,
            height: relativeFrame.height * screenFrame.height
        )
        
        return applyGaps(to: rawFrame, relativeFrame: relativeFrame, screenFrame: screenFrame)
    }
    
    /// An edge at the screen border is inset by the screen edge gap, any other edge by half the window gap.
    /// `relativeFrame` (0-1) tells which edges are at the border.
    private func applyGaps(to frame: CGRect, relativeFrame: CGRect, screenFrame: CGRect) -> CGRect {
        guard windowGap > 0 || screenEdgeGap > 0 else {
            logger.debug("No gaps to apply (windowGap=\(self.windowGap), screenEdgeGap=\(self.screenEdgeGap))")
            return frame
        }
        
        logger.debug("Applying gaps: windowGap=\(self.windowGap)px, screenEdgeGap=\(self.screenEdgeGap)px")
        logger.debug("  relativeFrame: x=\(relativeFrame.origin.x), y=\(relativeFrame.origin.y), w=\(relativeFrame.width), h=\(relativeFrame.height)")
        
        var adjustedFrame = frame
        let halfGap = windowGap / 2
        
        // An epsilon absorbs floating point error in the relative frame
        let epsilon: CGFloat = 0.01
        let isAtLeft = relativeFrame.origin.x < epsilon
        let isAtRight = (relativeFrame.origin.x + relativeFrame.width) > (1.0 - epsilon)
        let isAtBottom = relativeFrame.origin.y < epsilon
        let isAtTop = (relativeFrame.origin.y + relativeFrame.height) > (1.0 - epsilon)
        
        logger.debug("  edges: left=\(isAtLeft), right=\(isAtRight), bottom=\(isAtBottom), top=\(isAtTop)")
        
        if isAtLeft && isAtRight {
            adjustedFrame.origin.x += screenEdgeGap
            adjustedFrame.size.width -= 2 * screenEdgeGap
        } else if isAtLeft {
            adjustedFrame.origin.x += screenEdgeGap
            adjustedFrame.size.width -= screenEdgeGap + halfGap
        } else if isAtRight {
            adjustedFrame.origin.x += halfGap
            adjustedFrame.size.width -= screenEdgeGap + halfGap
        } else {
            adjustedFrame.origin.x += halfGap
            adjustedFrame.size.width -= windowGap
        }
        
        // AppKit coordinates: origin.y is the bottom edge
        if isAtBottom && isAtTop {
            adjustedFrame.origin.y += screenEdgeGap
            adjustedFrame.size.height -= 2 * screenEdgeGap
        } else if isAtBottom {
            adjustedFrame.origin.y += screenEdgeGap
            adjustedFrame.size.height -= screenEdgeGap + halfGap
        } else if isAtTop {
            adjustedFrame.origin.y += halfGap
            adjustedFrame.size.height -= screenEdgeGap + halfGap
        } else {
            adjustedFrame.origin.y += halfGap
            adjustedFrame.size.height -= windowGap
        }
        
        return adjustedFrame
    }
    
    /// Converts a frame from AppKit coordinates (origin at bottom-left) to
    /// Core Graphics/Accessibility coordinates (origin at top-left).
    /// - Parameters:
    ///   - frame: The frame in AppKit coordinates (global, relative to primary screen bottom-left)
    ///   - screen: Unused; the conversion is the same for every screen
    ///
    /// CG coordinates have origin at top-left of primary screen.
    /// AppKit coordinates have origin at bottom-left of primary screen.
    /// On every display the conversion uses the primary screen's height.
    func convertToCGCoordinates(frame: CGRect, for screen: NSScreen? = nil) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1440
        
        return CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
    
    // MARK: - Following Visible Area Changes

    /// Visible area of a screen in CG coordinates
    func visibleCGFrame(for screen: NSScreen) -> CGRect {
        convertToCGCoordinates(frame: visibleFrame(for: screen), for: screen)
    }

    /// Where a slot or window frame belongs after the screen's visible area changed from `old` to `new`
    /// (all in CG coordinates). The frame keeps its share of the screen; gaps keep their size in points.
    func rescale(_ frame: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        guard old != new, old.width > 0, old.height > 0 else { return frame }
        let halfGap = windowGap / 2

        // An edge at the screen border is inset by the screen edge gap, any other by half the window gap.
        // "At the border" is told the way `applyGaps` tells it, so the answer is the same at every resolution.
        func moved(_ value: CGFloat, isMin: Bool, low: CGFloat, length: CGFloat, newLow: CGFloat, newLength: CGFloat) -> CGFloat {
            let sign: CGFloat = isMin ? 1 : -1
            let share = (value - sign * screenEdgeGap - low) / length
            let inset = sign * ((isMin ? share < 0.01 : share > 0.99) ? screenEdgeGap : halfGap)
            return newLow + (value - inset - low) / length * newLength + inset
        }

        let minX = moved(frame.minX, isMin: true, low: old.minX, length: old.width, newLow: new.minX, newLength: new.width)
        let maxX = moved(frame.maxX, isMin: false, low: old.minX, length: old.width, newLow: new.minX, newLength: new.width)
        let minY = moved(frame.minY, isMin: true, low: old.minY, length: old.height, newLow: new.minY, newLength: new.height)
        let maxY = moved(frame.maxY, isMin: false, low: old.minY, length: old.height, newLow: new.minY, newLength: new.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Converts a frame from Core Graphics/Accessibility coordinates (origin at top-left) to
    /// AppKit coordinates (origin at bottom-left).
    /// - Parameters:
    ///   - frame: The frame in Core Graphics coordinates
    ///   - screen: Unused; the conversion is the same for every screen
    ///
    /// CG coordinates have origin at top-left of primary screen.
    /// AppKit coordinates have origin at bottom-left of primary screen.
    /// On every display the conversion uses the primary screen's height.
    func convertFromCGCoordinates(frame: CGRect, for screen: NSScreen? = nil) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1440
        
        return CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
