import AppKit
import CoreGraphics

// CGEventTap callback — must be a global C function pointer.
// `refcon` holds an unretained pointer to the owning HotkeyMonitor instance.
// The tap's run-loop source is added to CFRunLoopGetMain(), so this callback
// is always delivered on the main thread; `MainActor.assumeIsolated` bridges
// into the actor without a dispatch hop.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // Read the value-type flags here (CGEvent is not Sendable) and hand only
    // those across the actor boundary.
    let flags = event.flags
    MainActor.assumeIsolated { monitor.handle(flags: flags) }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class HotkeyMonitor {
    private let onPress: @Sendable () -> Void
    private let onRelease: @Sendable () -> Void
    private var tap: CFMachPort?
    private var fnDown = false
    private var lastChange = Date.distantPast

    init(onPress: @escaping @Sendable () -> Void, onRelease: @escaping @Sendable () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard tap == nil else { return } // already started; don't orphan the existing tap
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Whisp: failed to create event tap — grant Accessibility permission in System Settings > Privacy & Security > Accessibility.")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Called from the global C callback via MainActor.assumeIsolated, so this
    // always runs on the main actor — state mutation and synchronous callback
    // invocation are safe.
    fileprivate func handle(flags: CGEventFlags) {
        let isFn = flags.contains(.maskSecondaryFn)
        guard isFn != fnDown else { return }
        let now = Date()
        guard now.timeIntervalSince(lastChange) >= 0.15 else { return } // 150 ms debounce
        lastChange = now
        fnDown = isFn
        isFn ? onPress() : onRelease()
    }
}
