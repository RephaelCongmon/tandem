import SwiftUI

/// A small "Edited" pill with a pencil icon, for overlaying the thumbnail of
/// an attachment that has markup (e.g. in the chat composer).
///
/// ```swift
/// thumbnail
///     .overlay(alignment: .bottomLeading) {
///         if !attachment.markup.isEmpty {
///             MarkupThumbnailBadge().padding(4)
///         }
///     }
/// ```
public struct MarkupThumbnailBadge: View {
    private let title: String

    /// - Parameter title: The badge text; "Edited" by default.
    public init(_ title: String = "Edited") {
        self.title = title
    }

    public var body: some View {
        Pill(title, systemImage: "pencil", tint: Theme.accent, filled: true)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}
