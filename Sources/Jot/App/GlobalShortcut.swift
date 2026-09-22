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

    func register(_ choice: ShortcutChoice) throws {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        let signature = OSType(0x4A4F5421) // JOT!
        let identifier = EventHotKeyID(signature: signature, id: 1)
        let values: (UInt32, UInt32) = switch choice {
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlSpace: (UInt32(kVK_Space), UInt32(controlKey))
        case .commandShiftJ: (UInt32(kVK_ANSI_J), UInt32(cmdKey | shiftKey))
        }
        let status = RegisterEventHotKey(values.0, values.1, identifier, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
