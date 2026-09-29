import AppKit
import AVFoundation
import SwiftUI
import TandemCore
import TandemUI

// MARK: - Formatting

enum Formatters {
    static func interval(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let rest = Int(seconds) % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes)m \(rest)s"
        }
        return "\(Int(seconds / 3600)) h"
    }

    static func bitrate(kbps: Double) -> String {
        kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : "\(Int(kbps)) kbps"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 45 { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Device & link badges

struct DeviceIcon: View {
    let model: String
    var size: CGFloat = 30
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: DeviceIdentity.systemImage(forModel: model))
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LinkBadge: View {
    let link: LinkKind
    var filled = false

    var body: some View {
        Pill(link.shortName, systemImage: link.systemImage, tint: tint, filled: filled)
            .help("Connected over \(link.displayName)")
    }

    private var tint: Color {
        switch link {
        case .thunderbolt, .ethernet: return Theme.success
        case .wifi, .peerToPeerWiFi, .loopback, .other: return Theme.accentSecondary
        case .bluetooth: return Theme.warning
        }
    }
}

/// Compact monospaced stat, e.g. "42 ms".
struct StatChip: View {
    let systemImage: String
    let value: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold))
            Text(value).font(TandemFont.stat)
        }
        .foregroundStyle(tint)
    }
}

/// Large pairing code display, e.g. "482 913".
struct PairingCodeView: View {
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == " " {
                    Spacer().frame(width: 10)
                } else {
                    Text(String(character))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .frame(width: 40, height: 54)
                        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Theme.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code \(code)")
    }
}

// MARK: - Video layer hosting

/// Hosts an `AVSampleBufferDisplayLayer` (the live view / local preview).
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = layer
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        if view.hostedLayer !== layer { view.hostedLayer = layer }
    }

    final class LayerHostView: NSView {
        var hostedLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hostedLayer {
                    wantsLayer = true
                    layer?.addSublayer(hostedLayer)
                    needsLayout = true
                }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            // Keep the video behind SwiftUI overlays drawn in sibling layers.
            layer?.zPosition = -100
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            layer?.zPosition = -100
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            hostedLayer?.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is visible (not minimized/occluded).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ObservingView)?.onChange = onChange
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            observer = nil
            closeObserver = nil
            guard let window else {
                // Removed from its window (closed): nobody can see it.
                onChange?(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let window = self?.window else { return }
                self?.onChange?(window.occlusionState.contains(.visible))
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.onChange?(false)
            }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
}

// MARK: - Misc

extension View {
    /// Applies a modifier only on macOS 26+ (Liquid Glass), otherwise leaves the view as is.
    @ViewBuilder
    func glassButtonStyleIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// A banner row for errors/notices at the top of a panel.
struct InlineBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = Theme.warning
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(TandemFont.callout)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(TandemButtonStyle(.secondary, size: .small))
            }
            if let onDismiss {
                IconButton("xmark", help: "Dismiss", size: 20, action: onDismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}
