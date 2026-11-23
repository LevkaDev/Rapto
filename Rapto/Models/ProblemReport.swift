//
//  ProblemReport.swift
//  Rapto
//
//  Links that open a bug report with the setup details filled in. Rapto sends nothing
//  itself: the form or the mail opens for the user to finish and send.
//

import AppKit

nonisolated enum ProblemReport {

    struct Details: Equatable {
        var appVersion: String
        var build: String
        var macOS: String
        var displays: Int
        var desktops: Int
        var separateSpaces: Bool
        var modes: [TilingMode]
    }

    static let supportAddress = "support@rapto.app"

    /// The bug report form of the repository. The parameter names are the field ids in
    /// `.github/ISSUE_TEMPLATE/bug_report.yml`; keep the two in step.
    static func gitHubURL(for details: Details) -> URL {
        var components = URLComponents(string: "https://github.com/LevkaDev/Rapto/issues/new")!
        var items = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: versionText(details)),
            URLQueryItem(name: "macos", value: details.macOS),
            // The modes are repeated here because GitHub may not fill a dropdown from a link
            URLQueryItem(name: "displays", value: "\(setupText(details)); \(modesText(details))"),
        ]
        if let mode = details.modes.first, details.modes.count == 1 {
            items.append(URLQueryItem(name: "mode", value: formOption(for: mode)))
        }
        components.queryItems = items
        return components.url!
    }

    static func mailURL(for details: Details) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Rapto problem report"),
            URLQueryItem(name: "body", value: mailBody(for: details)),
        ]
        return components.url!
    }

    static func mailBody(for details: Details) -> String {
        """
        What I did:


        What I expected:


        What happened:


        ---
        Rapto \(versionText(details))
        macOS \(details.macOS)
        \(setupText(details))
        \(modesText(details))
        """
    }

    static func versionText(_ details: Details) -> String {
        details.build.isEmpty ? details.appVersion : "\(details.appVersion) (\(details.build))"
    }

    static func setupText(_ details: Details) -> String {
        let displays = details.displays == 1 ? "1 display" : "\(details.displays) displays"
        let desktops = details.desktops == 1 ? "1 desktop" : "\(details.desktops) desktops"
        return "\(displays), \(desktops), separate Spaces \(details.separateSpaces ? "on" : "off")"
    }

    static func modesText(_ details: Details) -> String {
        let names = details.modes.map(formOption(for:))
        return "\(names.count == 1 ? "mode" : "modes"): \(names.isEmpty ? "unknown" : names.joined(separator: ", "))"
    }

    /// The option of the form's Mode dropdown for a mode
    static func formOption(for mode: TilingMode) -> String {
        switch mode {
        case .manualAssignment: return "Manual"
        case .autoTiling: return "Auto Tiling"
        case .dragSnap: return "Drag to Snap"
        case .none: return "None"
        }
    }

    static func macOSVersionText(_ version: OperatingSystemVersion) -> String {
        version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

extension AppState {
    /// The setup as it is now, for a problem report
    var problemReportDetails: ProblemReport.Details {
        let info = Bundle.main.infoDictionary
        var modes: [TilingMode] = []
        for screen in screenManager.allScreens() where !modes.contains(mode(for: screen)) {
            modes.append(mode(for: screen))
        }
        return ProblemReport.Details(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            macOS: ProblemReport.macOSVersionText(ProcessInfo.processInfo.operatingSystemVersion),
            displays: NSScreen.screens.count,
            desktops: spaceManager.allSpaceIDs.count,
            separateSpaces: NSScreen.screensHaveSeparateSpaces,
            modes: modes
        )
    }
}
