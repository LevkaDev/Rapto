//
//  ProblemReportTests.swift
//  RaptoTests
//
//  The links behind Report a Problem in Settings, About.
//

import Testing
import Foundation
@testable import Rapto

struct ProblemReportTests {

    private let details = ProblemReport.Details(
        appVersion: "6.0", build: "88", macOS: "27.2",
        displays: 2, desktops: 4, separateSpaces: true, modes: [.manualAssignment]
    )

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("The GitHub link opens the bug form with the setup filled in")
    func gitHubLink() {
        let url = ProblemReport.gitHubURL(for: details)
        #expect(url.absoluteString.hasPrefix("https://github.com/LevkaDev/Rapto/issues/new?"))
        #expect(query(url) == [
            "template": "bug_report.yml",
            "version": "6.0 (88)",
            "macos": "27.2",
            "displays": "2 displays, 4 desktops, separate Spaces on; mode: Manual",
            "mode": "Manual",
        ])
    }

    @Test("With different modes on the displays the dropdown is left to the user")
    func severalModes() {
        var mixed = details
        mixed.modes = [.autoTiling, .dragSnap]
        let fields = query(ProblemReport.gitHubURL(for: mixed))
        #expect(fields["mode"] == nil)
        #expect(fields["displays"] == "2 displays, 4 desktops, separate Spaces on; modes: Auto Tiling, Drag to Snap")
    }

    @Test("The link's field names are the ids of the form in the repository")
    func fieldNamesMatchTheForm() throws {
        let form = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let text = try String(contentsOf: form, encoding: .utf8)
        for name in query(ProblemReport.gitHubURL(for: details)).keys where name != "template" {
            #expect(text.contains("id: \(name)\n"), "No field with id \(name) in bug_report.yml")
        }
        for mode in TilingMode.allCases {
            #expect(text.contains("- \(ProblemReport.formOption(for: mode))\n"))
        }
    }

    @Test("The mail goes to support with the setup under the questions")
    func mailLink() {
        let url = ProblemReport.mailURL(for: details)
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:support@rapto.app?"))
        let fields = query(url)
        #expect(fields["subject"] == "Rapto problem report")
        #expect(fields["body"]?.hasSuffix("---\nRapto 6.0 (88)\nmacOS 27.2\n2 displays, 4 desktops, separate Spaces on\nmode: Manual") == true)
    }

    @Test("One display and one desktop read in the singular; a patch version is shown when there is one")
    func wording() {
        var single = details
        single.displays = 1
        single.desktops = 1
        single.separateSpaces = false
        #expect(ProblemReport.setupText(single) == "1 display, 1 desktop, separate Spaces off")
        #expect(ProblemReport.macOSVersionText(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)) == "27.2")
        #expect(ProblemReport.macOSVersionText(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)) == "27.2.1")
    }
}
