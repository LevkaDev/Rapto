//
//  CustomLayoutHintsTests.swift
//  RaptoTests
//
//  Unit tests for CustomLayoutSaveRequirement and custom layout editor save guards.
//

import CoreGraphics
import Foundation
import Testing
@testable import Rapto

@Suite("Custom Layout Editor Hints Tests")
struct CustomLayoutHintsTests {

    @Test("Save requirement explains missing zones first, then missing name, then trims ready name")
    func evaluateSaveRequirement() {
        let noZonesUnnamed = CustomLayoutSaveRequirement.evaluate(zoneCount: 0, layoutName: "")
        #expect(noZonesUnnamed == .needsZones)
        #expect(noZonesUnnamed.statusText == "Click + inside the frame to add Zone 1")
        #expect(noZonesUnnamed.statusIcon == "plus.circle")

        let noZonesNamed = CustomLayoutSaveRequirement.evaluate(zoneCount: 0, layoutName: "Coding")
        #expect(noZonesNamed == .needsZones)

        let unnamedWithZones = CustomLayoutSaveRequirement.evaluate(zoneCount: 2, layoutName: "   ")
        #expect(unnamedWithZones == .needsName)
        #expect(unnamedWithZones.statusText == "Name your layout on the left to save")
        #expect(unnamedWithZones.statusIcon == "character.cursor.ibeam")

        let ready = CustomLayoutSaveRequirement.evaluate(zoneCount: 2, layoutName: "  Ultrawide Dev  ")
        #expect(ready == .ready(trimmedName: "Ultrawide Dev"))
        #expect(ready.statusText == nil)
        #expect(ready.statusIcon == nil)
    }

    @Test("saveCustomTemplate ignores whitespace-only names and preserves draft zones")
    @MainActor
    func saveCustomTemplateRequiresNonBlankName() {
        let appState = AppState()
        appState.startCustomGridCreation()
        appState.addTempZone(Zone(relativeFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1), fillOrder: 0))

        let beforeCount = appState.customTemplates.count
        appState.saveCustomTemplate(name: "   ")

        #expect(appState.customTemplates.count == beforeCount)
        #expect(appState.isCreatingCustomGrid)
        #expect(appState.tempZones.count == 1)
    }
}
