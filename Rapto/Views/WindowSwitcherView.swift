//
//  WindowSwitcherView.swift
//  Rapto
//
//  Search field and window list of the window switcher.
//

import SwiftUI

struct WindowSwitcherView: View {
    @ObservedObject var model: WindowSwitcherModel
    let onActivate: (WindowSwitcherEntry) -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search windows", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: WindowSwitcherController.searchHeight)

            Divider()

            if model.results.isEmpty {
                Text("No matching windows")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index)
                                    .id(entry.id)
                                    .onTapGesture { onActivate(entry) }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) { _, selection in
                        guard model.results.indices.contains(selection) else { return }
                        proxy.scrollTo(model.results[selection].id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
        .onAppear { isSearchFocused = true }
    }

    private func row(_ entry: WindowSwitcherEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: entry.window.pid))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: WindowSwitcherController.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(index == model.selection ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func subtitle(for entry: WindowSwitcherEntry) -> String {
        var parts: [String] = []
        if entry.title != entry.appName {
            parts.append(entry.appName)
        }
        parts.append(entry.isFullScreen ? "Full Screen" : "Desktop \(entry.desktopNumber)")
        if let displayName = entry.displayName {
            parts.append(displayName)
        }
        return parts.joined(separator: " · ")
    }
}
