import CoreGraphics
import Foundation

// MARK: - Glance

// Glance puts text from the Studio (something pasted, or an AI answer) in a see-through
// overlay on the Source's screen. The Studio owns the state and drives it in real time:
// `GlanceContent` carries the text (streamed answers send only what's new), `GlanceLayout`
// carries where the overlay sits and how far it's scrolled (latest wins, many per second),
// and the Source answers with `GlanceStatus`: what it applied and the geometry it measured.

/// A rectangle as fractions of a screen, origin at the top left (like the video frame).
public struct GlanceFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The whole screen.
    public static let unit = GlanceFrame(x: 0, y: 0, width: 1, height: 1)
    /// Where a new overlay appears: the top right, out of the way of most content.
    public static let standard = GlanceFrame(x: 0.62, y: 0.07, width: 0.35, height: 0.42)

    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    /// Inside `bounds`, and at least `minWidth` × `minHeight` (all fractions of the screen).
    public func clamped(to bounds: GlanceFrame = .unit, minWidth: Double = 0.05, minHeight: Double = 0.05) -> GlanceFrame {
        let source = isFinite ? self : .standard
        let width = min(max(source.width, min(minWidth, bounds.width)), bounds.width)
        let height = min(max(source.height, min(minHeight, bounds.height)), bounds.height)
        return GlanceFrame(
            x: min(max(source.x, bounds.x), bounds.maxX - width),
            y: min(max(source.y, bounds.y), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    public func offsetBy(dx: Double, dy: Double) -> GlanceFrame {
        GlanceFrame(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The same size, moved to `placement` inside `bounds` with `margin` (fractions) around it.
    public func placed(_ placement: GlancePlacement, in bounds: GlanceFrame = .unit, margin: Double = 0.02) -> GlanceFrame {
        let fitted = clamped(to: bounds)
        let left = bounds.x + margin
        let right = bounds.maxX - margin - fitted.width
        let top = bounds.y + margin
        let bottom = bounds.maxY - margin - fitted.height
        let midX = bounds.x + (bounds.width - fitted.width) / 2
        let midY = bounds.y + (bounds.height - fitted.height) / 2
        let (x, y): (Double, Double)
        switch placement {
        case .topLeft: (x, y) = (left, top)
        case .top: (x, y) = (midX, top)
        case .topRight: (x, y) = (right, top)
        case .left: (x, y) = (left, midY)
        case .center: (x, y) = (midX, midY)
        case .right: (x, y) = (right, midY)
        case .bottomLeft: (x, y) = (left, bottom)
        case .bottom: (x, y) = (midX, bottom)
        case .bottomRight: (x, y) = (right, bottom)
        }
        return GlanceFrame(x: x, y: y, width: fitted.width, height: fitted.height).clamped(to: bounds)
    }
}

public extension GlanceFrame {
    /// This frame on a screen whose frame is `screen`, in AppKit coordinates (origin at the bottom left).
    func rect(in screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX + x * screen.width,
            y: screen.maxY - maxY * screen.height,
            width: width * screen.width,
            height: height * screen.height
        )
    }

    /// `rect` (AppKit coordinates) as fractions of `screen`.
    init(rect: CGRect, in screen: CGRect) {
        let width = max(screen.width, 1)
        let height = max(screen.height, 1)
        self.init(
            x: (rect.minX - screen.minX) / width,
            y: (screen.maxY - rect.maxY) / height,
            width: rect.width / width,
            height: rect.height / height
        )
    }
}

/// Where on the screen the Studio can snap the overlay.
public enum GlancePlacement: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .top: return "Top"
        case .topRight: return "Top Right"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottom: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// The text the overlay shows. Answers stream: while `isStreaming`, each message usually
/// carries only the new words (`appendingToUTF8Count` set).
public struct GlanceContent: Codable, Sendable, Hashable {
    public enum Origin: String, Codable, Sendable, Hashable {
        /// Typed or pasted on the Studio.
        case note
        /// An AI answer.
        case answer
    }

    /// The most text a Glance holds; longer text is cut (UTF-8 bytes).
    public static let maxTextBytes = 256 * 1024

    /// A new id replaces whatever the overlay showed.
    public var documentID: UUID
    /// Grows with every change to the document.
    public var revision: Int
    /// The whole text, or only the part to add when `appendingToUTF8Count` is set.
    public var text: String
    /// Set for an append: the receiver must hold exactly this many UTF-8 bytes of the
    /// document already, else it asks for the whole text (`GlanceStatus.needsFullText`).
    public var appendingToUTF8Count: Int?
    public var title: String?
    public var origin: Origin
    /// More text is on the way (an answer that's still being written).
    public var isStreaming: Bool
    /// Resent without the user doing anything (after connecting, or because the Source lost
    /// track). It doesn't replace a Glance another connected Studio is showing.
    public var isResync: Bool?

    public init(documentID: UUID, revision: Int, text: String, appendingToUTF8Count: Int? = nil, title: String? = nil, origin: Origin, isStreaming: Bool, isResync: Bool? = nil) {
        self.documentID = documentID
        self.revision = revision
        self.text = text
        self.appendingToUTF8Count = appendingToUTF8Count
        self.title = title
        self.origin = origin
        self.isStreaming = isStreaming
        self.isResync = isResync
    }
}

/// Where the overlay sits, how far it's scrolled, and how it looks. Each one replaces the
/// last; the Source ignores any older than the newest it applied.
public struct GlanceLayout: Codable, Sendable, Hashable {
    public static let defaultOpacity = 0.72
    public static let opacityRange: ClosedRange<Double> = 0.2...0.95
    public static let textScaleRange: ClosedRange<Double> = 0.7...2.2

    public var sequence: UInt64
    public var isVisible: Bool
    /// Fractions of the Source's screen, top-left origin.
    public var frame: GlanceFrame
    /// How far the text is scrolled, in the Source's points from the top.
    public var scrollOffset: Double
    /// Ease into this state (a button or key) rather than jump (a drag or trackpad scroll).
    public var animated: Bool
    /// Opacity of the dark backdrop; the text stays opaque.
    public var backgroundOpacity: Double
    /// 1 is the standard size.
    public var textScale: Double
    /// Studio wall clock when sent, nanoseconds since 1970 (for latency logs only).
    public var sentAtNanos: UInt64?
    /// Sent on connecting rather than by the user (see `GlanceContent.isResync`).
    public var isResync: Bool?
    /// The Source display to show it on (`GlanceDisplay.id`); nil follows what's shared.
    public var displayID: String?

    public init(sequence: UInt64 = 0, isVisible: Bool = true, frame: GlanceFrame = .standard, scrollOffset: Double = 0, animated: Bool = false, backgroundOpacity: Double = GlanceLayout.defaultOpacity, textScale: Double = 1, sentAtNanos: UInt64? = nil, isResync: Bool? = nil, displayID: String? = nil) {
        self.sequence = sequence
        self.isVisible = isVisible
        self.frame = frame
        self.scrollOffset = scrollOffset
        self.animated = animated
        self.backgroundOpacity = backgroundOpacity
        self.textScale = textScale
        self.sentAtNanos = sentAtNanos
        self.isResync = isResync
        self.displayID = displayID
    }

    /// Values a peer may have sent out of range, made safe to show.
    public var sanitized: GlanceLayout {
        var copy = self
        copy.frame = frame.clamped()
        copy.scrollOffset = scrollOffset.isFinite ? max(0, scrollOffset) : 0
        copy.backgroundOpacity = backgroundOpacity.isFinite ? min(max(backgroundOpacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound) : Self.defaultOpacity
        copy.textScale = textScale.isFinite ? min(max(textScale, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound) : 1
        return copy
    }
}

/// One of the Source's displays, for choosing where the overlay goes.
public struct GlanceDisplay: Codable, Sendable, Hashable, Identifiable {
    /// The display's ID on the Source (as in `CaptureSourceID` for displays).
    public var id: String
    public var name: String
    /// It's the display being shared.
    public var isShared: Bool

    public init(id: String, name: String, isShared: Bool) {
        self.id = id
        self.name = name
        self.isShared = isShared
    }
}

/// The screen the overlay is on, as the Source sees it.
public struct GlanceScreen: Codable, Sendable, Hashable {
    /// Size in points.
    public var width: Double
    public var height: Double
    /// The part not covered by the menu bar or Dock, as fractions of the screen.
    public var visibleFrame: GlanceFrame
    /// The overlay is on the display being shared, so its frame maps straight onto the live video.
    public var isSharedDisplay: Bool
    /// Which display it is (`GlanceDisplay.id`).
    public var displayID: String?

    public init(width: Double, height: Double, visibleFrame: GlanceFrame, isSharedDisplay: Bool, displayID: String? = nil) {
        self.width = width
        self.height = height
        self.visibleFrame = visibleFrame
        self.isSharedDisplay = isSharedDisplay
        self.displayID = displayID
    }
}

/// The Source's report after applying Glance messages, and whenever its geometry changes.
public struct GlanceStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        /// On screen.
        case showing
        /// Nothing to show, or the Studio hid it.
        case hidden
        /// Hidden by the person at the Source (it stays hidden until they show it again).
        case hiddenOnSource
        /// The Source's user turned Glance off in Settings.
        case notAllowed
    }

    public var state: State
    public var documentID: UUID?
    /// The newest content revision applied.
    public var revision: Int
    /// An append from this Studio didn't fit what the Source holds: send the whole text.
    public var needsFullText: Bool
    /// What's shown came from the Studio receiving this report (not from another one).
    public var isFromYou: Bool
    /// The newest layout applied (lets the Studio measure the round trip).
    public var layoutSequence: UInt64
    /// What the Source applied, after keeping the overlay on screen.
    public var frame: GlanceFrame
    public var scrollOffset: Double
    /// Height of the whole text and of the part that fits, in the Source's points.
    public var contentHeight: Double
    public var viewportHeight: Double
    public var screen: GlanceScreen
    /// Every display the Source has, for choosing where the overlay goes.
    public var displays: [GlanceDisplay]

    public init(state: State, documentID: UUID?, revision: Int, needsFullText: Bool = false, isFromYou: Bool = true, layoutSequence: UInt64, frame: GlanceFrame, scrollOffset: Double, contentHeight: Double, viewportHeight: Double, screen: GlanceScreen, displays: [GlanceDisplay] = []) {
        self.state = state
        self.documentID = documentID
        self.revision = revision
        self.needsFullText = needsFullText
        self.isFromYou = isFromYou
        self.layoutSequence = layoutSequence
        self.frame = frame
        self.scrollOffset = scrollOffset
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.screen = screen
        self.displays = displays
    }

    /// How far the text can scroll.
    public var maxScrollOffset: Double { GlanceScroll.maxOffset(content: contentHeight, viewport: viewportHeight) }
}
