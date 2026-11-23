//
//  DockSpaceSwipe.swift
//  Rapto
//
//  Synthetic Dock swipes that switch real macOS desktops with no slide.
//

import CoreGraphics
import Darwin
import Foundation

// MARK: - Workaround:
// Cause: There is no public way to switch desktops, and SLSManagedDisplaySetCurrentSpace
//        changes the desktop number without redrawing the screen.
// Context: Send a Dock swipe the way a trackpad does. A near-zero length and a high velocity
//          give a switch without animation. macOS 27 accepts the swipe only with raw
//          trackpad data inside the event. The format comes from InstantSpaceSwitcher
//          (https://github.com/jurplel/InstantSpaceSwitcher, MIT; see THIRD_PARTY_NOTICES.md).
enum DockSpaceSwipe {
    /// Posts `count` swipes back to back toward the next or previous desktop.
    static func post(towardHigherIndex: Bool, count: Int) {
        guard count > 0 else { return }
        let modern = needsTrackpadPayload
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<count {
                for phase in [Phase.began, .changed, .ended] {
                    let event = modern
                        ? modernEvent(phase: phase, towardHigherIndex: towardHigherIndex)
                        : legacyEvent(phase: phase, towardHigherIndex: towardHigherIndex, count: count)
                    guard let event, let companion = CGEvent(source: nil) else { continue }
                    companion.setIntegerValueField(Field.eventType, value: 29)
                    event.post(tap: .cgSessionEventTap)
                    companion.post(tap: .cgSessionEventTap)
                }
            }
        }
    }

    // MARK: - Fields

    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let hidType = CGEventField(rawValue: 110)!
        static let scrollY = CGEventField(rawValue: 119)!
        static let swipeMotion = CGEventField(rawValue: 123)!
        static let swipeProgress = CGEventField(rawValue: 124)!
        static let swipePositionX = CGEventField(rawValue: 125)!
        static let swipePositionY = CGEventField(rawValue: 126)!
        static let swipeVelocityX = CGEventField(rawValue: 129)!
        static let swipeVelocityY = CGEventField(rawValue: 130)!
        static let phase = CGEventField(rawValue: 132)!
        static let phaseAlias = CGEventField(rawValue: 134)!
        static let swipeDirection = CGEventField(rawValue: 135)!
        static let zoomDeltaY = CGEventField(rawValue: 138)!
        static let zoomDeltaX = CGEventField(rawValue: 139)!
        static let swipeMask = CGEventField(rawValue: 115)!
        static let timestampAlias = CGEventField(rawValue: 169)!
    }

    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    private static let dockControlEvent: Int64 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    /// The smallest step the Dock still reads as a direction. It leaves nothing to animate.
    private static let minimalProgress = 0.000016

    // MARK: - macOS 26

    private static func legacyEvent(phase: Phase, towardHigherIndex: Bool, count: Int) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let sign: Double = towardHigherIndex ? 1 : -1
        let velocity = sign * 2000 * Double(count)
        event.setIntegerValueField(Field.eventType, value: dockControlEvent)
        event.setIntegerValueField(Field.hidType, value: dockSwipeHIDType)
        event.setIntegerValueField(Field.phase, value: phase.rawValue)
        event.setIntegerValueField(Field.swipeDirection, value: towardHigherIndex ? 1 : 0)
        event.setIntegerValueField(Field.swipeMotion, value: horizontalMotion)
        event.setDoubleValueField(Field.scrollY, value: 0)
        event.setDoubleValueField(Field.zoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
        event.setDoubleValueField(Field.swipeProgress, value: sign * minimalProgress)
        event.setDoubleValueField(Field.swipeVelocityX, value: velocity)
        event.setDoubleValueField(Field.swipeVelocityY, value: velocity)
        return event
    }

    // MARK: - macOS 27

    /// The payload's velocity is 16.16 fixed point, so it cannot scale with the step count.
    private static let modernFlingVelocity = 9999.0

    private static var needsTrackpadPayload: Bool {
        var size = 0
        guard sysctlbyname("kern.osproductversion", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osproductversion", &buffer, &size, nil, 0) == 0 else { return false }
        let version = String(cString: buffer)
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        return major >= 27
    }

    /// On macOS 27 right is negative, and the Dock also flips it when natural scrolling is off.
    private static func modernSign(towardHigherIndex: Bool) -> Double {
        let key = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue(key, kCFPreferencesAnyApplication, &valid)
        let sign: Double = towardHigherIndex ? -1 : 1
        return (!valid.boolValue || natural) ? sign : -sign
    }

    private static func modernEvent(phase: Phase, towardHigherIndex: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let sign = modernSign(towardHigherIndex: towardHigherIndex)
        event.setIntegerValueField(Field.eventType, value: dockControlEvent)
        event.setIntegerValueField(Field.hidType, value: dockSwipeHIDType)
        event.setIntegerValueField(Field.phase, value: phase.rawValue)
        event.setIntegerValueField(Field.swipeMotion, value: horizontalMotion)
        event.setDoubleValueField(Field.swipeProgress, value: sign * minimalProgress)
        event.setIntegerValueField(Field.phaseAlias, value: phase.rawValue)
        event.setDoubleValueField(Field.zoomDeltaY, value: 3.0)
        event.setDoubleValueField(Field.timestampAlias, value: Double(mach_absolute_time()))
        event.setDoubleValueField(Field.swipePositionX, value: 0.1)
        if phase == .ended {
            event.setDoubleValueField(Field.swipeVelocityX, value: sign * modernFlingVelocity)
        }
        return withTrackpadPayload(event)
    }

    /// Appends the raw IOHID trackpad gesture that macOS 27 reads instead of the public fields.
    private static func withTrackpadPayload(_ event: CGEvent) -> CGEvent? {
        guard let original = event.data as Data?,
              original.count >= 4,
              original.prefix(4) == Data([0, 0, 0, 2]) else { return nil }

        let phase = event.getIntegerValueField(Field.phase)
        let velocityX = event.getDoubleValueField(Field.swipeVelocityX)
        let velocityY = event.getDoubleValueField(Field.swipeVelocityY)
        let includeVelocity = velocityX != 0 || velocityY != 0 || phase == Phase.ended.rawValue

        var payload = Data()
        // Queue element header: timestamp, sender, options, attribute length, event count.
        let timestamp = event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        payload.appendLittleEndian(UInt64(timestamp))
        payload.appendLittleEndian(UInt64(0))
        payload.appendLittleEndian(UInt32(0))
        payload.appendLittleEndian(UInt32(0))
        payload.appendLittleEndian(UInt32(includeVelocity ? 2 : 1))

        // Fluid touch gesture, flavor "Dock primary".
        payload.appendLittleEndian(UInt32(40))
        payload.appendLittleEndian(UInt32(23))
        payload.appendLittleEndian(UInt32((UInt64(phase) & 0xFF) << 24))
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.appendLittleEndian(fixed1616(event.getDoubleValueField(Field.swipePositionX)))
        payload.appendLittleEndian(fixed1616(event.getDoubleValueField(Field.swipePositionY)))
        payload.appendLittleEndian(Int32(0))
        payload.appendLittleEndian(UInt32(truncatingIfNeeded: event.getIntegerValueField(Field.swipeMask)))
        payload.appendLittleEndian(UInt16(truncatingIfNeeded: event.getIntegerValueField(Field.swipeMotion)))
        payload.appendLittleEndian(UInt16(3))
        payload.appendLittleEndian(fixed1616(event.getDoubleValueField(Field.swipeProgress)))

        if includeVelocity {
            payload.appendLittleEndian(UInt32(28))
            payload.appendLittleEndian(UInt32(9))
            payload.appendLittleEndian(UInt32(0))
            payload.append(contentsOf: [1, 0, 0, 0])
            payload.appendLittleEndian(fixed1616(velocityX))
            payload.appendLittleEndian(fixed1616(velocityY))
            payload.appendLittleEndian(Int32(0))
        }

        var combined = original
        let length = UInt16(payload.count)
        let tag: UInt16 = 4205
        combined.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF), UInt8(tag >> 8), UInt8(tag & 0xFF)])
        combined.append(payload)
        return CGEvent(withDataAllocator: kCFAllocatorDefault, data: combined as CFData)
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64(value * 65536))
        if fixed == 0 && value != 0 {
            return value > 0 ? 1 : -1
        }
        return fixed
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
