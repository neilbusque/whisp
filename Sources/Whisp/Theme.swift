import AppKit
import SwiftUI

/// Shared charcoal and blue palette, matching Replay Coach.
enum Theme {
    static let ink   = NSColor(srgbRed: 0.094, green: 0.090, blue: 0.110, alpha: 1) // #0E1116
    static let mist  = NSColor(srgbRed: 0.910, green: 0.922, blue: 0.949, alpha: 1) // #E8EBF2
    static let muted = NSColor(srgbRed: 0.541, green: 0.576, blue: 0.651, alpha: 1) // #8A93A6
    static let iris  = NSColor(srgbRed: 0.506, green: 0.714, blue: 1.0, alpha: 1) // #7C8CF8
    static let aqua  = NSColor(srgbRed: 0.506, green: 0.714, blue: 1.0, alpha: 1) // #4FD8E8
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


extension Color {
    private static func workspaceColor(_ name: String, dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static let workspaceBackground = workspaceColor("WhispBackground", dark: (0.075, 0.078, 0.094), light: (0.97, 0.97, 0.98))
    static let workspaceSidebar = workspaceColor("WhispSidebar", dark: (0.094, 0.090, 0.110), light: (0.94, 0.94, 0.96))
    static let workspaceSurface = workspaceColor("WhispSurface", dark: (0.119, 0.125, 0.149), light: (1, 1, 1))
    static let workspaceSelection = workspaceColor("WhispSelection", dark: (0.18, 0.19, 0.22), light: (0.86, 0.88, 0.91))
    static let workspaceAccent = workspaceColor("WhispAccent", dark: (0.506, 0.714, 1), light: (0.02, 0.29, 0.68))
    static let workspaceBorder = Color.secondary.opacity(0.18)
}
