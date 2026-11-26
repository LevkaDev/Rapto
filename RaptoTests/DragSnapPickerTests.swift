import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Drag to Snap top layout picker")
struct DragSnapPickerTests {

    @Test("Without custom layouts, the picker uses a single row of 8 thumbnails and no divider")
    func standardOnlyGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = DragSnapLayoutPicker.layoutGeometry(
            standardCount: 8,
            customCount: 0,
            visibleFrame: screen,
            showsCaption: false
        )

        #expect(geometry.thumbnails.count == 8)
        #expect(geometry.verticalDividerX == nil)
        #expect(geometry.horizontalDividerY == nil)
        #expect(Set(geometry.thumbnails.map(\.minY)).count == 1)
        #expect(geometry.panelSize.width == 762)
    }

    @Test("A few custom layouts fit on one row with a vertical divider")
    func customLayoutsFitSingleRow() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = DragSnapLayoutPicker.layoutGeometry(
            standardCount: 8,
            customCount: 2,
            visibleFrame: screen,
            showsCaption: true
        )

        #expect(geometry.thumbnails.count == 10)
        #expect(geometry.verticalDividerX != nil)
        #expect(geometry.horizontalDividerY == nil)
        #expect(geometry.panelSize.width <= screen.width - 32)
        // Divider sits strictly between the last built-in thumbnail and the first custom thumbnail
        let dividerX = geometry.verticalDividerX!
        #expect(geometry.thumbnails[7].maxX < dividerX)
        #expect(dividerX < geometry.thumbnails[8].minX)
    }

    @Test("Many custom layouts wrap into centered rows below the built-in row on compact displays")
    func manyCustomLayoutsWrapSafely() {
        let laptop = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let geometry = DragSnapLayoutPicker.layoutGeometry(
            standardCount: 8,
            customCount: 10,
            visibleFrame: laptop,
            showsCaption: false
        )

        #expect(geometry.thumbnails.count == 18)
        #expect(geometry.verticalDividerX == nil)
        #expect(geometry.horizontalDividerY != nil)
        #expect(geometry.panelSize.width <= laptop.width - 32)

        let dividerY = geometry.horizontalDividerY!
        for i in 0..<8 {
            #expect(geometry.thumbnails[i].minY > dividerY)
            #expect(geometry.thumbnails[i].minX >= 0)
            #expect(geometry.thumbnails[i].maxX <= geometry.panelSize.width)
        }
        for i in 8..<18 {
            #expect(geometry.thumbnails[i].maxY < dividerY)
            #expect(geometry.thumbnails[i].minX >= 0)
            #expect(geometry.thumbnails[i].maxX <= geometry.panelSize.width)
        }
    }

    @Test("SettingsBackup includes dragSnapPickerTemplateIDs")
    func settingsBackupIncludesPinnedPickerLayouts() {
        #expect(SettingsBackup.settingKeys.contains(AppState.dragSnapPickerTemplatesKey))
    }

    @Test("SettingsSearch finds the Drag to Snap top bar section")
    func settingsSearchFindsDragSnapBar() {
        let results = SettingsSearch.filter(query: "top bar")
        #expect(results.contains { $0.id == "behavior.dragSnapTopBar" && $0.tab == .behavior })
    }
}
