import AppKit
import SwiftUI

/// Whisp's visual identity. One small palette built around the idea of voice
/// becoming visible: an iris→aqua accent for the live waveform, mint for
/// success, amber for trouble. Used by the HUD (AppKit) and the windows (SwiftUI).
enum Theme {
    static let ink   = NSColor(srgbRed: 0.055, green: 0.067, blue: 0.086, alpha: 1) // #0E1116
    static let mist  = NSColor(srgbRed: 0.910, green: 0.922, blue: 0.949, alpha: 1) // #E8EBF2
    static let muted = NSColor(srgbRed: 0.541, green: 0.576, blue: 0.651, alpha: 1) // #8A93A6
    static let iris  = NSColor(srgbRed: 0.486, green: 0.549, blue: 0.973, alpha: 1) // #7C8CF8
    static let aqua  = NSColor(srgbRed: 0.310, green: 0.847, blue: 0.910, alpha: 1) // #4FD8E8
    static let mint  = NSColor(srgbRed: 0.353, green: 0.847, blue: 0.651, alpha: 1) // #5AD8A6
    static let amber = NSColor(srgbRed: 0.961, green: 0.651, blue: 0.137, alpha: 1) // #F5A623

    /// SF Pro Rounded at a given size/weight, falling back to system if rounded
    /// isn't available.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

extension Color {
    static let wInk   = Color(nsColor: Theme.ink)
    static let wMist  = Color(nsColor: Theme.mist)
    static let wMuted = Color(nsColor: Theme.muted)
    static let wIris  = Color(nsColor: Theme.iris)
    static let wAqua  = Color(nsColor: Theme.aqua)
    static let wMint  = Color(nsColor: Theme.mint)
    static let wAmber = Color(nsColor: Theme.amber)

    /// The signature voice gradient.
    static let voiceGradient = LinearGradient(
        colors: [.wIris, .wAqua], startPoint: .leading, endPoint: .trailing)
}
