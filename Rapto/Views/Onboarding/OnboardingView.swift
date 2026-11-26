//
//  OnboardingView.swift
//  Rapto
//
//  First-launch onboarding: a dark demo stage on top, the step below, navigation at the bottom.
//

import Combine
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case macTiling
    case mode
    case desktopsBar
    case workspaces
    case shortcuts
    case tryIt

    var id: Int { rawValue }
}

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    let onComplete: () -> Void
    var onOpenSetupGuide: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingStep = .welcome
    @State private var hasAccessibilityPermission = AXIsProcessTrusted()
    @State private var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @State private var didAskAccessibility = false
    @State private var didAskScreenRecording = false
    @State private var chosenMode: TilingMode?
    @State private var hoveredMode: TilingMode?
    @State private var autoTilingMaxWindows = OnboardingView.suggestedMaxWindows()
    @State private var completedTasks: Set<OnboardingTask> = []
    @State private var shortcuts = OnboardingShortcuts()
    @State private var macTilingOptions = MacOSTiling.enabledOptions()
    /// Decided once, so the step doesn't vanish while the user turns the options off
    @State private var showsMacTilingStep = !MacOSTiling.enabledOptions().isEmpty

    private var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .macTiling || showsMacTilingStep }
    }

    static let stageHeight: CGFloat = 230

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStage(clip: clip) { stage }
                .frame(height: Self.stageHeight)
                .ignoresSafeArea(edges: .top)

            stepContent
                .padding(.horizontal, 32)
                .padding(.top, 24)
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
            }
            if appState.hasCompletedOnboarding {
                autoTilingMaxWindows = appState.autoTilingPreferences.maxWindows
            }
        }
        .task(id: currentStep) {
            guard currentStep == .permissions || currentStep == .macTiling else { return }
            while !Task.isCancelled {
                if currentStep == .permissions { checkPermissions() } else { checkMacTiling() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
            checkMacTiling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowSwitcherDidOpen).receive(on: RunLoop.main)) { _ in
            markDone(.windowSwitcher)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSnapDidSnap).receive(on: RunLoop.main)) { _ in
            markDone(.dragSnap)
        }
        .onChange(of: appState.isOverlayVisible) { _, isVisible in
            if isVisible { markDone(.layoutOverlay) }
        }
    }

    // MARK: - Stage

    private var clip: OnboardingClip? {
        switch currentStep {
        case .welcome: return .welcome
        case .mode: return .forMode(hoveredMode ?? chosenMode)
        case .desktopsBar: return .desktops
        case .workspaces: return .workspaces
        case .permissions, .macTiling, .shortcuts, .tryIt: return nil
        }
    }

    /// Live demos for the steps that show your own permissions and shortcuts
    @ViewBuilder
    private var stage: some View {
        switch currentStep {
        case .permissions:
            PermissionDemo(isGranted: hasAccessibilityPermission)
        case .macTiling:
            MacTilingDemo(enabled: macTilingOptions)
        case .shortcuts:
            ShortcutsDemo(focusRight: shortcuts.focusRight, focusDown: shortcuts.focusDown, swapLeft: shortcuts.swapLeft)
                .frame(maxWidth: 340)
        case .tryIt:
            WindowSwitcherDemo(shortcut: shortcuts.switcher)
        default:
            EmptyView()
        }
    }

    // MARK: - Step

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WelcomeStepView()
        case .permissions:
            PermissionsStepView(
                hasAccessibility: hasAccessibilityPermission,
                hasScreenRecording: hasScreenRecordingPermission,
                onRequestAccessibility: requestAccessibilityPermission,
                onRequestScreenRecording: requestScreenRecordingPermission
            )
        case .macTiling:
            MacTilingStepView(enabled: macTilingOptions, onOpenSettings: { MacOSTiling.openSettings() })
        case .mode:
            ModeStepView(selection: $chosenMode, hovered: $hoveredMode, maxWindows: $autoTilingMaxWindows, suggestedMaxWindows: Self.suggestedMaxWindows(), overlayShortcut: shortcuts.overlay)
        case .desktopsBar:
            DesktopsBarStepView()
        case .workspaces:
            WorkspacesStepView()
        case .shortcuts:
            ShortcutsStepView(shortcuts: shortcuts, mode: chosenMode)
        case .tryIt:
            TryItStepView(mode: chosenMode, shortcuts: shortcuts, completed: completedTasks)
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

            if currentStep == .mode {
                Button("Decide Later") {
                    chosenMode = nil
                    goForward()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if currentStep == .tryIt {
                Button("Skip for Now", action: onComplete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if currentStep != .welcome {
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
        case .welcome: return "Get Started"
        case .tryIt: return "Open Setup Guide"
        default: return "Continue"
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case .permissions: return hasAccessibilityPermission
        case .mode: return chosenMode != nil
        default: return true
        }
    }

    private func primaryAction() {
        switch currentStep {
        case .mode:
            applyChosenMode()
            goForward()
        case .tryIt:
            if let onOpenSetupGuide {
                onOpenSetupGuide()
            } else {
                onComplete()
            }
        default:
            goForward()
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

    private func markDone(_ task: OnboardingTask) {
        guard currentStep == .tryIt else { return }
        completedTasks.insert(task)
    }

    // MARK: - Mode

    /// Makes the choice the default for every desktop and turns it on for the current one.
    /// Screens already in this mode are left alone, so their slots aren't cleared.
    private func applyChosenMode() {
        guard let mode = chosenMode else { return }
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
        for screen in appState.screenManager.allScreens() where appState.mode(for: screen) != mode {
            appState.setMode(mode, for: screen)
        }
        debugLog("Onboarding", "Chose mode \(mode.rawValue)")
    }

    static func suggestedMaxWindows() -> Int {
        DisplayProfile.dominant(for: NSScreen.screens).suggestedMaxWindows
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let hadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

        if !hadAccessibility && hasAccessibilityPermission && currentStep == .permissions {
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

    private func requestScreenRecordingPermission() {
        if didAskScreenRecording {
            openPrivacySettings("Privacy_ScreenCapture")
        } else {
            didAskScreenRecording = true
            _ = CGRequestScreenCaptureAccess()
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
