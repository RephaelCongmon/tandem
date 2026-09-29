import AppKit
import SwiftUI

/// Tandem's visual language: graphite surfaces, a violet→cyan "signal" accent,
/// hairline strokes, and Liquid Glass for floating chrome (macOS 26+, with a
/// material fallback on older systems). Every color adapts to light/dark mode.
public enum Theme {
    // MARK: Brand

    public static let accent = Color(hex: 0x7C5CFF)
    public static let accentSecondary = Color(hex: 0x33CFF2)
    public static let live = Color(hex: 0xFF4D5E)
    public static let success = Color(hex: 0x2FD493)
    public static let warning = Color(hex: 0xF7B32B)
    public static let danger = Color(hex: 0xF25F5C)

    public static let accentGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Surfaces (adaptive)

    /// Window canvas behind panels.
    public static let canvas = Color(light: 0xF4F4F7, dark: 0x0D0E12)
    /// Primary panel surface.
    public static let surface = Color(light: 0xFFFFFF, dark: 0x16171C)
    /// Raised elements on top of a surface (cards, bubbles, inputs).
    public static let surfaceRaised = Color(light: 0xF0F0F4, dark: 0x1E2027)
    /// Deeper inset areas (code blocks, wells, the live stage letterbox).
    public static let surfaceSunken = Color(light: 0xE8E8EE, dark: 0x0A0B0E)
    /// Hairline stroke for panel edges and dividers.
    public static let stroke = Color(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    public static let strokeStrong = Color(light: 0x000000, lightAlpha: 0.14, dark: 0xFFFFFF, darkAlpha: 0.16)

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary = Color(light: 0x000000, lightAlpha: 0.38, dark: 0xFFFFFF, darkAlpha: 0.38)

    /// User message bubble fill.
    public static let userBubble = Color(light: 0x7C5CFF, lightAlpha: 0.12, dark: 0x7C5CFF, darkAlpha: 0.22)
}

public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum Radius {
    public static let xs: CGFloat = 6
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 22
}

public enum TandemFont {
    public static let display = Font.system(size: 28, weight: .bold, design: .default)
    public static let title = Font.system(size: 20, weight: .semibold)
    public static let headline = Font.system(size: 14, weight: .semibold)
    public static let body = Font.system(size: 13.5)
    public static let callout = Font.system(size: 12.5)
    public static let caption = Font.system(size: 11.5)
    public static let micro = Font.system(size: 10, weight: .semibold)
    public static let mono = Font.system(size: 12.5, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, design: .monospaced)
    public static let stat = Font.system(size: 11, weight: .medium).monospacedDigit()
}

// MARK: - Color helpers

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// A color that resolves differently in light and dark appearances.
    init(light: UInt32, lightAlpha: Double = 1, dark: UInt32, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .darkAqua
                || appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) == .vibrantDark
            let hex = isDark ? dark : light
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}
