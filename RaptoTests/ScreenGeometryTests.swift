import Testing
import CoreGraphics
@testable import Rapto

/// Main display 1920×1080 at the origin, a second display 2560×1440 above it with a 25 pt menu bar.
@Suite("Screen geometry on a second display")
struct ScreenGeometryTests {
    let primaryHeight: CGFloat = 1080
    let upperScreen = CGRect(x: 0, y: 1080, width: 2560, height: 1440)
    let upperVisible = CGRect(x: 0, y: 1080, width: 2560, height: 1415)

    @Test("Overlay starts below the menu bar of a display above the main one")
    func overlayOffsetOnUpperScreen() {
        let offset = OverlayView.visibleAreaOffset(screenFrame: upperScreen, visibleFrame: upperVisible)
        #expect(offset == CGPoint(x: 0, y: 25))
    }

    @Test("Overlay offset accounts for a Dock on the left of the main display")
    func overlayOffsetWithLeftDock() {
        let offset = OverlayView.visibleAreaOffset(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 80, y: 0, width: 1840, height: 1055)
        )
        #expect(offset == CGPoint(x: 80, y: 25))
    }

    @Test("Snapshot of the left half of a display above the main one")
    func snapshotOnUpperScreen() {
        let window = CGRect(x: 0, y: -1415, width: 1280, height: 1415)
        let frame = AppState.snapshotRelativeFrame(of: window, in: upperVisible, primaryScreenHeight: primaryHeight)
        #expect(frame == CGRect(x: 0, y: 0, width: 0.5, height: 1))
    }

    @Test("Snapshot of the top-right quarter of the main display")
    func snapshotOnMainScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056)
        let window = CGRect(x: 960, y: 24, width: 960, height: 528)
        let frame = AppState.snapshotRelativeFrame(of: window, in: visible, primaryScreenHeight: primaryHeight)
        #expect(frame == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }
}
