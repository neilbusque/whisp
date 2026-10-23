import AppKit
import ApplicationServices
import CoreGraphics

// CGEventTap callback — a global C function pointer. Kept lightweight (no file
// I/O) so the tap is never disabled for being slow. Bridges to the main actor.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    let isFn = event.flags.contains(.maskSecondaryFn)
    MainActor.assumeIsolated { monitor.setFn(isFn) }
    return Unmanaged.passUnretained(event)
}

/// Detects the Fn (Globe) key being held, for hold-to-talk. Uses TWO detectors
/// feeding one debounced handler, because the Fn key is delivered inconsistently
/// across Macs: a CGEventTap (maskSecondaryFn) and NSEvent flag monitors
/// (.function). Whichever sees Fn first wins; the shared state de-dupes.
@MainActor
final class HotkeyMonitor {
    private let onPress: @Sendable () -> Void
    private let onRelease: @Sendable () -> Void
    private var tap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnDown = false
    private var poll: Task<Void, Never>?
    private var prompted = false
    private var installed = false

    init(onPress: @escaping @Sendable () -> Void, onRelease: @escaping @Sendable () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard !installed else { return }
        // Both detectors need Accessibility. Gate on trust, prompt, and poll so
        // they come online the moment it's granted (no relaunch).
        if !AXIsProcessTrusted() {
            Diag.log("hotkey: Accessibility not granted — prompting + polling")
            promptAccessibilityOnce()
            scheduleTrustPoll()
            return
        }
        install()
    }

    private func install() {
        guard !installed else { return }
        installed = true

        // Detector 1: NSEvent flag monitors (catch Fn via .function).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            let isFn = e.modifierFlags.contains(.function)
            MainActor.assumeIsolated { self?.setFn(isFn) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            let isFn = e.modifierFlags.contains(.function)
            MainActor.assumeIsolated { self?.setFn(isFn) }
            return e
        }

        // Detector 2: CGEventTap (catch Fn via maskSecondaryFn).
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            tap = newTap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
        }
        Diag.log("hotkey: detectors installed (tap=\(tap != nil), nsevent=true) — Fn ready")
    }

    private func scheduleTrustPoll() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !self.installed else { return }
                if AXIsProcessTrusted() {
                    Diag.log("hotkey: Accessibility granted — installing detectors")
                    self.install()
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
    }

    /// Single debounced entry point for both detectors.
    func setFn(_ isFn: Bool) {
        guard isFn != fnDown else { return }
        // State deduplication is sufficient for the two detectors. A time
        // debounce drops quick key-UP events and can leave the mic running.
        fnDown = isFn
        Diag.log("hotkey.fn \(isFn ? "DOWN" : "UP")")
        isFn ? onPress() : onRelease()
    }
}
