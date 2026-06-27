import AppKit
import ApplicationServices
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
    // The system disables a tap if it ever times out; re-enable and keep going.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags   // CGEvent isn't Sendable; pass only the value-type flags
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
    private var poll: Task<Void, Never>?
    private var prompted = false

    init(onPress: @escaping @Sendable () -> Void, onRelease: @escaping @Sendable () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard tap == nil else { return }
        // A session tap on keyboard events needs Accessibility. tapCreate can
        // succeed while untrusted but the OS won't *deliver* events, so gate on
        // trust: prompt, then poll, and only build the tap once granted.
        if !AXIsProcessTrusted() {
            Diag.log("hotkey: Accessibility not granted — prompting + polling")
            promptAccessibilityOnce()
            scheduleTrustPoll()
            return
        }
        createTap()
    }

    private func createTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Diag.log("hotkey: tapCreate returned nil despite trust — polling")
            scheduleTrustPoll()
            return
        }
        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        Diag.log("hotkey: tap live — Fn ready")
    }

    /// Poll Accessibility trust; build the tap the moment it's granted so Fn
    /// starts working without a relaunch.
    private func scheduleTrustPoll() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.tap == nil else { return }
                if AXIsProcessTrusted() {
                    Diag.log("hotkey: Accessibility granted — building tap")
                    self.createTap()
                    return
                }
            }
        }
    }

    private func promptAccessibilityOnce() {
        guard !prompted else { return }
        prompted = true
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Diag.log("hotkey: tap was disabled, re-enabled")
    }

    // Always runs on the main actor (bridged from the C callback).
    fileprivate func handle(flags: CGEventFlags) {
        let isFn = flags.contains(.maskSecondaryFn)
        guard isFn != fnDown else { return }
        let now = Date()
        guard now.timeIntervalSince(lastChange) >= 0.12 else { return } // debounce
        lastChange = now
        fnDown = isFn
        Diag.log("hotkey.fn \(isFn ? "DOWN" : "UP")")
        isFn ? onPress() : onRelease()
    }
}
