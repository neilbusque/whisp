import CoreGraphics

/// Creates a shortcut without borrowing the session's modifier/button state.
/// Construction is separate from posting so tests never inject user input.
struct SyntheticKeypress {
    static let eventTag: Int64 = 0x5748495350 // WHISP
    let source: CGEventSource
    let down: CGEvent
    let up: CGEvent

    init?(keyCode: CGKeyCode, command: Bool, physicalFlags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.localEventsSuppressionInterval = 0
        let hardwareEvents: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents,
                                                .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(hardwareEvents,
            state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(hardwareEvents,
            state: .eventSuppressionStateRemoteMouseDrag)
        source.userData = Self.eventTag
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        down.flags = command ? .maskCommand : []
        // End our shortcut without leaving Command active or releasing a
        // modifier the user is physically holding.
        up.flags = physicalFlags
        self.source = source
        self.down = down
        self.up = up
    }

    static func isWhispEvent(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    func post() {
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
