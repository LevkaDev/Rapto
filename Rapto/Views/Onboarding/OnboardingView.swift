//
//  OnboardingView.swift
//  Rapto
//
//  Focused first-launch onboarding:
//  1. Welcome & Accessibility (no Screen Recording wall up front)
//  2. Auto-tuned Setup for this Mac + Mode choice (pre-selected, no "None" exit)
//  3. Optional macOS Tiling step (only when Stage Manager or Drag-to-Snap edge conflict is on)
//  4. Quick Start: Arrange My Windows (with Undo) or Sample Windows, Launch at Login, Start Short Tour
//

import Combine
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcomePermissions
    case setup
    case macTiling
    case quickStart

    var id: Int { rawValue }
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    let onComplete: () -> Void
    var onStartTour: ((TilingMode, Bool) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingStep = .welcomePermissions
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    @State private var didAskAccessibility = false
    @State private var chosenMode: TilingMode = DisplayProfile.dominant(for: NSScreen.screens).recommendedStarterMode
    @State private var hoveredMode: TilingMode?
    @State private var autoTilingMaxWindows = OnboardingView.suggestedMaxWindows()
    @State private var shortcuts = OnboardingShortcuts()
    @State private var macTilingOptions = MacOSTiling.enabledOptions()
    @State private var didArrangeDuringOnboarding = false
    @State private var didUndoArrange = false

    private var dominantProfile: DisplayProfile {
        DisplayProfile.dominant(for: appState.screenManager.allScreens())
    }

    /// Only warn about macOS tiling when it actually fights the chosen setup:
    /// Stage Manager fights every mode; macOS edge tiling fights Drag to Snap.
    private var showsMacTilingStep: Bool {
        if macTilingOptions.contains(.stageManager) { return true }
        return chosenMode == .dragSnap && !macTilingOptions.isEmpty
    }

    private var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .macTiling || showsMacTilingStep }
    }

    static let stageHeight: CGFloat = 225

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStage(clip: clip) { stage }
                .frame(height: Self.stageHeight)
                .ignoresSafeArea(edges: .top)

            stepContent
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(currentStep)
                .transition(stepTransition)

            Divider()

            navigation
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            shortcuts = OnboardingShortcuts()
            if appState.currentMode != .none {
                chosenMode = appState.currentMode
            } else {
                chosenMode = dominantProfile.recommendedStarterMode
            }
            if appState.hasCompletedOnboarding {
                autoTilingMaxWindows = appState.autoTilingPreferences.maxWindows
            } else {
                autoTilingMaxWindows = dominantProfile.suggestedMaxWindows
            }
        }
        .task(id: currentStep) {
            guard currentStep == .welcomePermissions || currentStep == .macTiling else { return }
            while !Task.isCancelled {
                if currentStep == .welcomePermissions { checkPermissions() } else { checkMacTiling() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
            checkMacTiling()
        }
    }

    // MARK: - Stage

    private var clip: OnboardingClip? {
        switch currentStep {
        case .welcomePermissions:
            return hasAccessibilityPermission ? .welcome : nil
        case .setup:
            return .forMode(hoveredMode ?? chosenMode)
        case .macTiling:
            return nil
        case .quickStart:
            return .forMode(chosenMode)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch currentStep {
        case .welcomePermissions:
            PermissionDemo(isGranted: hasAccessibilityPermission)
        case .macTiling:
            MacTilingDemo(enabled: macTilingOptions)
        default:
            EmptyView()
        }
    }

    // MARK: - Step

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcomePermissions:
            WelcomeAccessibilityStepView(
                hasAccessibility: hasAccessibilityPermission,
                onRequestAccessibility: requestAccessibilityPermission
            )
        case .setup:
            AutoTunedModeStepView(
                selection: $chosenMode,
                hovered: $hoveredMode,
                maxWindows: $autoTilingMaxWindows,
                suggestedMaxWindows: Self.suggestedMaxWindows(),
                overlayShortcut: shortcuts.overlay,
                autoTuneSummary: dominantProfile.autoTuneSummary(
                    screenCount: appState.screenManager.screenCount,
                    desktopCount: appState.desktopCountOnActiveScreen
                )
            )
        case .macTiling:
            MacTilingStepView(enabled: macTilingOptions, onOpenSettings: { MacOSTiling.openSettings() })
        case .quickStart:
            QuickStartStepView(
                mode: chosenMode,
                didArrange: $didArrangeDuringOnboarding,
                onArrange: {
                    applyModePreferences()
                    let arranged = appState.arrangeWindowsForFirstRun(mode: chosenMode)
                    if arranged {
                        didUndoArrange = false
                    }
                    return arranged
                },
                onUndo: {
                    appState.undoFirstRunArrange()
                    didArrangeDuringOnboarding = false
                    didUndoArrange = true
                }
            )
        }
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    // MARK: - Navigation

    private var navigation: some View {
        HStack(spacing: 12) {
            progressDots

            Spacer()

            if currentStep == .macTiling && !macTilingOptions.isEmpty {
                Button("Skip for Now", action: goForward)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if currentStep == .quickStart {
                Button("Done") {
                    finishOnboardingWithoutTour()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if currentStep != .welcomePermissions {
                Button("Back", action: goBack)
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
        }
        .controlSize(.large)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                Capsule()
                    .fill(step == currentStep ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(step.rawValue < currentStep.rawValue ? 0.35 : 0.15)))
                    .frame(width: step == currentStep ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((steps.firstIndex(of: currentStep) ?? 0) + 1) of \(steps.count)")
    }

    private var primaryTitle: String {
        switch currentStep {
        case .welcomePermissions: return hasAccessibilityPermission ? "Continue" : "Allow Accessibility…"
        case .quickStart: return "Start Short Tour"
        default: return "Continue"
        }
    }

    private var canProceed: Bool {
        true
    }

    private func primaryAction() {
        switch currentStep {
        case .welcomePermissions:
            if hasAccessibilityPermission {
                goForward()
            } else {
                requestAccessibilityPermission()
            }
        case .setup:
            // Wait until Quick Start (Arrange Now / Start Short Tour / Done) to switch the active
            // desktop's mode so tiling doesn't raise user windows on top of onboarding mid-flow.
            goForward()
        case .macTiling:
            goForward()
        case .quickStart:
            startShortTour()
        }
    }

    private func finishOnboardingWithoutTour() {
        applyModePreferences()
        if !didArrangeDuringOnboarding && !didUndoArrange {
            applyChosenModeToAllScreens()
        }
        onComplete()
    }

    private func startShortTour() {
        applyModePreferences()
        // For Drag to Snap, activate immediately (it never moves existing windows).
        // For Manual / Auto-tiling, if the user didn't click Arrange Now yet, the tour's own
        // first task ("Arrange your open windows") activates it on demand with Undo support.
        if chosenMode == .dragSnap || didArrangeDuringOnboarding {
            applyChosenModeToAllScreens()
        }
        if let onStartTour {
            onStartTour(chosenMode, didArrangeDuringOnboarding)
        } else {
            onComplete()
        }
    }

    private func goForward() {
        guard let index = steps.firstIndex(of: currentStep), index + 1 < steps.count else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { currentStep = steps[index + 1] }
    }

    private func goBack() {
        guard let index = steps.firstIndex(of: currentStep), index > 0 else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { currentStep = steps[index - 1] }
    }

    private func checkMacTiling() {
        let options = MacOSTiling.enabledOptions()
        guard options != macTilingOptions else { return }
        macTilingOptions = options
        debugLog("Onboarding", "macOS tiling options on: \(options.map(\.rawValue))")
    }

    // MARK: - Mode

    /// Saves the chosen mode defaults and Auto-tiling limits without moving windows on screen yet.
    private func applyModePreferences() {
        let mode = chosenMode
        if mode == .autoTiling {
            let dominant = DisplayProfile.dominant(for: appState.screenManager.allScreens())
            var prefs = appState.autoTilingPreferences
            prefs.maxWindows = autoTilingMaxWindows
            if !appState.hasCompletedOnboarding {
                prefs.templateFor1Window = dominant.suggestedSingleWindowTemplateID
            }
            if prefs != appState.autoTilingPreferences {
                appState.autoTilingPreferences = prefs
                debugLog("Onboarding", "Auto Tiling windows on screen: \(autoTilingMaxWindows)")
            }
            appState.applyPerScreenAutoTilingOverrides(dominantMaxWindows: autoTilingMaxWindows)
        }
        appState.defaultModeForNewSpaces = mode
        debugLog("Onboarding", "Chose mode \(mode.rawValue)")
    }

    /// Turns the chosen mode on across connected screens that aren't already in it.
    private func applyChosenModeToAllScreens() {
        let mode = chosenMode
        for screen in appState.screenManager.allScreens() where appState.mode(for: screen) != mode {
            appState.setMode(mode, for: screen)
        }
    }

    static func suggestedMaxWindows() -> Int {
        DisplayProfile.dominant(for: NSScreen.screens).suggestedMaxWindows
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let hadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()

        if !hadAccessibility && hasAccessibilityPermission && currentStep == .welcomePermissions {
            NSApp.activate()
        }
    }

    /// macOS shows its permission prompt only once, so later clicks open System Settings instead
    private func requestAccessibilityPermission() {
        if didAskAccessibility {
            openPrivacySettings("Privacy_Accessibility")
        } else {
            didAskAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .frame(width: 700, height: 600)
}
