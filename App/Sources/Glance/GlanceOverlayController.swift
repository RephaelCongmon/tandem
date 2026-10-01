import AppKit
import Observation
import SwiftUI
import TandemCore
import TandemUI

final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class GlanceOverlayController {
    private(set) var session = GlanceSession()
    private(set) var ownerName: String?
    @ObservationIgnored private(set) var panel: GlancePanel?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var preferredDisplayID: String?
    @ObservationIgnored private let scrollView = NSScrollView()
    @ObservationIgnored private let document = GlanceDocumentContainer()
    @ObservationIgnored private let header = NSTextField(labelWithString: "GLANCE INJECT")
    @ObservationIgnored private var hosting: NSHostingView<GlanceDocument>?
    @ObservationIgnored private var renderedContent: GlanceContent?
    @ObservationIgnored private var renderedWidth: CGFloat = 0
    @ObservationIgnored private var renderedFont: Double = 0
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPanel(); self?.onChange?() }
        }
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    @discardableResult
    func apply(_ command: GlanceCommand, from viewer: UUID, ownerName: String) -> String? {
        if let error = session.apply(command, from: viewer) { return error }
        if command.content != nil { self.ownerName = ownerName }
        if command.clear { self.ownerName = nil }
        if !command.isQuery { refreshPanel() }
        return nil
    }

    func status(for viewer: UUID, error: String? = nil) -> GlanceStatus {
        var layout = session.layout
        if let screen = targetScreen { layout.displayID = Self.id(screen) }
        let maximum = max(0, document.frame.height - scrollView.contentSize.height)
        return .init(revision: session.revision, layout: layout, visible: session.visible,
                     hasContent: session.content != nil, isOwner: session.owner == viewer,
                     scrollFraction: maximum > 0 ? min(1, max(0, scrollView.contentView.bounds.minY / maximum)) : 0,
                     maxScrollPoints: maximum, displays: NSScreen.screens.map {
                         .init(id: Self.id($0), name: $0.localizedName, width: $0.visibleFrame.width, height: $0.visibleFrame.height)
                     }, ownerName: ownerName, error: error)
    }

    func hide() {
        guard let owner = session.owner else { return }
        _ = session.apply(.init(revision: session.revision + 1, visible: false), from: owner)
        panel?.orderOut(nil)
        onChange?()
    }

    func reset() {
        session.reset()
        ownerName = nil
        panel?.orderOut(nil)
        renderedContent = nil
        hosting?.rootView = GlanceDocument(content: .init(text: ""), width: renderedWidth, fontSize: 16)
        document.setFrameSize(.init(width: renderedWidth, height: 0))
        onChange?()
    }

    private static func id(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private var targetScreen: NSScreen? {
        let preferred = session.layout.displayID ?? preferredDisplayID
        return NSScreen.screens.first { Self.id($0) == preferred }
            ?? panel?.screen.flatMap { current in NSScreen.screens.first { Self.id($0) == Self.id(current) } }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshPanel() {
        guard let content = session.content else { panel?.orderOut(nil); return }
        guard let screen = targetScreen else { panel?.orderOut(nil); return }
        if panel == nil { makePanel() }
        guard let panel, let container = panel.contentView else { return }
        let frame = session.layout.frame(in: screen.visibleFrame)
        panel.setFrame(frame, display: session.visible)
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(session.layout.opacity).cgColor
        header.stringValue = "GLANCE INJECT · \(ownerName ?? "Studio")"
        header.frame = NSRect(x: 14, y: frame.height - 32, width: frame.width - 28, height: 18)
        scrollView.frame = NSRect(x: 12, y: 12, width: frame.width - 24, height: frame.height - 50)
        let width = scrollView.contentSize.width
        if content != renderedContent || width != renderedWidth || session.layout.fontSize != renderedFont {
            let view = GlanceDocument(content: content, width: width, fontSize: session.layout.fontSize)
            if let hosting { hosting.rootView = view; hosting.invalidateIntrinsicContentSize() }
            else {
                let hosting = NSHostingView(rootView: view)
                document.addSubview(hosting)
                self.hosting = hosting
            }
            let height = max(scrollView.contentSize.height, hosting?.fittingSize.height ?? 0)
            document.setFrameSize(NSSize(width: width, height: height))
            hosting?.frame = document.bounds
            renderedContent = content
            renderedWidth = width
            renderedFont = session.layout.fontSize
        }
        let maximum = max(0, document.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximum * session.scrollFraction))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if session.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func makePanel() {
        let panel = GlancePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Glance Inject"
        panel.identifier = NSUserInterfaceItemIdentifier("glance-inject")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        header.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        header.textColor = NSColor.white.withAlphaComponent(0.7)
        scrollView.drawsBackground = false
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        container.addSubview(header)
        container.addSubview(scrollView)
        panel.contentView = container
        self.panel = panel
    }
}

private final class GlanceDocumentContainer: NSView { override var isFlipped: Bool { true } }

private struct GlanceDocument: View {
    let content: GlanceContent
    let width: CGFloat
    let fontSize: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            GlanceMarkdownView(blocks: MarkdownDocument.parse(content.text).blocks, fontSize: fontSize)
        }
        .frame(width: max(1, width), alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
    }
}
