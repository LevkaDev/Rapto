//
//  WindowFlow.swift
//  Rapto
//
//  Visual 3D window switcher across all desktops of the active display.
//  With Screen Recording enabled, live window previews shrink into a 3D amphitheatre strip
//  and grow seamlessly into the chosen window's frame; without Screen Recording, it opens
//  as an icon overlay with a prompt to enable Screen Recording in System Settings.
//

import AppKit
import Carbon
import CoreImage
import CoreText
import QuartzCore
import ScreenCaptureKit

// MARK: - Spring

/// A damped spring stepped by the display link, so every value can be redirected mid-flight.
nonisolated struct WindowFlowSpring: Sendable {
    var value: Double
    var target: Double
    var velocity: Double = 0
    var stiffness: Double = 260
    var damping: Double = 28

    init(_ value: Double, stiffness: Double = 260, damping: Double = 28) {
        self.value = value
        self.target = value
        self.stiffness = stiffness
        self.damping = damping
    }

    var isSettled: Bool { abs(value - target) < 0.0015 && abs(velocity) < 0.02 }

    mutating func step(_ dt: Double) {
        var remaining = min(dt, 0.05)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240.0)
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
            remaining -= h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }

    mutating func jump(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }
}

// MARK: - Pure Layout & Scroll Math

nonisolated enum WindowFlowLayout {
    /// Picks the clamped card index a scroll flick coasts to.
    static func coastTarget(
        position: Double,
        velocity: Double,
        coastSeconds: Double,
        count: Int
    ) -> Double {
        guard count > 1 else { return 0 }
        let speed = min(max(velocity, -18), 18)
        let last = Double(count - 1)
        return min(max((position + speed * coastSeconds).rounded(), 0), last)
    }

    /// Computes a card's visual size at `position`, smoothly interpolating between `centerBox` and `sideBox`.
    static func cardSize(
        index: Int,
        at position: Double,
        centerBox: CGSize,
        sideBox: CGSize,
        aspect: CGFloat
    ) -> CGSize {
        let dist = abs(Double(index) - position)
        let closeness = CGFloat(max(0, 1 - dist))
        let eased = closeness * closeness * (3 - 2 * closeness)
        let outerScale = dist <= 1 ? 1.0 : CGFloat(max(0.74, 1.0 - (dist - 1.0) * 0.085))
        let box = CGSize(
            width: (sideBox.width * outerScale) + (centerBox.width - sideBox.width * outerScale) * eased,
            height: (sideBox.height * outerScale) + (centerBox.height - sideBox.height * outerScale) * eased
        )
        let safeAspect = max(aspect, 0.2)
        return box.width / box.height > safeAspect
            ? CGSize(width: box.height * safeAspect, height: box.height)
            : CGSize(width: box.width, height: box.width / safeAspect)
    }

    /// The size a picture of `pixels` gets to fit inside `limit` without growing.
    static func fittedSize(_ pixels: CGSize, in limit: CGSize) -> CGSize {
        guard pixels.width >= 1, pixels.height >= 1 else { return pixels }
        let factor = min(1, limit.width / pixels.width, limit.height / pixels.height)
        return CGSize(
            width: max(1, (pixels.width * factor).rounded()),
            height: max(1, (pixels.height * factor).rounded())
        )
    }

    /// A smaller copy of the picture that fits `limit`; the picture itself when it already fits.
    static func downscaled(_ image: CGImage, toFit limit: CGSize) -> CGImage {
        let size = fittedSize(CGSize(width: image.width, height: image.height), in: limit)
        guard Int(size.width) < image.width || Int(size.height) < image.height,
              let context = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height),
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }

    /// Excludes browser Picture-in-Picture mini-players and tiny utility panels that sometimes sit at layer 0.
    static func isExcludedMiniPlayer(title: String, size: CGSize?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "picture in picture" || trimmed == "picture-in-picture" {
            return true
        }
        if let size, (size.width < 120 || size.height < 80) {
            return true
        }
        return false
    }

    /// Checks whether a `CGEvent` key press matches a Carbon `HotkeyBinding`.
    static func matchesBinding(
        keyCode: Int64,
        flags: CGEventFlags,
        binding: HotkeyBinding?
    ) -> Bool {
        guard let binding, !binding.isCleared else { return false }
        guard keyCode == Int64(binding.keyCode) else { return false }
        let mods = Int(binding.modifiers)
        let wantCmd = (mods & cmdKey) != 0
        let wantOpt = (mods & optionKey) != 0
        let wantCtrl = (mods & controlKey) != 0
        let wantShift = (mods & shiftKey) != 0
        return flags.contains(.maskCommand) == wantCmd
            && flags.contains(.maskAlternate) == wantOpt
            && flags.contains(.maskControl) == wantCtrl
            && flags.contains(.maskShift) == wantShift
    }
}

// MARK: - Window Name Formatting

/// Extracts a clean window headline and context subtitle without repeating the app name.
nonisolated enum WindowFlowNameFormat {
    struct Label: Equatable {
        let headline: String
        let subtitle: String
        let isCurrentDesktop: Bool
    }

    private static let separators = [" — ", " – ", " - ", " · ", " | ", ": "]

    @MainActor
    static func makeLabel(for entry: WindowSwitcherEntry) -> Label {
        makeLabel(
            appName: entry.appName,
            title: entry.title,
            desktopNumber: entry.desktopNumber,
            isFullScreen: entry.isFullScreen,
            isOnCurrentDesktop: entry.isOnCurrentDesktop
        )
    }

    static func makeLabel(
        appName: String,
        title: String,
        desktopNumber: Int,
        isFullScreen: Bool,
        isOnCurrentDesktop: Bool
    ) -> Label {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = stripAppAffixes(from: raw, appName: app)

        let place: String
        if isFullScreen {
            place = "Full Screen"
        } else if isOnCurrentDesktop {
            place = "Desktop \(desktopNumber) · Current"
        } else {
            place = "Desktop \(desktopNumber)"
        }

        if cleaned.isEmpty || cleaned.caseInsensitiveCompare(app) == .orderedSame {
            return Label(headline: app, subtitle: place, isCurrentDesktop: isOnCurrentDesktop)
        }
        return Label(headline: cleaned, subtitle: "\(app)  ·  \(place)", isCurrentDesktop: isOnCurrentDesktop)
    }

    /// Removes trailing or leading `" — AppName"` suffixes that browsers and editors append to titles.
    private static func stripAppAffixes(from title: String, appName: String) -> String {
        guard !title.isEmpty, !appName.isEmpty else { return title }
        var current = title
        var didStrip = true
        while didStrip {
            didStrip = false
            for sep in separators {
                let suffix = sep + appName
                if current.count > suffix.count,
                   let range = current.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                    current = String(current[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    didStrip = true
                    break
                }
                let prefix = appName + sep
                if current.count > prefix.count,
                   let range = current.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                    current = String(current[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    didStrip = true
                    break
                }
            }
        }
        return current
    }
}

// MARK: - Item

private struct WindowFlowItem {
    var entry: WindowSwitcherEntry
    /// The window's frame in the strip view's coordinates, nil when it is on another display.
    var frameInView: CGRect?
    let fullPointWidth: CGFloat
    let aspect: CGFloat
    let icon: CGImage?

    var id: CGWindowID { entry.id }
}

// MARK: - Capture

private enum WindowFlowCapture {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// A window's picture without its shadow. `maxPixels` limits the size for strip cards.
    static func window(_ window: SCWindow, maxPixels: CGSize? = nil) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        var width = filter.contentRect.width * scale
        var height = filter.contentRect.height * scale
        guard width >= 1, height >= 1 else { return nil }
        if let maxPixels {
            let factor = min(1, maxPixels.width / width, maxPixels.height / height)
            width *= factor
            height *= factor
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(width.rounded()))
        configuration.height = max(1, Int(height.rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The whole display at full logical point size for crisp Glass blurring.
    static func display(_ display: SCDisplay) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, display.width)
        configuration.height = max(1, display.height)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The desktop far out of focus: what shows through the Glass backdrop.
    static func blurredDesktop(_ shot: CGImage) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: shot.width, height: shot.height)
        let blurred = CIImage(cgImage: shot)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 140])
            .cropped(to: extent)
        return context.createCGImage(blurred, from: extent)
    }
}

struct WindowFlowDecor {
    let image: CGImage
    let parallax: CGFloat
    let drift: CGFloat
}

struct WindowFlowBackdrop {
    let name: String
    /// Non-nil when the theme is rendered live at native 5K resolution by `WindowFlowMetalSkyLayer`.
    let skyMode: Int32?
    let image: CGImage?
    let decor: [WindowFlowDecor]
    let vignette: Float
}

enum WindowFlowTheme: String, CaseIterable {
    case azure
    case dusk
    case night
    case glass

    var next: WindowFlowTheme {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .azure }
        return all[(idx + 1) % all.count]
    }
}

/// Pre-compiled Metal sky shader pipeline plus the static glass sheen layer.
nonisolated struct WindowFlowArt: @unchecked Sendable {
    let pixels: CGSize
    let metalPipeline: WindowFlowMetalPipeline?
    let glassSurface: CGImage?

    init(pixels: CGSize, existingPipeline: WindowFlowMetalPipeline? = nil) {
        self.pixels = pixels
        self.metalPipeline = existingPipeline ?? WindowFlowMetalPipeline.build()
        self.glassSurface = WindowFlowBackdropArt.glassSurface()
    }
}

// MARK: - Workaround: Non-key shield panel and session event tap
// Cause: When a key window covers the screen during DockSpaceSwipe, macOS WindowServer briefly
//        detaches it or draws the incoming desktop above it, causing a single-frame flash.
// Context: Keep the Window Flow panel non-key at CGShieldingWindowLevel() and read navigation keys
//          through a session CGEvent tap while browsing, falling back to key status if tap fails.
private final class WindowFlowOverlayPanel: NSPanel {
    var allowKey = false
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        if allowKey { onResignKey?() }
    }
}

nonisolated private final class WindowFlowKeyTapContext: @unchecked Sendable {
    weak var owner: WindowFlowController?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func attach(tap: CFMachPort, runLoopSource: CFRunLoopSource?) {
        self.tap = tap
        self.runLoopSource = runLoopSource
    }

    func enableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }
}

// MARK: - Controller

@MainActor
final class WindowFlowController {
    var onVisibilityChanged: ((Bool) -> Void)?
    var onDidFocusWindow: (() -> Void)?
    var toggleBinding: (() -> HotkeyBinding?)?

    private static let themeDefaultsKey = "windowFlowTheme"
    private static let iconOverlayScrimDefaultsKey = "windowFlowIconOverlayScrim"
    private static let maxCachedThumbnails = 32

    private let spaceBar: SpaceBarController
    private let screenManager: ScreenManager
    private let usageTracker: WindowUsageTracker
    private var panel: WindowFlowOverlayPanel?
    private var stripView: WindowFlowView?
    private let keyTapContext = WindowFlowKeyTapContext()
    private var workspaceObserver: NSObjectProtocol?
    private var isOpening = false
    /// Bounded LRU cache of card previews shown immediately until fresh captures arrive.
    /// Kept between openings, so the pictures are stored at side-card size: at centre-card size
    /// one took up to 30 MB on a 5K-wide display.
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var thumbnailAccessedAt: [CGWindowID: Date] = [:]
    /// Per-space wallpapers held only while Window Flow is open (freed in `close()`).
    private var sessionWallpapers: [UInt64: CGImage] = [:]
    /// Resolved Accessibility titles cached across openings.
    private var titleCache: [CGWindowID: String] = [:]
    /// When Screen Recording is off, `B` cycles the live Sky themes plus translucent `Overlay`.
    private var iconModeUseOverlayScrim: Bool {
        didSet { UserDefaults.standard.set(iconModeUseOverlayScrim, forKey: Self.iconOverlayScrimDefaultsKey) }
    }
    private var theme: WindowFlowTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeDefaultsKey) }
    }
    private var art: WindowFlowArt?
    /// Points the sliding backdrop layers reach beyond the screen on every side.
    static let decorMargin: CGFloat = 56

    init(spaceBar: SpaceBarController, screenManager: ScreenManager, usageTracker: WindowUsageTracker) {
        self.spaceBar = spaceBar
        self.screenManager = screenManager
        self.usageTracker = usageTracker
        let savedTheme = UserDefaults.standard.string(forKey: Self.themeDefaultsKey)
            .flatMap(WindowFlowTheme.init(rawValue:)) ?? .azure
        self.theme = savedTheme
        self.iconModeUseOverlayScrim = UserDefaults.standard.bool(forKey: Self.iconOverlayScrimDefaultsKey)
        if let screen = NSScreen.main {
            let pixels = Self.artPixels(for: screen)
            Task.detached(priority: .utility) { [weak self] in
                let art = WindowFlowArt(pixels: pixels)
                await self?.store(art)
            }
        }
    }

    deinit {
        keyTapContext.removeTap()
    }

    private func store(_ art: WindowFlowArt) {
        if self.art == nil { self.art = art }
    }

    /// Pixels of a side card on that screen: all a cached picture has to fill until a fresh one arrives.
    private static func cachePixelLimit(for screen: NSScreen) -> CGSize {
        CGSize(
            width: screen.frame.width * 0.20 * screen.backingScaleFactor,
            height: screen.frame.height * 0.27 * screen.backingScaleFactor
        )
    }

    /// Scales the picture down for the cache off the main thread, then stores it.
    private func cacheThumbnail(_ image: CGImage, for windowID: CGWindowID, limit: CGSize) {
        Task { [weak self] in
            let small = await Task.detached(priority: .utility) {
                WindowFlowLayout.downscaled(image, toFit: limit)
            }.value
            self?.storeThumbnail(small, for: windowID)
        }
    }

    private func storeThumbnail(_ image: CGImage, for windowID: CGWindowID) {
        thumbnails[windowID] = image
        thumbnailAccessedAt[windowID] = Date()
        if thumbnails.count > Self.maxCachedThumbnails {
            let sorted = thumbnailAccessedAt.sorted { $0.value < $1.value }
            for (evictID, _) in sorted.prefix(thumbnails.count - Self.maxCachedThumbnails) {
                thumbnails.removeValue(forKey: evictID)
                thumbnailAccessedAt.removeValue(forKey: evictID)
            }
        }
    }

    private static func artPixels(for screen: NSScreen) -> CGSize {
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    private func backdrop(_ theme: WindowFlowTheme, art: WindowFlowArt, shot: CGImage?) -> WindowFlowBackdrop {
        switch theme {
        case .azure:
            return WindowFlowBackdrop(name: "Sky · Azure", skyMode: 0, image: nil, decor: [], vignette: 0.18)
        case .dusk:
            return WindowFlowBackdrop(name: "Sky · Dusk", skyMode: 1, image: nil, decor: [], vignette: 0.22)
        case .night:
            return WindowFlowBackdrop(name: "Sky · Night", skyMode: 2, image: nil, decor: [], vignette: 0.26)
        case .glass:
            let glass = shot.flatMap(WindowFlowCapture.blurredDesktop).flatMap { WindowFlowBackdropArt.glass(size: art.pixels, blurred: $0) }
            let surface = art.glassSurface.map { [WindowFlowDecor(image: $0, parallax: -18, drift: 5)] } ?? []
            return WindowFlowBackdrop(name: "Glass", skyMode: nil, image: glass, decor: surface, vignette: 0.34)
        }
    }

    func toggle() {
        if let stripView {
            stripView.cancel()
            return
        }
        guard !isOpening else { return }
        isOpening = true
        Task {
            await open()
            isOpening = false
        }
    }

    private func open() async {
        let started = Date()
        let rawEntries = spaceBar.switcherWindows()
        guard !rawEntries.isEmpty else { return }
        let bounds = Self.windowBounds()
        let entries = rawEntries.filter { entry in
            !WindowFlowLayout.isExcludedMiniPlayer(title: entry.title, size: bounds[entry.id]?.size)
        }
        guard !entries.isEmpty else { return }

        // The window with the keyboard is the one the shortcut was pressed in. The window list is
        // front to back but puts floating and always-on-top windows first, so it is only the fallback.
        let focusedID = spaceBar.frontmostWindowID()
        let heroPosition = entries.firstIndex { $0.id == focusedID && $0.isOnCurrentDesktop }
            ?? entries.firstIndex { $0.isOnCurrentDesktop && !$0.isFullScreen }
        let heroID = heroPosition.map { entries[$0].id }
        debugLog("WindowFlow", "Focused window \(focusedID.map(String.init) ?? "unknown"), starting from \(heroPosition.map { entries[$0].appName } ?? "nothing")")

        let heroFrame = heroID.flatMap { bounds[$0] }
            .map { screenManager.convertFromCGCoordinates(frame: $0) }
        let screen = heroFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }

        // Window Flow belongs to one display: windows of other displays are neither shown nor touched
        let displayID = screenManager.displayIdentifier(for: screen)
        var ordered = displayID.isEmpty ? entries : entries.filter { $0.displayID == displayID }
        guard !ordered.isEmpty else { return }

        // Smart order: current window at 0, previous genuine window at 1, frequent/recent windows at 2+
        let allOpenIDs = Set(entries.map(\.id))
        let currentHeroID = heroID.flatMap { id in ordered.contains(where: { $0.id == id }) ? id : nil }
        ordered = usageTracker.order(ordered, allOpenWindowIDs: allOpenIDs, currentWindowID: currentHeroID)
        let hasHeroEntry = currentHeroID != nil && ordered.first?.id == currentHeroID
        debugLog("WindowFlow", "\(ordered.count) of \(entries.count) windows are on this display")

        var hasLivePreviews = CGPreflightScreenCaptureAccess()

        // Never call ScreenCaptureKit unless Screen Recording is already granted, so opening
        // the icon overlay never triggers an unsolicited macOS permission popup.
        var shareable: [CGWindowID: SCWindow] = [:]
        var display: SCDisplay?
        var wallpaperBySpace: [UInt64: SCWindow] = [:]
        var fallbackWallpaper: SCWindow?
        if hasLivePreviews {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                shareable = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                let displayNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                display = content.displays.first { $0.displayID == displayNumber }

                // Map WindowManager's per-space Wallpaper windows on this display so cross-desktop exits
                // can dissolve the sky into the exact target desktop BEFORE switching spaces.
                for scWin in content.windows where scWin.windowLayer < 0 && scWin.frame.width >= screen.frame.width * 0.8 {
                    let bundle = scWin.owningApplication?.bundleIdentifier ?? ""
                    guard scWin.title == "Wallpaper" || bundle == "com.apple.WindowManager" else { continue }
                    let appKitRect = screenManager.convertFromCGCoordinates(frame: scWin.frame)
                    guard screen.frame.contains(CGPoint(x: appKitRect.midX, y: appKitRect.midY)) else { continue }
                    if fallbackWallpaper == nil { fallbackWallpaper = scWin }
                    for sid in spaceBar.windowSpaceIDs(scWin.windowID) {
                        wallpaperBySpace[sid] = scWin
                    }
                }
            } else {
                debugLog("WindowFlow", "Could not read shareable content, falling back to icon overlay")
                hasLivePreviews = false
            }
        }
        let wallpaperPixelLimit = CGSize(
            width: min(5120, screen.frame.width * screen.backingScaleFactor),
            height: min(2880, screen.frame.height * screen.backingScaleFactor)
        )

        let iconPixels: CGFloat = hasLivePreviews ? 128 : 512
        var icons: [pid_t: CGImage] = [:]
        let items: [WindowFlowItem] = ordered.map { rawEntry in
            var entry = rawEntry
            // Prefer cached Accessibility title or ScreenCaptureKit's own window title when CGWindowList lacked one
            if entry.lacksListedTitle {
                if let cachedTitle = titleCache[entry.id], !cachedTitle.isEmpty {
                    entry.resolvedTitle = cachedTitle
                } else if let scTitle = shareable[entry.id]?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !scTitle.isEmpty, scTitle != entry.appName {
                    entry.resolvedTitle = scTitle
                }
            }
            let cgFrame = bounds[entry.id]
            let appKitFrame = cgFrame.map { screenManager.convertFromCGCoordinates(frame: $0) }
            let isOnThisScreen = appKitFrame.map { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            let frameInView = isOnThisScreen ? appKitFrame?.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) : nil
            let pid = entry.window.pid
            if icons[pid] == nil {
                var rect = CGRect(x: 0, y: 0, width: iconPixels, height: iconPixels)
                icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon?
                    .cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            let widthPoints = max(cgFrame?.width ?? 900, 120)
            let aspect = cgFrame.map { $0.width / max($0.height, 1) } ?? 1.6
            return WindowFlowItem(
                entry: entry,
                frameInView: frameInView,
                fullPointWidth: widthPoints,
                aspect: aspect,
                icon: icons[pid]
            )
        }

        let openIDs = Set(items.map(\.id))
        thumbnails = thumbnails.filter { openIDs.contains($0.key) }
        thumbnailAccessedAt = thumbnailAccessedAt.filter { openIDs.contains($0.key) }
        titleCache = titleCache.filter { openIDs.contains($0.key) }

        var heroImage: CGImage?
        var screenShot: CGImage?
        var preloaded: [(CGWindowID, CGImage)] = []
        let needDisplayNow = hasLivePreviews && (theme == .glass)
        if hasLivePreviews {
            // Pre-capture the visible neighbour cards alongside the hero window before showing the panel,
            // so side cards never appear as dark placeholder boxes and flash bright 50 ms later.
            let approxCenterBox = CGSize(
                width: screen.frame.width * 0.52 * screen.backingScaleFactor,
                height: screen.frame.height * 0.58 * screen.backingScaleFactor
            )
            let heroWindow = hasHeroEntry ? shareable[items[0].id] : nil
            let capturedDisplay = display
            let preloadWindows: [(CGWindowID, SCWindow)] = items.dropFirst().prefix(3)
                .map(\.id)
                .filter { thumbnails[$0] == nil }
                .compactMap { id in shareable[id].map { (id, $0) } }

            async let heroShot: CGImage? = {
                guard let heroWindow else { return nil }
                return await WindowFlowCapture.window(heroWindow)
            }()
            async let displayShot: CGImage? = {
                guard needDisplayNow, let capturedDisplay else { return nil }
                return await WindowFlowCapture.display(capturedDisplay)
            }()
            async let preloadedNeighbors: [(CGWindowID, CGImage)] = withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for (id, win) in preloadWindows {
                    group.addTask { (id, await WindowFlowCapture.window(win, maxPixels: approxCenterBox)) }
                }
                var loaded: [(CGWindowID, CGImage)] = []
                for await (id, img) in group {
                    if let img { loaded.append((id, img)) }
                }
                return loaded
            }

            let (capturedHero, initialScreenShot, neighborShots) = await (heroShot, displayShot, preloadedNeighbors)
            heroImage = capturedHero
            screenShot = initialScreenShot
            preloaded = neighborShots
        }
        let cacheLimit = Self.cachePixelLimit(for: screen)

        let pixels = Self.artPixels(for: screen)
        if art?.pixels != pixels {
            art = WindowFlowArt(pixels: pixels, existingPipeline: art?.metalPipeline)
        }
        guard let art else { return }
        let overlayBackdrop = WindowFlowBackdrop(name: "Overlay", skyMode: nil, image: nil, decor: [], vignette: 0.44)
        let backdrop: WindowFlowBackdrop
        if hasLivePreviews {
            backdrop = self.backdrop(theme, art: art, shot: screenShot)
        } else if iconModeUseOverlayScrim {
            backdrop = overlayBackdrop
        } else {
            let skyTheme: WindowFlowTheme = (theme == .glass) ? .azure : theme
            backdrop = self.backdrop(skyTheme, art: art, shot: nil)
        }
        guard stripView == nil else { return }

        // Keep full 3D depth and micro-motion active even when macOS "Reduce motion" is turned on
        // solely to disable slow Mission Control desktop slides.
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let view = WindowFlowView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            items: items,
            hasHero: hasLivePreviews && hasHeroEntry && heroImage != nil && items[0].frameInView != nil,
            showsLivePreviews: hasLivePreviews,
            backingScale: screen.backingScaleFactor,
            menuBarHeight: menuBarHeight,
            metalPipeline: art.metalPipeline
        )
        if hasLivePreviews {
            view.nextBackdrop = { [weak self] in
                guard let self else { return nil }
                self.theme = self.theme.next
                return self.backdrop(self.theme, art: art, shot: screenShot)
            }
            for item in items {
                if let cached = thumbnails[item.id] {
                    thumbnailAccessedAt[item.id] = Date()
                    view.setImage(cached, for: item.id, animated: false)
                }
            }
            for (id, image) in preloaded {
                view.setImage(image, for: id, animated: false)
                cacheThumbnail(image, for: id, limit: cacheLimit)
            }
            if let heroImage { view.setImage(heroImage, for: items[0].id, animated: false) }
        } else {
            view.nextBackdrop = { [weak self] in
                guard let self else { return nil }
                if self.iconModeUseOverlayScrim {
                    self.iconModeUseOverlayScrim = false
                    self.theme = .azure
                    return self.backdrop(self.theme, art: art, shot: nil)
                }
                switch self.theme {
                case .azure:
                    self.theme = .dusk
                    return self.backdrop(self.theme, art: art, shot: nil)
                case .dusk:
                    self.theme = .night
                    return self.backdrop(self.theme, art: art, shot: nil)
                case .night, .glass:
                    self.iconModeUseOverlayScrim = true
                    return overlayBackdrop
                }
            }
        }

        view.currentFrame = { [weak self] windowID in
            guard let self, let cgFrame = Self.windowBounds()[windowID] else { return nil }
            let frame = self.screenManager.convertFromCGCoordinates(frame: cgFrame)
            guard screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        }
        if hasLivePreviews {
            view.captureFull = { windowID in
                guard let window = shareable[windowID] else { return nil }
                return await WindowFlowCapture.window(window)
            }
            view.fetchTargetWallpaper = { [weak self] spaceID in
                if let cached = self?.sessionWallpapers[spaceID] {
                    return cached
                }
                if let scWall = wallpaperBySpace[spaceID] ?? fallbackWallpaper,
                   let shot = await WindowFlowCapture.window(scWall, maxPixels: wallpaperPixelLimit) {
                    self?.sessionWallpapers[spaceID] = shot
                    return shot
                }
                if let url = NSWorkspace.shared.desktopImageURL(for: screen),
                   let nsImg = NSImage(contentsOf: url),
                   let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self?.sessionWallpapers[spaceID] = cgImg
                    return cgImg
                }
                return nil
            }
        }
        view.focus = { [weak self] item, done in
            self?.usageTracker.recordExplicitSelection(item.id)
            self?.spaceBar.focusWindow(
                item.entry.window,
                on: item.entry.spaceID,
                displayID: item.entry.displayID,
                fastSettle: true
            ) { [weak self] in
                self?.onDidFocusWindow?()
                done()
            }
        }
        view.isSpaceCurrent = { [weak self] item in
            self?.spaceBar.isCurrentSpace(item.entry.spaceID, on: item.entry.displayID) ?? true
        }
        view.spaceWindowOrder = { [weak self] spaceID in
            self?.spaceBar.orderedWindowIDs(on: spaceID) ?? []
        }
        view.onOpenScreenRecordingSettings = { [weak self] in
            guard let self else { return }
            self.close()
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        view.onCommitBegan = { [weak self] in self?.stopBrowsingInput() }
        view.onFinished = { [weak self] in self?.close() }

        let panel = makePanel(on: screen)
        panel.contentView = view
        panel.onKeyDown = { [weak view] event in view?.handleKey(event) ?? false }
        panel.onResignKey = { [weak view] in view?.cancelIfBrowsing() }
        self.panel = panel
        self.stripView = view
        onVisibilityChanged?(true)
        view.setBackdrop(backdrop)
        view.start()
        // MARK: - Workaround: Secure Input
        // Cause: While another app holds Secure Input (a password field, a terminal's Secure Keyboard
        //        Entry) event taps get no keyboard events, yet the shortcut still opens Window Flow.
        // Context: The keys would go to the app underneath, so take the keyboard as a key window then.
        if !IsSecureEventInputEnabled(), startKeyTap() {
            panel.allowKey = false
            panel.orderFrontRegardless()
            installBrowsingActivationObserver()
        } else {
            panel.allowKey = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }
        debugLog("WindowFlow", "Opened \(hasLivePreviews ? "live" : "icon overlay") with \(items.count) windows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // Resolve any missing window titles through Accessibility in parallel
        let untitled = items.map(\.entry).filter { $0.lacksListedTitle && $0.resolvedTitle == nil }
        if !untitled.isEmpty {
            let windowsByPID = Dictionary(grouping: untitled, by: \.window.pid).mapValues { Set($0.map(\.id)) }
            Task { [weak self, weak view] in
                let resolved = await Task.detached(priority: .userInitiated) {
                    WindowTitleResolver.titles(for: windowsByPID)
                }.value
                guard !resolved.isEmpty, let self else { return }
                self.titleCache.merge(resolved) { _, new in new }
                view?.applyResolvedTitles(resolved)
            }
        }

        guard hasLivePreviews else { return }

        // Capture desktop in the background if we opened on a Sky theme, so pressing B for Glass is instant
        if !needDisplayNow, let display {
            Task {
                if let captured = await WindowFlowCapture.display(display) {
                    screenShot = captured
                }
            }
        }

        // Pre-warm target desktop wallpapers in the background while browsing (freed in `close()`)
        let otherSpaceIDs = Array(Set(items.filter { !$0.entry.isOnCurrentDesktop && !$0.entry.isFullScreen }.map(\.entry.spaceID)))
        if !otherSpaceIDs.isEmpty {
            Task { [weak self, weak view] in
                for sid in otherSpaceIDs {
                    guard self?.stripView === view, view != nil else { return }
                    if self?.sessionWallpapers[sid] == nil,
                       let scWall = wallpaperBySpace[sid] ?? fallbackWallpaper,
                       let shot = await WindowFlowCapture.window(scWall, maxPixels: wallpaperPixelLimit) {
                        self?.sessionWallpapers[sid] = shot
                    }
                }
            }
        }

        let cardPixels = view.cardPixelLimit
        for item in items where !(view.hasHero && item.id == items[0].id) {
            guard let window = shareable[item.id] else { continue }
            Task { [weak self, weak view] in
                guard let image = await WindowFlowCapture.window(window, maxPixels: cardPixels) else { return }
                self?.cacheThumbnail(image, for: item.id, limit: cacheLimit)
                view?.setImage(image, for: item.id, animated: true)
            }
        }
    }

    private func stopBrowsingInput() {
        keyTapContext.removeTap()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    private func startKeyTap() -> Bool {
        keyTapContext.removeTap()
        keyTapContext.owner = self
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<WindowFlowKeyTapContext>.fromOpaque(userInfo).takeUnretainedValue()
                guard let owner = context.owner else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated { owner.handleTappedKey(type, event) }
            },
            userInfo: Unmanaged.passUnretained(keyTapContext).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        keyTapContext.attach(tap: tap, runLoopSource: source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleTappedKey(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            keyTapContext.enableTap()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, let stripView else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // Let the user's Window Flow toggle shortcut and Cmd-chords (e.g. Cmd+Tab) reach the system
        if WindowFlowLayout.matchesBinding(keyCode: keyCode, flags: flags, binding: toggleBinding?()) {
            return Unmanaged.passUnretained(event)
        }
        if flags.contains(.maskCommand) {
            return Unmanaged.passUnretained(event)
        }
        if let nsEvent = NSEvent(cgEvent: event) {
            _ = stripView.handleKey(nsEvent)
        }
        return nil
    }

    private func installBrowsingActivationObserver() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stripView?.cancelIfBrowsing()
            }
        }
    }

    private func close() {
        stopBrowsingInput()
        stripView?.stop()
        sessionWallpapers.removeAll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        stripView = nil
        onVisibilityChanged?(false)
    }

    private func makePanel(on screen: NSScreen) -> WindowFlowOverlayPanel {
        let panel = WindowFlowOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.setFrame(screen.frame, display: false)
        return panel
    }

    /// Frames of every window in Core Graphics coordinates.
    private static func windowBounds() -> [CGWindowID: CGRect] {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: CGRect] = [:]
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            result[id] = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
        return result
    }
}

// MARK: - Card Layer

private final class WindowFlowCard {
    var item: WindowFlowItem
    let isIconOnly: Bool
    private let backingScale: CGFloat
    /// Outer layer carrying GPU 3D transform and drop shadow (`masksToBounds = false`).
    let layer = CALayer()
    /// Masked container (`cornerCurve = .continuous`) so shade, sheen and rim never bleed past rounded corners.
    let clipLayer = CALayer()
    let pictureLayer = CALayer()
    /// Sculpted dark-glass background + soft halo + centered icon + title caption used when Screen Recording is off.
    private let cardGradientLayer = CAGradientLayer()
    private let iconGlowLayer = CAGradientLayer()
    private let centerIconLayer = CALayer()
    private let cardLabelLayer = CALayer()
    /// Specular diagonal sheen responding softly to 3D card tilt.
    let sheenLayer = CAGradientLayer()
    /// Darkens a card that is turned away from the viewer.
    let shade = CALayer()
    /// Crisp 1pt hairline border so dark-mode windows stay defined against dark backdrops.
    let rimLayer = CALayer()
    /// Stage-Manager-style corner app badge shown on side cards, melting away in the centre slot.
    let sideBadge = CALayer()

    var frame = CGRect.zero
    var hasImage = false
    var hover = WindowFlowSpring(0, stiffness: 340, damping: 28)
    private var measuredBaseCorner: CGFloat?

    /// Fallback window corner radius in screen points before an image is measured.
    private static let fallbackCornerPoints: CGFloat = 13

    var baseSize = CGSize(width: 1, height: 1) {
        didSet {
            let rect = CGRect(origin: .zero, size: baseSize)
            layer.bounds = rect
            clipLayer.frame = rect
            pictureLayer.frame = rect
            if isIconOnly {
                cardGradientLayer.frame = rect
                iconGlowLayer.frame = rect
                let iconDim = min(baseSize.width * 0.42, baseSize.height * 0.46)
                let iconY = (baseSize.height - iconDim) * 0.5 + baseSize.height * 0.075
                centerIconLayer.frame = CGRect(
                    x: (baseSize.width - iconDim) * 0.5,
                    y: iconY,
                    width: iconDim,
                    height: iconDim
                )
                let padX = max(20, baseSize.width * 0.065)
                let labelHeight: CGFloat = 26
                let labelY = max(18, iconY - labelHeight - 16)
                cardLabelLayer.frame = CGRect(
                    x: padX,
                    y: labelY,
                    width: max(20, baseSize.width - padX * 2),
                    height: labelHeight
                )
                updateCardLabel()
            }
            sheenLayer.frame = rect
            shade.frame = rect
            rimLayer.frame = rect
            updateShadowPath()
        }
    }

    var baseCornerRadius: CGFloat {
        if isIconOnly { return 24 }
        if let measuredBaseCorner { return measuredBaseCorner }
        let ratio = baseSize.width / max(item.fullPointWidth, 1)
        return max(8, Self.fallbackCornerPoints * ratio)
    }

    /// Renders the centered single-line card title directly with CoreText (`CTLineCreateTruncatedLine`)
    /// into a Retina image so long titles truncate cleanly with `…` and never clip vertically.
    func updateCardLabel() {
        guard isIconOnly else { return }
        let size = cardLabelLayer.bounds.size
        guard size.width >= 20, size.height >= 12 else { return }
        let label = WindowFlowNameFormat.makeLabel(for: item.entry)
        cardLabelLayer.contents = Self.renderTruncatedCenteredText(
            label.headline,
            in: size,
            scale: backingScale,
            font: NSFont.systemFont(ofSize: 14.5, weight: .medium),
            color: NSColor(white: 1, alpha: 0.90)
        )
    }

    private static func renderTruncatedCenteredText(
        _ text: String,
        in size: CGSize,
        scale: CGFloat,
        font: NSFont,
        color: NSColor
    ) -> CGImage? {
        let pxW = max(1, Int(ceil(size.width * scale)))
        let pxH = max(1, Int(ceil(size.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pxW,
                  height: pxH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let fullWidth = CGFloat(CTLineGetTypographicBounds(fullLine, &ascent, &descent, &leading))
        let line: CTLine
        if fullWidth > size.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            line = CTLineCreateTruncatedLine(fullLine, Double(size.width), .end, ellipsis) ?? fullLine
        } else {
            line = fullLine
        }
        ascent = 0
        descent = 0
        leading = 0
        let drawWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = max(0, floor((size.width - drawWidth) * 0.5))
        let y = floor((size.height - (ascent + descent)) * 0.5 + descent)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    func updateCorner(from image: CGImage) {
        let measuredPixels = Self.measureCornerPixels(in: image)
        let scaleToBase = baseSize.width / CGFloat(max(image.width, 1))
        measuredBaseCorner = measuredPixels * scaleToBase
        updateShadowPath()
    }

    private func updateShadowPath() {
        let rect = CGRect(origin: .zero, size: baseSize)
        let corner = min(baseCornerRadius, min(rect.width, rect.height) / 2)
        layer.shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil
        )
    }

    /// Reads a tiny 48x48 corner of the captured window image once to match its real corner radius.
    private static func measureCornerPixels(in image: CGImage) -> CGFloat {
        let sample = min(48, image.width / 2, image.height / 2)
        guard sample >= 4,
              let tile = image.cropping(to: CGRect(x: 0, y: 0, width: sample, height: sample)) else {
            return 24
        }
        var rgba = [UInt8](repeating: 0, count: sample * sample * 4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: sample,
                height: sample,
                bitsPerComponent: 8,
                bytesPerRow: sample * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: sample, height: sample))
            return true
        }
        guard ok else { return 24 }
        // Check that interior pixel is opaque enough to trust the corner alpha profile
        let innerAlpha = rgba[((sample - 1) * sample + (sample - 1)) * 4 + 3]
        guard innerAlpha >= 180 else { return 24 }
        for k in 0..<sample {
            let alpha = rgba[(k * sample + k) * 4 + 3]
            if alpha >= 128 {
                if k == 0 { return 0 }
                // Along the 45-degree diagonal of a continuous corner, boundary sits at ~0.28 * R
                return CGFloat(k) / 0.28
            }
        }
        return 24
    }

    init(item: WindowFlowItem, backingScale: CGFloat, isIconOnly: Bool = false) {
        self.item = item
        self.isIconOnly = isIconOnly
        self.backingScale = backingScale
        layer.contentsScale = backingScale
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.46
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: -10)

        clipLayer.masksToBounds = true
        clipLayer.cornerCurve = .continuous
        clipLayer.contentsScale = backingScale

        pictureLayer.contentsGravity = .resize
        pictureLayer.minificationFilter = .trilinear
        pictureLayer.magnificationFilter = .linear
        pictureLayer.backgroundColor = isIconOnly
            ? nil
            : NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1).cgColor
        pictureLayer.contentsScale = backingScale

        sheenLayer.colors = [
            NSColor(white: 1, alpha: 0).cgColor,
            NSColor(white: 1, alpha: 0.04).cgColor,
            NSColor(white: 1, alpha: 0.16).cgColor,
            NSColor(white: 1, alpha: 0.04).cgColor,
            NSColor(white: 1, alpha: 0).cgColor
        ]
        sheenLayer.locations = [0.0, 0.35, 0.5, 0.65, 1.0]
        sheenLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        sheenLayer.endPoint = CGPoint(x: 1.0, y: 0.0)
        sheenLayer.opacity = 0

        shade.backgroundColor = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.06, alpha: 1).cgColor
        shade.opacity = 0

        rimLayer.cornerCurve = .continuous
        rimLayer.borderColor = NSColor(white: 1, alpha: 1).cgColor
        rimLayer.opacity = 0

        if isIconOnly {
            cardGradientLayer.colors = [
                NSColor(srgbRed: 0.14, green: 0.17, blue: 0.25, alpha: 0.90).cgColor,
                NSColor(srgbRed: 0.07, green: 0.09, blue: 0.14, alpha: 0.94).cgColor
            ]
            cardGradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
            cardGradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
            clipLayer.addSublayer(cardGradientLayer)

            iconGlowLayer.type = .radial
            iconGlowLayer.colors = [
                NSColor(white: 1, alpha: 0.12).cgColor,
                NSColor(white: 1, alpha: 0.03).cgColor,
                NSColor(white: 1, alpha: 0.0).cgColor
            ]
            iconGlowLayer.locations = [0.0, 0.45, 1.0]
            iconGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.56)
            iconGlowLayer.endPoint = CGPoint(x: 1.05, y: 1.12)
            clipLayer.addSublayer(iconGlowLayer)

            centerIconLayer.contents = item.icon
            centerIconLayer.contentsGravity = .resizeAspect
            centerIconLayer.minificationFilter = .trilinear
            centerIconLayer.magnificationFilter = .linear
            centerIconLayer.contentsScale = backingScale
            centerIconLayer.shadowColor = NSColor.black.cgColor
            centerIconLayer.shadowOpacity = 0.45
            centerIconLayer.shadowRadius = 14
            centerIconLayer.shadowOffset = CGSize(width: 0, height: -6)
            clipLayer.addSublayer(centerIconLayer)

            cardLabelLayer.contentsScale = backingScale
            cardLabelLayer.contentsGravity = .resize
            cardLabelLayer.minificationFilter = .trilinear
            cardLabelLayer.magnificationFilter = .linear
            clipLayer.addSublayer(cardLabelLayer)
            updateCardLabel()
        } else {
            clipLayer.addSublayer(pictureLayer)
        }
        clipLayer.addSublayer(sheenLayer)
        clipLayer.addSublayer(shade)
        clipLayer.addSublayer(rimLayer)
        layer.addSublayer(clipLayer)

        sideBadge.contents = item.icon
        sideBadge.contentsGravity = .resizeAspect
        sideBadge.minificationFilter = .trilinear
        sideBadge.contentsScale = backingScale
        sideBadge.shadowColor = NSColor.black.cgColor
        sideBadge.shadowOpacity = 0.52
        sideBadge.shadowRadius = 7
        sideBadge.shadowOffset = CGSize(width: 0, height: -3)
        sideBadge.opacity = 0
        sideBadge.isHidden = isIconOnly
        layer.addSublayer(sideBadge)
    }
}

// MARK: - Sculpted Glass Title HUD & Page Dots

private final class WindowFlowTitleHUD {
    let container = CALayer()
    private let pill = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let content = CALayer()
    private let iconLayer = CALayer()
    private let headlineLayer = CATextLayer()
    private let subtitleLayer = CATextLayer()
    private let desktopDot = CALayer()

    private var widthSpring = WindowFlowSpring(280, stiffness: 320, damping: 30)
    private let height: CGFloat = 52
    private let cornerRadius: CGFloat = 16
    private var currentLabel: WindowFlowNameFormat.Label?
    private var measuredWidth: CGFloat = 280

    init(backingScale: CGFloat) {
        container.zPosition = 60
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.44
        container.shadowRadius = 18
        container.shadowOffset = CGSize(width: 0, height: -6)

        pill.cornerRadius = cornerRadius
        pill.cornerCurve = .continuous
        pill.colors = [
            NSColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.78).cgColor,
            NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 0.86).cgColor
        ]
        pill.startPoint = CGPoint(x: 0.5, y: 1.0)
        pill.endPoint = CGPoint(x: 0.5, y: 0.0)
        container.addSublayer(pill)

        rim.cornerRadius = cornerRadius
        rim.cornerCurve = .continuous
        rim.colors = [
            NSColor(white: 1, alpha: 0.28).cgColor,
            NSColor(white: 1, alpha: 0.07).cgColor
        ]
        rim.startPoint = CGPoint(x: 0.5, y: 1.0)
        rim.endPoint = CGPoint(x: 0.5, y: 0.0)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1
        rim.mask = rimMask
        container.addSublayer(rim)

        iconLayer.contentsGravity = .resizeAspect
        iconLayer.minificationFilter = .trilinear
        iconLayer.contentsScale = backingScale
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOpacity = 0.32
        iconLayer.shadowRadius = 4
        iconLayer.shadowOffset = CGSize(width: 0, height: -1.5)
        content.addSublayer(iconLayer)

        headlineLayer.contentsScale = backingScale
        headlineLayer.alignmentMode = .left
        headlineLayer.truncationMode = .end
        content.addSublayer(headlineLayer)

        desktopDot.cornerRadius = 3
        desktopDot.backgroundColor = NSColor.controlAccentColor.cgColor
        content.addSublayer(desktopDot)

        subtitleLayer.contentsScale = backingScale
        subtitleLayer.alignmentMode = .left
        subtitleLayer.truncationMode = .end
        content.addSublayer(subtitleLayer)

        container.addSublayer(content)
    }

    func updateItem(_ item: WindowFlowItem, maxWidth: CGFloat, jumpWidth: Bool) {
        let label = WindowFlowNameFormat.makeLabel(for: item.entry)
        iconLayer.contents = item.icon

        if label != currentLabel {
            currentLabel = label
            let headFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let subFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let truncStyle = NSMutableParagraphStyle()
            truncStyle.lineBreakMode = .byTruncatingTail

            let headAttr = NSAttributedString(
                string: label.headline,
                attributes: [
                    .font: headFont,
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: truncStyle
                ]
            )
            let subAttr = NSAttributedString(
                string: label.subtitle,
                attributes: [
                    .font: subFont,
                    .foregroundColor: NSColor(white: 1, alpha: 0.66),
                    .paragraphStyle: truncStyle
                ]
            )
            headlineLayer.string = headAttr
            subtitleLayer.string = subAttr
            desktopDot.isHidden = !label.isCurrentDesktop

            let dotExtra: CGFloat = label.isCurrentDesktop ? 11 : 0
            let textWidth = max(ceil(headAttr.size().width), ceil(subAttr.size().width) + dotExtra)
            let hasIcon = item.icon != nil
            let leading: CGFloat = hasIcon ? 54 : 18
            let ideal = leading + textWidth + 20
            measuredWidth = min(max(ideal, 156), maxWidth)
            if jumpWidth {
                widthSpring.jump(to: Double(measuredWidth))
            } else {
                widthSpring.target = Double(measuredWidth)
            }
        } else {
            widthSpring.target = Double(min(measuredWidth, maxWidth))
        }
    }

    func step(_ dt: Double) {
        widthSpring.step(dt)
    }

    func layout(centerX: CGFloat, topY: CGFloat, alpha: Float, scrollDip: CGFloat) {
        let w = CGFloat(widthSpring.value)
        let rect = CGRect(x: round(centerX - w / 2), y: round(topY - height), width: round(w), height: height)
        container.frame = rect
        container.opacity = alpha

        let local = CGRect(origin: .zero, size: rect.size)
        pill.frame = local
        rim.frame = local
        let path = CGPath(roundedRect: local.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        rimMask.path = path
        container.shadowPath = path

        content.bounds = local
        content.position = CGPoint(x: local.midX, y: local.midY)
        let contentFade = Float(1 - 0.42 * scrollDip)
        content.opacity = contentFade
        let contentScale = 1 - 0.018 * scrollDip
        content.transform = CATransform3DMakeScale(contentScale, contentScale, 1)

        let hasIcon = iconLayer.contents != nil
        iconLayer.isHidden = !hasIcon
        let textX: CGFloat
        if hasIcon {
            iconLayer.frame = CGRect(x: 11, y: (height - 34) / 2, width: 34, height: 34)
            textX = 53
        } else {
            textX = 18
        }
        let availWidth = max(40, local.width - textX - 16)
        headlineLayer.frame = CGRect(x: textX, y: 24, width: availWidth, height: 21)

        if desktopDot.isHidden {
            subtitleLayer.frame = CGRect(x: textX, y: 8, width: availWidth, height: 16)
        } else {
            desktopDot.frame = CGRect(x: textX, y: 13.5, width: 6, height: 6)
            subtitleLayer.frame = CGRect(x: textX + 11, y: 8, width: max(28, availWidth - 11), height: 16)
        }
    }
}

// MARK: - Screen Recording Hint Banner

/// Sculpted glass capsule shown when Screen Recording is turned off, explaining how to enable
/// live window previews (optional, never saves or uploads) with a one-click Settings button.
private final class WindowFlowPermissionBanner {
    let container = CALayer()
    private let pill = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let iconLayer = CALayer()
    private let messageLayer = CATextLayer()
    private let buttonBg = CALayer()
    private let buttonLabel = CATextLayer()

    private let height: CGFloat = 40
    private let cornerRadius: CGFloat = 20
    private let messageWidth: CGFloat
    private let buttonWidth: CGFloat
    private let totalWidth: CGFloat

    private(set) var bannerFrame = CGRect.zero
    private(set) var buttonFrame = CGRect.zero

    init(backingScale: CGFloat) {
        container.zPosition = 70
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.42
        container.shadowRadius = 16
        container.shadowOffset = CGSize(width: 0, height: -5)

        pill.cornerRadius = cornerRadius
        pill.cornerCurve = .continuous
        pill.colors = [
            NSColor(srgbRed: 0.11, green: 0.14, blue: 0.21, alpha: 0.84).cgColor,
            NSColor(srgbRed: 0.06, green: 0.08, blue: 0.13, alpha: 0.90).cgColor
        ]
        pill.startPoint = CGPoint(x: 0.5, y: 1.0)
        pill.endPoint = CGPoint(x: 0.5, y: 0.0)
        container.addSublayer(pill)

        rim.cornerRadius = cornerRadius
        rim.cornerCurve = .continuous
        rim.colors = [
            NSColor(white: 1, alpha: 0.28).cgColor,
            NSColor(white: 1, alpha: 0.08).cgColor
        ]
        rim.startPoint = CGPoint(x: 0.5, y: 1.0)
        rim.endPoint = CGPoint(x: 0.5, y: 0.0)
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1
        rim.mask = rimMask
        container.addSublayer(rim)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.45, green: 0.74, blue: 1.0, alpha: 1)]))
        if let symbolImage = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            var rect = CGRect(x: 0, y: 0, width: 20, height: 20)
            iconLayer.contents = symbolImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = backingScale
        container.addSublayer(iconLayer)

        let primaryAttr = NSAttributedString(
            string: "Enable Screen Recording to preview live windows",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.92)
            ]
        )
        let secondaryAttr = NSAttributedString(
            string: "  ·  Optional, Rapto never saves or uploads",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(white: 1, alpha: 0.58)
            ]
        )
        let combined = NSMutableAttributedString(attributedString: primaryAttr)
        combined.append(secondaryAttr)
        messageLayer.string = combined
        messageLayer.contentsScale = backingScale
        messageLayer.alignmentMode = .left
        messageLayer.truncationMode = .end
        container.addSublayer(messageLayer)
        messageWidth = ceil(combined.size().width)

        let btnAttr = NSAttributedString(
            string: "Open Settings",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        buttonLabel.string = btnAttr
        buttonLabel.contentsScale = backingScale
        buttonLabel.alignmentMode = .center
        buttonWidth = ceil(btnAttr.size().width) + 22

        buttonBg.cornerRadius = 13
        buttonBg.cornerCurve = .continuous
        buttonBg.borderWidth = 1
        buttonBg.borderColor = NSColor(srgbRed: 0.46, green: 0.72, blue: 1.0, alpha: 0.52).cgColor
        buttonBg.backgroundColor = NSColor(srgbRed: 0.22, green: 0.54, blue: 0.98, alpha: 0.34).cgColor
        container.addSublayer(buttonBg)
        container.addSublayer(buttonLabel)

        // 16 lead + 18 icon + 8 gap + message + 14 gap + button + 8 trail
        totalWidth = 16 + 18 + 8 + messageWidth + 14 + buttonWidth + 8
    }

    func layout(centerX: CGFloat, topY: CGFloat, maxWidth: CGFloat, alpha: Float, buttonHovered: Bool) {
        let w = min(totalWidth, maxWidth)
        let rect = CGRect(x: round(centerX - w / 2), y: round(topY - height), width: round(w), height: height)
        bannerFrame = rect
        container.frame = rect
        container.opacity = alpha

        let local = CGRect(origin: .zero, size: rect.size)
        pill.frame = local
        rim.frame = local
        let path = CGPath(roundedRect: local.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        rimMask.path = path
        container.shadowPath = path

        iconLayer.frame = CGRect(x: 15, y: (height - 17) / 2, width: 18, height: 17)
        let btnRect = CGRect(x: local.width - buttonWidth - 7, y: (height - 26) / 2, width: buttonWidth, height: 26)
        buttonBg.frame = btnRect
        buttonBg.backgroundColor = buttonHovered
            ? NSColor(srgbRed: 0.28, green: 0.60, blue: 1.0, alpha: 0.54).cgColor
            : NSColor(srgbRed: 0.22, green: 0.54, blue: 0.98, alpha: 0.34).cgColor
        buttonLabel.frame = CGRect(x: btnRect.minX, y: btnRect.minY + 4, width: btnRect.width, height: 17)
        buttonFrame = btnRect.offsetBy(dx: rect.minX, dy: rect.minY)

        let msgX: CGFloat = 41
        let msgW = max(60, btnRect.minX - msgX - 12)
        messageLayer.frame = CGRect(x: msgX, y: (height - 17) / 2 - 1, width: msgW, height: 18)
    }
}

// MARK: - View

final class WindowFlowView: NSView {
    private enum Phase {
        case browsing
        case committing
        case revealing
        case finished
    }

    fileprivate var currentFrame: ((CGWindowID) -> CGRect?)?
    fileprivate var captureFull: ((CGWindowID) async -> CGImage?)?
    fileprivate var fetchTargetWallpaper: ((UInt64) async -> CGImage?)?
    fileprivate var focus: ((WindowFlowItem, @escaping () -> Void) -> Void)?
    fileprivate var isSpaceCurrent: ((WindowFlowItem) -> Bool)?
    fileprivate var spaceWindowOrder: ((UInt64) -> [CGWindowID])?
    var nextBackdrop: (() -> WindowFlowBackdrop?)?
    var onOpenScreenRecordingSettings: (() -> Void)?
    var onCommitBegan: (() -> Void)?
    var onFinished: (() -> Void)?

    let hasHero: Bool
    let showsLivePreviews: Bool
    private let cards: [WindowFlowCard]
    /// Pre-composited preview of the target desktop (wallpaper + sibling windows) placed beneath
    /// `backdropLayer` so the sky can dissolve to 0% BEFORE `DockSpaceSwipe` switches spaces.
    private let targetDesktopClipLayer = CALayer()
    private let targetWallpaperLayer = CALayer()
    private var targetSiblingLayers: [CGWindowID: CALayer] = [:]
    private let menuBarHeight: CGFloat
    private let backdropLayer = CALayer()
    private let metalSkyLayer: WindowFlowMetalSkyLayer?
    private var activeSkyMode: Int32?
    /// Seconds the sky has been on screen, over all openings. The shader takes time as a 32-bit
    /// float: seconds since boot lose precision after a few days of uptime (steps of 1/8 s after
    /// two weeks) and the clouds would move in jumps. This clock stays small and the sky goes on
    /// from where it was.
    private static var skyClock: Double = 0
    /// Holds the cards and gives them perspective. A flat card at depth 0 is drawn exactly
    /// at its frame, which the pictures that stand in for real windows rely on.
    private let stage = CALayer()
    private let titleHUD: WindowFlowTitleHUD
    private let permissionBanner: WindowFlowPermissionBanner?
    private let dotsContainer = CALayer()
    private var dotLayers: [CALayer] = []
    private var dotFrames: [CGRect] = []
    private let hintLayer = CATextLayer()
    /// Darkens the edges of the backdrop so the centre of the strip reads as the lit part.
    private let vignette = CAGradientLayer()
    /// Backdrop layers at different depths: each is wider than the screen and slides by its own amount.
    private var decorLayers: [(layer: CALayer, decor: WindowFlowDecor)] = []
    private let backingScale: CGFloat

    private var phase = Phase.browsing
    /// Calm, critically-damped springs for liquid macOS entry and exit without abrupt snaps.
    private var open = WindowFlowSpring(0, stiffness: 132, damping: 23.2)
    /// The card in the centre, as a fractional index while scrolling.
    private var position = WindowFlowSpring(0, stiffness: 235, damping: 27.5)
    /// 0 in the strip, 1 when the chosen picture sits on its window's frame.
    private var commit = WindowFlowSpring(0, stiffness: 152, damping: 24.8)
    /// 0 while the backdrop hides the desktop, 1 when the desktop shows through again.
    private var clear = WindowFlowSpring(0, stiffness: 140, damping: 24.0)
    /// Smooth, unhurried final optical cross-dissolve into the real focused window with no end cut.
    private var reveal = WindowFlowSpring(0, stiffness: 68, damping: 18.5)
    /// When the chosen window's desktop was first seen on screen.
    private var spaceReadyAt: Date?
    private var commitStartedAt = Date()
    private var commitStaysOnCurrentSpace = false
    private var crossDesktopFocusLaunched = false
    private var targetDesktopReady = false
    private static let solidSkyBackstop = CGColor(srgbRed: 0.038, green: 0.095, blue: 0.195, alpha: 1)
    private static let overlayScrim = CGColor(srgbRed: 0.04, green: 0.06, blue: 0.11, alpha: 0.62)

    private var selected = 0
    private var hoveredIndex: Int?
    private var settingsButtonHovered = false
    private var commitTarget: CGRect?
    private var focusDoneAt: Date?
    private var commitDeadline = Date.distantFuture
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var shownTitleIndex = -1
    private var loggedScroll = false
    /// Where the pointer is, from -1 to 1 on each axis, smoothed.
    private var lean = CGPoint.zero
    /// Smoothed pointer position in view coordinates for per-card 3D magnetic reaction.
    private var smoothMouse = CGPoint.zero
    private var hasMouseSample = false
    /// Smoothed scroll speed used to bank cards slightly in 3D while flicking through the strip.
    private var smoothVelocity: CGFloat = 0
    /// Finger travel that moves the strip by one card.
    private static let pointsPerCard: Double = 470
    /// Base angle a side card turns toward the centre, in radians (~35 degrees).
    private static let sideAngle: CGFloat = 0.61
    /// How far a flick carries: its speed times this many seconds.
    private static let coastSeconds: Double = 0.42
    private static let maxVisibleDots = 18
    private var isScrolling = false
    private var scrollHasPhases = true
    private var scrollVelocity = 0.0
    private var lastScrollTime: TimeInterval = 0

    fileprivate init(
        frame: CGRect,
        items: [WindowFlowItem],
        hasHero: Bool,
        showsLivePreviews: Bool,
        backingScale: CGFloat,
        menuBarHeight: CGFloat,
        metalPipeline: WindowFlowMetalPipeline?
    ) {
        self.cards = items.map { WindowFlowCard(item: $0, backingScale: backingScale, isIconOnly: !showsLivePreviews) }
        self.hasHero = hasHero
        self.showsLivePreviews = showsLivePreviews
        self.backingScale = backingScale
        self.menuBarHeight = menuBarHeight
        self.titleHUD = WindowFlowTitleHUD(backingScale: backingScale)
        self.permissionBanner = showsLivePreviews ? nil : WindowFlowPermissionBanner(backingScale: backingScale)
        self.metalSkyLayer = WindowFlowMetalSkyLayer(pipelineBundle: metalPipeline)
        super.init(frame: frame)
        smoothMouse = CGPoint(x: bounds.midX, y: bounds.midY)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true

        targetDesktopClipLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(1, bounds.height - menuBarHeight)
        )
        targetDesktopClipLayer.masksToBounds = true
        targetDesktopClipLayer.zPosition = -12_000
        targetDesktopClipLayer.isHidden = true
        layer?.addSublayer(targetDesktopClipLayer)

        backdropLayer.frame = bounds
        backdropLayer.contentsGravity = .resize
        // No opaque black fill: avoids any dark flash before the first GPU frame composites
        backdropLayer.backgroundColor = nil
        backdropLayer.opacity = 0
        backdropLayer.zPosition = -10_000
        layer?.addSublayer(backdropLayer)

        if let sky = metalSkyLayer {
            let outerSkyRect = bounds.insetBy(dx: -WindowFlowController.decorMargin, dy: -36)
            sky.configureSize(bounds: outerSkyRect, backingScale: backingScale)
            sky.opacity = 0
            sky.isHidden = true
            backdropLayer.addSublayer(sky)
        }

        vignette.frame = bounds
        vignette.type = .radial
        vignette.colors = [NSColor.clear.cgColor, NSColor(white: 0, alpha: 0.82).cgColor]
        vignette.locations = [0.38, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.54)
        vignette.endPoint = CGPoint(x: 1.12, y: 1.28)
        backdropLayer.addSublayer(vignette)

        stage.frame = bounds
        stage.sublayerTransform = perspective
        layer?.addSublayer(stage)

        for (index, card) in cards.enumerated() {
            card.baseSize = cardSize(index, at: Double(index))
            stage.addSublayer(card.layer)
        }

        layer?.addSublayer(titleHUD.container)
        if let permissionBanner {
            layer?.addSublayer(permissionBanner.container)
        }

        dotsContainer.zPosition = 60
        if cards.count > 1, cards.count <= Self.maxVisibleDots {
            for _ in cards.indices {
                let dot = CALayer()
                dot.cornerRadius = 3
                dot.cornerCurve = .continuous
                dot.backgroundColor = NSColor.white.cgColor
                dotsContainer.addSublayer(dot)
                dotLayers.append(dot)
            }
        }
        layer?.addSublayer(dotsContainer)

        hintLayer.contentsScale = backingScale
        hintLayer.alignmentMode = .center
        hintLayer.frame = CGRect(x: bounds.midX - 420, y: 18, width: 840, height: 16)
        hintLayer.zPosition = 50
        layer?.addSublayer(hintLayer)

        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)

        open.target = 1
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Cards never show bigger than the centre slot, so their pictures need no more pixels than that.
    var cardPixelLimit: CGSize {
        CGSize(width: centerBox.width * backingScale, height: centerBox.height * backingScale)
    }

    func setBackdrop(_ backdrop: WindowFlowBackdrop) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let currentFade = (activeSkyMode != nil ? metalSkyLayer?.opacity : nil) ?? backdropLayer.opacity
        activeSkyMode = backdrop.skyMode
        if let skyMode = backdrop.skyMode, let sky = metalSkyLayer {
            backdropLayer.contents = nil
            backdropLayer.opacity = 1
            vignette.isHidden = true
            sky.opacity = currentFade
            sky.isHidden = false
            sky.drawSky(mode: skyMode, time: Self.skyClock, lean: lean)
        } else {
            metalSkyLayer?.isHidden = true
            vignette.isHidden = false
            backdropLayer.opacity = currentFade
            backdropLayer.contents = backdrop.image
        }
        decorLayers.forEach { $0.layer.removeFromSuperlayer() }
        decorLayers = backdrop.decor.map { decor in
            let layer = CALayer()
            layer.frame = bounds.insetBy(dx: -WindowFlowController.decorMargin, dy: -WindowFlowController.decorMargin)
            layer.contentsGravity = .resize
            layer.contents = decor.image
            backdropLayer.insertSublayer(layer, below: vignette)
            return (layer, decor)
        }
        vignette.opacity = backdrop.vignette
        if backdrop.skyMode == nil && !showsLivePreviews {
            backdropLayer.backgroundColor = Self.overlayScrim
        } else if backdrop.skyMode != nil {
            backdropLayer.backgroundColor = nil
        }
        CATransaction.commit()
        let hintText = "← → or Scroll   ·   ⏎ Open   ·   B Theme: \(backdrop.name)   ·   Esc Close"
        hintLayer.string = NSAttributedString(
            string: hintText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.44)
            ]
        )
    }

    func setImage(_ image: CGImage, for windowID: CGWindowID, animated: Bool = false, crossfade: Bool = false) {
        guard let card = cards.first(where: { $0.item.id == windowID }) else { return }
        let isFirstImage = !card.hasImage
        let oldContents = card.pictureLayer.contents
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.pictureLayer.contents = image
        card.pictureLayer.backgroundColor = nil
        card.updateCorner(from: image)
        card.hasImage = true
        targetSiblingLayers[windowID]?.contents = image
        CATransaction.commit()
        if animated && isFirstImage {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.pictureLayer.add(fade, forKey: "imageFade")
        } else if crossfade, let oldContents {
            let morph = CABasicAnimation(keyPath: "contents")
            morph.fromValue = oldContents
            morph.toValue = image
            morph.duration = 0.24
            morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            card.pictureLayer.add(morph, forKey: "contentsCrossfade")
        }
    }

    func applyResolvedTitles(_ resolved: [CGWindowID: String]) {
        var activeChanged = false
        for (index, card) in cards.enumerated() {
            guard let title = resolved[card.item.id], !title.isEmpty else { continue }
            card.item.entry.resolvedTitle = title
            card.updateCardLabel()
            if index == shownTitleIndex { activeChanged = true }
        }
        if activeChanged, cards.indices.contains(shownTitleIndex) {
            titleHUD.updateItem(cards[shownTitleIndex].item, maxWidth: maxHUDWidth, jumpWidth: false)
        }
    }

    func start() {
        render()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        phase = .finished
        link?.invalidate()
        link = nil
    }

    // MARK: - Input

    func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .browsing else { return true }
        debugLog("WindowFlow", "Key \(event.keyCode)")
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.subtracting([.numericPad]).isEmpty,
           let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), (1...9).contains(digit),
           cards.indices.contains(digit - 1) {
            jumpToIndex(digit - 1)
            return true
        }
        switch event.keyCode {
        case 123: step(-1)
        case 124: step(1)
        case 48: step(modifiers.contains(.shift) ? -1 : 1)
        case 36, 76, 49: commitSelection(nearestIndex)
        case 53: cancel()
        case 11:
            if let backdrop = nextBackdrop?() { setBackdrop(backdrop) }
        default: break
        }
        return true
    }

    func cancel() {
        guard phase == .browsing else { return }
        commitSelection(hasHero ? 0 : nil)
    }

    func cancelIfBrowsing() {
        cancel()
    }

    override func mouseMoved(with event: NSEvent) {
        guard phase == .browsing else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = hitCard(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard phase == .browsing, cards.count > 1 else { return }
        if !loggedScroll {
            loggedScroll = true
            debugLog("WindowFlow", "First scroll event, precise=\(event.hasPreciseScrollingDeltas)")
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 { step(delta < 0 ? 1 : -1) }
            return
        }
        // The system's momentum would fight the landing on a card, so it is replaced by our own
        guard event.momentumPhase == [] else { return }
        if !isScrolling {
            isScrolling = true
            scrollVelocity = 0
            lastScrollTime = event.timestamp
        }
        scrollHasPhases = event.phase != []
        let last = Double(cards.count - 1)
        var moved = -Double(delta) / Self.pointsPerCard
        let next = position.value + moved
        if next < 0 || next > last { moved *= 0.28 }
        let elapsed = max(event.timestamp - lastScrollTime, 1.0 / 240.0)
        lastScrollTime = event.timestamp
        if moved != 0 {
            scrollVelocity = scrollVelocity * 0.55 + (moved / elapsed) * 0.45
        }
        position.jump(to: position.value + moved)
        if event.phase == .ended || event.phase == .cancelled {
            landScroll()
        }
    }

    /// Carries the fingers' speed into the spring and picks the card it would coast to.
    private func landScroll() {
        guard isScrolling else { return }
        isScrolling = false
        let speed = min(max(scrollVelocity, -18), 18)
        position.target = WindowFlowLayout.coastTarget(
            position: position.value,
            velocity: speed,
            coastSeconds: Self.coastSeconds,
            count: cards.count
        )
        position.velocity = speed
        position.stiffness = 110
        position.damping = 21
    }

    override func mouseDown(with event: NSEvent) {
        guard phase == .browsing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let permissionBanner {
            if permissionBanner.buttonFrame.insetBy(dx: -6, dy: -6).contains(point) {
                onOpenScreenRecordingSettings?()
                return
            }
            if permissionBanner.bannerFrame.contains(point) {
                return
            }
        }
        if let dotIndex = dotFrames.firstIndex(where: { $0.insetBy(dx: -5, dy: -8).contains(point) }) {
            if dotIndex == nearestIndex {
                commitSelection(dotIndex)
            } else {
                jumpToIndex(dotIndex)
            }
            return
        }
        if let hit = hitCard(at: point) {
            commitSelection(hit)
        } else {
            cancel()
        }
    }

    private func hitCard(at point: CGPoint) -> Int? {
        cards.indices
            .filter { !cards[$0].layer.isHidden && cards[$0].frame.contains(point) }
            .min { abs(Double($0) - position.value) < abs(Double($1) - position.value) }
    }

    private var nearestIndex: Int {
        min(max(Int(position.target.rounded()), 0), cards.count - 1)
    }

    private func step(_ offset: Int) {
        isScrolling = false
        position.stiffness = 235
        position.damping = 27.5
        let current = nearestIndex
        let next = min(max(current + offset, 0), cards.count - 1)
        if next == current {
            // Subtle macOS rubber-band nudge at the ends of the strip
            position.velocity = Double(offset) * 2.4
        }
        position.target = Double(next)
    }

    private func jumpToIndex(_ index: Int) {
        isScrolling = false
        position.stiffness = 235
        position.damping = 27.5
        position.target = Double(min(max(index, 0), cards.count - 1))
    }

    // MARK: - Commit

    /// Assembles the target desktop's wallpaper and sibling windows underneath the opaque sky
    /// so the sky can dissolve to 0% BEFORE `DockSpaceSwipe` switches spaces.
    private func setupTargetDesktopPreview(for chosenIndex: Int) {
        let chosenItem = cards[chosenIndex].item
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        targetDesktopClipLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        targetSiblingLayers.removeAll(keepingCapacity: true)

        if chosenItem.entry.isFullScreen {
            targetDesktopClipLayer.frame = bounds
            targetWallpaperLayer.frame = bounds
            targetWallpaperLayer.contents = nil
            targetWallpaperLayer.backgroundColor = NSColor.black.cgColor
            targetDesktopClipLayer.addSublayer(targetWallpaperLayer)
            targetDesktopClipLayer.isHidden = false
            targetDesktopReady = true
            CATransaction.commit()
            return
        }

        targetDesktopClipLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(1, bounds.height - menuBarHeight)
        )
        targetWallpaperLayer.frame = bounds
        targetWallpaperLayer.contentsGravity = .resizeAspectFill
        targetWallpaperLayer.contentsScale = backingScale
        targetWallpaperLayer.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor
        targetDesktopClipLayer.addSublayer(targetWallpaperLayer)

        var largeSiblingIDs: [CGWindowID] = []
        // Sort siblings by WindowServer's true per-space front-to-back order (since global
        // CGWindowList can list a background-woken app ahead of the slot's real top window
        // while that desktop is off-screen), then add back-to-front.
        let trueFrontToBack = spaceWindowOrder?(chosenItem.entry.spaceID) ?? []
        var zRank: [CGWindowID: Int] = [:]
        for (rank, wid) in trueFrontToBack.enumerated() where zRank[wid] == nil {
            zRank[wid] = rank
        }
        let siblingsFrontToBack = cards.enumerated()
            .filter { $0.offset != chosenIndex && $0.element.item.entry.spaceID == chosenItem.entry.spaceID }
            .sorted { lhs, rhs in
                let r1 = zRank[lhs.element.item.id] ?? (1_000_000 + lhs.offset)
                let r2 = zRank[rhs.element.item.id] ?? (1_000_000 + rhs.offset)
                return r1 < r2
            }

        for (_, otherCard) in siblingsFrontToBack.reversed() {
            guard let winFrame = currentFrame?(otherCard.item.id) ?? otherCard.item.frameInView else { continue }

            let scaleRatio = winFrame.width / max(otherCard.baseSize.width, 1)
            let corner = min(otherCard.baseCornerRadius * scaleRatio, min(winFrame.width, winFrame.height) / 2)
            let localRect = CGRect(origin: .zero, size: winFrame.size)

            let shadowHost = CALayer()
            shadowHost.frame = winFrame
            shadowHost.shadowColor = NSColor.black.cgColor
            shadowHost.shadowOpacity = 0.28
            shadowHost.shadowRadius = 18
            shadowHost.shadowOffset = CGSize(width: 0, height: -8)
            shadowHost.shadowPath = CGPath(roundedRect: localRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

            let winClip = CALayer()
            winClip.frame = localRect
            winClip.masksToBounds = true
            winClip.cornerCurve = .continuous
            winClip.cornerRadius = corner
            winClip.contentsGravity = .resize
            winClip.contentsScale = backingScale
            winClip.minificationFilter = .trilinear
            winClip.magnificationFilter = .linear
            winClip.contents = otherCard.pictureLayer.contents
            shadowHost.addSublayer(winClip)

            targetDesktopClipLayer.addSublayer(shadowHost)
            targetSiblingLayers[otherCard.item.id] = winClip
            if winFrame.width > centerBox.width * 1.05 {
                largeSiblingIDs.append(otherCard.item.id)
            }
        }

        targetDesktopClipLayer.isHidden = false
        targetDesktopReady = false
        CATransaction.commit()

        let spaceID = chosenItem.entry.spaceID
        let chosenID = chosenItem.id
        Task { [weak self] in
            guard let self else { return }
            async let wallTask = self.fetchTargetWallpaper?(spaceID)
            async let chosenFullTask = self.captureFull?(chosenID)
            let (wallImg, chosenImg) = await (wallTask, chosenFullTask)
            guard self.phase == .committing else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let wallImg {
                self.targetWallpaperLayer.contents = wallImg
            }
            CATransaction.commit()
            if let chosenImg {
                self.setImage(chosenImg, for: chosenID, crossfade: false)
            }
            self.targetDesktopReady = true

            for sibID in largeSiblingIDs {
                guard self.phase == .committing, let fullSib = await self.captureFull?(sibID) else { continue }
                self.setImage(fullSib, for: sibID, crossfade: false)
            }
        }
    }

    /// nil closes the strip without choosing a window.
    private func commitSelection(_ index: Int?) {
        guard phase == .browsing else { return }
        phase = .committing
        onCommitBegan?()
        isScrolling = false
        hoveredIndex = nil
        crossDesktopFocusLaunched = false
        targetDesktopReady = false
        commitStartedAt = Date()
        commitDeadline = Date().addingTimeInterval(4.0)
        guard let index else {
            selected = -1
            commitStaysOnCurrentSpace = true
            commit.target = 1
            clear.target = 1
            focusDoneAt = Date()
            spaceReadyAt = Date()
            return
        }
        selected = index
        position.stiffness = 185
        position.damping = 26
        position.target = Double(index)
        let item = cards[index].item
        commit.target = 1

        // Overlay mode (no Screen Recording): focus the chosen window right away and dissolve
        // the icon overlay cleanly without trying to morph a placeholder card onto the real window.
        if !showsLivePreviews {
            commitTarget = nil
            commitStaysOnCurrentSpace = true
            commit.stiffness = 190
            commit.damping = 26
            clear.stiffness = 175
            clear.damping = 25
            clear.target = 1
            spaceReadyAt = Date()
            focusDoneAt = Date()
            focus?(item) { [weak self] in
                self?.focusDoneAt = Date()
            }
            return
        }

        commitTarget = currentFrame?(item.id) ?? item.frameInView
        let isCancel = hasHero && index == 0
        commitStaysOnCurrentSpace = isCancel || (isSpaceCurrent?(item) ?? true)

        if isCancel {
            focusDoneAt = Date()
            spaceReadyAt = Date()
            Task { [weak self] in
                guard let self, let image = await self.captureFull?(item.id) else { return }
                guard self.phase == .committing else { return }
                self.setImage(image, for: item.id, crossfade: false)
            }
        } else if commitStaysOnCurrentSpace {
            spaceReadyAt = Date()
            Task { [weak self] in
                guard let self, let image = await self.captureFull?(item.id) else { return }
                guard self.phase == .committing else { return }
                self.setImage(image, for: item.id, crossfade: false)
            }
            focus?(item) { [weak self] in
                self?.focusDoneAt = Date()
            }
        } else {
            // Play the ENTIRE visual exit BEFORE switching desktops: dissolve the 120 Hz sky into
            // the pre-composited target desktop while growing the chosen window to 100%, and fire
            // `DockSpaceSwipe` only once the sky is already 0% and the screen matches the target space.
            commit.stiffness = 165
            commit.damping = 25.8
            clear.stiffness = 132
            clear.damping = 23.4
            reveal.stiffness = 68
            reveal.damping = 18.5
            setupTargetDesktopPreview(for: index)
        }
    }

    // MARK: - Frame loop

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.targetTimestamp
            render()
            return
        }
        let dt = min(max(link.targetTimestamp - lastTimestamp, 0), 0.05)
        lastTimestamp = link.targetTimestamp
        Self.skyClock += dt
        open.step(dt)
        if isScrolling, !scrollHasPhases, ProcessInfo.processInfo.systemUptime - lastScrollTime > 0.12 {
            landScroll()
        }
        if !isScrolling { position.step(dt) }
        commit.step(dt)
        clear.step(dt)
        reveal.step(dt)
        titleHUD.step(dt)
        for (index, card) in cards.enumerated() {
            card.hover.target = (phase == .browsing && hoveredIndex == index) ? 1 : 0
            card.hover.step(dt)
        }

        switch phase {
        case .committing:
            let now = Date()
            if now > commitDeadline {
                spaceReadyAt = spaceReadyAt ?? .distantPast
                focusDoneAt = focusDoneAt ?? .distantPast
            }
            if commitStaysOnCurrentSpace, selected >= 0, commit.value < 0.85, let fresh = currentFrame?(cards[selected].item.id) {
                commitTarget = fresh
            }
            if clear.target == 0 {
                if commitStaysOnCurrentSpace {
                    if commit.value > 0.48 {
                        clear.target = 1
                    }
                } else if (targetDesktopReady || now.timeIntervalSince(commitStartedAt) > 0.16),
                          commit.value > 0.24 {
                    clear.target = 1
                }
            }
            // Only after the sky has melted completely to 0% and the chosen window stands flat at 100%
            // over the composed target desktop, switch the real desktop underneath via `DockSpaceSwipe`.
            if !commitStaysOnCurrentSpace, !crossDesktopFocusLaunched, selected >= 0,
               commit.value > 0.985, clear.target == 1, clear.value > 0.985 {
                crossDesktopFocusLaunched = true
                metalSkyLayer?.opacity = 0
                metalSkyLayer?.isHidden = true
                backdropLayer.opacity = 0
                backdropLayer.backgroundColor = nil
                let item = cards[selected].item
                focus?(item) { [weak self] in
                    guard let self else { return }
                    self.focusDoneAt = Date()
                    if let fresh = self.currentFrame?(item.id) {
                        self.commitTarget = fresh
                    }
                }
            }
            if spaceReadyAt == nil, selected >= 0,
               commitStaysOnCurrentSpace || crossDesktopFocusLaunched,
               isSpaceCurrent?(cards[selected].item) ?? true {
                spaceReadyAt = now
                debugLog("WindowFlow", "Desktop on screen \(Int(now.timeIntervalSince(commitStartedAt) * 1000)) ms after the choice")
            }
            let focusWait = commitStaysOnCurrentSpace ? 0.06 : 0.08
            let focused = !showsLivePreviews || (focusDoneAt.map { now.timeIntervalSince($0) >= focusWait } ?? false)
            let exitSettled: Bool
            if !showsLivePreviews {
                exitSettled = commit.value > 0.88 && clear.value > 0.88
            } else if commitStaysOnCurrentSpace {
                exitSettled = commit.value > 0.97 && clear.target == 1 && clear.value > 0.90
            } else {
                exitSettled = crossDesktopFocusLaunched && commit.value > 0.985 && clear.value > 0.985
            }
            if exitSettled && focused {
                debugLog("WindowFlow", "Handing over \(Int(now.timeIntervalSince(commitStartedAt) * 1000)) ms after the choice")
                phase = .revealing
                reveal.target = 1
            }
        case .revealing:
            let r = CGFloat(min(max(reveal.value, 0), 1))
            let smoothReveal = r * r * (3 - 2 * r)
            window?.alphaValue = 1 - smoothReveal
            if reveal.isSettled {
                phase = .finished
                self.link?.invalidate()
                self.link = nil
                onFinished?()
                return
            }
        case .browsing, .finished:
            break
        }
        render()
    }

    private var centerBox: CGSize {
        showsLivePreviews
            ? CGSize(width: bounds.width * 0.52, height: bounds.height * 0.58)
            : CGSize(width: min(bounds.width * 0.34, 420), height: min(bounds.height * 0.42, 296))
    }
    private var sideBox: CGSize {
        showsLivePreviews
            ? CGSize(width: bounds.width * 0.20, height: bounds.height * 0.27)
            : CGSize(width: min(bounds.width * 0.19, 226), height: min(bounds.height * 0.24, 162))
    }
    private var maxHUDWidth: CGFloat { min(560, bounds.width * 0.48) }

    /// Stronger spatial camera lens so 3D card turns, Z-depth and cursor tilt feel genuinely volumetric.
    private var perspective: CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / max(880, bounds.width * 0.42)
        return transform
    }

    private func cardSize(_ index: Int, at position: Double) -> CGSize {
        let aspect = showsLivePreviews ? cards[index].item.aspect : 1.42
        return WindowFlowLayout.cardSize(
            index: index,
            at: position,
            centerBox: centerBox,
            sideBox: sideBox,
            aspect: aspect
        )
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let openness = CGFloat(min(max(open.value, 0), 1))
        let committed = CGFloat(min(max(commit.value, 0), 1))
        let cleared = CGFloat(min(max(clear.value, 0), 1))
        let center = position.value

        // Smooth cubic S-curves (zero initial and final slope) eliminate sudden luminance steps on entry & exit.
        // Drive `metalSkyLayer.opacity` directly on Sky themes so WindowServer never switches between
        // direct CAMetalLayer scanout and an offscreen group-opacity buffer at opacity 1.0 <-> 0.999.
        let openBackdropT = min(max(openness / 0.92, 0), 1)
        let smoothBackdropIn = openBackdropT * openBackdropT * (3 - 2 * openBackdropT)
        let smoothBackdropOut = cleared * cleared * (3 - 2 * cleared)
        let skyFade = crossDesktopFocusLaunched ? Float(0) : Float(smoothBackdropIn * (1 - smoothBackdropOut))
        if activeSkyMode != nil, let sky = metalSkyLayer {
            backdropLayer.opacity = crossDesktopFocusLaunched ? 0 : 1
            backdropLayer.backgroundColor = skyFade >= 0.999 ? Self.solidSkyBackstop : nil
            sky.opacity = skyFade
        } else {
            backdropLayer.backgroundColor = showsLivePreviews ? nil : Self.overlayScrim
            backdropLayer.opacity = skyFade
        }

        let chromeInT = min(max((openness - 0.12) / 0.65, 0), 1)
        let chromeOutT = min(max(committed / 0.68, 0), 1)
        let stripAlpha = Float((chromeInT * chromeInT * (3 - 2 * chromeInT)) * (1 - chromeOutT * chromeOutT * (3 - 2 * chromeOutT)))

        // `life` smoothly eases from 0 -> 1 on entry and 1 -> 0 on exit with zero sudden snaps,
        // reaching 0 well before handover so the picture lines up pixel-for-pixel with the window.
        let lifeIn = openness * openness * (3 - 2 * openness)
        let lifeOutT = min(max(committed / 0.72, 0), 1)
        let lifeOut = 1 - lifeOutT * lifeOutT * (3 - 2 * lifeOutT)
        let life = lifeIn * lifeOut
        let time = CACurrentMediaTime()

        if let window {
            let mouse = window.mouseLocationOutsideOfEventStream
            if phase == .browsing {
                settingsButtonHovered = permissionBanner?.buttonFrame.insetBy(dx: -6, dy: -6).contains(mouse) ?? false
                hoveredIndex = (!settingsButtonHovered && bounds.contains(mouse)) ? hitCard(at: mouse) : nil
            } else {
                settingsButtonHovered = false
            }
            if !hasMouseSample {
                smoothMouse = mouse
                hasMouseSample = true
            } else {
                smoothMouse.x += (mouse.x - smoothMouse.x) * 0.14
                smoothMouse.y += (mouse.y - smoothMouse.y) * 0.14
            }
            let wantedX = min(max((mouse.x - bounds.midX) / max(bounds.width / 2, 1), -1), 1)
            let wantedY = min(max((mouse.y - bounds.midY) / max(bounds.height / 2, 1), -1), 1)
            lean.x += (wantedX - lean.x) * 0.085
            lean.y += (wantedY - lean.y) * 0.085
        }

        let liveVel = CGFloat(isScrolling ? scrollVelocity : position.velocity)
        smoothVelocity += (min(max(liveVel, -12), 12) - smoothVelocity) * 0.16

        // Global 3D camera orbit responding to pointer movement across the screen
        var leaned = perspective
        leaned = CATransform3DRotate(leaned, lean.x * 0.055 * life, 0, 1, 0)
        leaned = CATransform3DRotate(leaned, -lean.y * 0.038 * life, 1, 0, 0)
        stage.sublayerTransform = leaned

        // Multi-depth backdrop parallax + native 120 Hz live Metal sky synced to display refresh
        if let skyMode = activeSkyMode, let sky = metalSkyLayer, !sky.isHidden, sky.opacity > 0.001 {
            sky.position = CGPoint(
                x: bounds.midX - lean.x * 38,
                y: bounds.midY - lean.y * 22
            )
            sky.drawSky(mode: skyMode, time: Self.skyClock, lean: lean)
        }
        for (index, entry) in decorLayers.enumerated() {
            let phaseAngle = Double(index) * 2.1
            entry.layer.position = CGPoint(
                x: bounds.midX - lean.x * entry.decor.parallax + CGFloat(sin(time * 0.048 + phaseAngle)) * entry.decor.drift,
                y: bounds.midY - lean.y * entry.decor.parallax * 0.65 + CGFloat(cos(time * 0.040 + phaseAngle)) * entry.decor.drift * 0.65
            )
        }

        // Card centres along a curved 3D amphitheatre arc
        let baseGap = bounds.width * 0.025
        let sizes = cards.indices.map { cardSize($0, at: center) }
        var centers: [CGFloat] = []
        var cursor: CGFloat = 0
        for index in cards.indices {
            if index > 0 {
                let pairDist = abs((Double(index) - 0.5) - center)
                let compression = pairDist <= 1.0 ? 1.0 : CGFloat(max(0.55, 1.0 - (pairDist - 1.0) * 0.15))
                cursor += (sizes[index - 1].width / 2 + baseGap + sizes[index].width / 2) * compression
            }
            centers.append(cursor)
        }
        let lower = min(max(Int(center.rounded(.down)), 0), cards.count - 1)
        let upper = min(lower + 1, cards.count - 1)
        let fraction = CGFloat(min(max(center - Double(lower), 0), 1))
        let focusX = centers[lower] + (centers[upper] - centers[lower]) * fraction
        let midY = bounds.height * 0.545

        for (index, card) in cards.enumerated() {
            let size = sizes[index]
            let delta = Double(index) - center
            let absDelta = abs(delta)
            // Subtle vertical arc so outer cards curve gently around the viewer in 3D space
            let arcLift = -CGFloat(min(absDelta * absDelta, 5.0)) * 5.5 * life
            var frame = CGRect(
                x: bounds.midX + centers[index] - focusX - size.width / 2,
                y: midY - size.height / 2 + arcLift,
                width: size.width,
                height: size.height
            )
            var alpha: Float = 1
            let side: CGFloat = delta < 0 ? -1 : 1
            let isHero = hasHero && index == 0

            if isHero, let windowFrame = card.item.frameInView {
                frame = Self.mix(windowFrame, frame, openness)
            } else {
                let stagger = min(CGFloat(absDelta) * 0.04, 0.16)
                let cardOpen = min(max((openness - stagger) / max(1 - stagger, 0.01), 0), 1)
                let slideX: CGFloat = (!hasHero && absDelta < 0.01) ? 0 : side * (1 - cardOpen) * bounds.width * 0.16
                frame = frame.offsetBy(dx: slideX, dy: -(1 - cardOpen) * 18)
                alpha = Float(min(max((cardOpen - 0.06) / 0.68, 0), 1))
            }

            if absDelta > 3.0 {
                let edgeFade = max(0, 1 - (absDelta - 3.0) * 0.45)
                alpha *= Float(edgeFade)
            }

            var overlayExitScale: CGFloat = 1
            if phase != .browsing {
                if !showsLivePreviews {
                    if index == selected {
                        overlayExitScale = 1 + 0.045 * committed
                        alpha *= Float(1 - min(max(committed * 1.15, 0), 1))
                    } else if selected < 0 {
                        overlayExitScale = 1 - 0.04 * committed
                        alpha *= Float(1 - min(max(committed * 1.35, 0), 1))
                    } else {
                        let away: CGFloat = index < selected ? -1 : 1
                        frame = frame.offsetBy(dx: away * committed * bounds.width * 0.12, dy: 0)
                        alpha *= Float(1 - min(max(committed * 1.55, 0), 1))
                    }
                } else if index == selected, let target = commitTarget {
                    frame = Self.mix(frame, target, committed)
                } else {
                    let away: CGFloat = index < selected ? -1 : 1
                    frame = frame.offsetBy(dx: away * committed * bounds.width * 0.16, dy: 0)
                    alpha *= Float(1 - min(max(committed * 1.55, 0), 1))
                }
            }

            let visible = frame.maxX > -260 && frame.minX < bounds.width + 260 && alpha > 0.001
            card.layer.isHidden = !visible
            card.frame = frame
            guard visible else { continue }

            let isCommittingSelected = (phase != .browsing && index == selected)
            let closeness = CGFloat(max(0, 1 - absDelta))
            let hoverRaw = CGFloat(card.hover.value) * (1 - min(max(committed * 2, 0), 1))
            // Side cards lift more on hover; the centre card reacts with a refined spatial swell
            let sideWeight = 1 - closeness * 0.62
            let hoverLift = hoverRaw * sideWeight

            var depth = openness * openness * (3 - 2 * openness)
            if isCommittingSelected {
                let unwind = committed * committed * (3 - 2 * committed)
                depth *= (1 - unwind)
            }
            let cardLife = life

            // Per-window 3D magnetic reaction to the pointer: each window senses how close the cursor
            // is to its own centre and tilts/floats toward the pointer like a physical floating pane.
            let relX = (smoothMouse.x - frame.midX) / max(frame.width * 0.62, 160)
            let relY = (smoothMouse.y - frame.midY) / max(frame.height * 0.62, 140)
            let clampedRelX = min(max(relX, -1.5), 1.5)
            let clampedRelY = min(max(relY, -1.5), 1.5)
            let distSq = relX * relX * 0.55 + relY * relY * 0.55
            let mouseField = exp(-distSq * 0.85) * cardLife

            // Apple TV / VisionOS style specular tilt toward the pointer + gentle magnetic pull
            let mouseYaw = clampedRelX * 0.088 * mouseField
            let mousePitch = -clampedRelY * 0.072 * mouseField
            let magX = clampedRelX * 9.5 * mouseField
            let magY = clampedRelY * 7.0 * mouseField
            let magZ = (28 * mouseField * sideWeight) + (34 * hoverLift)

            // Organic 3-axis autonomous breathing so every window feels suspended in space
            let seed = Double(index) * 1.618
            let breathAmp = cardLife * (0.45 + 0.55 * min(CGFloat(absDelta), 1))
            let driftY = CGFloat(sin(time * 0.92 + seed)) * 5.8 * breathAmp
            let driftX = CGFloat(cos(time * 0.68 + seed * 1.4)) * 2.6 * breathAmp
            let swayY = CGFloat(sin(time * 0.64 + seed * 1.3)) * 0.028 * breathAmp
            let swayX = CGFloat(cos(time * 0.54 + seed * 0.9)) * 0.018 * breathAmp
            let rollZ = CGFloat(sin(time * 0.48 + seed * 1.7)) * 0.008 * breathAmp

            // Smooth wraparound 3D amphitheatre turn + scroll aerodynamic banking
            let smoothOffset = CGFloat(tanh(delta * 1.18))
            let extraArc = CGFloat(min(max(absDelta - 1.0, 0), 2.0)) * (delta < 0 ? -0.07 : 0.07)
            let scrollBank = -smoothVelocity * 0.011 * cardLife
            let baseTurn = -(smoothOffset * Self.sideAngle + extraArc) * depth * (1 - 0.22 * hoverLift)
            let totalYaw = baseTurn + swayY + mouseYaw + scrollBank
            let totalPitch = swayX + mousePitch

            // Deep Z-axis stage recession so side windows genuinely sit behind the centre plane
            let zRecess = -CGFloat(pow(min(absDelta, 3.0), 0.88)) * bounds.width * 0.072 * depth + magZ
            let scale = (frame.width / card.baseSize.width)
                * (1 + 0.038 * hoverLift + 0.012 * mouseField * closeness)
                * overlayExitScale

            var transform = CATransform3DMakeTranslation(magX + driftX, magY + driftY + hoverLift * 5, zRecess)
            transform = CATransform3DRotate(transform, totalYaw, 0, 1, 0)
            transform = CATransform3DRotate(transform, totalPitch, 1, 0, 0)
            transform = CATransform3DRotate(transform, rollZ, 0, 0, 1)
            transform = CATransform3DScale(transform, scale, scale, 1)

            card.layer.position = CGPoint(x: frame.midX, y: frame.midY)
            card.layer.transform = transform
            card.layer.opacity = alpha
            card.layer.zPosition = isCommittingSelected
                ? 20
                : CGFloat(-absDelta) * 0.04 + hoverLift * 0.02

            let surfaceBlend = min(max(depth * 1.25, 0), 1)
            card.clipLayer.cornerRadius = surfaceBlend < 0.02 ? 0 : card.baseCornerRadius * surfaceBlend

            let absOffset = abs(smoothOffset)
            let shadeStrength = absOffset * (0.30 - 0.15 * hoverLift - 0.06 * mouseField) * depth
            card.shade.opacity = Float(max(0, shadeStrength))

            card.rimLayer.cornerRadius = card.clipLayer.cornerRadius
            card.rimLayer.borderWidth = 1.0 / max(scale, 0.05)
            let rimAlpha = (0.14 + 0.16 * closeness + 0.18 * hoverLift + 0.08 * mouseField) * surfaceBlend
            card.rimLayer.opacity = Float(rimAlpha)

            // Dynamic specular light reflection sliding across the glass pane as the card tilts in 3D
            let glintShiftX = min(max(totalYaw * 0.85 + lean.x * 0.25, -0.45), 0.45)
            let glintShiftY = min(max(totalPitch * 1.1 + lean.y * 0.25, -0.35), 0.35)
            card.sheenLayer.startPoint = CGPoint(x: 0.08 + glintShiftX, y: 0.95 + glintShiftY)
            card.sheenLayer.endPoint = CGPoint(x: 0.92 + glintShiftX, y: 0.05 + glintShiftY)
            let sheenStrength = min(max(abs(totalYaw) * 1.3 + abs(totalPitch) * 1.8 + mouseField * 0.55 + hoverLift * 0.5, 0), 1)
            card.sheenLayer.opacity = Float(sheenStrength * 0.78 * surfaceBlend)

            // 3D-reactive drop shadow shifting opposite the card's tilt and deepening on lift
            var shadowFade = depth
            if isCommittingSelected { shadowFade *= (1 - cleared) }
            card.layer.shadowOpacity = Float((0.40 + 0.18 * closeness + 0.08 * hoverLift) * shadowFade)
            card.layer.shadowOffset = CGSize(
                width: -totalYaw * 16 - lean.x * 6 * cardLife,
                height: -12 - hoverLift * 8 + totalPitch * 12
            )

            // Stage-Manager corner app icon badge on side cards (hidden on icon-only overlay cards)
            if !card.isIconOnly {
                let sidePresence = min(max((CGFloat(absDelta) - 0.18) / 0.55, 0), 1)
                let badgeScreenSize: CGFloat = 34 + 5 * hoverLift
                let badgeSize = badgeScreenSize / max(scale, 0.05)
                let badgeInset = 10 / max(scale, 0.05)
                let badgeX = delta < 0 ? badgeInset : (card.baseSize.width - badgeSize - badgeInset)
                card.sideBadge.frame = CGRect(x: badgeX, y: badgeInset, width: badgeSize, height: badgeSize)
                card.sideBadge.opacity = stripAlpha * Float(sidePresence)
            }
        }

        // Top Screen Recording hint capsule when live previews are unavailable
        if let permissionBanner {
            let preferredTopY = min(bounds.height - menuBarHeight - 24, midY + centerBox.height * 0.5 + 88)
            let bannerTopY = max(midY + centerBox.height * 0.5 + 44, preferredTopY) + lean.y * 3 * life
            permissionBanner.layout(
                centerX: bounds.midX + lean.x * 5 * life,
                topY: min(bannerTopY, bounds.height - menuBarHeight - 16),
                maxWidth: min(bounds.width - 48, 760),
                alpha: stripAlpha,
                buttonHovered: settingsButtonHovered
            )
        }

        // Foreground HUD plane with subtle forward parallax so 3 distinct depth planes are felt
        let smoothFraction = fraction * fraction * (3 - 2 * fraction)
        let lowerMinY = cards[lower].frame.minY
        let upperMinY = cards[upper].frame.minY
        let interpolatedMinY = lowerMinY + (upperMinY - lowerMinY) * smoothFraction
        let hudTopCap = bounds.height * (showsLivePreviews ? 0.34 : 0.44)
        let hudGap: CGFloat = showsLivePreviews ? 18 : 22
        let hudTopY = min(max(interpolatedMinY - hudGap, 76 + 52), hudTopCap) + lean.y * 4 * life
        let hudCenterX = bounds.midX + lean.x * 7 * life

        let titleIndex = min(max(Int(center.rounded()), 0), cards.count - 1)
        let isInitialUpdate = shownTitleIndex == -1
        if titleIndex != shownTitleIndex {
            shownTitleIndex = titleIndex
            titleHUD.updateItem(cards[titleIndex].item, maxWidth: maxHUDWidth, jumpWidth: isInitialUpdate)
        }
        let distFromSnap = CGFloat(abs(center - center.rounded()))
        let scrollDip = min(max(distFromSnap * 2, 0), 1)
        let easedDip = scrollDip * scrollDip
        titleHUD.layout(centerX: hudCenterX, topY: hudTopY, alpha: stripAlpha, scrollDip: easedDip)

        if !dotLayers.isEmpty {
            let dotGap: CGFloat = 6
            var widths: [CGFloat] = []
            var totalWidth: CGFloat = 0
            for index in dotLayers.indices {
                let prox = CGFloat(max(0, 1 - abs(Double(index) - center)))
                let w = 6 + 14 * (prox * prox * (3 - 2 * prox))
                widths.append(w)
                totalWidth += w
            }
            totalWidth += CGFloat(max(0, dotLayers.count - 1)) * dotGap
            let dotsY = max(42, hudTopY - 52 - 20)
            dotsContainer.frame = CGRect(x: round(hudCenterX - totalWidth / 2), y: round(dotsY), width: ceil(totalWidth), height: 8)
            dotsContainer.opacity = stripAlpha
            dotFrames.removeAll(keepingCapacity: true)
            var x: CGFloat = 0
            for (index, dot) in dotLayers.enumerated() {
                let prox = CGFloat(max(0, 1 - abs(Double(index) - center)))
                let w = widths[index]
                let localFrame = CGRect(x: x, y: 1, width: w, height: 6)
                dot.frame = localFrame
                dot.opacity = Float(0.26 + 0.68 * prox)
                dotFrames.append(localFrame.offsetBy(dx: dotsContainer.frame.minX, dy: dotsContainer.frame.minY))
                x += w + dotGap
            }
        }

        hintLayer.opacity = stripAlpha
    }

    private static func mix(_ from: CGRect, _ to: CGRect, _ amount: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * amount,
            y: from.minY + (to.minY - from.minY) * amount,
            width: max(1, from.width + (to.width - from.width) * amount),
            height: max(1, from.height + (to.height - from.height) * amount)
        )
    }
}
