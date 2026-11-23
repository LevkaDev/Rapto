//
//  WindowTitleResolver.swift
//  Rapto
//
//  Reads window titles through Accessibility. The window list only carries
//  titles when Screen Recording is allowed, which Rapto does not require.
//

import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private nonisolated func WindowTitleAXGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private nonisolated func WindowTitleAXCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

enum WindowTitleResolver {

    /// An app that does not answer in this time is skipped.
    private nonisolated static let messagingTimeout: Float = 0.25
    /// How long to look for the windows of one app that are on other desktops.
    private nonisolated static let otherDesktopsBudget: TimeInterval = 0.15
    private nonisolated static let remoteElementLimit: UInt64 = 1000

    /// Titles of the given windows, grouped by the app that owns them. Apps are
    /// asked in parallel. Safe to call off the main thread.
    nonisolated static func titles(for windowsByPID: [pid_t: Set<CGWindowID>]) -> [CGWindowID: String] {
        let requests = Array(windowsByPID)
        guard !requests.isEmpty else { return [:] }
        let lock = NSLock()
        var result: [CGWindowID: String] = [:]
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            let found = titles(for: requests[index].value, pid: requests[index].key)
            lock.lock()
            result.merge(found) { _, new in new }
            lock.unlock()
        }
        return result
    }

    nonisolated static func titles(for windowIDs: Set<CGWindowID>, pid: pid_t) -> [CGWindowID: String] {
        var missing = windowIDs
        var result: [CGWindowID: String] = [:]
        guard AppResponsiveness.isResponding(pid) else { return [:] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var windowsRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsRef)
        if error == .cannotComplete || error == .apiDisabled { return [:] }
        for window in windowsRef as? [AXUIElement] ?? [] {
            record(window, missing: &missing, into: &result)
        }
        guard !missing.isEmpty else { return result }

        // The app only lists its windows on the current desktop. The rest are
        // reached by their element ids, which apps hand out from zero upwards.
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(otherDesktopsBudget)
        for elementID in 0..<remoteElementLimit {
            if missing.isEmpty || Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = WindowTitleAXCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            record(element, missing: &missing, into: &result)
        }
        return result
    }

    private nonisolated static func record(
        _ element: AXUIElement, missing: inout Set<CGWindowID>, into result: inout [CGWindowID: String]
    ) {
        var windowID: CGWindowID = 0
        guard WindowTitleAXGetWindow(element, &windowID) == .success, missing.contains(windowID) else { return }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              roleRef as? String == kAXWindowRole as String else { return }
        missing.remove(windowID)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = (titleRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        result[windowID] = title
    }
}
