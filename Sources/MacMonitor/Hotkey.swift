import Carbon

/// Global ⌥⌘M opens the panel from anywhere.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Hotkey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D4D4F4E), id: 1)   // 'MMON'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
