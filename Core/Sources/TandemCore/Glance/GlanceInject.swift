import CoreGraphics
import Foundation

public struct GlanceContent: Codable, Sendable, Hashable {
    public var text: String
    public var title: String
    public init(text: String, title: String = "Injected text") { self.text = text; self.title = title }
    public static let maximumBytes = 64 * 1024
}

/// Top-left position as a fraction of the space remaining around the panel.
public struct GlanceLayout: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var opacity: Double
    public var fontSize: Double
    public var displayID: String?
    public init(x: Double = 0.95, y: Double = 0.06, width: Double = 0.36, height: Double = 0.4,
                opacity: Double = 0.75, fontSize: Double = 16, displayID: String? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.opacity = opacity; self.fontSize = fontSize; self.displayID = displayID
    }
    public var isFinite: Bool { [x, y, width, height, opacity, fontSize].allSatisfy(\.isFinite) }
    public var bounded: Self {
        .init(x: min(1, max(0, x)), y: min(1, max(0, y)), width: min(0.85, max(0.2, width)),
              height: min(0.85, max(0.18, height)), opacity: min(0.95, max(0.15, opacity)),
              fontSize: min(28, max(12, fontSize)), displayID: displayID)
    }
    public func frame(in visible: CGRect) -> CGRect {
        guard isFinite, visible.width > 0, visible.height > 0 else { return .zero }
        let layout = bounded
        let width = min(visible.width, max(320, visible.width * layout.width))
        let height = min(visible.height, max(160, visible.height * layout.height))
        return CGRect(x: visible.minX + (visible.width - width) * layout.x,
                      y: visible.maxY - height - (visible.height - height) * layout.y,
                      width: width, height: height)
    }
}

public struct GlanceCommand: Codable, Sendable, Hashable {
    public var revision: UInt64
    public var content: GlanceContent?
    public var layout: GlanceLayout?
    public var visible: Bool?
    public var scrollFraction: Double?
    public var clear: Bool
    public init(revision: UInt64, content: GlanceContent? = nil, layout: GlanceLayout? = nil,
                visible: Bool? = nil, scrollFraction: Double? = nil, clear: Bool = false) {
        self.revision = revision; self.content = content; self.layout = layout
        self.visible = visible; self.scrollFraction = scrollFraction; self.clear = clear
    }
    public var isQuery: Bool { content == nil && layout == nil && visible == nil && scrollFraction == nil && !clear }
}

public struct GlanceDisplay: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var width: Double
    public var height: Double
    public init(id: String, name: String, width: Double, height: Double) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
}

public struct GlanceStatus: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var revision: UInt64
    public var layout: GlanceLayout
    public var visible: Bool
    public var hasContent: Bool
    public var isOwner: Bool
    public var scrollFraction: Double
    public var maxScrollPoints: Double
    public var displays: [GlanceDisplay]
    public var ownerName: String?
    public var error: String?
    public init(revision: UInt64 = 0, layout: GlanceLayout = .init(), visible: Bool = false, enabled: Bool = true,
                hasContent: Bool = false, isOwner: Bool = false, scrollFraction: Double = 0,
                maxScrollPoints: Double = 0, displays: [GlanceDisplay] = [], ownerName: String? = nil, error: String? = nil) {
        self.revision = revision; self.layout = layout; self.visible = visible; self.hasContent = hasContent
        self.isOwner = isOwner; self.scrollFraction = scrollFraction; self.maxScrollPoints = maxScrollPoints
        self.displays = displays; self.ownerName = ownerName; self.error = error
        self.enabled = enabled
    }
}

public struct GlanceSession: Sendable {
    private var revisions: [UUID: UInt64] = [:]
    public private(set) var owner: UUID?
    public private(set) var revision: UInt64 = 0
    public private(set) var content: GlanceContent?
    public private(set) var layout = GlanceLayout()
    public private(set) var visible = false
    public private(set) var scrollFraction: Double = 0
    public init() {}
    public mutating func apply(_ command: GlanceCommand, from viewer: UUID) -> String? {
        if let content = command.content {
            guard !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Paste some text to inject." }
            guard content.text.utf8.count <= GlanceContent.maximumBytes, content.title.utf8.count <= 512 else { return "Glance text must be 64 KiB or less." }
        }
        guard command.layout?.isFinite != false, command.scrollFraction?.isFinite != false else { return "Invalid Glance placement or scroll." }
        if command.isQuery { return nil }
        guard command.content != nil || owner == viewer else { return "Inject text to take control of Glance." }
        if let previous = revisions[viewer], command.revision <= previous { return "That Glance update was superseded." }
        if let content = command.content {
            owner = viewer
            self.content = content
            scrollFraction = 0
            visible = true
        }
        revision = command.revision
        revisions[viewer] = command.revision
        if let layout = command.layout { self.layout = layout.bounded }
        if let fraction = command.scrollFraction { scrollFraction = min(1, max(0, fraction)) }
        if let visible = command.visible { self.visible = visible }
        if command.clear {
            owner = nil
            content = nil
            visible = false
            scrollFraction = 0
        }
        return nil
    }
    public mutating func reset() {
        let layout = self.layout
        self = .init()
        self.layout = layout
    }
}
