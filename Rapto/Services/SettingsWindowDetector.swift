//
//  SettingsWindowDetector.swift
//  Rapto
//
//  Recognizes settings windows that look like ordinary windows (Gemini) by how they were opened.
//

import AppKit
import ApplicationServices

// MARK: - Workaround: Settings Windows Without Any Distinguishing Attribute
// Problem: Some apps (Gemini) open Settings as a standard, resizable window titled after the section
//          ("General"), with no subrole or identifier that tells it apart from the main window,
//          so Auto Tiling put it into a slot and rearranged the whole desktop.
// Solution: Watch for Cmd+, and for the "Settings…" menu item. A window of that app that appears
//           right after it is a settings window and is never tiled.
final class SettingsWindowDetector {
    static let shared = SettingsWindowDetector()
    
    /// How long after the request a new window still counts as the settings window
    private static let requestLifetime: TimeInterval = 2.0
    
    private let lock = NSLock()
    private var requests: [pid_t: (date: Date, existingWindows: Set<CGWindowID>)] = [:]
    private var settingsWindowIDs: Set<CGWindowID> = []
    /// Whether the last highlighted menu item of the app was "Settings…", read when its menu closes
    private var settingsMenuItemHighlighted: [pid_t: Bool] = [:]
    private var keyMonitor: Any?
    private var activationObserver: Any?
    private var spaceBarMoveEndObserver: Any?
    /// Menu observer of the frontmost app only; it moves with the app focus
    private var menuObserver: AXObserver?
    private var menuObserverPID: pid_t = 0
    
    private init() {}
    
    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
                  event.charactersIgnoringModifiers == ",",
                  let app = NSWorkspace.shared.frontmostApplication else { return }
            self?.settingsRequested(pid: app.processIdentifier)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let app else { return }
                self?.observeMenus(of: app)
            }
        }
        spaceBarMoveEndObserver = NotificationCenter.default.addObserver(
            forName: .spaceBarMoveDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let app = NSWorkspace.shared.frontmostApplication else { return }
                self?.observeMenus(of: app)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            observeMenus(of: app)
        }
    }
    
    private func observeMenus(of app: NSRunningApplication) {
        // Stand down while the Desktops Bar wakes and carries a window between Spaces so
        // attaching a menu AXObserver never blocks the main thread for 1 s on a waking app.
        guard !SpaceBarController.isDrivingMouse else { return }
        let pid = app.processIdentifier
        guard pid != menuObserverPID else { return }
        if let old = menuObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        menuObserver = nil
        menuObserverPID = 0
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard AppResponsiveness.isResponding(pid) else { return }
        
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, _ in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            SettingsWindowDetector.shared.handleMenuNotification(notification as String, element: element, pid: pid)
        }, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AppResponsiveness.shared.ask(pid) {
            AXObserverAddNotification(observer, appElement, kAXMenuItemSelectedNotification as CFString, nil)
        }
        guard AppResponsiveness.isResponding(pid) else { return }
        AXObserverAddNotification(observer, appElement, kAXMenuClosedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        menuObserver = observer
        menuObserverPID = pid
    }
    
    private func handleMenuNotification(_ notification: String, element: AXUIElement, pid: pid_t) {
        if notification == kAXMenuItemSelectedNotification as String {
            let isSettings = Self.isSettingsMenuItem(element)
            lock.withLock { settingsMenuItemHighlighted[pid] = isSettings }
        } else if notification == kAXMenuClosedNotification as String {
            let chosen = lock.withLock { settingsMenuItemHighlighted.removeValue(forKey: pid) ?? false }
            if chosen { settingsRequested(pid: pid) }
        }
    }
    
    /// Whether the window is a settings window opened by the request. Remembered for the window's lifetime.
    func isSettingsWindow(_ window: WindowInfo) -> Bool {
        lock.withLock {
            if settingsWindowIDs.contains(window.windowID) { return true }
            guard let request = requests[window.ownerPID] else { return false }
            guard Date().timeIntervalSince(request.date) < Self.requestLifetime else {
                requests[window.ownerPID] = nil
                return false
            }
            // Windows that were open before the request, and small helper windows the app opens alongside,
            // are not the settings window
            guard !request.existingWindows.contains(window.windowID),
                  window.frame.width >= 200, window.frame.height >= 150 else { return false }
            requests[window.ownerPID] = nil
            if settingsWindowIDs.count > 100 { settingsWindowIDs.removeAll() }
            settingsWindowIDs.insert(window.windowID)
            debugLog("SettingsWindowDetector", "Window \(window.windowID) of \(window.ownerName) is a settings window, not tiling it")
            return true
        }
    }
    
    private func settingsRequested(pid: pid_t) {
        let existing = Self.windowIDs(of: pid)
        lock.withLock { requests[pid] = (Date(), existing) }
        debugLog("SettingsWindowDetector", "Settings requested in PID \(pid), \(existing.count) existing window(s)")
    }
    
    private static func windowIDs(of pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }
    
    /// "Settings…" has Cmd+, in every app that follows the macOS conventions; the title covers apps without the shortcut
    private static func isSettingsMenuItem(_ element: AXUIElement) -> Bool {
        var charRef: CFTypeRef?, modifiersRef: CFTypeRef?, titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &charRef)
        AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &modifiersRef)
        // 0 means Command only
        if (charRef as? String) == ",", (modifiersRef as? Int ?? 0) == 0 { return true }
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String else { return false }
        return ["Settings", "Preferences"].contains { title.hasPrefix($0) }
    }
}
