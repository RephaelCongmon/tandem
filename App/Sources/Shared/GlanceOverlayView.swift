import SwiftUI
import TandemCore
import TandemUI

/// What a Glance shows. The Source's overlay and the Studio's stand-in for it on the live
/// view draw the same `GlanceOverlayView`, so the Studio sees the text wrap and scroll exactly
/// as it does on the shared Mac.
struct GlanceOverlayContent: Equatable {
    var text: String
    var title: String?
    var origin: GlanceContent.Origin
    var isStreaming: Bool
    /// Who sent it (the Studio's name), shown in the header on the Source.
    var from: String?
    /// The Studio that sent it isn't connected right now.
    var isDisconnected = false

    static let empty = GlanceOverlayContent(text: "", title: nil, origin: .note, isStreaming: false)
}

/// Glance's passive overlay look: a dark see-through panel (only the backdrop fades, the text
/// stays opaque), a small mint header, and text that scrolls to an offset the Studio sets.
struct GlanceOverlayView: View {
    /// Glance's panel color and accent.
    static let panelColor = Color(red: 0.045, green: 0.052, blue: 0.061)
    static let mint = Color(red: 0.57, green: 0.91, blue: 0.76)
    static let cornerRadius: CGFloat = 14
    /// Glance's 14 pt text; no Copy buttons, since clicks pass through the overlay.
    static let markdownStyle = MarkdownStyle(bodyFont: .system(size: 14), textColor: .white, showsCopyButtons: false)
    /// Space above and below the text inside the scrolling area.
    static let textInsets = EdgeInsets(top: 2, leading: 16, bottom: 14, trailing: 16)

    let content: GlanceOverlayContent
    /// Points from the top of the text (in the overlay's own points).
    let scrollOffset: Double
    let backgroundOpacity: Double
    let textScale: Double
    /// The Source's hint for hiding it.
    var hint: String?
    /// Called with the height of the whole text and of the part that fits, in points.
    var onMeasure: ((_ content: Double, _ viewport: Double) -> Void)?

    /// The text's height before scaling (scaling doesn't change layout).
    @State private var unscaledContentHeight: Double = 0
    @State private var viewportHeight: Double = 0

    /// The text's height on screen, in points.
    private var contentHeight: Double { unscaledContentHeight * textScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            textArea
            if let hint {
                Text(hint)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.panelColor.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .foregroundStyle(Color.white)
        .tint(Self.mint)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Glance: \(content.text)")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Self.mint)
            Text("GLANCE")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(1.4)
            if let caption {
                Text(caption)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if content.isStreaming {
                ProgressView().controlSize(.mini)
                Text("Writing…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.mint)
            } else if content.isDisconnected {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .help("The studio isn't connected")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private var caption: String? {
        let parts = [content.title, content.from.map { "from \($0)" }].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var maxOffset: Double { GlanceScroll.maxOffset(content: contentHeight, viewport: viewportHeight) }
    private var offset: Double { min(max(0, scrollOffset), maxOffset) }

    private var textArea: some View {
        GeometryReader { geometry in
            let scale = CGFloat(textScale)
            textBody(width: geometry.size.width / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(y: -CGFloat(offset))
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
        .mask(fadeMask)
        .overlay(alignment: .trailing) { scrollIndicator }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewportHeight = Double(height)
            onMeasure?(contentHeight, viewportHeight)
        }
        .onChange(of: textScale) { _, _ in
            onMeasure?(contentHeight, viewportHeight)
        }
    }

    /// The text laid out at the unscaled width, measured before scaling.
    private func textBody(width: CGFloat) -> some View {
        Group {
            if content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(content.isStreaming ? "Writing…" : "Nothing to show yet.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.56))
            } else {
                MarkdownView(content.text, style: Self.markdownStyle)
            }
        }
        .padding(Self.textInsets)
        .frame(width: width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            unscaledContentHeight = Double(height)
            onMeasure?(contentHeight, viewportHeight)
        }
    }

    /// Fades the edges where more text is hidden above or below.
    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(offset > 1 ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .black.opacity(offset < maxOffset - 1 ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
        }
    }

    /// A thin bar on the right showing how much text there is and where the view is.
    @ViewBuilder
    private var scrollIndicator: some View {
        if contentHeight > viewportHeight + 1, viewportHeight > 0 {
            GeometryReader { geometry in
                let track = geometry.size.height - 8
                let thumb = max(18, track * CGFloat(viewportHeight / contentHeight))
                let progress = maxOffset > 0 ? CGFloat(offset / maxOffset) : 0
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 3, height: thumb)
                    .offset(y: 4 + (track - thumb) * progress)
            }
            .frame(width: 3)
            .padding(.trailing, 5)
        }
    }
}
