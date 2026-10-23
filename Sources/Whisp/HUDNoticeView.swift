import AppKit
import QuartzCore

/// Static, click-through guidance with a consistent dark surface in either
/// system appearance. Speech activity is drawn separately from these notices.
@MainActor
final class HUDNoticeView: NSView {
    private let icon = NSImageView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let padding: CGFloat = 16
    private let iconSize: CGFloat = 15
    private let iconGap: CGFloat = 10
    private let textGap: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Self.color(0x1E2026).cgColor
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.borderColor = Self.color(0xCFE2FF, alpha: 0.17).cgColor
        layer?.borderWidth = 0.75
        layer?.masksToBounds = true

        icon.identifier = NSUserInterfaceItemIdentifier("notice.icon")
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        addSubview(icon)

        configure(heading, identifier: "notice.heading", size: 13, weight: .semibold,
                  color: Self.color(0xEDEEF2))
        configure(detail, identifier: "notice.detail", size: 12, weight: .regular,
                  color: Self.color(0xB2B3BA))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setMessage(_ text: String) {
        let message = Self.presentation(for: text)
        heading.stringValue = message.heading
        detail.stringValue = message.detail
        detail.isHidden = message.detail.isEmpty
        icon.image = NSImage(systemSymbolName: message.warning ? "exclamationmark.circle" : "info.circle",
                             accessibilityDescription: nil)
        icon.contentTintColor = Self.color(message.warning ? 0xFDBA74 : 0xB2B3BA)
        // Preserve the original diagnostic and recovery instructions, while
        // including the extra guidance added to the silent-recording notice.
        setAccessibilityLabel(message.accessibilityText)
        needsLayout = true
    }

    func sizeThatFits(width: CGFloat) -> NSSize {
        let textWidth = max(1, width - padding * 2 - iconSize - iconGap)
        let headingHeight = measuredHeight(of: heading, width: textWidth)
        let detailHeight = detail.isHidden ? 0 : measuredHeight(of: detail, width: textWidth)
        let contentHeight = headingHeight + (detail.isHidden ? 0 : textGap + detailHeight)
        return NSSize(width: width, height: max(68, ceil(contentHeight + padding * 2)))
    }

    override func layout() {
        super.layout()
        let textX = padding + iconSize + iconGap
        let textWidth = max(1, bounds.width - textX - padding)
        let headingHeight = measuredHeight(of: heading, width: textWidth)
        let detailHeight = detail.isHidden ? 0 : measuredHeight(of: detail, width: textWidth)
        let textHeight = headingHeight + (detail.isHidden ? 0 : textGap + detailHeight)
        let top = max(padding, (bounds.height - textHeight) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = NSRect(x: padding, y: top + 2, width: iconSize, height: iconSize)
        heading.frame = NSRect(x: textX, y: top, width: textWidth, height: headingHeight)
        detail.frame = NSRect(x: textX, y: top + headingHeight + textGap,
                              width: textWidth, height: detailHeight)
        CATransaction.commit()
    }

    private func configure(_ label: NSTextField, identifier: String, size: CGFloat,
                           weight: NSFont.Weight, color: NSColor) {
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    private func measuredHeight(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        // NSTextField's cell has a small horizontal inset. Measure inside it,
        // with no height cap, so long provider and recovery messages wrap fully.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let rect = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font ?? NSFont.systemFont(ofSize: 12),
                         .paragraphStyle: paragraph])
        return ceil(rect.height) + 2
    }

    private struct Presentation {
        let heading: String
        let detail: String
        let warning: Bool
        let accessibilityText: String
    }

    private static func presentation(for rawText: String) -> Presentation {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .lowercased()
        if normalized == "nothing heard" || normalized == "no audio captured" {
            return Presentation(heading: "Nothing heard",
                                detail: "Hold Fn while you speak, then release.",
                                warning: false,
                                accessibilityText: "\(text). Hold Fn while you speak, then release.")
        }
        if text == "Text field changed. Use Command+V or Copy Last Dictation." {
            return Presentation(heading: "Choose a text field",
                                detail: "Click where you want the text. Use Command+V or Copy Last Dictation.",
                                warning: false, accessibilityText: text)
        }

        let warningTerms = ["accessibility", "permission", "microphone unavailable", "microphone access",
                            "api key", "network", "connection", "internet", "timed out", "timeout",
                            "request failed", "server error", "unauthorized", "denied"]
        let warning = warningTerms.contains { normalized.contains($0) }
        // Only split at a sentence boundary followed by whitespace, avoiding
        // decimal values and hostnames. Preserve every subsequent sentence.
        if let boundary = text.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            let heading = String(text[..<boundary.lowerBound])
            let detail = String(text[boundary.upperBound...])
            return Presentation(heading: heading, detail: detail, warning: warning,
                                accessibilityText: text)
        }
        return Presentation(heading: text, detail: "", warning: warning, accessibilityText: text)
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
