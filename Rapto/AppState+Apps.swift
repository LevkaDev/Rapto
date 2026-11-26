//
//  AppState+Apps.swift
//  Rapto
//
//  Ignored and passthrough apps.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

extension AppState {
    // MARK: - Ignored Apps Management

    func saveIgnoredApps() {
        let array = Array(ignoredApps)
        UserDefaults.standard.set(array, forKey: "ignoredApps")
    }

    func loadIgnoredApps() {
        if let savedArray = UserDefaults.standard.stringArray(forKey: "ignoredApps") {
            ignoredApps = Set(savedArray)
        }
        // If nothing saved, keep the default set
        windowManager.ignoredBundleIdentifiers = ignoredApps
        WindowClassifier.shared.userExcludedBundleIDs = ignoredApps
    }

    /// Add an app to the ignore list and immediately release any slots its windows occupy
    func addIgnoredApp(_ bundleIdentifier: String) {
        guard ignoredApps.insert(bundleIdentifier).inserted else { return }
        evictIgnoredAppFromLayouts(bundleIdentifier)
    }

    /// Remove an app from the ignore list and retile Auto-tiling screens immediately
    func removeIgnoredApp(_ bundleIdentifier: String) {
        guard ignoredApps.remove(bundleIdentifier) != nil else { return }
        redistributeAutoTilingScreens()
        windowHighlightService?.refresh()
    }

    func resetIgnoredAppsToDefaults() {
        let previous = ignoredApps
        ignoredApps = AppState.defaultIgnoredApps
        for added in ignoredApps.subtracting(previous) {
            evictIgnoredAppFromLayouts(added)
        }
        if !previous.subtracting(ignoredApps).isEmpty {
            redistributeAutoTilingScreens()
        }
        windowHighlightService?.refresh()
    }

    /// Removes windows belonging to `bundleIdentifier` from Manual slots (promoting grouped windows
    /// into freed slots when available) and triggers Auto-tiling redistribution.
    private func evictIgnoredAppFromLayouts(_ bundleIdentifier: String) {
        let runningPIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier)
        )
        let currentVisibleIDs = Set(windowManager.enumerateWindows().map(\.windowID))
        var removedAnyManualWindow = false

        for screenID in Array(layoutManager.screenStates.keys) where !isAutoTilingScreen(screenID) {
            let screenState = layoutManager.state(forScreenID: screenID)
            let matchingWindowIDs = screenState.slots.flatMap(\.windows).compactMap { window -> CGWindowID? in
                if window.bundleIdentifier == bundleIdentifier || runningPIDs.contains(window.ownerPID) {
                    return window.windowID
                }
                return nil
            }
            guard !matchingWindowIDs.isEmpty else { continue }

            for windowID in matchingWindowIDs {
                layoutManager.removeWindow(windowID, forScreenID: screenID)
                lastKnownWindowIDs.remove(windowID)
                windowIDsAtLayoutApply.remove(windowID)
                autoTilingService?.forgetWindow(windowID)
            }
            removedAnyManualWindow = true

            if isGroupingEnabled {
                promoteGroupedWindowsIntoEmptySlots(on: screenID, visibleWindowIDs: currentVisibleIDs)
            }

            if let screen = screenManager.screen(for: screenID) {
                layoutManager.saveLayoutInfo(forSpaceID: spaceID(for: screen), screenID: screenID)
            }
        }

        if removedAnyManualWindow {
            windowResizeService?.setManagedLayout(windows: layoutManager.allWindows)
            groupIndicatorManager?.updateIndicators()
        }

        redistributeAutoTilingScreens()
        windowHighlightService?.refresh()
    }

    private func promoteGroupedWindowsIntoEmptySlots(on screenID: String, visibleWindowIDs: Set<CGWindowID>) {
        var screenState = layoutManager.state(forScreenID: screenID)
        guard screenState.isActive else { return }

        for slotIndex in screenState.slots.indices where screenState.slots[slotIndex].isEmpty {
            guard let (groupSlotIndex, windowToPromote) = Self.groupWindowToPromote(
                into: slotIndex,
                slots: screenState.slots,
                visibleWindowIDs: visibleWindowIDs
            ) else {
                break
            }
            layoutManager.removeWindow(windowToPromote.windowID, forScreenID: screenID)
            layoutManager.assignWindow(windowToPromote, to: slotIndex, forScreenID: screenID)
            positionWindowInZone(windowToPromote, zoneIndex: slotIndex, forScreenID: screenID)
            debugLog("AppState", " Promoted '\(windowToPromote.title)' from slot \(groupSlotIndex) into freed slot \(slotIndex) on screen \(screenID)")
            screenState = layoutManager.state(forScreenID: screenID)
        }
    }

    private func redistributeAutoTilingScreens() {
        for screen in screenManager.allScreens() where mode(for: screen) == .autoTiling {
            autoTilingService?.redistributeNow(forScreenID: screenManager.identifier(for: screen))
        }
    }

    // MARK: - Passthrough Apps Management

    func savePassthroughApps() {
        let array = Array(passthroughApps)
        UserDefaults.standard.set(array, forKey: "passthroughApps")
    }

    func loadPassthroughApps() {
        if let savedArray = UserDefaults.standard.stringArray(forKey: "passthroughApps") {
            passthroughApps = Set(savedArray)
        } else {
            passthroughApps = AppState.defaultPassthroughApps
        }
    }

    /// Add an app to the passthrough list and update hotkey suspension immediately
    /// (the Desktops Bar is non-activating, so frontmostApp doesn't change on menu clicks).
    func addPassthroughApp(_ bundleIdentifier: String) {
        passthroughApps.insert(bundleIdentifier)
        checkPassthroughState()
    }

    func removePassthroughApp(_ bundleIdentifier: String) {
        passthroughApps.remove(bundleIdentifier)
        checkPassthroughState()
    }

    func isFocusedAppInPassthrough() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            return false
        }
        return passthroughApps.contains(bundleID)
    }

    func resetPassthroughAppsToDefaults() {
        passthroughApps = AppState.defaultPassthroughApps
        checkPassthroughState()
    }

    // MARK: - Passthrough App Monitoring

    func setupPassthroughMonitoring() {
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.checkPassthroughState()
            }
        }

        checkPassthroughState()
    }

    /// Check if Rapto is paused, recording a shortcut, or in a passthrough app and suspend/resume hotkeys
    func checkPassthroughState() {
        if isPaused || isRecordingShortcut || isFocusedAppInPassthrough() {
            if !hotkeyManager.isSuspended {
                hotkeyManager.suspendHotkeys()
                let reason = isPaused ? "paused" : (isRecordingShortcut ? "recording a shortcut" : "passthrough app")
                debugLog("AppState", " Hotkeys suspended (\(reason))")
            }
        } else {
            if hotkeyManager.isSuspended {
                hotkeyManager.resumeHotkeys()
                debugLog("AppState", " Hotkeys resumed")
            }
        }
    }
}
