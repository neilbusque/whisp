import AppKit
import WhispCore

@MainActor
final class HUDWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let meter = NSProgressIndicator()
    private var hideWork: Task<Void, Never>?

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        card.layer?.cornerRadius = 12

        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        meter.style = .bar
        meter.minValue = 0; meter.maxValue = 1; meter.isIndeterminate = false
        meter.translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label); card.addSubview(meter)
        window.contentView = card
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 240),
            card.heightAnchor.constraint(equalToConstant: 56),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            meter.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            meter.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            meter.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: f.midX - 120, y: f.minY + 80))
    }

    func setLevel(_ level: Float) {
        meter.doubleValue = Double(level)
    }

    func show(_ status: PipelineStatus) {
        hideWork?.cancel()
        switch status {
        case .idle:         window.orderOut(nil); return
        case .listening:    label.stringValue = "🎙 Listening…"; meter.isHidden = false
        case .transcribing: label.stringValue = "✍️ Transcribing…"; meter.isHidden = true
        case .polishing:    label.stringValue = "✨ Polishing…"; meter.isHidden = true
        case .done:         label.stringValue = "✓ Done"; meter.isHidden = true; scheduleHide()
        case .error(let m): label.stringValue = "⚠️ \(m)"; meter.isHidden = true; scheduleHide()
        }
        positionBottomCenter()
        window.orderFrontRegardless()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        hideWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.window.orderOut(nil)
        }
    }
}
