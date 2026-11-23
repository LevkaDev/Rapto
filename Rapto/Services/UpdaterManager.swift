//
//  UpdaterManager.swift
//  Rapto
//
//  Manages automatic updates via Sparkle framework.
//

import Foundation
import Combine
import AppKit
@preconcurrency import UserNotifications

#if canImport(Sparkle)
import Sparkle

private nonisolated let updateNotificationID = "rapto-update-available"

@MainActor
final class UpdaterManager: NSObject, ObservableObject, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    
    static let shared = UpdaterManager()
    
    // MARK: - Properties
    
    private var updaterController: SPUStandardUpdaterController?
    
    /// Stored under Sparkle's own key, SUEnableAutomaticChecks
    @Published var automaticChecksEnabled: Bool = true {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticChecksEnabled
            UserDefaults.standard.set(automaticChecksEnabled, forKey: "SUEnableAutomaticChecks")
        }
    }
    
    /// Shown in Settings
    @Published var lastCheckDate: Date?
    
    /// Version of a found update that hasn't been installed or dismissed yet
    @Published var availableUpdateVersion: String?
    
    /// Opens What's New from Sparkle's "Version History" button
    weak var appState: AppState?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        UserDefaults.standard.register(defaults: ["SUEnableAutomaticChecks": true])
        
        automaticChecksEnabled = UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
        
        // Self is the user driver delegate so Rapto controls how update alerts are shown.
        // SPUStandardUpdaterController reads SUFeedURL and SUPublicEDKey from Info.plist
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        
        // didSet does not run during init, so the preference is passed to Sparkle here
        updaterController?.updater.automaticallyChecksForUpdates = automaticChecksEnabled
        
        UNUserNotificationCenter.current().delegate = self
        
        debugLog("UpdaterManager", "Sparkle updater initialized, autoCheck=\(automaticChecksEnabled)")
        
        // Check for updates at launch; Sparkle on its own waits for SUScheduledCheckInterval.
        // The delay lets the updater finish starting
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.automaticChecksEnabled {
                debugLog("UpdaterManager", "Performing initial background update check")
                self.checkForUpdatesInBackground()
            }
        }
    }
    
    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)
    
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }
    
    /// Rapto has no Dock icon, so without focus Sparkle would open the alert behind other apps.
    /// Then Rapto shows a notification and a menu item instead.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        return immediateFocus
    }
    
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            debugLog("UpdaterManager", "Update \(version) found, sparkleShows=\(handleShowingUpdate), userInitiated=\(state.userInitiated)")
            self.availableUpdateVersion = version
            if handleShowingUpdate {
                self.bringSparkleWindowsToFront()
            } else {
                self.postUpdateNotification(version: version)
            }
        }
    }
    
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            self.removeUpdateNotification()
        }
    }
    
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.availableUpdateVersion = nil
            self.removeUpdateNotification()
        }
    }
    
    /// "Version History" in Sparkle's "You're up to date" alert opens What's New
    nonisolated func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        Task { @MainActor in
            guard let appState = self.appState else { return }
            SettingsWindowController.shared.showSettings(appState: appState, tab: .whatsNew)
        }
    }
    
    // MARK: - Update Notification
    
    private func postUpdateNotification(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                debugLog("UpdaterManager", "Notifications not allowed, update shown in the menu only")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Rapto \(version) is available"
            content.body = "Click to see what's new and install it."
            let request = UNNotificationRequest(identifier: updateNotificationID, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
    
    private func removeUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [updateNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [updateNotificationID])
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.identifier == updateNotificationID
        Task { @MainActor in
            if isUpdate {
                self.checkForUpdates()
            }
            completionHandler()
        }
    }
    
    // MARK: - Public Methods
    
    /// Checks for updates with Sparkle's UI.
    /// If the updater is not ready yet, retries once after 0.5 seconds, then shows an alert
    func checkForUpdates() {
        debugLog("UpdaterManager", "Manual update check triggered, canCheck=\(canCheckForUpdates)")
        
        guard let controller = updaterController else {
            debugLog("UpdaterManager", "⚠️ Updater controller is nil")
            return
        }
        
        if controller.updater.canCheckForUpdates {
            debugLog("UpdaterManager", "✅ Checking for updates now")
            controller.checkForUpdates(nil)
            lastCheckDate = Date()
            bringSparkleWindowsToFront()
        } else {
            debugLog("UpdaterManager", "⏳ Updater not ready, retrying in 0.5s...")
            // Sparkle may still be initializing — retry after a short delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if controller.updater.canCheckForUpdates {
                    debugLog("UpdaterManager", "✅ Retry: checking for updates now")
                    controller.checkForUpdates(nil)
                    self.lastCheckDate = Date()
                    self.bringSparkleWindowsToFront()
                } else {
                    debugLog("UpdaterManager", "⚠️ Updater still not ready after retry")
                    self.showUpdaterNotReadyAlert()
                }
            }
        }
    }
    
    private func showUpdaterNotReadyAlert() {
        let alert = NSAlert()
        alert.messageText = "Update Check"
        alert.informativeText = "The update system is still initializing. Please try again in a moment."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    /// Brings Sparkle's windows, such as the "You're up to date" dialog, above all other windows.
    /// Sparkle creates its window some time after it reports the update, so this looks for up to 5 seconds.
    private func bringSparkleWindowsToFront() {
        Task { @MainActor in
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let sparkleWindows = NSApplication.shared.windows.filter { window in
                    guard window.isVisible else { return false }
                    let names = [window.className, window.windowController.map { $0.className } ?? ""]
                    return names.contains { $0.hasPrefix("SU") || $0.hasPrefix("SPU") }
                }
                guard !sparkleWindows.isEmpty else { continue }
                // A menu bar app may not get activated, so the window level keeps the alert above other apps
                NSApp.activate()
                for window in sparkleWindows {
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    window.level = .modalPanel
                    window.orderFrontRegardless()
                    window.makeKey()
                    debugLog("UpdaterManager", "Raised \(window.windowController.map { $0.className } ?? window.className) to front")
                }
                return
            }
            let visible = NSApplication.shared.windows.filter(\.isVisible)
                .map { "\($0.className)/\($0.windowController.map { $0.className } ?? "-") '\($0.title)'" }
            debugLog("UpdaterManager", "No Sparkle window to raise, visible: \(visible)")
        }
    }
    
    func checkForUpdatesInBackground() {
        debugLog("UpdaterManager", "Background update check triggered")
        updaterController?.updater.checkForUpdatesInBackground()
        lastCheckDate = Date()
    }
    
    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }
}

#else

// Stub implementation when Sparkle is not available (e.g., during development without SPM package)
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    
    static let shared = UpdaterManager()
    
    @Published var automaticChecksEnabled: Bool = true
    @Published var lastCheckDate: Date?
    @Published var availableUpdateVersion: String?
    weak var appState: AppState?
    
    private override init() {
        super.init()
        debugLog("UpdaterManager", "Sparkle not available - updates disabled")
    }
    
    func checkForUpdates() {
        debugLog("UpdaterManager", "Sparkle not available - cannot check for updates")
    }
    
    func checkForUpdatesInBackground() {
    }
    
    var canCheckForUpdates: Bool { false }
}

#endif
