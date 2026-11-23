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

    func showOnboarding() {
        if isOnboardingVisible {
            OnboardingWindowController.shared.show(appState: self)
        }
        isOnboardingVisible = true
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        isOnboardingVisible = false
        debugLog("AppState", " Onboarding completed")
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
    /// sets 4 px window & screen-edge gaps, and configures mode-appropriate border defaults.
    func applyStarterProfile(_ mode: TilingMode) {
        guard mode != .none else { return }

        if mode == .autoTiling {
            let suggested = OnboardingView.suggestedMaxWindows()
            if autoTilingPreferences.maxWindows != suggested {
                var prefs = autoTilingPreferences
                prefs.maxWindows = suggested
                autoTilingPreferences = prefs
            }
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
            content: { OneTimeHintCopy.snapBack },
            placement: { [weak self] in
                guard let self, let screen = self.screenManager.screen(for: screenID) else { return nil }
                let appKitSlotRect = self.screenManager.convertFromCGCoordinates(frame: cgSlotFrame, for: screen)
                return (.insideBottom(appKitSlotRect), screen)
            },
            stillValid: { [weak self] in
                guard let self,
                      !self.isOnboardingVisible,
                      let screen = self.screenManager.screen(for: screenID) else { return false }
                return self.mode(for: screen) == .manualAssignment
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
        if !passthroughApps.isEmpty || ignoredApps != Self.defaultIgnoredApps || !dismissedAppSuggestions.isEmpty {
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
