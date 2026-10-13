import AppKit
import SwiftUI

/// Visual language: warm ivory (light) / warm charcoal (dark) surfaces, one
/// terracotta accent, a serif for display text (New York) and SF for UI.
/// Flat: no gradients, no blur, no implicit layout animation.
enum Theme {
    // MARK: Colour (light / dark)

    static let background = adaptive(light: 0xFAF9F5, dark: 0x262624)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x30302E)
    static let surfaceSunken = adaptive(light: 0xF0EEE6, dark: 0x1F1E1D)
    static let border = adaptive(light: 0xE6E3D8, dark: 0x3E3E3A)
    static let borderStrong = adaptive(light: 0xD4D0C3, dark: 0x4C4B46)
    static let text = adaptive(light: 0x141413, dark: 0xF5F4EF)
    static let textSecondary = adaptive(light: 0x6B6A64, dark: 0xA8A69D)
    static let textTertiary = adaptive(light: 0x9C9A92, dark: 0x7A7870)
    static let accent = adaptive(light: 0xC96442, dark: 0xD97757)          // terracotta
    static let accentText = adaptive(light: 0xB05535, dark: 0xE38B6D)
    static let accentWash = adaptive(light: 0xF6E7E0, dark: 0x3D2D27)
    static let danger = adaptive(light: 0xB43C30, dark: 0xE5695C)
    static let dangerWash = adaptive(light: 0xF7E3E0, dark: 0x3F2826)
    static let warning = adaptive(light: 0x9A6B12, dark: 0xD9A441)
    static let warningWash = adaptive(light: 0xF6EED9, dark: 0x3A3223)
    static let success = adaptive(light: 0x4B7F52, dark: 0x7FB685)
    // Featured banner: a deep warm surface in both modes.
    static let heroFill = adaptive(light: 0x2E2B27, dark: 0x3A302B)
    static let heroText = Color(nsColor: NSColor(hex: 0xF5F1E8))
    static let heroTextSecondary = Color(nsColor: NSColor(hex: 0xC9C2B4))
    static let heroButton = Color(nsColor: NSColor(hex: 0xF5F1E8))
    static let heroButtonText = Color(nsColor: NSColor(hex: 0x1F1E1D))

    // MARK: Metrics

    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let panelWidth: CGFloat = 320
    static let padding: CGFloat = 16

    // MARK: Type

    /// Display serif (New York), for headlines and the countdown.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Continuous-corner rounded rectangle (the Apple "squircle" curve).
func rounded(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

/// A quiet surface with a fine border.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    var fill: Color = Theme.surface
    var stroke: Color = Theme.border
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rounded(Theme.cardRadius).fill(fill))
            .overlay(rounded(Theme.cardRadius).strokeBorder(stroke, lineWidth: 1))
    }
}

/// Outlined secondary button; `selected` fills it with the accent wash.
struct OutlineButtonStyle: ButtonStyle {
    var accent = false
    var expand = true
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        OutlineBody(configuration: configuration, accent: accent, expand: expand, height: height)
    }

    private struct OutlineBody: View {
        let configuration: ButtonStyleConfiguration
        let accent: Bool
        let expand: Bool
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.ui(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent ? Theme.accentText : Theme.text)
                .padding(.horizontal, 12)
                .frame(maxWidth: expand ? .infinity : nil, minHeight: height)
                .background(rounded(Theme.controlRadius).fill(configuration.isPressed ? Theme.surfaceSunken : Theme.surface))
                .overlay(rounded(Theme.controlRadius).strokeBorder(configuration.isPressed ? Theme.borderStrong : Theme.border, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(rounded(Theme.controlRadius))
        }
    }
}

/// Solid primary action in the accent colour.
struct PrimaryButtonStyle: ButtonStyle {
    var expand = false
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, expand: expand, color: color)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let expand: Bool
        let color: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.ui(13, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: expand ? .infinity : nil, minHeight: 30)
                .background(rounded(Theme.controlRadius).fill(color))
                .overlay(rounded(Theme.controlRadius).fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(rounded(Theme.controlRadius))
        }
    }
}

/// Destructive action: outlined, danger-coloured text.
struct DangerButtonStyle: ButtonStyle {
    var expand = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(13, weight: .medium))
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 12)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 30)
            .background(rounded(Theme.controlRadius).fill(configuration.isPressed ? Theme.dangerWash : Theme.surface))
            .overlay(rounded(Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(rounded(Theme.controlRadius))
    }
}

/// Text-only buttons (footer, navigation).
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(12.5))
            .foregroundStyle(configuration.isPressed ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rounded(6).fill(configuration.isPressed ? Theme.surfaceSunken : Color.clear))
            .contentShape(rounded(6))
    }
}

/// A label/value row with a thin monochrome icon.
struct StatusRow: View {
    let symbol: String
    let title: String
    let value: String
    var valueColor: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(Theme.ui(13))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.ui(12.5))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: 22)
    }
}

/// Thin separator inside cards.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.ui(11, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 2)
    }
}

/// Full-colour app mark for in-app use (the Dock/Finder icon follows the
/// user's icon style, which may be monochrome).
@MainActor
enum BrandMark {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "LidlessMark", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }()
}
