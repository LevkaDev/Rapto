//
//  LaunchAtLoginManager.swift
//  Rapto
//
//  Service for managing Launch at Login functionality using SMAppService.
//

import Foundation
import Combine
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "app.rapto.mac", category: "LaunchAtLoginManager")

/// Uses SMAppService (macOS 13+) to register/unregister the app for login items
@MainActor
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    
    /// Keeps `isEnabled`'s didSet from registering or unregistering while it mirrors the system state
    private var isUpdatingFromSystem = false
    
    /// Setting it registers or unregisters the app; a failure reverts it
    @Published var isEnabled: Bool = false {
        didSet {
            // Skip side effects when syncing from system or reverting after error
            guard !isUpdatingFromSystem, oldValue != isEnabled else { return }
            
            if isEnabled {
                register()
            } else {
                unregister()
            }
        }
    }
    
    private init() {
        refreshStatus()
    }
    
    // MARK: - Public Methods
    
    /// Reads the status from the system. Waiting for approval in System Settings counts as off.
    func refreshStatus() {
        let status = SMAppService.mainApp.status
        
        isUpdatingFromSystem = true
        defer { isUpdatingFromSystem = false }
        
        switch status {
        case .enabled:
            isEnabled = true
            logger.debug("Launch at Login is enabled")
        case .notRegistered, .notFound:
            isEnabled = false
            logger.debug("Launch at Login is not registered")
        case .requiresApproval:
            isEnabled = false
            logger.info("Launch at Login requires user approval in System Settings")
        @unknown default:
            isEnabled = false
            logger.warning("Unknown Launch at Login status")
        }
    }
    
    // MARK: - Private Methods
    
    private func register() {
        do {
            try SMAppService.mainApp.register()
            logger.info("Successfully registered for Launch at Login")
            debugLog("LaunchAtLogin", "Registered for Launch at Login")
        } catch {
            logger.error("Failed to register for Launch at Login: \(error.localizedDescription)")
            debugLog("LaunchAtLogin", "Failed to register: \(error.localizedDescription)")
            // Revert state without triggering another register/unregister
            isUpdatingFromSystem = true
            isEnabled = false
            isUpdatingFromSystem = false
        }
    }
    
    private func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            logger.info("Successfully unregistered from Launch at Login")
            debugLog("LaunchAtLogin", "Unregistered from Launch at Login")
        } catch {
            logger.error("Failed to unregister from Launch at Login: \(error.localizedDescription)")
            debugLog("LaunchAtLogin", "Failed to unregister: \(error.localizedDescription)")
            // Revert state without triggering another register/unregister
            isUpdatingFromSystem = true
            isEnabled = true
            isUpdatingFromSystem = false
        }
    }
}
