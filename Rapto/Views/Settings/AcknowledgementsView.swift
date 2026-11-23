//
//  AcknowledgementsView.swift
//  Rapto
//
//  Sheet with the third-party notices and Rapto's license.
//

import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private let notices = Acknowledgements.notices
    private let license = Acknowledgements.license

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Acknowledgements")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.neu)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("Rapto includes or is based on the following work. Thank you to its authors.")
                        .foregroundStyle(.neuTextSecondary)

                    ForEach(Array(notices.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }

                    Text("Rapto")
                        .font(.headline)
                        .padding(.top, AppSpacing.sm)
                    Text("Rapto is free software under the GNU General Public License, version 3 or later.")
                    licenseText(license)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(width: 620, height: 560)
        .background(Color.neuBase)
    }

    @ViewBuilder
    private func view(for block: Acknowledgements.Block) -> some View {
        switch block {
        case .heading(let title):
            Text(title)
                .font(.headline)
                .padding(.top, AppSpacing.sm)
        case .text(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .fixedSize(horizontal: false, vertical: true)
        case .link(let url):
            Link(url.absoluteString, destination: url)
        case .license(let text):
            licenseText(text)
        }
    }

    private func licenseText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.neuTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuInset(cornerRadius: AppRadius.md)
    }
}
