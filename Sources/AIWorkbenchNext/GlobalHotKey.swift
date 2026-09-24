import Carbon
import Foundation

/// Registers a permission-free system-wide keyboard shortcut through Carbon.
/// Carbon hot keys remain supported on modern macOS and do not require the
/// Accessibility or Input Monitoring permissions needed by global event taps.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let identifier: UInt32
    private let action: () -> Void
    private var lastPressedEventAt: TimeInterval = 0
    private var isActive = true

    init?(keyCode: UInt32, modifiers: UInt32, identifier: UInt32 = 1, action: @escaping () -> Void) {
        self.identifier = identifier
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return status }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                guard pressedID.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
                // Carbon can emit a stream of hot-key events while the keys are
                // held. Treat them as one gesture until the stream has been
                // quiet long enough for a deliberate second press.
                let now = ProcessInfo.processInfo.systemUptime
                let isNewGesture = now - owner.lastPressedEventAt > 0.35
                owner.lastPressedEventAt = now
                guard isNewGesture else { return noErr }
                // Re-registration can retire this hot key while a Carbon event
                // is still waiting to reach the main queue. Keep the dispatch
                // weak so an obsolete registration cannot toggle the new panel.
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.isActive else { return }
                    owner.action()
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x41495742), id: identifier) // "AIWB"
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            self.eventHandlerRef = nil
            return nil
        }
    }

    deinit {
        isActive = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
