//
//  WindowGrid.swift
//  Rapto
//
//  Grid display of window thumbnails for selection.
//

import SwiftUI

struct WindowGrid: View {
    /// Windows of the display the overlay is on
    let windows: [WindowInfo]
    
    /// Windows on the current desktops of the other displays, listed after a header
    var otherDisplayWindows: [WindowInfo] = []
    
    let assignedWindows: [WindowInfo]
    
    let onWindowSelect: (WindowInfo) -> Void
    
    private var thumbnailSize: ThumbnailSize {
        ThumbnailSize.calculate(windowCount: windows.count + otherDisplayWindows.count)
    }
    
    private var columns: [GridItem] {
        let size = thumbnailSize
        return [
            GridItem(.adaptive(minimum: size.width, maximum: size.width + 40), spacing: size.spacing)
        ]
    }
    
    var body: some View {
        ScrollView {
            if windows.isEmpty && otherDisplayWindows.isEmpty {
                emptyStateView
            } else {
                VStack(alignment: .leading, spacing: thumbnailSize.spacing) {
                    if !windows.isEmpty {
                        thumbnails(windows)
                    }
                    if !otherDisplayWindows.isEmpty {
                        Text("On Other Displays")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .padding(.top, windows.isEmpty ? 0 : 8)
                        thumbnails(otherDisplayWindows)
                    }
                }
                .padding(thumbnailSize.padding)
            }
        }
        .onAppear {
            debugLog("WindowGrid", "Rendering grid with \(windows.count) windows, \(otherDisplayWindows.count) on other displays")
        }
    }
    
    private func thumbnails(_ list: [WindowInfo]) -> some View {
        LazyVGrid(columns: columns, spacing: thumbnailSize.spacing) {
            ForEach(list) { window in
                WindowThumbnail(
                    window: window,
                    assignmentIndex: assignmentIndex(for: window),
                    size: thumbnailSize,
                    onTap: { onWindowSelect(window) }
                )
            }
        }
    }
    
    private func assignmentIndex(for window: WindowInfo) -> Int? {
        assignedWindows.firstIndex(of: window)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No windows found")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Open some application windows to arrange them")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Preview

#if DEBUG
struct WindowGrid_Previews: PreviewProvider {
    static let sampleWindows = [
        WindowInfo(
            windowID: 1,
            ownerPID: 1,
            title: "Document.txt",
            ownerName: "TextEdit",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        ),
        WindowInfo(
            windowID: 2,
            ownerPID: 2,
            title: "Safari - Apple",
            ownerName: "Safari",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        ),
        WindowInfo(
            windowID: 3,
            ownerPID: 3,
            title: "Xcode",
            ownerName: "Xcode",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
    ]
    
    static var previews: some View {
        Group {
            WindowGrid(
                windows: sampleWindows,
                assignedWindows: [sampleWindows[0]],
                onWindowSelect: { _ in }
            )
            .frame(width: 600, height: 400)
            .background(Color.black.opacity(0.8))
            .previewDisplayName("With Windows")
            
            WindowGrid(
                windows: [],
                assignedWindows: [],
                onWindowSelect: { _ in }
            )
            .frame(width: 600, height: 400)
            .background(Color.black.opacity(0.8))
            .previewDisplayName("Empty State")
        }
    }
}
#endif
