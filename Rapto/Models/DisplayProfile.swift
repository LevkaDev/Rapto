//
//  DisplayProfile.swift
//  Rapto
//
//  Classifies a display (compact laptop, large laptop, standard desktop, ultrawide)
//  so new installs get sensible layouts and window limits automatically.
//

import AppKit
import CoreGraphics
import Foundation

nonisolated enum DisplayProfile: String, CaseIterable, Equatable, Sendable {
    /// 13"–14" built-in laptop screens and narrow displays (< 1600 pt wide)
    case compactLaptop
    /// 15"–16" built-in laptop screens (1600..<2600 pt wide, aspect < 2.0)
    case largeLaptop
    /// Regular external / iMac desktop monitors (1600..<2600 pt wide, aspect < 2.0)
    case standardDesktop
    /// Wide and ultrawide displays (>= 2600 pt wide, or aspect ratio >= 2.0)
    case ultrawide

    /// Pure classification from logical screen size (in points) and built-in flag.
    static func classify(size: CGSize, isBuiltin: Bool) -> DisplayProfile {
        let width = size.width
        let height = size.height
        let aspect = height > 0 ? width / height : 1.0

        if width >= 2600 || aspect >= 2.0 {
            return .ultrawide
        }
        if width < 1600 {
            return .compactLaptop
        }
        return isBuiltin ? .largeLaptop : .standardDesktop
    }

    static func forScreen(_ screen: NSScreen) -> DisplayProfile {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let isBuiltin = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        return classify(size: screen.frame.size, isBuiltin: isBuiltin)
    }

    /// Picks the widest / highest-capacity profile across connected screens.
    static func dominant(in profiles: [DisplayProfile]) -> DisplayProfile {
        guard !profiles.isEmpty else { return .standardDesktop }
        return profiles.max(by: { $0.capacityRank < $1.capacityRank }) ?? .standardDesktop
    }

    static func dominant(for screens: [NSScreen]) -> DisplayProfile {
        dominant(in: screens.map(forScreen))
    }

    private var capacityRank: Int {
        switch self {
        case .compactLaptop: return 0
        case .largeLaptop: return 1
        case .standardDesktop: return 2
        case .ultrawide: return 3
        }
    }

    /// Recommended maximum side-by-side windows in Auto-tiling before extra windows group.
    var suggestedMaxWindows: Int {
        switch self {
        case .compactLaptop: return 2
        case .largeLaptop: return 3
        case .standardDesktop: return 4
        case .ultrawide: return 5
        }
    }

    /// Single-window layout in Auto-tiling: Full on laptops and regular monitors,
    /// Center Focus (60% centered) only on wide/ultrawide displays.
    var suggestedSingleWindowTemplateID: UUID {
        switch self {
        case .ultrawide:
            return PredefinedTemplates.centerFocus.id
        case .compactLaptop, .largeLaptop, .standardDesktop:
            return PredefinedTemplates.full.id
        }
    }

    /// Default fallback layout when entering Manual mode on a desktop with no chosen layout.
    var suggestedManualTemplate: GridTemplate {
        switch self {
        case .compactLaptop:
            return PredefinedTemplates.halvesVertical
        case .largeLaptop, .standardDesktop:
            return PredefinedTemplates.onePlusTwoLeft
        case .ultrawide:
            return PredefinedTemplates.centerFocus
        }
    }

    /// Whether ultrawide templates belong at the top level of layout menus and pickers.
    var prefersUltrawideLayouts: Bool {
        self == .ultrawide
    }

    /// Plain-English display description for onboarding's auto-tuning summary.
    var shortLabel: String {
        switch self {
        case .compactLaptop: return "Compact laptop"
        case .largeLaptop: return "Large laptop"
        case .standardDesktop: return "Desktop display"
        case .ultrawide: return "Wide display"
        }
    }

    /// One-line summary explaining what Rapto tuned for this Mac's screen(s) and desktops.
    func autoTuneSummary(screenCount: Int, desktopCount: Int) -> String {
        let displayPart = screenCount > 1
            ? "\(screenCount) displays · tuned per screen"
            : "\(shortLabel) · tuned for 1–\(suggestedMaxWindows) windows"
        if desktopCount > 1 {
            return "\(displayPart) · \(desktopCount) desktops ready in Desktops Bar"
        }
        return displayPart
    }

    /// Complete Auto-tiling preset tuned for this display profile.
    var autoTilingPreferences: AutoTilingPreferences {
        AutoTilingPreferences(
            templateFor1Window: suggestedSingleWindowTemplateID,
            templateFor2Windows: PredefinedTemplates.halvesVertical.id,
            templateFor3Windows: PredefinedTemplates.onePlusTwoLeft.id,
            templateFor4Windows: PredefinedTemplates.quarters.id,
            templateFor5Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor6Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor7Windows: PredefinedTemplates.centerSplitSidebars.id,
            templateFor8Windows: PredefinedTemplates.centerSplitSidebars.id,
            maxWindows: suggestedMaxWindows
        )
    }
}
