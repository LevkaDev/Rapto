//
//  DoubleClickGuard.swift
//  Rapto
//

import AppKit

/// Hides the second click of a modifier + double-click that Rapto handles from the app under the cursor,
/// so the app gets one modifier + click (a browser doesn't download a link twice, a player doesn't go full screen).
@MainActor
final class DoubleClickGuard {

    /// Whether a double-click with these modifiers belongs to Rapto
    var ownsDoubleClick: ((NSEvent.ModifierFlags) -> Bool)?

    /// A hidden click never reaches Rapto's own mouse monitors either, so it is handed over here
    var onHiddenClick: ((NSEvent) -> Void)?

    // MARK: - Workaround: the click tap outlives the guard
    // Cause: The tap callback got a plain pointer to the guard, and nothing removed the tap when
    //        the guard went away. The next click anywhere then called into freed memory.
    // Context: The app keeps one guard for its whole life, but every `AppState` made in a test
    //          starts one and drops it, so a click during a test run crashed the test host.
    //          The callback holds this context instead: it points to the guard weakly, and the
    //          guard removes the tap through it when it goes away.
    /// What the tap callback holds
    nonisolated final class TapContext: @unchecked Sendable {
        weak var owner: DoubleClickGuard?
        private let lock = NSLock()
        private var tap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?

        var isWatching: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tap != nil
        }

        func attach(tap: CFMachPort, runLoopSource: CFRunLoopSource?) {
            lock.lock()
            defer { lock.unlock() }
            self.tap = tap
            self.runLoopSource = runLoopSource
        }

        func enableTap() {
            lock.lock()
            defer { lock.unlock() }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }

        /// Stops the tap and takes it off the main run loop. Safe from any thread.
        func removeTap() {
            lock.lock()
            defer { lock.unlock() }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            tap = nil
            runLoopSource = nil
        }
    }

    let context = TapContext()
    private var retryTimer: Timer?
    /// The mouse up of a hidden mouse down is hidden too, even if the modifier was let go in between
    private var hidingClick = false

    deinit {
        context.removeTap()
    }

    func start() {
        guard !context.isWatching else { return }
        context.owner = self
        let events = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(events),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                guard let owner = context.owner else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated { owner.handle(type, event) }
            },
            // Retained for good: the callback may still run while the guard is going away
            userInfo: Unmanaged.passRetained(context).toOpaque()
        ) else {
            // Needs Accessibility; try again once it is granted
            debugLog("DoubleClickGuard", "Could not watch clicks yet, retrying")
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.start() }
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        context.attach(tap: tap, runLoopSource: source)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("DoubleClickGuard", "Watching modifier + double-clicks")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            context.enableTap()
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, hidingClick {
            hidingClick = false
            handOver(event)
            return nil
        }
        guard type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard ownsDoubleClick?(flags) == true else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.mouseEventClickState) >= 2 else {
            stripOptionIfActivating(event, flags: flags)
            return Unmanaged.passUnretained(event)
        }
        hidingClick = true
        debugLog("DoubleClickGuard", "Hid the second click of a modifier + double-click from the app")
        handOver(event)
        return nil
    }

    // MARK: - Workaround: Option + click on another app hides the front app
    // macOS hides the frontmost app when a window of another app is activated by a click with Option
    // held. The first click of an Option + double-click did that, and the app vanished (focus mode then
    // took its window for closed). Option is taken off that first click; the event is marked so Rapto's
    // own click monitors still see Option on it.

    /// Marks a mouse down that had Option taken off
    nonisolated static let strippedOptionMarker: Int64 = 0x5241_5054

    /// The modifiers held for a click, with Option back on a click that had it taken off
    nonisolated static func heldModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        var flags = event.modifierFlags
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == strippedOptionMarker {
            flags.insert(.option)
        }
        return flags
    }

    struct WindowUnderPoint {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// Whether a click at `point` activates another app: the topmost window there (not Rapto's own)
    /// is a normal window of an app other than the frontmost one.
    nonisolated static func activatesOtherApp(
        at point: CGPoint,
        windowsFrontToBack: [WindowUnderPoint],
        frontmostPID: pid_t?,
        ownPID: pid_t
    ) -> Bool {
        guard let top = windowsFrontToBack.first(where: { $0.pid != ownPID && $0.bounds.contains(point) }) else {
            return false
        }
        return top.layer == 0 && top.pid != frontmostPID
    }

    private func stripOptionIfActivating(_ event: CGEvent, flags: NSEvent.ModifierFlags) {
        guard flags.contains(.option) else { return }
        let point = event.location
        guard Self.activatesOtherApp(
            at: point,
            windowsFrontToBack: Self.onScreenWindows(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        ) else { return }
        event.flags.remove(.maskAlternate)
        event.setIntegerValueField(.eventSourceUserData, value: Self.strippedOptionMarker)
        debugLog("DoubleClickGuard", "Took Option off a click on another app's window, so macOS doesn't hide the front app")
    }

    private static func onScreenWindows() -> [WindowUnderPoint] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return WindowUnderPoint(pid: pid, layer: layer, bounds: bounds)
        }
    }

    private func handOver(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        // Out of the tap callback, so slow handling can't get the tap disabled by timeout
        DispatchQueue.main.async { [weak self] in
            self?.onHiddenClick?(nsEvent)
        }
    }
}
