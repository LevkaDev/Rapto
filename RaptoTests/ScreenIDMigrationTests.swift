//
//  ScreenIDMigrationTests.swift
//  RaptoTests
//
//  Which stable display id each old "display-<number>" id is moved to.
//

import Testing
import Foundation
@testable import Rapto

@Suite("Screen ID Migration Tests")
struct ScreenIDMigrationTests {

    @Test("A workspace record beats another display that has the old number now")
    func workspaceRecordWins() {
        let mapping = ScreenIDMigration.legacyMapping(
            connected: [(legacyID: "display-3", stableID: "display-NEW")],
            workspaceScreens: [["screenID": "display-3", "displayUUID": "OLD"]],
            legacyIDsForOnlyDisplay: [],
            onlyDisplay: nil
        )
        #expect(mapping["display-3"] == "display-OLD")
    }

    @Test("Without a record, a display's current number maps to it")
    func currentNumberWithoutRecord() {
        let mapping = ScreenIDMigration.legacyMapping(
            connected: [(legacyID: "display-3", stableID: "display-A"), (legacyID: "display-5", stableID: "display-B")],
            workspaceScreens: [["screenID": "display-7", "displayUUID": "C"]],
            legacyIDsForOnlyDisplay: [],
            onlyDisplay: nil
        )
        #expect(mapping == ["display-3": "display-A", "display-5": "display-B", "display-7": "display-C"])
    }

    @Test("Records without a display UUID or with a stable id are ignored")
    func unusableRecordsIgnored() {
        let mapping = ScreenIDMigration.legacyMapping(
            connected: [(legacyID: "display-3", stableID: "display-A")],
            workspaceScreens: [
                ["screenID": "display-3", "displayUUID": ""],
                ["screenID": "display-3"],
                ["screenID": "display-X", "displayUUID": "Y"],
            ],
            legacyIDsForOnlyDisplay: [],
            onlyDisplay: nil
        )
        #expect(mapping == ["display-3": "display-A"])
    }

    @Test("On the first run with one display, every older number goes to it")
    func onlyDisplayTakesTheRest() {
        let mapping = ScreenIDMigration.legacyMapping(
            connected: [(legacyID: "display-3", stableID: "display-A")],
            workspaceScreens: [["screenID": "display-4", "displayUUID": "B"]],
            legacyIDsForOnlyDisplay: ["display-4", "display-9"],
            onlyDisplay: "display-A"
        )
        #expect(mapping == ["display-3": "display-A", "display-4": "display-B", "display-9": "display-A"])
    }

    @Test("A display that has no legacy-style id is not mapped")
    func identityNotMapped() {
        let mapping = ScreenIDMigration.legacyMapping(
            connected: [(legacyID: "display-3", stableID: "display-3")],
            workspaceScreens: [],
            legacyIDsForOnlyDisplay: [],
            onlyDisplay: nil
        )
        #expect(mapping.isEmpty)
    }
}
