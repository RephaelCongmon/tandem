import SwiftUI

// MARK: - Surfaces

public extension View {
    /// A solid panel: surface fill, hairline stroke, continuous corners.
    func tandemPanel(cornerRadius: CGFloat = Radius.l, fill: Color = Theme.surface) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }

    /// Floating chrome (toolbars, HUDs, popovers over video). Uses Liquid Glass on
    /// macOS 26 and a thin material elsewhere.
    @ViewBuilder
    func tandemGlass(cornerRadius: CGFloat = Radius.l, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }

    /// Capsule-shaped glass, for pills and compact toolbars.
    @ViewBuilder
    func tandemGlassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }
}

// MARK: - Buttons

public struct TandemButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, destructive }
    public enum Size { case small, regular, large }

    let kind: Kind
    let size: Size
    let isOn: Bool

    /// `isOn` shows a tool button as switched on (accent text, fill and border).
    public init(_ kind: Kind = .primary, size: Size = .regular, isOn: Bool = false) {
        self.kind = kind
        self.size = size
        self.isOn = isOn
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size, isOn: isOn)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height)
                .background(background)
                .overlay(border)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var font: Font {
            switch size {
            case .small: return .system(size: 11.5, weight: .semibold)
            case .regular: return .system(size: 12.5, weight: .semibold)
            case .large: return .system(size: 14, weight: .semibold)
            }
        }

        private var height: CGFloat {
            switch size {
            case .small: return 24
            case .regular: return 30
            case .large: return 38
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .small: return 9
            case .regular: return 13
            case .large: return 18
            }
        }

        private var cornerRadius: CGFloat { size == .large ? Radius.m : Radius.s }

        private var foreground: Color {
            if isOn, kind == .secondary || kind == .ghost { return Theme.accent }
            switch kind {
            case .primary: return .white
            case .secondary: return Theme.textPrimary
            case .ghost: return hovering ? Theme.textPrimary : Theme.textSecondary
            case .destructive: return .white
            }
        }

        @ViewBuilder
        private var background: some View {
            if isOn, kind == .secondary || kind == .ghost {
                Theme.accent.opacity(hovering ? 0.22 : 0.16)
            } else {
                kindBackground
            }
        }

        @ViewBuilder
        private var kindBackground: some View {
            switch kind {
            case .primary:
                ZStack {
                    Theme.accentGradient
                    Color.white.opacity(hovering ? 0.10 : 0)
                    Color.black.opacity(configuration.isPressed ? 0.12 : 0)
                }
            case .secondary:
                Theme.surfaceRaised.overlay(Color.primary.opacity(hovering ? 0.05 : 0))
            case .ghost:
                Color.primary.opacity(hovering ? 0.07 : 0)
            case .destructive:
                Theme.danger.overlay(Color.white.opacity(hovering ? 0.10 : 0))
            }
        }

        @ViewBuilder
        private var border: some View {
            if isOn, kind == .secondary || kind == .ghost {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            } else if kind == .secondary {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
        }
    }
}

public extension ButtonStyle where Self == TandemButtonStyle {
    static var tandemPrimary: TandemButtonStyle { TandemButtonStyle(.primary) }
    static var tandemSecondary: TandemButtonStyle { TandemButtonStyle(.secondary) }
    static var tandemGhost: TandemButtonStyle { TandemButtonStyle(.ghost) }
    static var tandemDestructive: TandemButtonStyle { TandemButtonStyle(.destructive) }
}

/// A compact square icon button with hover feedback; used in toolbars and HUDs.
public struct IconButton: View {
    let systemName: String
    let help: String
    let size: CGFloat
    let isActive: Bool
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ systemName: String,
        help: String,
        size: CGFloat = 28,
        isActive: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.isActive = isActive
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isActive ? (tint ?? Theme.accent) : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(isActive ? (tint ?? Theme.accent).opacity(0.16) : Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Status & labels

/// A small colored dot; optionally pulses (used for "live").
public struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    let size: CGFloat
    @State private var pulse = false

    public init(_ color: Color, pulsing: Bool = false, size: CGFloat = 8) {
        self.color = color
        self.pulsing = pulsing
        self.size = size
    }

    public var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.45))
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing { pulse = true } }
        .onChange(of: pulsing) { _, newValue in pulse = newValue }
        .accessibilityHidden(true)
    }
}

/// A capsule label with optional icon, e.g. link type or state badges.
public struct Pill: View {
    let text: String
    let systemImage: String?
    let tint: Color
    let filled: Bool

    public init(_ text: String, systemImage: String? = nil, tint: Color = Theme.textSecondary, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.filled = filled
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold))
            }
            Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
    }
}

/// Renders a keyboard shortcut as key caps, e.g. ⌃ ⌥ S.
public struct KeyCaps: View {
    let keys: [String]

    public init(_ keys: [String]) { self.keys = keys }
    public init(_ display: String) { self.keys = display.map { String($0) } }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 17, minHeight: 17)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.strokeStrong, lineWidth: 0.5)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// Uppercased small section header used in sidebars and settings.
public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Centered empty/blank-slate state with icon, copy, and optional actions.
public struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: Actions

    public init(systemImage: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Spacing.m) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: Spacing.xs) {
                Text(title).font(TandemFont.title)
                Text(message)
                    .font(TandemFont.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions.padding(.top, Spacing.xs)
        }
        .padding(Spacing.xl)
    }
}

public extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Divider using the theme hairline.
public struct Hairline: View {
    let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
