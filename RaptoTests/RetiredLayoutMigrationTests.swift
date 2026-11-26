import Testing
import Foundation
import CoreGraphics
@testable import Rapto

@Suite("Retired built-in layout migration")
struct RetiredLayoutMigrationTests {

    @Test("Every built-in layout has a distinct zone geometry")
    func builtInLayoutsHaveDistinctGeometries() {
        let templates = PredefinedTemplates.all
        for i in 0..<templates.count {
            for j in (i + 1)..<templates.count {
                let zonesA = templates[i].zones.sorted { $0.fillOrder < $1.fillOrder }.map(\.relativeFrame)
                let zonesB = templates[j].zones.sorted { $0.fillOrder < $1.fillOrder }.map(\.relativeFrame)
                #expect(
                    zonesA != zonesB,
                    "Built-in layouts '\(templates[i].name)' and '\(templates[j].name)' have identical zones"
                )
            }
        }
    }

    @Test("Retired 2+1+2 ID resolves to Center + Split Sides and leaves other IDs unchanged")
    func canonicalIDResolvesRetiredTwoOneTwo() {
        #expect(PredefinedTemplates.canonicalID(for: PredefinedTemplates.retiredTwoOneTwoID) == PredefinedTemplates.centerSplitSidebars.id)
        #expect(PredefinedTemplates.canonicalID(for: PredefinedTemplates.quarters.id) == PredefinedTemplates.quarters.id)
        #expect(!PredefinedTemplates.all.contains { $0.id == PredefinedTemplates.retiredTwoOneTwoID })
    }

    @Test("Auto-tiling preferences migrate retired 2+1+2 ID on load")
    func autoTilingPreferencesMigrateRetiredID() {
        let suite = TestDefaults(prefix: "retired-layout-auto")
        defer { suite.remove() }

        var prefs = AutoTilingPreferences.default
        prefs.templateFor5Windows = PredefinedTemplates.retiredTwoOneTwoID
        prefs.templateFor6Windows = PredefinedTemplates.retiredTwoOneTwoID
        AutoTilingPreferencesStorage.save(prefs, to: suite.defaults)

        let loaded = AutoTilingPreferencesStorage.load(from: suite.defaults)
        #expect(loaded.templateFor5Windows == PredefinedTemplates.centerSplitSidebars.id)
        #expect(loaded.templateFor6Windows == PredefinedTemplates.centerSplitSidebars.id)
    }

    @Test("Screen and space configurations migrate retired 2+1+2 ID on load")
    @MainActor
    func screenAndSpaceConfigurationsMigrateRetiredID() throws {
        let suite = TestDefaults(prefix: "retired-layout-configs")
        defer { suite.remove() }

        var screenConfig = ScreenConfiguration(mode: .manualAssignment, templateID: PredefinedTemplates.retiredTwoOneTwoID)
        screenConfig.dragSnapTemplateID = PredefinedTemplates.retiredTwoOneTwoID
        let encodedScreens = try JSONEncoder().encode(["space:1|screen:main": screenConfig])
        suite.defaults.set(encodedScreens, forKey: "screenConfigurations_v1")

        let loadedScreens = ScreenConfigurationStorage.load(from: suite.defaults)
        #expect(loadedScreens["space:1|screen:main"]?.templateID == PredefinedTemplates.centerSplitSidebars.id)
        #expect(loadedScreens["space:1|screen:main"]?.dragSnapTemplateID == PredefinedTemplates.centerSplitSidebars.id)

        let spaceConfig = SpaceConfiguration(mode: .manualAssignment, templateID: PredefinedTemplates.retiredTwoOneTwoID)
        let encodedSpaces = try JSONEncoder().encode(["space-1": spaceConfig])
        suite.defaults.set(encodedSpaces, forKey: "spaceConfigurations")

        let loadedSpaces = SpaceConfigurationStorage.load(from: suite.defaults)
        #expect(loadedSpaces["space-1"]?.templateID == PredefinedTemplates.centerSplitSidebars.id)
    }

    @Test("Workspace storage migrates retired 2+1+2 ID on load")
    @MainActor
    func workspaceStorageMigratesRetiredID() throws {
        let suite = TestDefaults(prefix: "retired-layout-workspaces")
        defer { suite.remove() }

        let workspace = Workspace(
            name: "Ultrawide",
            screens: [
                Workspace.Screen(
                    screenID: "screen-1",
                    displayUUID: nil,
                    displayName: "Display",
                    templateID: PredefinedTemplates.retiredTwoOneTwoID,
                    slots: []
                )
            ]
        )
        let data = try JSONEncoder().encode([workspace])
        suite.defaults.set(data, forKey: "workspaces.v1")

        let loaded = WorkspaceStorage.load(from: suite.defaults)
        #expect(loaded.first?.screens.first?.templateID == PredefinedTemplates.centerSplitSidebars.id)
    }

    @Test("Template hotkeys migrate retired 2+1+2 without overriding an existing Center + Split Sides shortcut")
    @MainActor
    func templateHotkeysMigrateRetiredID() {
        let retiredOnly = [
            TemplateHotkey(
                templateID: PredefinedTemplates.retiredTwoOneTwoID,
                templateName: "2+1+2",
                keyCode: 0x17,
                modifiers: 0x1800
            )
        ]
        let migrated = TemplateHotkeyStorage.migratedHotkeys(retiredOnly)
        #expect(migrated.count == 1)
        #expect(migrated[0].templateID == PredefinedTemplates.centerSplitSidebars.id)
        #expect(migrated[0].templateName == PredefinedTemplates.centerSplitSidebars.name)
        #expect(migrated[0].keyCode == 0x17)

        let bothPresent = [
            TemplateHotkey(
                templateID: PredefinedTemplates.retiredTwoOneTwoID,
                templateName: "2+1+2",
                keyCode: 0x17,
                modifiers: 0x1800
            ),
            TemplateHotkey(
                templateID: PredefinedTemplates.centerSplitSidebars.id,
                templateName: PredefinedTemplates.centerSplitSidebars.name,
                keyCode: 0x16,
                modifiers: 0x1800
            ),
        ]
        let deduped = TemplateHotkeyStorage.migratedHotkeys(bothPresent)
        #expect(deduped.count == 1)
        #expect(deduped[0].templateID == PredefinedTemplates.centerSplitSidebars.id)
        #expect(deduped[0].keyCode == 0x16)
    }
}
