//
//  WindowThumbnail.swift
//  Rapto
//
//  Visual thumbnail representation of a window for selection.
//

import SwiftUI
import AppKit
import ScreenCaptureKit

/// Calculated thumbnail size based on window count and screen resolution
struct ThumbnailSize {
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat
    let padding: CGFloat
    let badgeSize: CGFloat
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let titleFont: Font
    let subtitleFont: Font
    
    static func calculate(windowCount: Int) -> ThumbnailSize {
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let screenArea = screenSize.width * screenSize.height
        
        let screenScale = sqrt(screenArea / (1920 * 1080))
        
        let countScale: CGFloat
        switch windowCount {
        case 0...2:
            countScale = 1.6
        case 3...4:
            countScale = 1.3
        case 5...6:
            countScale = 1.1
        case 7...9:
            countScale = 0.95
        case 10...12:
            countScale = 0.85
        default:
            countScale = 0.75
        }
        
        let combinedScale = screenScale * countScale
        
        let baseWidth: CGFloat = 180
        let baseHeight: CGFloat = 120
        
        let width = min(max(baseWidth * combinedScale, 140), 360)
        let height = min(max(baseHeight * combinedScale, 95), 240)
        
        let spacing = max(12, 16 * combinedScale)
        let padding = max(16, 24 * combinedScale)
        
        let badgeSize = max(20, 24 * combinedScale)
        let iconSize = max(14, 18 * combinedScale)
        let cornerRadius = max(6, 8 * combinedScale)
        
        let titleFont: Font = combinedScale > 1.2 ? .subheadline : .caption
        let subtitleFont: Font = combinedScale > 1.2 ? .caption : .caption2
        
        return ThumbnailSize(
            width: width,
            height: height,
            spacing: spacing,
            padding: padding,
            badgeSize: badgeSize,
            iconSize: iconSize,
            cornerRadius: cornerRadius,
            titleFont: titleFont,
            subtitleFont: subtitleFont
        )
    }
}

struct WindowThumbnail: View {
    let window: WindowInfo
    
    let assignmentIndex: Int?
    
    let size: ThumbnailSize
    
    let onTap: () -> Void
    
    @State private var thumbnail: NSImage?
    
    var body: some View {
        VStack(spacing: size.spacing / 2) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: size.width, height: size.height)
                    .cornerRadius(size.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: size.cornerRadius)
                            .stroke(
                                assignmentIndex != nil ? Color.accentColor : Color.white.opacity(0.2),
                                lineWidth: assignmentIndex != nil ? 3 : 1
                            )
                    )
                
                if let index = assignmentIndex {
                    Text("\(index + 1)")
                        .font(.system(size: size.badgeSize * 0.55, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: size.badgeSize, height: size.badgeSize)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .offset(x: size.badgeSize / 3, y: -size.badgeSize / 3)
                }
            }
            
            HStack(spacing: 4) {
                if let appIcon = getAppIcon() {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: size.iconSize, height: size.iconSize)
                }
                
                Text(window.ownerName)
                    .font(size.titleFont)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            
            if !window.title.isEmpty {
                Text(window.title)
                    .font(size.subtitleFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size.width)
        .contentShape(Rectangle())
        .onTapGesture {
            debugLog("WindowThumbnail", "TAPPED: \(window.title)")
            onTap()
        }
        .onAppear {
            debugLog("WindowThumbnail", "WindowThumbnail.onAppear for: \(window.title) (ID: \(window.windowID))")
            loadThumbnail()
        }
    }
    
    // MARK: - Thumbnail View
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: size.width, maxHeight: size.height)
                .background(Color.gray.opacity(0.2))
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    ProgressView()
                        .scaleEffect(0.8)
                )
        }
    }
    
    // MARK: - Async Loading
    
    /// Falls back to app icon if screen recording permission not granted or capture fails
    private func loadThumbnail() {
        let captureWidth = size.width
        let captureHeight = size.height
        
        debugLog("WindowThumbnail", "loadThumbnail START for: \(window.title)")
        
        Task {
            // Check screen recording permission first to avoid triggering dialog
            if #available(macOS 15.0, *) {
                let hasPermission = CGPreflightScreenCaptureAccess()
                debugLog("WindowThumbnail", "  Preflight check: \(hasPermission)")
                
                guard hasPermission else {
                    debugLog("WindowThumbnail", "  No permission - using app icon")
                    await MainActor.run {
                        self.thumbnail = getAppIcon()
                    }
                    return
                }
            }
            
            do {
                debugLog("WindowThumbnail", "  Getting shareable content...")
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                debugLog("WindowThumbnail", "  Found \(content.windows.count) windows")
                
                guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                    debugLog("WindowThumbnail", "  Window ID \(window.windowID) not found in shareable content, using app icon")
                    await MainActor.run {
                        self.thumbnail = getAppIcon()
                    }
                    return
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                
                let configuration = SCStreamConfiguration()
                configuration.width = Int(captureWidth * 2) // Retina resolution
                configuration.height = Int(captureHeight * 2)
                configuration.scalesToFit = true
                configuration.showsCursor = false
                
                debugLog("WindowThumbnail", "  Capturing screenshot...")
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                debugLog("WindowThumbnail", "  ✅ Screenshot captured successfully: \(cgImage.width)x\(cgImage.height)")
                
                await MainActor.run {
                    self.thumbnail = nsImage
                }
            } catch {
                debugLog("WindowThumbnail", "  ❌ Capture failed: \(error.localizedDescription), using app icon")
                await MainActor.run {
                    self.thumbnail = getAppIcon()
                }
            }
        }
    }
    
    private func getAppIcon() -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            return nil
        }
        return app.icon
    }
}

// MARK: - Preview

#if DEBUG
struct WindowThumbnail_Previews: PreviewProvider {
    static var previews: some View {
        let size = ThumbnailSize.calculate(windowCount: 3)
        
        HStack(spacing: 16) {
            WindowThumbnail(
                window: WindowInfo(
                    windowID: 1,
                    ownerPID: 1,
                    title: "Document.txt",
                    ownerName: "TextEdit",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                ),
                assignmentIndex: nil,
                size: size,
                onTap: {}
            )
            
            WindowThumbnail(
                window: WindowInfo(
                    windowID: 2,
                    ownerPID: 2,
                    title: "Safari",
                    ownerName: "Safari",
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
                ),
                assignmentIndex: 0,
                size: size,
                onTap: {}
            )
        }
        .padding()
        .background(Color.black)
    }
}
#endif
