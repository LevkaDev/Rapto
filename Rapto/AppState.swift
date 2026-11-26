//
//  AppState.swift
//  Rapto
//
//  Central state management for the Rapto application.
//

import SwiftUI
import Combine
import Carbon
import os.log
import UserNotifications

private let logger = Logger(subsystem: "app.rapto.mac", category: "AppState")

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties
    
    @Published var isOverlayVisible: Bool = false {
        didSet {
            // Suppress mouse events in services when overlay or Window Flow is visible
            // This prevents accidental window dragging while drawing custom zones or browsing
            let suppress = isOverlayVisible || isWindowFlowOpen
            dragSnapService?.suppressMouseEvents = suppress
            windowSwapService?.suppressMouseEvents = suppress
            windowHighlightService?.suppressMouseEvents = suppress
            if isOverlayVisible, hasFinishedLaunchSetup {
                oneTimeHints.hideIfShowing(.manualNeedsLayout)
            }
        }
    }

    private(set) var isWindowFlowOpen: Bool = false
    var activeWindowFlowBinding: HotkeyBinding?
    
    @Published var selectedTemplate: GridTemplate?
    
    @Published var windows: [WindowInfo] = []
    /// Windows the overlay lists apart: they are on the current desktop of another display
    @Published var windowsOnOtherDisplays: [WindowInfo] = []
    
    /// Windows that have been assigned to zones (in order)
    @Published var assignedWindows: [WindowInfo] = []
    
    /// Index of the next zone to be filled
    @Published var currentZoneIndex: Int = 0
    
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted() {
        didSet {
            guard hasAccessibilityPermission != oldValue else { return }
            spaceBarController.hasAccessibilityPermission = hasAccessibilityPermission
        }
    }
    
    // MARK: - Space Management
    
    let spaceManager: SpaceManager
    
    /// Per-Space configurations (mode + template) - LEGACY, kept for backward compatibility
    @Published var spaceConfigurations: [String: SpaceConfiguration] = [:]
    
    // MARK: - Multi-Monitor Support
    
    /// Per-Space-Screen configurations (key: "space:{spaceID}|screen:{screenID}")
    @Published var screenConfigurations: [String: ScreenConfiguration] = [:]
    
    /// Each display can have independent Spaces, so we need the correct spaceID per screen
    func spaceID(for screen: NSScreen) -> String {
        let displayID = screenManager.displayIdentifier(for: screen)
        return spaceManager.currentSpaceID(forDisplayID: displayID) ?? spaceManager.currentSpaceID
    }
    
    /// The current tiling mode for the active Space AND Screen
    var currentMode: TilingMode {
        get {
            return mode(for: screenManager.activeScreen())
        }
        set {
            setMode(newValue, for: screenManager.activeScreen())
        }
    }
    
    /// Get tiling mode for a specific screen (on its current Space)
    func mode(for screen: NSScreen) -> TilingMode {
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        let config = ScreenConfigurationStorage.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        return config.mode
    }

    /// Auto Tiling keeps its own slots in sync, so Manual mode handlers must leave these screens alone
    func isAutoTilingScreen(_ screenID: String) -> Bool {
        guard let screen = screenManager.screen(for: screenID) else { return false }
        return mode(for: screen) == .autoTiling
    }
    
    /// Set tiling mode for a specific screen (on its current Space).
    /// Coming back to Manual brings back the Manual layout the desktop had, unless `restoreManualLayout` is false.
    func setMode(_ mode: TilingMode, for screen: NSScreen, restoreManualLayout: Bool = true) {
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        var config = ScreenConfigurationStorage.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        let previousMode = config.mode
        let hadChosenManualTemplate = config.templateID != nil
            || spaceConfigurations[screenSpaceID]?.templateID != nil
            || (restoreManualLayout && layoutManager.loadManualLayout(forSpaceID: screenSpaceID, screenID: screenID) != nil)
        if config.mode == .manualAssignment && mode != .manualAssignment {
            layoutManager.saveManualLayout(forSpaceID: screenSpaceID, screenID: screenID)
        }
        if !restoreManualLayout {
            layoutManager.removeManualLayout(forSpaceID: screenSpaceID, screenID: screenID)
        }
        config.mode = mode
        ScreenConfigurationStorage.setConfiguration(
            config,
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: &screenConfigurations
        )
        debugLog("AppState", " setMode: screen=\(screenID), spaceID=\(screenSpaceID), mode=\(mode)")
        handleModeChange(to: mode, for: screen)
        if hasFinishedLaunchSetup {
            if mode == .manualAssignment, previousMode != .manualAssignment, !hadChosenManualTemplate {
                didEnterManualWithoutSavedTemplate(on: screen)
            } else if mode != .manualAssignment {
                oneTimeHints.hideIfShowing(.manualNeedsLayout)
            }
        }
    }

    /// Pure rule deciding whether `setMode(targetMode, for: screen)` must run to activate a mode.
    /// Checking `effectiveMode != targetMode` alone fails on a fresh install: setting
    /// `defaultModeForNewSpaces = targetMode` makes `effectiveMode` return `targetMode` via
    /// `ScreenConfiguration.userDefault` even though no service was ever started on the desktop.
    nonisolated static func needsModeActivation(
        targetMode: TilingMode,
        effectiveMode: TilingMode,
        hasExplicitConfig: Bool,
        isServiceRunning: Bool
    ) -> Bool {
        if effectiveMode != targetMode { return true }
        guard targetMode != .none else { return false }
        return !hasExplicitConfig || !isServiceRunning
    }

    /// Ensures `mode` is explicitly stored for `screen`'s current desktop and its service is running,
    /// without clearing an existing layout when the mode is already explicitly active.
    func ensureModeActive(_ mode: TilingMode, on screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        let key = ConfigurationKey.make(spaceID: screenSpaceID, screenID: screenID)
        let hasExplicitConfig = screenConfigurations[key] != nil
        let effectiveMode = self.mode(for: screen)
        let serviceRunning: Bool
        switch mode {
        case .dragSnap:
            serviceRunning = dragSnapService?.isActive(forScreenID: screenID) == true
        case .autoTiling:
            serviceRunning = autoTilingService?.isActive(forScreenID: screenID) == true
        case .manualAssignment:
            serviceRunning = hasExplicitConfig
                && effectiveMode == .manualAssignment
                && (windowSwapService?.isActive == true)
        case .none:
            serviceRunning = true
        }

        if Self.needsModeActivation(
            targetMode: mode,
            effectiveMode: effectiveMode,
            hasExplicitConfig: hasExplicitConfig,
            isServiceRunning: serviceRunning
        ) {
            setMode(mode, for: screen)
        }
    }

    /// Switch a screen to Manual around the layout just placed on it, without tiling its windows again
    func enterManualKeepingLayout(on screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        let screenSpaceID = spaceID(for: screen)
        var config = ScreenConfigurationStorage.configuration(forSpaceID: screenSpaceID, screenID: screenID, in: screenConfigurations)
        guard config.mode != .manualAssignment else { return }
        let previous = config.mode
        dragSnapService?.stop(forScreenID: screenID)
        config.mode = .manualAssignment
        ScreenConfigurationStorage.setConfiguration(config, forSpaceID: screenSpaceID, screenID: screenID, in: &screenConfigurations)
        if !(windowSwapService?.isActive ?? false) {
            windowSwapService?.start()
        }
        if !(windowResizeService?.isActive ?? false) {
            windowResizeService?.start()
        }
        if snapBackEnabled {
            snapBackService?.start(forScreenID: screenID)
        }
        updateHighlightForCurrentMode()
        debugLog("AppState", " A layout from the overlay switched screen \(screenID) from \(previous) to Manual")
    }
    
    func configuration(forSpaceID spaceID: String, screenID: String) -> ScreenConfiguration {
        return ScreenConfigurationStorage.configuration(
            forSpaceID: spaceID,
            screenID: screenID,
            in: screenConfigurations
        )
    }
    
    // MARK: - Per-Screen Auto Tiling Depth
    
    /// Returns nil if using global setting, or the per-screen override
    func autoTilingMaxWindows(forScreenID screenID: String) -> Int? {
        guard let screen = screenManager.screen(for: screenID) else {
            let config = ScreenConfigurationStorage.configuration(
                forSpaceID: spaceManager.currentSpaceID,
                screenID: screenID,
                in: screenConfigurations
            )
            return config.autoTilingMaxWindows
        }
        let screenSpaceID = spaceID(for: screen)
        let config = ScreenConfigurationStorage.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        return config.autoTilingMaxWindows
    }
    
    /// Get effective auto-tiling max windows for a screen (per-screen or global fallback)
    func effectiveAutoTilingMaxWindows(forScreenID screenID: String) -> Int {
        return autoTilingMaxWindows(forScreenID: screenID) ?? autoTilingPreferences.maxWindows
    }
    
    /// Pass nil to use global setting
    func setAutoTilingMaxWindows(_ maxWindows: Int?, forScreenID screenID: String) {
        guard let screen = screenManager.screen(for: screenID) else {
            logger.warning("setAutoTilingMaxWindows: screen not found for \(screenID)")
            return
        }
        let screenSpaceID = spaceID(for: screen)
        var config = ScreenConfigurationStorage.configuration(
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: screenConfigurations
        )
        config.autoTilingMaxWindows = maxWindows
        ScreenConfigurationStorage.setConfiguration(
            config,
            forSpaceID: screenSpaceID,
            screenID: screenID,
            in: &screenConfigurations
        )

        if config.mode == .autoTiling {
            autoTilingService?.redistributeNow(forScreenID: screenID)
        }
        
        logger.info("Set auto-tiling maxWindows for screen \(screenID): \(maxWindows.map { String($0) } ?? "global")")
    }
    
    /// Whether to minimize non-assigned windows after applying layout (Manual mode)
    @Published var minimizeOthersOnApply: Bool = false {
        didSet { UserDefaults.standard.set(minimizeOthersOnApply, forKey: "minimizeOthersOnApply") }
    }
    
    // MARK: - Auto-Tiling Preferences
    
    @Published var autoTilingPreferences: AutoTilingPreferences = .default {
        didSet {
            AutoTilingPreferencesStorage.save(autoTilingPreferences)
            autoTilingService?.preferences = autoTilingPreferences
            if currentMode == .autoTiling {
                autoTilingService?.redistributeNow()
            }
        }
    }
    
    /// Automatically enabled and locked in multi-monitor setups (required for cross-screen move detection)
    @Published var snapBackEnabled: Bool = true {
        didSet {
            if isMultiMonitor && !snapBackEnabled {
                // Re-enable on the next run loop pass, outside this didSet
                DispatchQueue.main.async { [weak self] in
                    self?.snapBackEnabled = true
                }
                return
            }
            
            if snapBackEnabled {
                if currentMode == .manualAssignment {
                    snapBackService?.start()
                }
            } else {
                // Only stop the service, don't clear the layout
                // Layout should persist for grouping and other features
                snapBackService?.stop()
            }
        }
    }
    
    var isMultiMonitor: Bool {
        NSScreen.screens.count > 1
    }
    
    /// Whether window swap requires holding Control key (default: true)
    /// If disabled and moveRequiresShift is also disabled, moveRequiresShift will be auto-enabled
    @Published var swapRequiresOption: Bool = true {
        didSet {
            UserDefaults.standard.set(swapRequiresOption, forKey: "swapRequiresOption")
            windowSwapService?.requiresModifierKey = swapRequiresOption
            
            // Swap and move can't both work without a modifier, so re-enable the other one
            if !swapRequiresOption && !moveRequiresShift {
                debugLog("AppState", " ⚠️ Both swap and move modifiers disabled - enabling Shift for move")
                moveRequiresShift = true
            }
        }
    }
    
    /// Whether window move-to-slot requires holding Shift key (default: false - drag works without modifier)
    /// If disabled and swapRequiresOption is also disabled, swapRequiresOption will be auto-enabled
    @Published var moveRequiresShift: Bool = false {
        didSet {
            UserDefaults.standard.set(moveRequiresShift, forKey: "moveRequiresShift")
            windowSwapService?.moveRequiresShift = moveRequiresShift
            
            // Swap and move can't both work without a modifier, so re-enable the other one
            if !moveRequiresShift && !swapRequiresOption {
                debugLog("AppState", " ⚠️ Both swap and move modifiers disabled - enabling Control for swap")
                swapRequiresOption = true
            }
        }
    }
    
    // MARK: - Window Gaps Settings
    
    /// Default window and screen-edge gap in pixels when no value has been saved yet
    nonisolated static let defaultGap: CGFloat = 4

    /// Stored gap in pixels, or `defaultGap` when unset or invalid; keeps an explicit `0`.
    nonisolated static func loadedGap(forKey key: String, from defaults: UserDefaults) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return defaultGap }
        let value = CGFloat(number.doubleValue)
        return value.isFinite && value >= 0 ? value : defaultGap
    }

    /// The gap for an install that has none saved: 0 for one set up before the 4 px default
    /// existed (its windows sat edge to edge and must not move after an update), 4 px for a new one.
    nonisolated static func gapForInstallWithoutSavedGap(hasCompletedOnboarding: Bool) -> CGFloat {
        hasCompletedOnboarding ? 0 : defaultGap
    }

    /// Saves the gap of an install that has none saved, so the answer no longer depends on
    /// whether onboarding is finished: a new install finishes it after its first launch.
    nonisolated static func settleUnsavedGap(forKey key: String, in defaults: UserDefaults) {
        guard defaults.object(forKey: key) == nil else { return }
        let gap = gapForInstallWithoutSavedGap(hasCompletedOnboarding: defaults.bool(forKey: "hasCompletedOnboarding"))
        defaults.set(Double(gap), forKey: key)
    }
    
    /// Gap between windows (in pixels)
    @Published var windowGap: CGFloat = AppState.defaultGap {
        didSet {
            logger.info("AppState windowGap changed to \(self.windowGap)px, updating ScreenManager")
            screenManager.windowGap = windowGap
            UserDefaults.standard.set(windowGap, forKey: "windowGap")
        }
    }
    
    /// Gap from screen edges (in pixels)
    @Published var screenEdgeGap: CGFloat = AppState.defaultGap {
        didSet {
            logger.info("AppState screenEdgeGap changed to \(self.screenEdgeGap)px, updating ScreenManager")
            screenManager.screenEdgeGap = screenEdgeGap
            UserDefaults.standard.set(screenEdgeGap, forKey: "screenEdgeGap")
        }
    }
    
    // MARK: - Active Window Highlight Settings
    
    @Published var highlightActiveWindow: Bool = true {
        didSet {
            UserDefaults.standard.set(highlightActiveWindow, forKey: "highlightActiveWindow")
            updateHighlightForCurrentMode()
        }
    }
    
    @Published var highlightColor: NSColor = .systemBlue {
        didSet {
            let newColor = highlightColor
            // Defer to avoid "Publishing changes from within view updates"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.windowHighlightService?.setColor(newColor)
                self.spaceBarController.currentDesktopColor = newColor
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: newColor, requiringSecureCoding: false) {
                    UserDefaults.standard.set(data, forKey: "highlightColor")
                }
            }
        }
    }
    
    @Published var highlightBorderWidth: CGFloat = 2 {
        didSet {
            let newWidth = highlightBorderWidth
            // Defer to avoid "Publishing changes from within view updates"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.windowHighlightService?.setBorderWidth(newWidth)
                UserDefaults.standard.set(newWidth, forKey: "highlightBorderWidth")
            }
        }
    }
    
    @Published var disableHighlightInDragSnapMode: Bool = true {
        didSet {
            UserDefaults.standard.set(disableHighlightInDragSnapMode, forKey: "disableHighlightInDragSnapMode")
            updateHighlightForCurrentMode()
        }
    }
    
    // MARK: - Focus Mode Settings
    
    @Published var focusModeEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled")
            if focusModeEnabled {
                focusModeService?.start()
                focusModeService?.doubleTapEnabled = focusModeDoubleTapEnabled
                // Hotkey is registered via hotkeyManager in applyHotkeyPreset()
            } else {
                focusModeService?.stop()
            }
        }
    }
    
    /// Whether modifier+double-click on window activates focus mode
    @Published var focusModeDoubleTapEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(focusModeDoubleTapEnabled, forKey: "focusModeDoubleTapEnabled")
            focusModeService?.doubleTapEnabled = focusModeDoubleTapEnabled
        }
    }
    
    @Published var focusModeDoubleTapModifier: FocusModeModifierKey = .option {
        didSet {
            focusModeService?.doubleTapModifier = focusModeDoubleTapModifier
            UserDefaults.standard.set(focusModeDoubleTapModifier.rawValue, forKey: "focusModeDoubleTapModifier")
        }
    }
    
    // MARK: - Floating Window Double-tap Settings
    
    /// Whether modifier+double-click on window toggles floating
    @Published var floatingDoubleTapEnabled: Bool = false {
        didSet {
            floatingWindowService?.doubleTapEnabled = floatingDoubleTapEnabled
            floatingWindowService?.updateDoubleTapMonitoring()
            UserDefaults.standard.set(floatingDoubleTapEnabled, forKey: "floatingDoubleTapEnabled")
        }
    }
    
    @Published var floatingDoubleTapModifier: FloatingModifierKey = .optionCommand {
        didSet {
            floatingWindowService?.doubleTapModifier = floatingDoubleTapModifier
            UserDefaults.standard.set(floatingDoubleTapModifier.rawValue, forKey: "floatingDoubleTapModifier")
        }
    }
    
    /// Custom zone for focus mode (normalized 0-1 rect, relative to visible screen area)
    /// nil means full screen
    @Published var focusModeZone: CGRect? = nil {
        didSet {
            saveFocusModeZone()
            focusModeService?.customZone = focusModeZone
        }
    }
    
    @Published var isSelectingFocusZone: Bool = false
    
    /// Whether the user is creating a custom focus zone (drawing mode)
    @Published var isCreatingFocusZone: Bool = false
    
    // MARK: - New Space Defaults
    
    @Published var defaultModeForNewSpaces: TilingMode = .none {
        didSet {
            UserDefaults.standard.set(defaultModeForNewSpaces.rawValue, forKey: "defaultModeForNewSpaces")
        }
    }
    
    /// Default template ID for new Spaces in Manual mode
    @Published var defaultTemplateForNewSpaces: UUID? = nil {
        didSet {
            if let uuid = defaultTemplateForNewSpaces {
                UserDefaults.standard.set(uuid.uuidString, forKey: "defaultTemplateForNewSpaces")
            } else {
                UserDefaults.standard.removeObject(forKey: "defaultTemplateForNewSpaces")
            }
        }
    }
    
    // MARK: - Debug Logging
    
    /// Logs are written to ~/Library/Logs/Rapto/debug.log
    @Published var enableFileLogging: Bool = false {
        didSet {
            UserDefaults.standard.set(enableFileLogging, forKey: "enableFileLogging")
            FileLogger.shared.isEnabled = enableFileLogging
        }
    }
    
    // MARK: - Ignored Apps Settings
    
    static let defaultIgnoredApps: Set<String> = [
        "com.apple.systempreferences",  // System Settings
        "com.apple.Spotlight",           // Spotlight
        "pl.maketheweb.cleanshotx"       // CleanShot X (screenshot tool)
    ]
    
    /// Bundle identifiers of apps to ignore in window management
    @Published var ignoredApps: Set<String> = AppState.defaultIgnoredApps {
        didSet {
            saveIgnoredApps()
            windowManager.ignoredBundleIdentifiers = ignoredApps
            WindowClassifier.shared.userExcludedBundleIDs = ignoredApps
        }
    }
    
    /// Default passthrough apps (hotkeys disabled when these are focused)
    /// Only MacVim as example - user adds their own apps
    static let defaultPassthroughApps: Set<String> = [
        "org.vim.MacVim"
    ]
    
    /// Bundle identifiers of apps where hotkeys are disabled (passthrough)
    @Published var passthroughApps: Set<String> = [] {
        didSet {
            savePassthroughApps()
        }
    }
    
    // MARK: - Window Grouping Settings
    
    @Published var isGroupingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isGroupingEnabled, forKey: "isGroupingEnabled")
            windowSwapService?.isGroupingEnabled = isGroupingEnabled
            // Group membership itself lives in layoutManager.state.slots
        }
    }
    
    @Published var groupIndicatorSize: GroupIndicatorSize = .large {
        didSet {
            UserDefaults.standard.set(groupIndicatorSize.rawValue, forKey: "groupIndicatorSize")
            groupIndicatorManager?.indicatorSize = groupIndicatorSize
            groupIndicatorManager?.updateIndicators()
        }
    }
    
    /// Whether to use scroll wheel to cycle through grouped windows
    @Published var enableScrollToSwitch: Bool = true {
        didSet {
            UserDefaults.standard.set(enableScrollToSwitch, forKey: "enableScrollToSwitch")
        }
    }
    
    @Published var autoGroupSameApp: Bool = true {
        didSet {
            UserDefaults.standard.set(autoGroupSameApp, forKey: "autoGroupSameApp")
        }
    }
    
    /// Whether to redirect new windows to the monitor where existing app windows are located
    /// When enabled: if you move an app to monitor B and create a new window, it will be moved to monitor B
    /// When disabled: new windows stay where macOS creates them (default macOS behavior)
    @Published var redirectNewWindowsToAppMonitor: Bool = true {
        didSet {
            UserDefaults.standard.set(redirectNewWindowsToAppMonitor, forKey: "redirectNewWindowsToAppMonitor")
        }
    }
    
    /// Whether group indicators are temporarily hidden (toggled via hotkey)
    @Published var groupIndicatorsHidden: Bool = false {
        didSet {
            UserDefaults.standard.set(groupIndicatorsHidden, forKey: "groupIndicatorsHidden")
            groupIndicatorManager?.updateIndicators()
        }
    }
    
    @Published var groupIndicatorPosition: GroupIndicatorPosition = .right {
        didSet {
            UserDefaults.standard.set(groupIndicatorPosition.rawValue, forKey: "groupIndicatorPosition")
            groupIndicatorManager?.hideAll()
            groupIndicatorManager?.updateIndicators()
        }
    }
    
    // MARK: - Onboarding
    
    /// Drives the window here: a scene `onChange` doesn't fire while the menu bar icon is hidden.
    @Published var isOnboardingVisible: Bool = false {
        didSet {
            guard isOnboardingVisible != oldValue else { return }
            if isOnboardingVisible {
                OnboardingWindowController.shared.show(appState: self)
            } else {
                OnboardingWindowController.shared.close()
            }
        }
    }

    /// True while the compact floating interactive tour HUD is open.
    @Published var isInteractiveTourActive: Bool = false

    /// Saved pre-arrange CG window frames and screen mode during onboarding/tour so "Put Back" restores cleanly.
    var preArrangeWindowFrames: [CGWindowID: CGRect] = [:]
    var preArrangeScreenID: String?
    var preArrangeScreenMode: TilingMode?
    @Published var hasUndoableFirstArrange: Bool = false
    
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user finished the Quick Setup checklist in Settings → Guide (local to this Mac)
    @Published var hasCompletedSetupGuide: Bool = UserDefaults.standard.bool(forKey: "hasCompletedSetupGuide") {
        didSet {
            guard hasCompletedSetupGuide != oldValue else { return }
            UserDefaults.standard.set(hasCompletedSetupGuide, forKey: "hasCompletedSetupGuide")
        }
    }

    /// Set by Guide's Smart App Scanner when no terminals, modal editors or VMs are installed,
    /// so everyday users aren't left with an incomplete checklist badge for apps they don't use.
    @Published var detectedNoPassthroughApps: Bool = false

    /// App bundle identifiers hidden by the user in Guide's Smart App Scanner (local to this Mac)
    @Published var dismissedAppSuggestions: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "dismissedAppSuggestions") ?? []
    ) {
        didSet {
            guard dismissedAppSuggestions != oldValue else { return }
            UserDefaults.standard.set(Array(dismissedAppSuggestions).sorted(), forKey: "dismissedAppSuggestions")
        }
    }

    /// Whether in-action hints are shown during dragging and shortcuts (exported in SettingsBackup)
    @Published var showsHints: Bool = (UserDefaults.standard.object(forKey: "showsHints") as? Bool) ?? true {
        didSet {
            guard showsHints != oldValue else { return }
            UserDefaults.standard.set(showsHints, forKey: "showsHints")
            windowSwapService?.showsHints = showsHints
            dragSnapService?.showsHints = showsHints
            spaceBarController.showsHints = showsHints
        }
    }
    
    // MARK: - Custom Grid Creation
    
    @Published var isCreatingCustomGrid: Bool = false
    
    @Published var tempZones: [Zone] = []
    
    @Published var customTemplateName: String = ""
    
    @Published var customTemplates: [GridTemplate] = [] {
        didSet {
            autoTilingService?.allTemplates = allTemplates
        }
    }
    
    /// Saved workspaces: the apps of one desktop and where they go
    /// The first stored setting read at launch, so saved settings are moved to stable display ids here
    @Published var workspaces: [Workspace] = {
        ScreenIDMigration.run()
        return WorkspaceStorage.load()
    }() {
        didSet {
            WorkspaceStorage.save(workspaces)
            if !workspaces.isEmpty {
                oneTimeHints.markCompleted(.workspacesTip)
            }
        }
    }
    
    // MARK: - Template Hotkeys
    
    @Published var templateHotkeys: [TemplateHotkey] = []
    
    // MARK: - Services
    
    let accessibilityService: AccessibilityService
    
    let windowManager: WindowManager
    
    let screenManager: ScreenManager
    
    let hotkeyManager: HotkeyManager
    
    let customTemplateStorage: CustomTemplateStorage
    
    let templateHotkeyStorage: TemplateHotkeyStorage
    
    private(set) var dragSnapService: DragSnapService?
    
    /// Visible area of each screen (CG coordinates) when the screens last changed
    var knownVisibleFrames: [String: CGRect] = [:]
    
    /// Windows macOS refused to move into their slot, retried when the screen is unlocked
    var windowsToPlaceAfterUnlock: [CGWindowID: (zoneIndex: Int, screenID: String)] = [:]
    var screenUnlockObserver: NSObjectProtocol?
    var accessibilityObservers: [NSObjectProtocol] = []
    var accessibilityPollTask: Task<Void, Never>?
    
    private(set) var autoTilingService: AutoTilingService?
    
    private(set) var windowHighlightService: WindowHighlightService?
    
    private(set) var windowSwapService: WindowSwapService?
    
    private(set) var windowResizeService: WindowResizeService?
    
    private(set) var snapBackService: SnapBackService?
    
    private(set) var focusModeService: FocusModeService?
    
    private(set) var floatingWindowService: FloatingWindowService?
    
    /// Keeps apps from also acting on Rapto's modifier + double-clicks
    let doubleClickGuard = DoubleClickGuard()
    
    private(set) var groupIndicatorManager: FloatingGroupIndicatorManager?

    /// Menu-bar pill listing macOS desktops and the apps open on each one
    let spaceBarController: SpaceBarController
    /// Tracks window focus frequency/recency so Window Flow puts frequent windows first
    let windowUsageTracker: WindowUsageTracker
    lazy var windowSwitcher = WindowSwitcherController(spaceBar: spaceBarController)
    lazy var windowFlow: WindowFlowController = {
        let flow = WindowFlowController(
            spaceBar: spaceBarController,
            screenManager: screenManager,
            usageTracker: windowUsageTracker
        )
        flow.toggleBinding = { [weak self] in
            self?.activeWindowFlowBinding
        }
        flow.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.isWindowFlowOpen = visible
            self.spaceBarController.isWindowFlowOpen = visible
            if visible {
                self.oneTimeHints.markCompleted(.manyWindowsFlow)
                NotificationCenter.default.post(name: .raptoTourDidOpenWindowFlow, object: nil)
            }
            self.windowUsageTracker.isSuppressed = visible
            let suppress = visible || self.isOverlayVisible
            self.dragSnapService?.suppressMouseEvents = suppress
            self.windowSwapService?.suppressMouseEvents = suppress
            self.windowHighlightService?.suppressMouseEvents = suppress
        }
        flow.onDidFocusWindow = { [weak self] in
            self?.groupIndicatorManager?.updateIndicators()
        }
        return flow
    }()
    private(set) lazy var oneTimeHints = OneTimeHints(appState: self)
    var hasFinishedLaunchSetup = false

    @Published var showsSpaceBar: Bool = true {
        didSet {
            UserDefaults.standard.set(showsSpaceBar, forKey: "showsSpaceBar")
            spaceBarController.setEnabled(showsSpaceBar)
        }
    }

    /// Temporarily suspends tiling, snapping, window watchers and global shortcuts without
    /// changing any desktop's saved mode or layout. Always starts active on launch.
    @Published var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            handlePauseStateChanged()
        }
    }

    /// New installs show the menu bar icon by default so Rapto stays reachable on notched MacBooks
    /// where the Desktops Bar hides under the notch. Existing installs set up before this default keep it off.
    nonisolated static func menuBarIconForInstallWithoutSavedPreference(hasCompletedOnboarding: Bool) -> Bool {
        !hasCompletedOnboarding
    }

    /// Persists the initial menu bar icon visibility when unset, so finishing onboarding does not flip it.
    nonisolated static func settleUnsavedMenuBarIcon(in defaults: UserDefaults) {
        guard defaults.object(forKey: "showsMenuBarIcon") == nil else { return }
        let show = menuBarIconForInstallWithoutSavedPreference(
            hasCompletedOnboarding: defaults.bool(forKey: "hasCompletedOnboarding")
        )
        defaults.set(show, forKey: "showsMenuBarIcon")
    }

    /// Whether the Rapto icon stays in the menu bar while the desktops pill is shown.
    /// The pill's right-click menu covers the same controls.
    @Published var showsMenuBarIcon: Bool = true {
        didSet {
            guard showsMenuBarIcon != oldValue else { return }
            UserDefaults.standard.set(showsMenuBarIcon, forKey: "showsMenuBarIcon")
        }
    }

    /// When the desktops bar is on screen. Automatic shows it on hover on screens with a notch.
    @Published var spaceBarPresentation: SpaceBarPresentation = .automatic {
        didSet {
            guard spaceBarPresentation != oldValue else { return }
            UserDefaults.standard.set(spaceBarPresentation.rawValue, forKey: "spaceBarPresentation")
            spaceBarController.presentation = spaceBarPresentation
        }
    }

    @Published var spaceBarStyle: SpaceBarStyle = .dark {
        didSet {
            guard spaceBarStyle != oldValue else { return }
            UserDefaults.standard.set(spaceBarStyle.rawValue, forKey: "spaceBarStyle")
            spaceBarController.style = spaceBarStyle
        }
    }

    /// Whether moving a window from the desktops bar takes the user to its new desktop.
    /// Holding Option on drop does the opposite.
    @Published var spaceBarMoveFollowsWindow: Bool = false {
        didSet {
            guard spaceBarMoveFollowsWindow != oldValue else { return }
            UserDefaults.standard.set(spaceBarMoveFollowsWindow, forKey: "spaceBarMoveFollowsWindow")
            spaceBarController.movesFollowWindow = spaceBarMoveFollowsWindow
        }
    }

    /// Without the pill, the icon is the only way into Rapto, so it is always shown then.
    var isMenuBarIconVisible: Bool {
        showsMenuBarIcon || !showsSpaceBar
    }

    // MARK: - Workaround:
    // Cause: SwiftUI writes MenuBarExtra's isInserted in the middle of a scene update.
    //        Publishing from there triggers another update, and the app hangs in a loop.
    // Context: Accept only the user removing the icon (Cmd-drag) while the bar is on,
    //          and apply it after the update.
    func menuBarIconInsertionChanged(_ inserted: Bool) {
        guard !inserted, showsMenuBarIcon, showsSpaceBar else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showsMenuBarIcon, self.showsSpaceBar else { return }
            self.showsMenuBarIcon = false
        }
    }
    
    /// Unified window layout manager (single source of truth)
    private(set) var layoutManager: WindowLayoutManager!
    
    var cancellables = Set<AnyCancellable>()
    
    /// Workspace observers for auto-grouping in manual mode
    var manualModeObservers: [Any] = []
    var manualModeClickMonitor: Any?
    
    /// AX observers for window creation (keyed by PID)
    var axObservers: [pid_t: AXObserver] = [:]
    
    /// Last known window IDs (to detect new windows)
    var lastKnownWindowIDs: Set<CGWindowID> = []
    
    /// Window IDs that existed when layout was applied (should not be auto-grouped)
    var windowIDsAtLayoutApply: Set<CGWindowID> = []

    /// Manual slot each window last had, per desktop key. Filled when the desktops bar moves a window away.
    var spaceBarSlotMemory: [CGWindowID: [String: Int]] = [:]
    /// Windows the desktops bar moved onto a Manual desktop that still need a slot there.
    var spaceBarPendingPlacements: [String: Set<CGWindowID>] = [:]
    
    /// Flag to prevent parallel execution of checkForNewWindows
    var isCheckingForNewWindows: Bool = false
    
    var newWindowCheckWorkItem: DispatchWorkItem?
    
    var indicatorUpdateWorkItem: DispatchWorkItem?
    var integrationCheckWorkItem: DispatchWorkItem?
    var screenLossCheck: Task<Void, Never>?
    /// Screens whose layout was cleared when they went away
    var lostScreenIDs: Set<String> = []
    
    // MARK: - State Used by the Extensions
    // Stored properties of the code in AppState+*.swift: extensions cannot hold them.

    var frontmostAppObserver: NSObjectProtocol?

    /// A shortcut field in Settings is recording: Rapto's hotkeys are off so the keys reach the field
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            checkPassthroughState()
        }
    }

    /// Track the previous Space ID for saving layout on switch
    var previousSpaceID: String = ""

    var previousDisplaySpaceIDs: [String: String] = [:]

    @Published var activeHotkeyPreset: HotkeyPresetType = .rapto

    /// Pending window groups during overlay assignment (zoneID -> [WindowInfo])
    /// Committed to layoutManager.slots in applyLayout()
    var pendingGroups: [UUID: [WindowInfo]] = [:]

    /// Standard layouts the user removed from the lists.
    /// They are only left out of menus and pickers: a desktop that already uses one keeps working.
    @Published var hiddenStandardTemplateIDs: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: AppState.hiddenStandardTemplatesKey) ?? []).compactMap(UUID.init(uuidString:))
    )

    // MARK: - Initialization
    
    init() {
        self.accessibilityService = AccessibilityService()
        self.spaceBarController = SpaceBarController()
        self.windowUsageTracker = WindowUsageTracker(spaceBar: spaceBarController)
        self.windowManager = WindowManager()
        self.screenManager = ScreenManager()
        self.screenManager.windowGap = Self.defaultGap
        self.screenManager.screenEdgeGap = Self.defaultGap
        self.hotkeyManager = HotkeyManager()
        self.customTemplateStorage = CustomTemplateStorage()
        self.templateHotkeyStorage = TemplateHotkeyStorage()
        self.spaceManager = SpaceManager()
        
        // Initialize unified layout manager (must be before services that depend on it)
        self.layoutManager = WindowLayoutManager(screenManager: screenManager)

        self.customTemplates = customTemplateStorage.loadTemplates()
        
        self.dragSnapService = DragSnapService(
            accessibilityService: accessibilityService,
            screenManager: screenManager,
            windowManager: windowManager
        )
        
        self.autoTilingService = AutoTilingService(
            accessibilityService: accessibilityService,
            screenManager: screenManager,
            windowManager: windowManager
        )
        
        // Auto-tiling templates and preferences are set after loadSavedSettings runs
        
        self.windowHighlightService = WindowHighlightService(
            windowManager: windowManager,
            accessibilityService: accessibilityService
        )
        
        self.windowSwapService = WindowSwapService(
            accessibilityService: accessibilityService,
            windowManager: windowManager
        )
        
        self.windowResizeService = WindowResizeService(
            accessibilityService: accessibilityService,
            windowManager: windowManager,
            screenManager: screenManager
        )
        
        self.snapBackService = SnapBackService(
            accessibilityService: accessibilityService,
            screenManager: screenManager,
            windowManager: windowManager,
            layoutManager: layoutManager
        )
        
        self.focusModeService = FocusModeService(
            accessibilityService: accessibilityService,
            screenManager: screenManager,
            windowManager: windowManager
        )
        
        self.floatingWindowService = FloatingWindowService(
            accessibilityService: accessibilityService,
            windowManager: windowManager,
            screenManager: screenManager
        )
        
        // Wire up floating service to snap-back (to skip floating windows)
        self.snapBackService?.floatingWindowService = self.floatingWindowService
        self.snapBackService?.focusModeService = self.focusModeService
        self.snapBackService?.onWindowSnappedBack = { [weak self] cgSlotFrame, screenID in
            self?.didSnapWindowBack(cgSlotFrame: cgSlotFrame, screenID: screenID)
        }
        self.autoTilingService?.onWindowSnappedBack = { [weak self] cgSlotFrame, screenID in
            self?.didSnapWindowBack(cgSlotFrame: cgSlotFrame, screenID: screenID)
        }
        self.focusModeService?.spaceIDForScreen = { [weak self] screen in self?.spaceID(for: screen) ?? "" }
        
        self.groupIndicatorManager = FloatingGroupIndicatorManager(appState: self)
        
        self.autoTilingService?.setLayoutManager(layoutManager)
        self.snapBackService?.setLayoutManager(layoutManager)
        self.windowSwapService?.setLayoutManager(layoutManager)
        
        self.autoTilingService?.isFollowAppToMonitorEnabled = { [weak self] in
            self?.redirectNewWindowsToAppMonitor ?? true
        }
        self.autoTilingService?.isWindowFloating = { [weak self] windowID in
            self?.floatingWindowService?.isFloating(windowID: windowID) == true
        }
        self.autoTilingService?.isWindowFocused = { [weak self] windowID in
            self?.focusModeService?.isFocusedWindow(windowID) == true
        }
        self.autoTilingService?.onFocusedWindowReleased = { [weak self] window in
            self?.focusModeService?.putBackFocusedWindow(window)
        }
        self.autoTilingService?.onFocusEnded = { [weak self] windowID in
            self?.focusModeService?.forgetWindow(windowID)
        }
        self.windowSwapService?.setScreenManager(screenManager)
        self.windowResizeService?.setLayoutManager(layoutManager)
        
        setupCrossScreenMoveCallback()
        
        setupSwapCallback()
        
        setupResizeCoordination()
        
        setupWindowRepositioningSubscription()
        
        setupFocusMode()
        
        // Hide border and group indicators while Mission Control is open
        observeMissionControl()
        
        // Setup floating window service (hotkey registered via preset in applyHotkeyPreset)
        setupFloatingWindowHotkey()
        
        checkAccessibilityPermission()
        startAccessibilityMonitoring()
        
        setupHotkey()
        
        setupPassthroughMonitoring()
        
        UserSession.startMonitoring { [weak self] in
            self?.resyncWindowsAfterSessionReturn()
        }
        observeScreenUnlock()
        
        // Setup mode change observation first
        setupModeObservation()
        
        // Load saved settings (this will trigger mode change handling)
        loadSavedSettings()
        
        // Give auto-tiling service access to all templates AFTER loading custom templates
        self.autoTilingService?.allTemplates = allTemplates
        self.autoTilingService?.preferences = autoTilingPreferences
        
        self.autoTilingService?.getMaxWindowsForScreen = { [weak self] screenID in
            self?.autoTilingMaxWindows(forScreenID: screenID)
        }
        self.autoTilingService?.onLayoutTransition = { [weak self] inTransition in
            if inTransition {
                self?.windowHighlightService?.beginLayoutTransition()
            } else {
                self?.windowHighlightService?.endLayoutTransition()
            }
        }
        
        self.dragSnapService?.layoutZones = { [weak self] screen in
            self?.dragSnapTemplate(for: screen)?.zones.map(\.relativeFrame) ?? []
        }
        
        debugLog("AppState"," Configured AutoTilingService with \(allTemplates.count) templates")
        
        // Setup group cycling hotkeys AFTER loading settings (so isGroupingEnabled is set)
        setupGroupCyclingHotkeys()
        
        loadSavedHotkeyPreset()
        
        loadAndRegisterTemplateHotkeys()
        
        // Activate modes on every screen, not just the active one, so a mode picked
        // on an empty screen also applies to windows opened there later
        applyInitialModesToAllScreens()
        
        if isGroupingEnabled && autoGroupSameApp {
            setupWindowMonitoring()
        }
        
        // Try to restore saved layout for grouping to work on restart
        if isGroupingEnabled && currentMode == .manualAssignment {
            restoreSavedLayout()
        }

        spaceBarController.hasAccessibilityPermission = hasAccessibilityPermission
        spaceBarController.onAccessibilityWarningClicked = { [weak self] in
            guard let self else { return }
            SettingsWindowController.shared.showSettings(appState: self)
        }
        spaceBarController.menuBuilder = { [weak self] space, glyph, displayID in
            self?.makeSpaceBarMenu(for: space, glyph: glyph, displayID: displayID)
        }
        spaceBarController.onWillMoveWindow = { [weak self] windowID, spaceKey, displayID in
            self?.spaceBarWillMoveWindow(windowID, fromSpaceKey: spaceKey, displayID: displayID)
        }
        spaceBarController.onDidMoveWindow = { [weak self] windowID, spaceKey, displayID in
            self?.spaceBarDidMoveWindow(windowID, toSpaceKey: spaceKey, displayID: displayID)
            NotificationCenter.default.post(name: .raptoTourDidMoveWindowToDesktop, object: nil)
        }
        spaceBarController.onUserRevealedHoverBar = { [weak self] in
            self?.didRevealNotchDesktopsBar()
        }
        spaceBarController.onUserUsedDesktopsBar = { [weak self] in
            self?.oneTimeHints.markCompleted(.secondDesktopCreated)
        }
        spaceBarController.onWindowFlowClicked = { [weak self] displayID in
            self?.windowFlow.toggle(onDisplayID: displayID)
        }
        spaceBarController.windowFlowShortcut = activeWindowFlowBinding?.displayString
        NotificationCenter.default.publisher(for: .dragSnapDidSnap)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.maybeShowWindowFlowOrWorkspacesHint(on: self.screenManager.activeScreen())
            }
            .store(in: &cancellables)
        spaceBarController.start(enabled: showsSpaceBar)
        windowUsageTracker.start()

        AppResponsiveness.shared.onStoppedResponding = { [weak self] pid in
            self?.appStoppedResponding(pid)
        }
        AppResponsiveness.shared.onRespondingAgain = { [weak self] pid in
            self?.appIsRespondingAgain(pid)
        }

        // The menu bar icon may be hidden, so onboarding cannot wait for its menu to open.
        checkAndShowOnboardingIfNeeded()
        if hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showNotchDesktopsBarHintIfNeeded()
            }
        }
        UpdaterManager.shared.appState = self
        Scripting.appState = self
        ReleaseNotes.showIfUpdated(appState: self)
        _ = oneTimeHints
        hasFinishedLaunchSetup = true
    }

    deinit {
        accessibilityPollTask?.cancel()
    }
    
    /// Restore saved layout from previous session (for grouping)
    /// Restores layouts for ALL screens, not just the active one
    private func restoreSavedLayout() {
        debugLog("AppState"," Attempting to restore saved layout for all screens...")
        
        let currentWindows = windowManager.enumerateWindows()
        debugLog("AppState"," Found \(currentWindows.count) current windows")
        
        var restoredAny = false
        
        for screen in NSScreen.screens {
            let screenID = screenManager.identifier(for: screen)
            // Use per-screen spaceID (each display can have independent Spaces)
            let screenSpaceID = spaceID(for: screen)
            
            guard let savedInfo = layoutManager.loadSavedLayoutInfo(forSpaceID: screenSpaceID, screenID: screenID) else {
                debugLog("AppState"," No saved layout info for space '\(screenSpaceID)', screen '\(screenID)'")
                continue
            }
            
            guard let template = allTemplates.first(where: { $0.id == savedInfo.templateID }) else {
                debugLog("AppState"," Template not found for screen '\(screenID)': \(savedInfo.templateID)")
                continue
            }
            
            let windowsOnScreen = currentWindows.filter { window in
                let windowScreen = screenManager.screen(for: window)
                return screenManager.identifier(for: windowScreen) == screenID
            }
            
            if layoutManager.restoreLayout(from: savedInfo, template: template, currentWindows: windowsOnScreen, forScreenID: screenID) {
                debugLog("AppState"," ✅ Layout restored for screen '\(screenID)'")
                restoredAny = true
                
                if mode(for: screen) == .manualAssignment && snapBackEnabled {
                    snapBackService?.start(forScreenID: screenID)
                }
                
                let restoredWindows = layoutManager.state(forScreenID: screenID).allWindows
                processUnassignedWindowsAfterRestore(
                    allWindowsOnScreen: windowsOnScreen,
                    restoredWindows: restoredWindows,
                    forScreenID: screenID
                )
            } else {
                debugLog("AppState"," Layout restoration failed for screen '\(screenID)' - no matching windows")
            }
        }
        
        if restoredAny {
            // Update resize service with restored windows for adjacent resize to work
            let restoredWindows = layoutManager.allWindows
            if !restoredWindows.isEmpty {
                windowResizeService?.setManagedLayout(windows: restoredWindows)
                debugLog("AppState"," Set managed layout for resize service with \(restoredWindows.count) windows")
            }
            
            if autoGroupSameApp {
                setupManualModeGroupingObservers()
            }
            
            setupSwapHotkeys()
            
            groupIndicatorManager?.updateIndicators()
        } else {
            debugLog("AppState"," No layouts were restored")
        }
    }
    
    private func loadSavedSettings() {
        let defaults = UserDefaults.standard
        
        if defaults.object(forKey: "showsSpaceBar") != nil {
            showsSpaceBar = defaults.bool(forKey: "showsSpaceBar")
        }
        Self.settleUnsavedMenuBarIcon(in: defaults)
        if defaults.object(forKey: "showsMenuBarIcon") != nil {
            showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon")
        }
        if defaults.object(forKey: "showsHints") != nil {
            showsHints = defaults.bool(forKey: "showsHints")
        }
        windowSwapService?.showsHints = showsHints
        dragSnapService?.showsHints = showsHints
        spaceBarController.showsHints = showsHints
        spaceBarMoveFollowsWindow = defaults.bool(forKey: "spaceBarMoveFollowsWindow")
        spaceBarController.movesFollowWindow = spaceBarMoveFollowsWindow
        if let raw = defaults.string(forKey: "spaceBarPresentation"),
           let presentation = SpaceBarPresentation(rawValue: raw) {
            spaceBarPresentation = presentation
        }
        spaceBarController.presentation = spaceBarPresentation
        if let raw = defaults.string(forKey: "spaceBarStyle"),
           let style = SpaceBarStyle(rawValue: raw) {
            spaceBarStyle = style
        }
        spaceBarController.style = spaceBarStyle

        spaceConfigurations = SpaceConfigurationStorage.load()
        logger.info("Loaded \(self.spaceConfigurations.count) legacy space configurations")
        
        screenConfigurations = ScreenConfigurationStorage.load()
        logger.info("Loaded \(self.screenConfigurations.count) screen configurations")
        
        migrateSpaceToScreenConfigurations()
        
        setupSpaceChangeHandler()
        
        setupScreenChangeHandler()
        
        Self.settleUnsavedGap(forKey: "windowGap", in: defaults)
        Self.settleUnsavedGap(forKey: "screenEdgeGap", in: defaults)
        let savedWindowGap = Self.loadedGap(forKey: "windowGap", from: defaults)
        if savedWindowGap != windowGap {
            windowGap = savedWindowGap
        } else {
            screenManager.windowGap = savedWindowGap
        }
        
        let savedScreenEdgeGap = Self.loadedGap(forKey: "screenEdgeGap", from: defaults)
        if savedScreenEdgeGap != screenEdgeGap {
            screenEdgeGap = savedScreenEdgeGap
        } else {
            screenManager.screenEdgeGap = savedScreenEdgeGap
        }
        
        if defaults.object(forKey: "highlightActiveWindow") != nil {
            highlightActiveWindow = defaults.bool(forKey: "highlightActiveWindow")
        }
        
        if let colorData = defaults.data(forKey: "highlightColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            highlightColor = color
        }
        
        let savedBorderWidth = defaults.double(forKey: "highlightBorderWidth")
        if savedBorderWidth > 0 {
            highlightBorderWidth = savedBorderWidth
        }
        
        if defaults.object(forKey: "disableHighlightInDragSnapMode") != nil {
            disableHighlightInDragSnapMode = defaults.bool(forKey: "disableHighlightInDragSnapMode")
        }
        
        if defaults.object(forKey: "isGroupingEnabled") != nil {
            isGroupingEnabled = defaults.bool(forKey: "isGroupingEnabled")
        }
        windowSwapService?.isGroupingEnabled = isGroupingEnabled
        
        if defaults.object(forKey: "enableScrollToSwitch") != nil {
            enableScrollToSwitch = defaults.bool(forKey: "enableScrollToSwitch")
        }
        
        if defaults.object(forKey: "autoGroupSameApp") != nil {
            autoGroupSameApp = defaults.bool(forKey: "autoGroupSameApp")
        }
        
        if defaults.object(forKey: "redirectNewWindowsToAppMonitor") != nil {
            redirectNewWindowsToAppMonitor = defaults.bool(forKey: "redirectNewWindowsToAppMonitor")
        }
        
        if let savedSizeRaw = defaults.string(forKey: "groupIndicatorSize"),
           let savedSize = GroupIndicatorSize(rawValue: savedSizeRaw) {
            groupIndicatorSize = savedSize
            groupIndicatorManager?.indicatorSize = savedSize
        }
        
        if let savedPositionRaw = defaults.string(forKey: "groupIndicatorPosition"),
           let savedPosition = GroupIndicatorPosition(rawValue: savedPositionRaw) {
            groupIndicatorPosition = savedPosition
        }
        
        if defaults.object(forKey: "groupIndicatorsHidden") != nil {
            groupIndicatorsHidden = defaults.bool(forKey: "groupIndicatorsHidden")
        }
        
        if defaults.object(forKey: "swapRequiresOption") != nil {
            swapRequiresOption = defaults.bool(forKey: "swapRequiresOption")
        }
        windowSwapService?.requiresModifierKey = swapRequiresOption
        
        if defaults.object(forKey: "moveRequiresShift") != nil {
            moveRequiresShift = defaults.bool(forKey: "moveRequiresShift")
        }
        windowSwapService?.moveRequiresShift = moveRequiresShift
        
        // Load template hotkeys (registration happens separately after all services are initialized)
        templateHotkeys = templateHotkeyStorage.loadHotkeys()
        
        loadIgnoredApps()
        
        loadPassthroughApps()
        
        loadFocusModeZone()
        loadFocusModeDoubleTapModifier()
        loadFloatingDoubleTapSettings()
        
        let dominantProfile = DisplayProfile.dominant(for: screenManager.allScreens())
        AutoTilingPreferencesStorage.settleUnsaved(in: defaults, for: dominantProfile)
        autoTilingPreferences = AutoTilingPreferencesStorage.load(from: defaults)
        autoTilingService?.preferences = autoTilingPreferences
        autoTilingService?.allTemplates = allTemplates
        logger.info("Loaded auto-tiling preferences: maxWindows=\(self.autoTilingPreferences.maxWindows)")
        
        if let savedModeRaw = defaults.string(forKey: "defaultModeForNewSpaces"),
           let savedMode = TilingMode(rawValue: savedModeRaw) {
            defaultModeForNewSpaces = savedMode
        }
        
        if let savedTemplateString = defaults.string(forKey: "defaultTemplateForNewSpaces"),
           let savedTemplateID = UUID(uuidString: savedTemplateString) {
            defaultTemplateForNewSpaces = savedTemplateID
        }
        
        if defaults.object(forKey: "enableFileLogging") != nil {
            enableFileLogging = defaults.bool(forKey: "enableFileLogging")
        }
    }
}

