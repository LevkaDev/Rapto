//
//  TestIsolationTests.swift
//  RaptoTests
//
//  Guards against unit tests writing to the user's debug.log or starting
//  live hotkeys, window watchers, and SpaceManager observers.
//

import Testing
import Foundation
@testable import Rapto

@MainActor
@Suite("Test Isolation Tests")
struct TestIsolationTests {

    @Test("FileLogger allows file logging outside tests and blocks it under XCTest")
    func fileLoggerEnvironmentGuard() {
        #expect(FileLogger.allowsFileLogging(environment: [:]))
        #expect(!FileLogger.allowsFileLogging(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
    }

    @Test("FileLogger refuses to write to debug.log while running unit tests")
    func fileLoggerStaysDisabledInTests() {
        let wasEnabled = FileLogger.shared.isEnabled
        defer {
            FileLogger.shared.isEnabled = wasEnabled
        }

        FileLogger.shared.isEnabled = true
        #expect(!FileLogger.shared.isEnabled)
    }

    @Test("AppState created in tests stays idle without registering hotkeys or starting services")
    func appStateDoesNotStartLiveServicesInTests() {
        let appState = AppState()

        #expect(!appState.startsServices)
        #expect(!appState.hasFinishedLaunchSetup)
        #expect(appState.hotkeyManager.registeredActions.isEmpty)
        #expect(!appState.hotkeyManager.hasGroupCyclingHotkey)
        #expect(appState.spaceManager.currentSpaceID == "default-space")
        #expect(appState.dragSnapService == nil)
        #expect(appState.autoTilingService == nil)
        #expect(appState.windowHighlightService == nil)
    }
}
