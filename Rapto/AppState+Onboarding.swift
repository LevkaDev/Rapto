//
//  AppState+Onboarding.swift
//  Rapto
//
//  First launch, Setup Guide starter profiles, and hint resets.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

extension Notification.Name {
    static let raptoHintsDidReset = Notification.Name("raptoHintsDidReset")
}

extension AppState {
    // MARK: - Onboarding

    static let firstOnboardingCompletedAtKey = "firstOnboardingCompletedAt"

    func showOnboarding() {
        if isOnboardingVisible {
            OnboardingWindowController.shared.show(appState: self)
        }
        isOnboardingVisible = true
    }

    func completeOnboarding(launchingTour: Bool = false) {
        hasCompletedOnboarding = true
        if UserDefaults.standard.object(forKey: Self.firstOnboardingCompletedAtKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.firstOnboardingCompletedAtKey)
        }
        isOnboardingVisible = false
        debugLog("AppState", " Onboarding completed (launchingTour=\(launchingTour))")
        if !launchingTour {
            closeTourSandboxWindows()
            clearFirstRunArrangeUndo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showNotchDesktopsBarHintIfNeeded()
            }
        }
    }

    // MARK: - First-Run Arrange, Undo & Interactive Tour Helpers

    /// True when at least one connected screen hides the Desktops Bar under its notch.
    var hasNotchedHoverBar: Bool {
        showsSpaceBar
            && spaceBarPresentation != .always
            && screenManager.allScreens().contains { spaceBarController.notchAnchor(on: $0) != nil }
    }

    /// Number of regular macOS desktops currently on the active screen.
    var desktopCountOnActiveScreen: Int {
        let displayID = screenManager.displayIdentifier(for: screenManager.activeScreen())
        if let display = spaceBarController.displays.first(where: { $0.id == displayID }) {
            return max(1, display.spaces.filter { !$0.isFullScreen }.count)
        }
        return 1
    }

    /// Movable, tilable windows currently visible on `screen` (including active tour sample windows).
    func eligibleWindowsForFirstArrange(on screen: NSScreen) -> [WindowInfo] {
        let all = windowManager.enumerateWindows()
        let onScreen = filterWindowsOnScreen(all, screen: screen)
        let minSize = WindowManager.minimumTilableSize
        return onScreen.filter { window in
            guard window.frame.width >= minSize && window.frame.height >= minSize else { return false }
            return WindowClassifier.shared.isTilable(window)
        }
    }

    /// Snapshots the current positions of open windows on the active screen and neatly lays them out
    /// so new users see immediate value during first-run setup, with one-click Undo.
    @discardableResult
    func arrangeWindowsForFirstRun(mode: TilingMode) -> Bool {
        let screen = screenManager.activeScreen()
        let windows = eligibleWindowsForFirstArrange(on: screen)
        guard !windows.isEmpty else { return false }

        if preArrangeWindowFrames.isEmpty {
            for window in windows {
                preArrangeWindowFrames[window.windowID] = window.frame
            }
        }

        let effectiveMode: TilingMode = (mode == .none) ? DisplayProfile.forScreen(screen).recommendedStarterMode : mode
        switch effectiveMode {
        case .autoTiling:
            if self.mode(for: screen) != .autoTiling {
                setMode(.autoTiling, for: screen)
            } else {
                autoTilingService?.redistributeNow(forScreenID: screenManager.identifier(for: screen))
            }
        case .manualAssignment:
            let template = DisplayProfile.forScreen(screen).suggestedManualTemplate
            applyTemplateToScreen(template: template, screen: screen)
        case .dragSnap, .none:
            let profile = DisplayProfile.forScreen(screen)
            let template: GridTemplate = windows.count == 1
                ? PredefinedTemplates.full
                : (windows.count == 2 ? PredefinedTemplates.halvesVertical : profile.suggestedManualTemplate)
            let visible = screenManager.visibleFrame(for: screen)
            let zones = template.zones.sorted { $0.fillOrder < $1.fillOrder }
            for (index, window) in windows.prefix(zones.count).enumerated() {
                let appKitFrame = screenManager.calculateAbsoluteFrame(relativeFrame: zones[index].relativeFrame, in: visible)
                let cgFrame = screenManager.convertToCGCoordinates(frame: appKitFrame, for: screen)
                _ = accessibilityService.setWindowFrame(window, frame: cgFrame)
            }
        }

        hasUndoableFirstArrange = !preArrangeWindowFrames.isEmpty
        return true
    }

    /// Restores every window moved by `arrangeWindowsForFirstRun` to its exact pre-arrange frame.
    func undoFirstRunArrange() {
        guard !preArrangeWindowFrames.isEmpty else { return }
        let saved = preArrangeWindowFrames
        clearFirstRunArrangeUndo()
        let current = windowManager.enumerateWindows()
        for (windowID, frame) in saved {
            guard let window = current.first(where: { $0.windowID == windowID }) else { continue }
            _ = accessibilityService.setWindowFrame(window, frame: frame)
        }
    }

    func clearFirstRunArrangeUndo() {
        preArrangeWindowFrames.removeAll()
        hasUndoableFirstArrange = false
    }

    func openTourSandboxWindows() {
        TourSandboxWindows.shared.openSamplePair(on: screenManager.activeScreen())
    }

    func closeTourSandboxWindows() {
        TourSandboxWindows.shared.closeAll()
    }

    func resetOnboardingForDebug() {
        hasCompletedOnboarding = false
        debugLog("AppState", " Onboarding reset for debugging")
    }

    func checkAndShowOnboardingIfNeeded() {
        if !hasCompletedOnboarding {
            // Delay slightly to let the app fully initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isOnboardingVisible = true
                debugLog("AppState", " Showing onboarding (first launch)")
            }
        }
    }

    // MARK: - Setup Guide & Starter Profiles

    /// Applies one of the three starter profiles from Settings → Guide:
    /// sets the mode on all connected displays and for newly created desktops,
    /// tunes Auto-tiling for the connected displays, sets 4 px window & screen-edge gaps,
    /// and configures mode-appropriate border defaults.
    func applyStarterProfile(_ mode: TilingMode) {
        guard mode != .none else { return }

        if mode == .autoTiling {
            let screens = screenManager.allScreens()
            let dominant = DisplayProfile.dominant(for: screens)
            var prefs = autoTilingPreferences
            prefs.maxWindows = dominant.suggestedMaxWindows
            prefs.templateFor1Window = dominant.suggestedSingleWindowTemplateID
            autoTilingPreferences = prefs
            applyPerScreenAutoTilingOverrides(dominantMaxWindows: dominant.suggestedMaxWindows)
        }

        setWindowGap(Self.defaultGap)
        setScreenEdgeGap(Self.defaultGap)

        switch mode {
        case .dragSnap:
            disableHighlightInDragSnapMode = true
        case .manualAssignment, .autoTiling:
            highlightActiveWindow = true
            highlightBorderWidth = 2
        case .none:
            break
        }

        defaultModeForNewSpaces = mode
        for screen in screenManager.allScreens() where self.mode(for: screen) != mode {
            setMode(mode, for: screen)
        }
        updateHighlightForCurrentMode()
        debugLog("AppState", " Applied starter profile: \(mode.rawValue)")
    }

    /// In multi-monitor setups (e.g. a MacBook paired with a wide monitor), gives narrower screens
    /// their own smaller Auto-tiling window limit so windows aren't crushed on the smaller display.
    func applyPerScreenAutoTilingOverrides(dominantMaxWindows: Int) {
        let screens = screenManager.allScreens()
        guard screens.count > 1 else { return }
        for screen in screens {
            let screenMax = DisplayProfile.forScreen(screen).suggestedMaxWindows
            let screenID = screenManager.identifier(for: screen)
            if screenMax < dominantMaxWindows && autoTilingMaxWindows(forScreenID: screenID) == nil {
                setAutoTilingMaxWindows(screenMax, forScreenID: screenID)
            }
        }
    }

    /// Hides a suggested app chip in Guide's Smart App Scanner on this Mac.
    func dismissAppSuggestion(_ bundleIdentifier: String) {
        dismissedAppSuggestions.insert(bundleIdentifier)
    }

    func restoreDismissedAppSuggestions() {
        dismissedAppSuggestions.removeAll()
    }

    /// Clears shown contextual tips and modifier usage counters so in-action hints appear again.
    func resetHints() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "shownHints")
        defaults.removeObject(forKey: OneTimeHintScheduler.countsDefaultsKey)
        defaults.removeObject(forKey: "hintKeyUses")
        showsHints = true
        oneTimeHints.reset()
        NotificationCenter.default.post(name: .raptoHintsDidReset, object: nil)
        debugLog("AppState", " Reset shown hints and key usage counters")
    }

    // MARK: - Contextual One-Time Hints

    /// Live display string for an action in the user's active shortcut preset, or `nil` when unbound.
    func shortcutDisplayString(for action: HotkeyAction) -> String? {
        HotkeyPresetStorage().loadCurrentPreset().bindings[action]?.displayString
    }

    func didEnterManualWithoutSavedTemplate(on screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        oneTimeHints.showOnce(
            .manualNeedsLayout,
            content: { [weak self] in
                OneTimeHintCopy.manualNeedsLayout(overlayShortcut: self?.shortcutDisplayString(for: .openOverlay))
            },
            placement: { [weak self] in
                guard let self, let resolvedScreen = self.screenManager.screen(for: screenID) else { return nil }
                return (.below(self.spaceBarController.barAnchor(on: resolvedScreen)), resolvedScreen)
            },
            stillValid: { [weak self] in
                guard let self,
                      !self.isOnboardingVisible,
                      !self.isOverlayVisible,
                      let resolvedScreen = self.screenManager.screen(for: screenID) else { return false }
                let currentSpaceID = self.spaceID(for: resolvedScreen)
                return self.mode(for: resolvedScreen) == .manualAssignment
                    && self.configuration(forSpaceID: currentSpaceID, screenID: screenID).templateID == nil
            }
        )
    }

    func didSnapWindowBack(cgSlotFrame: CGRect, screenID: String) {
        oneTimeHints.showOnce(
            .snapBack,
            content: { [weak self] in
                guard let self, let screen = self.screenManager.screen(for: screenID) else {
                    return OneTimeHintCopy.snapBack
                }
                return self.mode(for: screen) == .autoTiling
                    ? OneTimeHintCopy.autoTilingSnapBack
                    : OneTimeHintCopy.snapBack
            },
            placement: { [weak self] in
                guard let self, let screen = self.screenManager.screen(for: screenID) else { return nil }
                let appKitSlotRect = self.screenManager.convertFromCGCoordinates(frame: cgSlotFrame, for: screen)
                return (.insideBottom(appKitSlotRect), screen)
            },
            stillValid: { [weak self] in
                guard let self,
                      !self.isOnboardingVisible,
                      let screen = self.screenManager.screen(for: screenID) else { return false }
                let activeMode = self.mode(for: screen)
                return (activeMode == .manualAssignment || activeMode == .autoTiling)
                    && self.layoutManager.state(forScreenID: screenID).isActive
            }
        )
    }

    func didShowGroupBadge(frame: NSRect, screenID: String) {
        oneTimeHints.showOnce(
            .groupBadge,
            content: { [weak self] in
                guard let self else { return OneTimeHintCopy.groupBadge(enableScroll: true, cycleShortcut: nil) }
                return OneTimeHintCopy.groupBadge(
                    enableScroll: self.enableScrollToSwitch,
                    cycleShortcut: self.shortcutDisplayString(for: .cycleGroupForward)
                )
            },
            placement: { [weak self] in
                guard let self, let screen = self.screenManager.screen(for: screenID) else { return nil }
                return (.below(frame), screen)
            },
            stillValid: { [weak self] in
                guard let self, !self.isOnboardingVisible, !self.groupIndicatorsHidden else { return false }
                return self.layoutManager.state(forScreenID: screenID).slots.contains(where: \.hasGroup)
            }
        )
    }

    func didRevealNotchDesktopsBar() {
        oneTimeHints.markCompleted(.notchDesktopsBar)
    }

    /// Points to the notch on MacBooks where the Desktops Bar is hidden until hovered (max 2 times,
    /// retired immediately once the user hovers the notch and reveals the bar).
    func showNotchDesktopsBarHintIfNeeded(force: Bool = false) {
        guard !isOnboardingVisible, showsSpaceBar, spaceBarPresentation != .always else { return }
        let orderedScreens = [screenManager.activeScreen()] + screenManager.allScreens().filter { $0 != screenManager.activeScreen() }
        guard let targetScreen = orderedScreens.first(where: { spaceBarController.notchAnchor(on: $0) != nil }) else {
            return
        }
        let screenID = screenManager.identifier(for: targetScreen)
        if force {
            oneTimeHints.showImmediate(
                .notchDesktopsBar,
                content: OneTimeHintCopy.notchDesktopsBar,
                placement: { [weak self] in
                    guard let self,
                          let screen = self.screenManager.screen(for: screenID),
                          let notchRect = self.spaceBarController.notchAnchor(on: screen) else { return nil }
                    return (.belowNotch(notchRect), screen)
                },
                autoHideAfter: 16
            )
            return
        }
        oneTimeHints.showOnce(
            .notchDesktopsBar,
            content: { OneTimeHintCopy.notchDesktopsBar },
            placement: { [weak self] in
                guard let self,
                      let screen = self.screenManager.screen(for: screenID),
                      let notchRect = self.spaceBarController.notchAnchor(on: screen) else { return nil }
                return (.belowNotch(notchRect), screen)
            },
            stillValid: { [weak self] in
                guard let self,
                      !self.isOnboardingVisible,
                      self.showsSpaceBar,
                      self.spaceBarPresentation != .always,
                      let screen = self.screenManager.screen(for: screenID) else { return false }
                return self.spaceBarController.notchAnchor(on: screen) != nil
            },
            autoHideAfter: 12
        )
    }

    func didExpandFocusModeWindow(windowID: CGWindowID, targetFrame: CGRect, on screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        oneTimeHints.showOnce(
            .focusMode,
            content: { [weak self] in
                guard let self else {
                    return OneTimeHintCopy.focusMode(doubleTapEnabled: true, modifierSymbol: "⌥", shortcut: nil)
                }
                return OneTimeHintCopy.focusMode(
                    doubleTapEnabled: self.focusModeDoubleTapEnabled,
                    modifierSymbol: GuideGestureCopy.shortSymbol(for: self.focusModeDoubleTapModifier),
                    shortcut: self.shortcutDisplayString(for: .toggleFullscreen)
                )
            },
            placement: { [weak self] in
                guard let self, let resolvedScreen = self.screenManager.screen(for: screenID) else { return nil }
                return (.insideTop(targetFrame), resolvedScreen)
            },
            stillValid: { [weak self] in
                guard let self, !self.isOnboardingVisible else { return false }
                return self.focusModeService?.isFocusedWindow(windowID) == true
            }
        )
    }

    /// Number of Fine-Tune checklist items (out of 4) currently satisfied in Settings → Guide.
    var setupGuideCompletedStepsCount: Int {
        var count = 0
        if !passthroughApps.isEmpty || ignoredApps != Self.defaultIgnoredApps || !dismissedAppSuggestions.isEmpty || detectedNoPassthroughApps {
            count += 1
        }
        if defaultModeForNewSpaces != .none {
            count += 1
        }
        if UserDefaults.standard.object(forKey: "windowGap") != nil || defaultModeForNewSpaces != .none {
            count += 1
        }
        if LaunchAtLoginManager.shared.isEnabled {
            count += 1
        }
        return count
    }
}
