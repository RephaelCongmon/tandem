import AppKit
import SwiftUI
import TandemUI

/// The Glance text field. Pasting a formatted document (Notion, Google Docs, a web page, Word,
/// Pages, Notes) keeps its headings, lists, emphasis, links, code and tables, as Markdown the
/// overlay renders; ⌥⇧⌘V pastes plain text. It grows from one line to five as you type.
struct GlanceDraftEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    var focusOnAppear = true

    static let minHeight: CGFloat = 32
    static let maxHeight: CGFloat = 112

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PasteAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13.5)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GlanceDraftEditor
        weak var textView: PasteAwareTextView?

        init(_ parent: GlanceDraftEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(content.rounded(.up), GlanceDraftEditor.minHeight), GlanceDraftEditor.maxHeight)
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }
    }
}

/// A plain-text view whose ⌘V keeps the clipboard's formatting as Markdown.
final class PasteAwareTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }

    override func paste(_ sender: Any?) {
        guard let markdown = RichTextMarkdown.markdown(from: .general), !markdown.isEmpty else {
            super.paste(sender)
            return
        }
        // Through the normal path, so it can be undone and the binding hears about it.
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: markdown) else { return }
        replaceCharacters(in: range, with: markdown)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let plain = NSPasteboard.general.string(forType: .string) else { return }
        insertText(plain, replacementRange: selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}
