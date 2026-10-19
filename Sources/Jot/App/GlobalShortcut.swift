import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { shortcut.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private var registeredChord: KeyChord?

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredChord = nil
    }

    func register(_ chord: KeyChord) throws {
        guard chord != registeredChord else { return }
        let identifier = EventHotKeyID(signature: OSType(0x4A4F5421), id: 1)
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers, identifier,
            GetApplicationEventTarget(), 0, &replacement
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        registeredChord = chord
    }
}
