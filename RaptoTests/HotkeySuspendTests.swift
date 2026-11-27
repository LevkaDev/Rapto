import Testing
import Carbon.HIToolbox
@testable import Rapto

@MainActor
@Suite("Hotkeys while suspended for a passthrough app")
struct HotkeySuspendTests {
    /// F19 with every modifier: nothing else uses it, so registering it in tests is harmless.
    let preset = HotkeyPreset(
        type: .custom,
        bindings: [.focusLeft: HotkeyBinding(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))]
    )

    @Test("Hotkeys registered while suspended wait until resume")
    func registerWhileSuspended() {
        let manager = HotkeyManager()
        manager.suspendHotkeys()
        manager.registerFromPreset(preset, handlers: [.focusLeft: {}])
        #expect(manager.registeredActions.isEmpty)

        manager.resumeHotkeys()
        #expect(manager.registeredActions == [.focusLeft])
        manager.unregisterAllActionHotkeys()
    }

    @Test("Suspend and resume keep one registration per action")
    func suspendResumeCycle() {
        let manager = HotkeyManager()
        manager.registerFromPreset(preset, handlers: [.focusLeft: {}])
        #expect(manager.registeredActions == [.focusLeft])

        manager.suspendHotkeys()
        #expect(manager.registeredActions.isEmpty)
        manager.resumeHotkeys()
        #expect(manager.registeredActions == [.focusLeft])
        manager.unregisterAllActionHotkeys()
    }

    @Test("Group cycling still reaches its handler after suspend and resume")
    func groupCyclingSurvivesResume() {
        let manager = HotkeyManager()
        // F18 with every modifier: free, and not the key of the other tests, which run in parallel
        manager.registerGroupCyclingHotkey(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)) {}
        #expect(manager.hasGroupCyclingHotkey)

        manager.suspendHotkeys()
        #expect(!manager.hasGroupCyclingHotkey)
        manager.resumeHotkeys()
        #expect(manager.hasGroupCyclingHotkey)
        manager.unregisterGroupCyclingHotkeys()
    }

    @Test("Deallocating HotkeyManager unregisters all hotkeys so a new manager can register them")
    func deinitUnregistersAllHotkeys() {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        // F17 and F16 with every modifier: free, and distinct from the other parallel tests
        let actionPreset = HotkeyPreset(
            type: .custom,
            bindings: [.focusLeft: HotkeyBinding(keyCode: UInt32(kVK_F17), modifiers: modifiers)]
        )

        do {
            let first = HotkeyManager()
            first.registerFromPreset(actionPreset, handlers: [.focusLeft: {}])
            first.registerGroupCyclingHotkey(keyCode: UInt32(kVK_F16), modifiers: modifiers) {}
            #expect(first.registeredActions == [.focusLeft])
            #expect(first.hasGroupCyclingHotkey)
        }

        let second = HotkeyManager()
        second.registerFromPreset(actionPreset, handlers: [.focusLeft: {}])
        second.registerGroupCyclingHotkey(keyCode: UInt32(kVK_F16), modifiers: modifiers) {}
        #expect(second.registeredActions == [.focusLeft])
        #expect(second.hasGroupCyclingHotkey)
        second.unregisterAllActionHotkeys()
        second.unregisterGroupCyclingHotkeys()
    }

    @Test("A cleared direction leaves the other three shortcuts")
    func clearedDirectionKeepsTheOthers() {
        var bindings = HotkeyPreset.preset(for: .rapto).bindings
        bindings[.swapUp] = nil
        let preset = HotkeyPreset(type: .custom, bindings: bindings)

        let directions = preset.directionBindings(left: .swapLeft, right: .swapRight, up: .swapUp, down: .swapDown).map(\.direction)
        #expect(directions == [.left, .right, .down])
    }

    @Test("Presets bind nothing to the template actions, which no code registers")
    func presetsLeaveTemplateActionsUnbound() {
        let unregistered: [HotkeyAction] = [
            .applyTemplate1, .applyTemplate2, .applyTemplate3, .applyTemplate4, .applyTemplate5,
            .applyTemplate6, .applyTemplate7, .applyTemplate8, .applyTemplate9
        ]
        for type in [HotkeyPresetType.rapto, .vimStyle] {
            let bindings = HotkeyPreset.preset(for: type).bindings
            #expect(unregistered.allSatisfy { bindings[$0] == nil })
        }
    }
}
