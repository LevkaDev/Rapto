//
//  AppResponsivenessTests.swift
//  RaptoTests
//
//  Telling an app that hangs from one that answers, and what the user is told.
//

import ApplicationServices
import CoreGraphics
import Testing
@testable import Rapto

struct AppResponsivenessTests {

    @Test func requestThatWaitedTheWholeTimeoutIsATimeout() {
        #expect(AppResponsiveness.timedOut(.cannotComplete, waited: 1.0, timeout: 1.0))
        #expect(AppResponsiveness.timedOut(.cannotComplete, waited: 0.95, timeout: 1.0))
    }

    @Test func quickFailureIsNotATimeout() {
        // An element that is gone fails with the same error at once
        #expect(!AppResponsiveness.timedOut(.cannotComplete, waited: 0.01, timeout: 1.0))
        #expect(!AppResponsiveness.timedOut(.cannotComplete, waited: 0.5, timeout: 1.0))
    }

    @Test func slowAnswerIsNotATimeout() {
        #expect(!AppResponsiveness.timedOut(.success, waited: 1.2, timeout: 1.0))
        #expect(!AppResponsiveness.timedOut(.attributeUnsupported, waited: 1.2, timeout: 1.0))
        #expect(!AppResponsiveness.timedOut(.invalidUIElement, waited: 1.2, timeout: 1.0))
    }

    @Test func messageNamesTheApp() {
        #expect(AppResponsiveness.notRespondingMessage(appName: "Gemini")
                == "Gemini is not responding. Rapto will skip its windows until it does.")
    }

    @Test func messageWithoutANameStillReads() {
        let expected = "An app is not responding. Rapto will skip its windows until it does."
        #expect(AppResponsiveness.notRespondingMessage(appName: nil) == expected)
        #expect(AppResponsiveness.notRespondingMessage(appName: "") == expected)
    }

    @Test func skippedAppsAreRememberedOnce() {
        let apps = NotRespondingApps()
        let pid: pid_t = 4242
        #expect(!apps.contains(pid))
        #expect(apps.insert(pid))
        #expect(!apps.insert(pid))
        #expect(apps.contains(pid))
        #expect(apps.remove(pid))
        #expect(!apps.remove(pid))
        #expect(!apps.contains(pid))
    }

    @Test func userIsToldOnlyAfterSeveralMissedProbes() {
        #expect(AppResponsiveness.probesBeforeTelling >= 2)
    }

    @Test func windowInItsSlotIsLeftAlone() {
        let slot = CGRect(x: 1374, y: 34, width: 2461, height: 1544)
        #expect(!AppState.isOffItsSlot(windowFrame: slot, slotFrame: slot))
        // Rounding by the app
        #expect(!AppState.isOffItsSlot(windowFrame: CGRect(x: 1375, y: 34, width: 2460, height: 1545), slotFrame: slot))
    }

    @Test func windowLeftBehindByASwapIsOffItsSlot() {
        let slot = CGRect(x: 1374, y: 34, width: 2461, height: 1544)
        let oldPlace = CGRect(x: 8, y: 34, width: 1342, height: 753)
        #expect(AppState.isOffItsSlot(windowFrame: oldPlace, slotFrame: slot))
    }

    @Test func windowWithTheOldGapIsOffItsSlot() {
        // Same place, the gap grew by 12 pt on every side
        let slot = CGRect(x: 20, y: 46, width: 1318, height: 729)
        let before = CGRect(x: 8, y: 34, width: 1342, height: 753)
        #expect(AppState.isOffItsSlot(windowFrame: before, slotFrame: slot))
    }
}
