import AppKit
import Carbon.HIToolbox
import FluxCore

/// System-wide shortcuts, through the Carbon hot-key API: it needs no Accessibility
/// permission and only ever sees the registered combinations, never other typing.
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    var perform: ((GlobalShortcutAction) -> Void)?
    /// Actions whose combination the system refused (taken by another app).
    private(set) var unavailable: Set<GlobalShortcutAction> = []

    private var shortcuts: [GlobalShortcutAction: KeyCombo] = [:]
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var suspended = false

    private static let signature: OSType = 0x464C_5558 // 'FLUX'

    private init() {}

    func register(_ shortcuts: [GlobalShortcutAction: KeyCombo]) {
        guard shortcuts != self.shortcuts else { return }
        self.shortcuts = shortcuts
        if !suspended { install() }
    }

    /// While recording a new shortcut, so pressing a current one is recorded, not run.
    func suspend() {
        suspended = true
        removeAll()
    }

    func resume() {
        suspended = false
        install()
    }

    private func install() {
        removeAll()
        installHandler()
        var refused: Set<GlobalShortcutAction> = []
        for (index, action) in GlobalShortcutAction.allCases.enumerated() {
            guard let combo = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered.append(ref) } else { refused.insert(action) }
        }
        unavailable = refused
    }

    private func removeAll() {
        for ref in registered { UnregisterEventHotKey(ref) }
        registered = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id) - 1
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                if GlobalShortcutAction.allCases.indices.contains(index) {
                    GlobalHotKeys.shared.perform?(GlobalShortcutAction.allCases[index])
                }
            }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
