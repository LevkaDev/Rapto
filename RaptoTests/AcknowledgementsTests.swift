//
//  AcknowledgementsTests.swift
//  RaptoTests
//
//  The notices shown in Settings, About.
//

import Testing
import Foundation
@testable import Rapto

struct AcknowledgementsTests {

    @Test("Headings, paragraphs, links and license blocks come out in order")
    func blocksInOrder() {
        let markdown = """
        # Third-party notices

        Intro line one
        and line two.

        ## Some Project

        <https://example.com/project>

        ```
        MIT License

        Copyright (c) someone
        ```
        """
        #expect(Acknowledgements.blocks(fromMarkdown: markdown) == [
            .text("Intro line one and line two."),
            .heading("Some Project"),
            .link(URL(string: "https://example.com/project")!),
            .license("MIT License\n\nCopyright (c) someone"),
        ])
    }

    @Test("The app carries the notices of everything it is based on, and its own license")
    func bundledFiles() {
        let notices = Acknowledgements.notices
        #expect(notices.contains(.heading("InstantSpaceSwitcher")))
        #expect(notices.contains(.heading("Sparkle")))
        #expect(notices.contains { if case .license(let text) = $0 { text.contains("MIT License") } else { false } })
        #expect(Acknowledgements.license.contains("GNU GENERAL PUBLIC LICENSE"))
    }
}
