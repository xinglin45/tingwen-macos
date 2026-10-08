import AppKit
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    static let standard = KeyboardShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyName: "Space")
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        guard let name = names[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased(), !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: name)
    }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: KeyboardShortcut?
    private var localMonitor: Any?
    private var carbonKeyHeld = false
    private var lastTrigger = -Double.infinity
    var action: (() -> Void)?

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == 0x4C535458 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in
                if pressed {
                    guard !shortcut.carbonKeyHeld else { return }
                    shortcut.carbonKeyHeld = true
                    shortcut.trigger()
                } else { shortcut.carbonKeyHeld = false }
            }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Also handle app-local key events. This covers focused controls and
        // accessibility-generated keys that bypass the system hot-key dispatcher.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let configured = self.registeredShortcut,
                  let candidate = KeyboardShortcut(event: event),
                  candidate.keyCode == configured.keyCode, candidate.modifiers == configured.modifiers else { return event }
            if !event.isARepeat { self.trigger() }
            return nil
        }
    }

    private func trigger() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTrigger > 0.15 else { return }
        lastTrigger = now
        action?()
    }

    func register(_ shortcut: KeyboardShortcut) -> Bool {
        if registeredShortcut == shortcut, hotKey != nil { return true }
        guard handler != nil else { return false }
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: 0x4C535458, id: 1),
                                        GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr else { return false }
        suspend()
        hotKey = candidate
        registeredShortcut = shortcut
        return true
    }

    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
        carbonKeyHeld = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
