//
//  HotkeyManager.swift
//  Rapto
//
//  Registers and handles global hotkeys using Carbon Events API.
//

import Foundation
import Carbon

private struct HotkeyEntry {
    let id: UInt32
    let ref: EventHotKeyRef
    let handler: () -> Void
}

/// Stored hotkey info for re-registration after suspend
private struct StoredHotkeyInfo {
    let keyCode: UInt32
    let modifiers: UInt32
    let handler: () -> Void
}

class HotkeyManager {
    // MARK: - Properties
    
    /// Reference to the registered hotkey (main overlay toggle)
    private var hotkeyRef: EventHotKeyRef?
    
    private var eventHandler: (() -> Void)?
    
    private var eventHandlerRef: EventHandlerRef?
    
    /// Additional registered hotkeys (for group cycling, etc.)
    private var additionalHotkeys: [HotkeyEntry] = []
    
    private var templateHotkeys: [UInt32: HotkeyEntry] = [:]
    
    private var swapHotkeys: [HotkeyEntry] = []
    
    private var moveToSlotHotkeys: [HotkeyEntry] = []
    
    /// Next hotkey ID to hand out. ID 1 is the main hotkey
    private var nextHotkeyID: UInt32 = 2
    
    private(set) var isSuspended: Bool = false
    
    /// Stored hotkey registrations for resume after suspend
    private var storedMainHotkey: StoredHotkeyInfo?
    private var storedAdditionalHotkeys: [StoredHotkeyInfo] = []
    private var storedTemplateHotkeys: [UUID: StoredHotkeyInfo] = [:]
    private var storedSwapHotkeys: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)] = []
    private var storedMoveToSlotHotkeys: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)] = []
    private var storedWindowMoveHotkeys: [(keyCode: UInt32, modifiers: UInt32, direction: MoveToScreenDirection)] = []
    private var storedResizeHotkeys: [(keyCode: UInt32, modifiers: UInt32, direction: ResizeDirection)] = []
    private var storedFocusSlotHotkeys: [(keyCode: UInt32, modifiers: UInt32, slot: Int)] = []
    private var storedFocusDirectionHotkeys: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)] = []
    private var storedModeCycleHotkey: StoredHotkeyInfo?
    private var storedFullscreenHotkey: StoredHotkeyInfo?
    private var storedRestoreLayoutHotkey: StoredHotkeyInfo?
    
    /// Handlers for resume (stored separately as closures can't be easily stored with specific params)
    private var swapHandler: ((SwapDirection) -> Void)?
    private var moveToSlotHandler: ((SwapDirection) -> Void)?
    private var windowMoveHandler: ((MoveToScreenDirection) -> Void)?
    private var resizeHandler: ((ResizeDirection) -> Void)?
    private var focusSlotHandler: ((Int) -> Void)?
    private var focusDirectionHandler: ((SwapDirection) -> Void)?  // Uses SwapDirection for left/right/up/down
    
    @available(*, deprecated, message: "Use suspendHotkeys/resumeHotkeys instead")
    var shouldPassthrough: (() -> Bool)?
    
    deinit {
        unregisterAllHotkeys()
    }
    
    // MARK: - Public Methods
    
    /// Register a global hotkey with the specified key code and modifiers
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., kVK_ANSI_G = 0x05)
    ///   - modifiers: The modifier flags (e.g., controlKey | optionKey)
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        
        self.eventHandler = handler
        
        // Store for re-registration after suspend
        storedMainHotkey = StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        
        guard !isSuspended else { return }
        
        registerHotkeyInternal(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }
    
    private func handleHotkeyEvent(_ event: EventRef?) {
        guard let event = event else { return }
        
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        
        if hotKeyID.id == 1 {
            eventHandler?()
            return
        }
        
        if let entry = additionalHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
        
        if let entry = swapHotkeys.first(where: { $0.id == hotKeyID.id }) {
            debugLog("HotkeyManager", " handleHotkeyEvent: swap hotkey matched (id=\(hotKeyID.id))")
            entry.handler()
            return
        }
        
        if let entry = windowMoveHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
        
        if let entry = moveToSlotHotkeys.first(where: { $0.id == hotKeyID.id }) {
            debugLog("HotkeyManager", " handleHotkeyEvent: move-to-slot hotkey matched (id=\(hotKeyID.id))")
            entry.handler()
            return
        }
        
        for (_, entry) in templateHotkeys {
            if entry.id == hotKeyID.id {
                entry.handler()
                return
            }
        }
        
        if let entry = resizeHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
        
        if let entry = focusSlotHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
        
        if let entry = focusDirectionHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
        
        if let entry = modeCycleHotkey, entry.id == hotKeyID.id {
            entry.handler()
            return
        }
        
        if let entry = fullscreenHotkey, entry.id == hotKeyID.id {
            entry.handler()
            return
        }
        
        if let entry = restoreLayoutHotkey, entry.id == hotKeyID.id {
            entry.handler()
            return
        }
        
        for (_, entry) in actionHotkeys {
            if entry.id == hotKeyID.id {
                entry.handler()
                return
            }
        }
        
        if let entry = genericHotkeys.first(where: { $0.id == hotKeyID.id }) {
            entry.handler()
            return
        }
    }
    
    /// Unregisters the main hotkey and removes the Carbon event handler
    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
        
        eventHandler = nil
    }
    
    /// Unregisters the main (overlay) hotkey only; the other hotkeys keep working
    func unregisterMainHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        eventHandler = nil
        storedMainHotkey = nil
    }
    
    /// Unregisters every Carbon hotkey registered by this manager and removes its event handler.
    func unregisterAllHotkeys() {
        unregisterActiveHotkeys()
        
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
        
        eventHandler = nil
        storedMainHotkey = nil
        storedAdditionalHotkeys.removeAll()
        storedTemplateHotkeys.removeAll()
        storedSwapHotkeys.removeAll()
        storedMoveToSlotHotkeys.removeAll()
        storedWindowMoveHotkeys.removeAll()
        storedResizeHotkeys.removeAll()
        storedFocusSlotHotkeys.removeAll()
        storedFocusDirectionHotkeys.removeAll()
        storedModeCycleHotkey = nil
        storedFullscreenHotkey = nil
        storedRestoreLayoutHotkey = nil
        storedGenericHotkeys.removeAll()
        storedActionHotkeys.removeAll()
        swapHandler = nil
        moveToSlotHandler = nil
        windowMoveHandler = nil
        resizeHandler = nil
        focusSlotHandler = nil
        focusDirectionHandler = nil
    }
    
    /// Unregisters all currently active Carbon hotkeys while leaving stored definitions intact.
    private func unregisterActiveHotkeys() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        
        for entry in additionalHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        additionalHotkeys.removeAll()
        
        for entry in swapHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        swapHotkeys.removeAll()
        
        for entry in moveToSlotHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        moveToSlotHotkeys.removeAll()
        
        for (_, entry) in actionHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        actionHotkeys.removeAll()
        
        for (_, entry) in templateHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        templateHotkeys.removeAll()
        
        for entry in windowMoveHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        windowMoveHotkeys.removeAll()
        
        for entry in resizeHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        resizeHotkeys.removeAll()
        
        for entry in focusSlotHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        focusSlotHotkeys.removeAll()
        
        for entry in focusDirectionHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        focusDirectionHotkeys.removeAll()
        
        if let entry = modeCycleHotkey {
            UnregisterEventHotKey(entry.ref)
            modeCycleHotkey = nil
        }
        
        if let entry = fullscreenHotkey {
            UnregisterEventHotKey(entry.ref)
            fullscreenHotkey = nil
        }
        
        if let entry = restoreLayoutHotkey {
            UnregisterEventHotKey(entry.ref)
            restoreLayoutHotkey = nil
        }
        
        for entry in genericHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        genericHotkeys.removeAll()
    }
    
    // MARK: - Suspend/Resume for Passthrough
    
    /// Suspend all hotkeys (unregister temporarily) for passthrough mode
    /// Key events will pass through to the focused application
    func suspendHotkeys() {
        guard !isSuspended else { return }
        
        debugLog("HotkeyManager", " Suspending all hotkeys for passthrough")
        isSuspended = true
        unregisterActiveHotkeys()
        // The stored registrations stay, so resumeHotkeys() can register them again
    }
    
    func resumeHotkeys() {
        guard isSuspended else { return }
        
        debugLog("HotkeyManager", " Resuming all hotkeys")
        isSuspended = false
        
        if let stored = storedMainHotkey {
            registerHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler)
        }
        
        for stored in storedAdditionalHotkeys {
            // Without its entry the key is still taken from every app, and pressing it does nothing
            if let ref = registerAdditionalHotkey(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler) {
                additionalHotkeys.append(HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: stored.handler))
            }
        }
        
        for (templateID, stored) in storedTemplateHotkeys {
            registerTemplateHotkeyInternal(templateID: templateID, keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler)
        }
        
        if let handler = swapHandler, !storedSwapHotkeys.isEmpty {
            for stored in storedSwapHotkeys {
                registerSwapHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, direction: stored.direction, handler: handler)
            }
        }
        
        if let handler = moveToSlotHandler, !storedMoveToSlotHotkeys.isEmpty {
            for stored in storedMoveToSlotHotkeys {
                registerMoveToSlotHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, direction: stored.direction, handler: handler)
            }
        }
        
        if let handler = windowMoveHandler, !storedWindowMoveHotkeys.isEmpty {
            for stored in storedWindowMoveHotkeys {
                registerWindowMoveHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, direction: stored.direction, handler: handler)
            }
        }
        
        if let handler = resizeHandler, !storedResizeHotkeys.isEmpty {
            for stored in storedResizeHotkeys {
                registerResizeHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, direction: stored.direction, handler: handler)
            }
        }
        
        if let handler = focusSlotHandler, !storedFocusSlotHotkeys.isEmpty {
            for stored in storedFocusSlotHotkeys {
                registerFocusSlotHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, slot: stored.slot, handler: handler)
            }
        }
        
        if let handler = focusDirectionHandler, !storedFocusDirectionHotkeys.isEmpty {
            for stored in storedFocusDirectionHotkeys {
                registerFocusDirectionHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, direction: stored.direction, handler: handler)
            }
        }
        
        if let stored = storedModeCycleHotkey {
            registerModeCycleHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler)
        }
        
        if let stored = storedFullscreenHotkey {
            registerFullscreenHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler)
        }
        
        if let stored = storedRestoreLayoutHotkey {
            registerRestoreLayoutHotkeyInternal(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler)
        }
        
        for stored in storedGenericHotkeys {
            if let ref = registerAdditionalHotkey(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler) {
                let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: stored.handler)
                genericHotkeys.append(entry)
            }
        }
        
        for (action, stored) in storedActionHotkeys {
            if let existing = actionHotkeys.removeValue(forKey: action) {
                UnregisterEventHotKey(existing.ref)
            }
            if let ref = registerAdditionalHotkey(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: stored.handler) {
                actionHotkeys[action] = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: stored.handler)
            }
        }
    }
    
    /// Internal register without storing (used by initial registration and resume)
    private func registerHotkeyInternal(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        
        self.eventHandler = handler
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = "GSNP".fourCharCode
        hotKeyID.id = 1
        
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData = userData else { return noErr }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.handleHotkeyEvent(event)
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            
            guard status == noErr else {
                debugLog("HotkeyManager"," Failed to install event handler, status: \(status)")
                return
            }
        }
        
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        
        if registerStatus != noErr {
            debugLog("HotkeyManager"," Failed to register hotkey, status: \(registerStatus)")
        }
    }
    
    func registerGroupCyclingHotkey(
        keyCode: UInt32 = 0x30, // Tab key
        modifiers: UInt32 = UInt32(controlKey),
        handler: @escaping () -> Void
    ) {
        unregisterGroupCyclingHotkeys()
        
        storedAdditionalHotkeys = [
            StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        ]
        
        guard !isSuspended else { return }
        
        if let ref = registerAdditionalHotkey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            let entry = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
            additionalHotkeys.append(entry)
        }
    }
    
    func unregisterGroupCyclingHotkeys() {
        for entry in additionalHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        additionalHotkeys.removeAll()
        storedAdditionalHotkeys.removeAll()
    }
    
    /// Whether a press of the group cycling shortcut reaches its handler
    var hasGroupCyclingHotkey: Bool { !additionalHotkeys.isEmpty }
    
    // MARK: - Additional Hotkeys (Generic)
    
    /// Storage for generic additional hotkeys (like toggle indicators)
    private var genericHotkeys: [HotkeyEntry] = []
    private var storedGenericHotkeys: [StoredHotkeyInfo] = []
    
    /// Registers a hotkey and returns its ID, or nil while suspended or if registration fails.
    /// It is registered again on resume either way.
    @discardableResult
    func registerAdditionalHotkeyWithID(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) -> UInt32? {
        storedGenericHotkeys.append(StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler))
        
        guard !isSuspended else { return nil }
        
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            let id = nextHotkeyID - 1
            let entry = HotkeyEntry(id: id, ref: ref, handler: handler)
            genericHotkeys.append(entry)
            return id
        }
        return nil
    }
    
    func unregisterGenericHotkeys() {
        for entry in genericHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        genericHotkeys.removeAll()
        storedGenericHotkeys.removeAll()
    }
    
    // MARK: - Template Hotkeys
    
    func registerTemplateHotkey(
        templateID: UUID,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        storedTemplateHotkeys[templateID] = StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        
        guard !isSuspended else { return }
        
        let hotkeyHash = UInt32(templateID.hashValue & 0x7FFFFFFF)
        
        if let existingEntry = templateHotkeys[hotkeyHash] {
            UnregisterEventHotKey(existingEntry.ref)
            templateHotkeys.removeValue(forKey: hotkeyHash)
        }
        
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            let entry = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
            templateHotkeys[hotkeyHash] = entry
        }
    }
    
    func unregisterTemplateHotkey(templateID: UUID) {
        let hotkeyHash = UInt32(templateID.hashValue & 0x7FFFFFFF)
        
        if let entry = templateHotkeys[hotkeyHash] {
            UnregisterEventHotKey(entry.ref)
            templateHotkeys.removeValue(forKey: hotkeyHash)
        }
        storedTemplateHotkeys.removeValue(forKey: templateID)
    }
    
    /// Internal: Register a template hotkey without storing (used by resume)
    private func registerTemplateHotkeyInternal(templateID: UUID, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let hotkeyHash = UInt32(templateID.hashValue & 0x7FFFFFFF)
        
        if let existingEntry = templateHotkeys[hotkeyHash] {
            UnregisterEventHotKey(existingEntry.ref)
            templateHotkeys.removeValue(forKey: hotkeyHash)
        }
        
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: handler)
            templateHotkeys[hotkeyHash] = entry
        }
    }
    
    // MARK: - Window Movement Hotkeys (Multi-Monitor)
    
    enum MoveToScreenDirection {
        case next
        case previous
        case left
        case right
    }
    
    private var windowMoveHotkeys: [HotkeyEntry] = []
    
    /// Internal: Register a single window move hotkey (used by resume)
    private func registerWindowMoveHotkeyInternal(keyCode: UInt32, modifiers: UInt32, direction: MoveToScreenDirection, handler: @escaping (MoveToScreenDirection) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(direction) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(direction) })
            windowMoveHotkeys.append(entry)
        }
    }
    
    func unregisterWindowMoveHotkeys() {
        for entry in windowMoveHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        windowMoveHotkeys.removeAll()
        storedWindowMoveHotkeys.removeAll()
    }
    
    func registerWindowMoveHotkeysWithBindings(
        _ bindings: [(keyCode: UInt32, modifiers: UInt32, direction: MoveToScreenDirection)],
        handler: @escaping (MoveToScreenDirection) -> Void
    ) {
        unregisterWindowMoveHotkeys()
        
        self.windowMoveHandler = handler
        
        storedWindowMoveHotkeys = bindings.map { ($0.keyCode, $0.modifiers, $0.direction) }
        
        guard !isSuspended else { return }
        
        for (keyCode, modifiers, direction) in bindings {
            registerWindowMoveHotkeyInternal(keyCode: keyCode, modifiers: modifiers, direction: direction, handler: handler)
        }
    }
    
    // MARK: - Swap Hotkeys
    
    enum SwapDirection {
        case left, right, up, down
    }
    
    func registerSwapHotkeysWithBindings(
        _ bindings: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)],
        handler: @escaping (SwapDirection) -> Void
    ) {
        unregisterSwapHotkeys()
        
        self.swapHandler = handler
        
        storedSwapHotkeys = bindings
        
        guard !isSuspended else {
            debugLog("HotkeyManager"," ⚠️ Swap hotkeys NOT registered - hotkeys are suspended")
            return
        }
        
        debugLog("HotkeyManager"," Registering swap hotkeys (isSuspended=\(isSuspended), swapHotkeys.count before=\(swapHotkeys.count))")
        
        for (keyCode, modifiers, direction) in bindings {
            if let ref = registerAdditionalHotkey(
                keyCode: keyCode,
                modifiers: modifiers,
                handler: { 
                    debugLog("HotkeyManager", " 🔥 Swap hotkey fired: \(direction)")
                    handler(direction) 
                }
            ) {
                let entry = HotkeyEntry(
                    id: nextHotkeyID - 1,
                    ref: ref,
                    handler: { 
                        debugLog("HotkeyManager", " 🔥 Swap hotkey fired: \(direction)")
                        handler(direction) 
                    }
                )
                swapHotkeys.append(entry)
                debugLog("HotkeyManager"," ✅ Registered swap hotkey: \(direction) (keyCode=0x\(String(keyCode, radix: 16)), id=\(entry.id))")
            } else {
                debugLog("HotkeyManager"," ❌ Failed to register swap hotkey: \(direction)")
            }
        }
        
        debugLog("HotkeyManager"," Registered \(swapHotkeys.count) swap hotkeys")
    }
    
    /// Internal: Register a single swap hotkey (used by resume)
    private func registerSwapHotkeyInternal(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection, handler: @escaping (SwapDirection) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(direction) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(direction) })
            swapHotkeys.append(entry)
        }
    }
    
    func unregisterSwapHotkeys() {
        for entry in swapHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        swapHotkeys.removeAll()
        storedSwapHotkeys.removeAll()
    }
    
    func registerMoveToSlotHotkeysWithBindings(
        _ bindings: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)],
        handler: @escaping (SwapDirection) -> Void
    ) {
        debugLog("HotkeyManager"," 📋 registerMoveToSlotHotkeysWithBindings called with \(bindings.count) bindings")
        
        unregisterMoveToSlotHotkeys()
        
        self.moveToSlotHandler = handler
        debugLog("HotkeyManager"," moveToSlotHandler set: YES")
        
        storedMoveToSlotHotkeys = bindings
        debugLog("HotkeyManager"," storedMoveToSlotHotkeys count: \(storedMoveToSlotHotkeys.count)")
        
        guard !isSuspended else {
            debugLog("HotkeyManager"," ⚠️ Move-to-slot hotkeys NOT registered - hotkeys are suspended")
            return
        }
        
        debugLog("HotkeyManager"," Registering move-to-slot hotkeys (isSuspended=\(isSuspended))")
        
        for (keyCode, modifiers, direction) in bindings {
            let modString = formatModifiers(modifiers)
            debugLog("HotkeyManager"," Attempting to register: \(direction) keyCode=0x\(String(keyCode, radix: 16)) mods=\(modString)")
            
            if let ref = registerAdditionalHotkey(
                keyCode: keyCode,
                modifiers: modifiers,
                handler: { 
                    debugLog("HotkeyManager", " 🔥 Move-to-slot hotkey fired: \(direction)")
                    handler(direction) 
                }
            ) {
                let entry = HotkeyEntry(
                    id: nextHotkeyID - 1,
                    ref: ref,
                    handler: { 
                        debugLog("HotkeyManager", " 🔥 Move-to-slot hotkey fired: \(direction)")
                        handler(direction) 
                    }
                )
                moveToSlotHotkeys.append(entry)
                debugLog("HotkeyManager"," ✅ Registered move-to-slot: \(direction) (keyCode=0x\(String(keyCode, radix: 16)), id=\(entry.id), mods=\(modString))")
            } else {
                debugLog("HotkeyManager"," ❌ FAILED to register move-to-slot: \(direction) keyCode=0x\(String(keyCode, radix: 16)) mods=\(modString)")
            }
        }
        
        debugLog("HotkeyManager"," 📊 Move-to-slot registration complete: \(moveToSlotHotkeys.count)/\(bindings.count) hotkeys registered")
    }
    
    /// Format modifier flags for logging
    private func formatModifiers(_ mods: UInt32) -> String {
        var parts: [String] = []
        if mods & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if mods & UInt32(optionKey) != 0 { parts.append("Opt") }
        if mods & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if mods & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
    
    func unregisterMoveToSlotHotkeys() {
        for entry in moveToSlotHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        moveToSlotHotkeys.removeAll()
        storedMoveToSlotHotkeys.removeAll()
    }
    
    /// Internal: Register a single move-to-slot hotkey (used by resume)
    private func registerMoveToSlotHotkeyInternal(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection, handler: @escaping (SwapDirection) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(direction) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(direction) })
            moveToSlotHotkeys.append(entry)
        }
    }
    
    private func registerAdditionalHotkey(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) -> EventHotKeyRef? {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = "GSNP".fourCharCode
        hotKeyID.id = nextHotkeyID
        nextHotkeyID += 1
        
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        if eventHandlerRef == nil {
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData = userData else { return noErr }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.handleHotkeyEvent(event)
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            
            guard status == noErr else {
                debugLog("HotkeyManager"," Failed to install event handler, status: \(status)")
                return nil
            }
        }
        
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        
        if registerStatus != noErr {
            debugLog("HotkeyManager"," Failed to register additional hotkey, status: \(registerStatus)")
            return nil
        }
        
        return ref
    }
    
    // MARK: - Resize Hotkeys
    
    enum ResizeDirection {
        case shrinkWidth
        case growWidth
        case shrinkHeight
        case growHeight
    }
    
    private var resizeHotkeys: [HotkeyEntry] = []
    
    func registerResizeHotkeys(
        bindings: [(keyCode: UInt32, modifiers: UInt32, direction: ResizeDirection)],
        handler: @escaping (ResizeDirection) -> Void
    ) {
        unregisterResizeHotkeys()
        
        self.resizeHandler = handler
        storedResizeHotkeys = bindings.map { ($0.keyCode, $0.modifiers, $0.direction) }
        
        guard !isSuspended else { return }
        
        for (keyCode, modifiers, direction) in bindings {
            if let ref = registerAdditionalHotkey(
                keyCode: keyCode,
                modifiers: modifiers,
                handler: { handler(direction) }
            ) {
                let entry = HotkeyEntry(
                    id: nextHotkeyID - 1,
                    ref: ref,
                    handler: { handler(direction) }
                )
                resizeHotkeys.append(entry)
            }
        }
        
        debugLog("HotkeyManager", " Registered \(resizeHotkeys.count) resize hotkeys")
    }
    
    /// Internal: Register a single resize hotkey (used by resume)
    private func registerResizeHotkeyInternal(keyCode: UInt32, modifiers: UInt32, direction: ResizeDirection, handler: @escaping (ResizeDirection) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(direction) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(direction) })
            resizeHotkeys.append(entry)
        }
    }
    
    func unregisterResizeHotkeys() {
        for entry in resizeHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        resizeHotkeys.removeAll()
        storedResizeHotkeys.removeAll()
    }
    
    // MARK: - Focus Slot Hotkeys
    
    private var focusSlotHotkeys: [HotkeyEntry] = []
    
    /// Internal: Register a single focus slot hotkey (used by resume)
    private func registerFocusSlotHotkeyInternal(keyCode: UInt32, modifiers: UInt32, slot: Int, handler: @escaping (Int) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(slot) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(slot) })
            focusSlotHotkeys.append(entry)
        }
    }
    
    // MARK: - Focus Direction Hotkeys (vim-style)
    
    private var focusDirectionHotkeys: [HotkeyEntry] = []
    
    func registerFocusDirectionHotkeys(
        bindings: [(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection)],
        handler: @escaping (SwapDirection) -> Void
    ) {
        unregisterFocusDirectionHotkeys()
        
        self.focusDirectionHandler = handler
        storedFocusDirectionHotkeys = bindings.map { ($0.keyCode, $0.modifiers, $0.direction) }
        
        guard !isSuspended else { return }
        
        for (keyCode, modifiers, direction) in bindings {
            if let ref = registerAdditionalHotkey(
                keyCode: keyCode,
                modifiers: modifiers,
                handler: { handler(direction) }
            ) {
                let entry = HotkeyEntry(
                    id: nextHotkeyID - 1,
                    ref: ref,
                    handler: { handler(direction) }
                )
                focusDirectionHotkeys.append(entry)
            }
        }
        
        debugLog("HotkeyManager", " Registered \(focusDirectionHotkeys.count) focus direction hotkeys")
    }
    
    /// Internal: Register a single focus direction hotkey (used by resume)
    private func registerFocusDirectionHotkeyInternal(keyCode: UInt32, modifiers: UInt32, direction: SwapDirection, handler: @escaping (SwapDirection) -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: { handler(direction) }) {
            let entry = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: { handler(direction) })
            focusDirectionHotkeys.append(entry)
        }
    }
    
    func unregisterFocusDirectionHotkeys() {
        for entry in focusDirectionHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        focusDirectionHotkeys.removeAll()
        storedFocusDirectionHotkeys.removeAll()
    }
    
    // MARK: - Mode Cycle Hotkey
    
    private var modeCycleHotkey: HotkeyEntry?
    
    func registerModeCycleHotkey(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        unregisterModeCycleHotkey()
        
        storedModeCycleHotkey = StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        
        guard !isSuspended else { return }
        
        if let ref = registerAdditionalHotkey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            modeCycleHotkey = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
            debugLog("HotkeyManager", " Registered mode cycle hotkey")
        }
    }
    
    /// Internal: Register mode cycle hotkey (used by resume)
    private func registerModeCycleHotkeyInternal(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            modeCycleHotkey = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: handler)
        }
    }
    
    func unregisterModeCycleHotkey() {
        if let entry = modeCycleHotkey {
            UnregisterEventHotKey(entry.ref)
            modeCycleHotkey = nil
        }
        storedModeCycleHotkey = nil
    }
    
    // MARK: - Fullscreen Toggle Hotkey
    
    private var fullscreenHotkey: HotkeyEntry?
    
    func registerFullscreenHotkey(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        unregisterFullscreenHotkey()
        
        storedFullscreenHotkey = StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        
        guard !isSuspended else { return }
        
        if let ref = registerAdditionalHotkey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            fullscreenHotkey = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
            debugLog("HotkeyManager", " Registered fullscreen toggle hotkey")
        }
    }
    
    /// Internal: Register fullscreen hotkey (used by resume)
    private func registerFullscreenHotkeyInternal(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            fullscreenHotkey = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: handler)
        }
    }
    
    func unregisterFullscreenHotkey() {
        if let entry = fullscreenHotkey {
            UnregisterEventHotKey(entry.ref)
            fullscreenHotkey = nil
        }
        storedFullscreenHotkey = nil
    }
    
    // MARK: - Restore Layout Hotkey
    
    private var restoreLayoutHotkey: HotkeyEntry?
    
    func registerRestoreLayoutHotkey(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        unregisterRestoreLayoutHotkey()
        
        storedRestoreLayoutHotkey = StoredHotkeyInfo(keyCode: keyCode, modifiers: modifiers, handler: handler)
        
        guard !isSuspended else { return }
        
        if let ref = registerAdditionalHotkey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: handler
        ) {
            restoreLayoutHotkey = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
            debugLog("HotkeyManager", " Registered restore layout hotkey")
        }
    }
    
    /// Internal: Register restore layout hotkey (used by resume)
    private func registerRestoreLayoutHotkeyInternal(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        if let ref = registerAdditionalHotkey(keyCode: keyCode, modifiers: modifiers, handler: handler) {
            restoreLayoutHotkey = HotkeyEntry(id: nextHotkeyID - 1, ref: ref, handler: handler)
        }
    }
    
    func unregisterRestoreLayoutHotkey() {
        if let entry = restoreLayoutHotkey {
            UnregisterEventHotKey(entry.ref)
            restoreLayoutHotkey = nil
        }
        storedRestoreLayoutHotkey = nil
    }
    
    // MARK: - Preset-based Registration
    
    func registerFromPreset(
        _ preset: HotkeyPreset,
        handlers: [HotkeyAction: () -> Void]
    ) {
        for (action, binding) in preset.bindings {
            if let handler = handlers[action] {
                registerActionHotkey(action: action, binding: binding, handler: handler)
            }
        }
        
        debugLog("HotkeyManager", " Registered hotkeys from preset: \(preset.type.rawValue)")
    }
    
    private var actionHotkeys: [HotkeyAction: HotkeyEntry] = [:]
    private var storedActionHotkeys: [HotkeyAction: StoredHotkeyInfo] = [:]
    
    /// Actions whose hotkeys are registered with the system right now
    var registeredActions: Set<HotkeyAction> { Set(actionHotkeys.keys) }
    
    private func registerActionHotkey(
        action: HotkeyAction,
        binding: HotkeyBinding,
        handler: @escaping () -> Void
    ) {
        if let existing = actionHotkeys[action] {
            UnregisterEventHotKey(existing.ref)
            actionHotkeys.removeValue(forKey: action)
        }
        storedActionHotkeys[action] = StoredHotkeyInfo(keyCode: binding.keyCode, modifiers: binding.modifiers, handler: handler)
        
        // Don't register if suspended: resumeHotkeys() registers it from storedActionHotkeys
        guard !isSuspended else { return }
        
        if let ref = registerAdditionalHotkey(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers,
            handler: handler
        ) {
            actionHotkeys[action] = HotkeyEntry(
                id: nextHotkeyID - 1,
                ref: ref,
                handler: handler
            )
        }
    }
    
    func unregisterAllActionHotkeys() {
        for (_, entry) in actionHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        actionHotkeys.removeAll()
        storedActionHotkeys.removeAll()
    }
}

extension String {
    var fourCharCode: FourCharCode {
        var result: FourCharCode = 0
        for char in self.utf8.prefix(4) {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}


