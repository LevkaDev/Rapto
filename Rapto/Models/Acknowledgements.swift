//
//  Acknowledgements.swift
//  Rapto
//
//  The third-party notices and the license that ship inside the app.
//

import Foundation

nonisolated enum Acknowledgements {

    enum Block: Equatable {
        case heading(String)
        case text(String)
        case link(URL)
        case license(String)
    }

    static var notices: [Block] {
        blocks(fromMarkdown: bundledText("THIRD_PARTY_NOTICES", "md"))
    }

    static var license: String {
        bundledText("LICENSE", nil)
    }

    private static func bundledText(_ name: String, _ fileExtension: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// Splits the notices file into what the sheet draws. Knows only what that file uses:
    /// `#` headings, paragraphs, a `<url>` on its own line and fenced blocks. The document
    /// title (`# …`) is left out, the sheet has its own.
    static func blocks(fromMarkdown markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var fenced: [String]?

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.text(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if let lines = fenced {
                    blocks.append(.license(lines.joined(separator: "\n")))
                    fenced = nil
                } else {
                    closeParagraph()
                    fenced = []
                }
            } else if fenced != nil {
                fenced?.append(line)
            } else if line.hasPrefix("#") {
                closeParagraph()
                let level = line.prefix { $0 == "#" }.count
                if level > 1 {
                    blocks.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                }
            } else if line.hasPrefix("<"), line.hasSuffix(">"), let url = URL(string: String(line.dropFirst().dropLast())) {
                closeParagraph()
                blocks.append(.link(url))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                closeParagraph()
            } else {
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        closeParagraph()
        return blocks
    }
}
