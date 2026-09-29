import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

/// A keyboard shortcut expressed the way Carbon's `RegisterEventHotKey` wants it: a
/// layout-independent virtual key code plus a Carbon modifier mask.
///
/// Because the key code identifies a physical key, a combo keeps working when the user
/// switches keyboard layouts; only its displayed name follows the current layout.
///
/// Only the four shortcut modifiers (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`)
/// are kept; any other bits passed to the initializers are dropped.
public struct KeyCombo: Hashable, Sendable {
    /// Carbon virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier mask, a combination of `cmdKey`, `optionKey`, `controlKey` and `shiftKey`.
    public var modifiers: UInt32

    /// Creates a combo from a Carbon key code and Carbon modifier mask.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedCarbonModifiers
    }

    /// Creates a combo from a Carbon key code and Cocoa modifier flags.
    public init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifiers: Self.carbonModifiers(from: modifierFlags))
    }

    /// Creates a combo from a `keyDown` (or `keyUp`) event.
    ///
    /// Returns `nil` for any other event type, for modifier-only keys, and for combos that
    /// fail ``isValidGlobalShortcut`` (e.g. a bare letter).
    public init?(event: NSEvent) {
        guard let combo = Self.candidate(from: event), combo.isValidGlobalShortcut else { return nil }
        self = combo
    }

    /// The combo an event describes, without applying ``isValidGlobalShortcut``. `nil` for
    /// non-key events and modifier-only keys. Used by the recorder to tell "invalid" apart
    /// from "not a key press".
    static func candidate(from event: NSEvent) -> KeyCombo? {
        // `keyCode` raises for non-key events, so check the type first.
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let keyCode = UInt32(event.keyCode)
        guard !Self.modifierKeyCodes.contains(keyCode) else { return nil }
        return KeyCombo(keyCode: keyCode, modifierFlags: event.modifierFlags)
    }

    // MARK: Modifiers

    /// The Carbon modifier bits a combo can carry.
    public static let supportedCarbonModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// The Cocoa modifier flags a combo can carry.
    public static let supportedModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Converts Cocoa modifier flags to a Carbon modifier mask. Flags other than
    /// ⌘ ⌥ ⌃ ⇧ (Caps Lock, Fn, numeric pad…) are ignored.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Converts a Carbon modifier mask to Cocoa modifier flags. Unknown bits are ignored.
    public static func modifierFlags(fromCarbon mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if mask & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mask & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mask & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// The combo's modifiers as Cocoa flags.
    public var modifierFlags: NSEvent.ModifierFlags {
        Self.modifierFlags(fromCarbon: modifiers)
    }

    /// Modifier glyphs for `flags` in the canonical macOS order ⌃ ⌥ ⇧ ⌘.
    public static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> [String] {
        orderedModifiers.compactMap { flags.contains($0.flag) ? $0.symbol : nil }
    }

    private static let orderedModifiers: [(flag: NSEvent.ModifierFlags, symbol: String, spoken: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command")
    ]

    // MARK: Display

    /// The key's display name without modifiers: a special-key glyph or name ("Space",
    /// "↩", "F5", "Keypad 1") or, for character keys, the uppercased character the key
    /// produces in the current keyboard layout.
    ///
    /// Layout lookups need the main thread; off the main thread a cached value or a
    /// U.S. layout fallback is returned.
    public var keyDisplayName: String {
        Self.displayName(forKeyCode: keyCode)
    }

    /// Modifier glyphs followed by the key name, in macOS order, e.g. `["⌃", "⌥", "S"]`.
    /// Feed this to ``KeyCaps``.
    public var displayKeys: [String] {
        Self.modifierSymbols(for: modifierFlags) + [keyDisplayName]
    }

    /// The combo as one string, e.g. `"⌃⌥S"` or `"⌃⌥Space"`.
    public var displayString: String {
        displayKeys.joined()
    }

    /// A VoiceOver-friendly description, e.g. "Control Option S".
    public var accessibilityDescription: String {
        let keyName = Self.spokenKeyNames[keyCode] ?? keyDisplayName
        return (Self.spokenModifierNames(for: modifierFlags) + [keyName]).joined(separator: " ")
    }

    /// Spoken modifier names for `flags` in macOS order, e.g. `["Control", "Option"]`.
    static func spokenModifierNames(for flags: NSEvent.ModifierFlags) -> [String] {
        orderedModifiers.compactMap { flags.contains($0.flag) ? $0.spoken : nil }
    }

    // MARK: Validation

    /// Whether the combo is usable as a system-wide shortcut: it needs ⌘, ⌃ or ⌥ (⇧ alone
    /// isn't enough), unless the key is F1–F20, which may be used with any modifiers or
    /// none. Modifier-only keys and out-of-range key codes are never valid.
    public var isValidGlobalShortcut: Bool {
        guard keyCode < 0x80, !Self.modifierKeyCodes.contains(keyCode) else { return false }
        if isFunctionKey { return true }
        return modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// Whether the key is one of F1–F20.
    public var isFunctionKey: Bool {
        Self.functionKeyCodes.contains(keyCode)
    }

    // MARK: SwiftUI interop

    /// The key as a SwiftUI `KeyEquivalent`, for showing the shortcut in menus. `nil` when
    /// the key has no character representation in the current layout.
    ///
    /// Global hot keys are delivered before menu key equivalents, so pairing a menu item
    /// with the same combo only displays the shortcut; the action fires once.
    public var swiftUIKeyEquivalent: KeyEquivalent? {
        if let special = Self.specialKeyEquivalents[keyCode] { return special }
        if let index = Self.functionKeyCodes.firstIndex(of: keyCode),
           let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(index)) {
            return KeyEquivalent(Character(scalar))
        }
        let raw = KeyboardLayoutTranslator.shared.characters(forKeyCode: keyCode)
            ?? Self.ansiKeyNames[keyCode]?.lowercased()
        guard let raw, raw.count == 1, let character = raw.lowercased().first,
              !character.isWhitespace, !(character.asciiValue.map { $0 < 0x20 } ?? false)
        else { return nil }
        return KeyEquivalent(character)
    }

    /// The modifiers as SwiftUI `EventModifiers`.
    public var swiftUIModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }

    /// The combo as a SwiftUI `KeyboardShortcut`, e.g. for `.keyboardShortcut(_:)` on a
    /// menu `Button`. `nil` when ``swiftUIKeyEquivalent`` is `nil`.
    public var swiftUIKeyboardShortcut: KeyboardShortcut? {
        swiftUIKeyEquivalent.map { KeyboardShortcut($0, modifiers: swiftUIModifiers) }
    }
}

// MARK: - Presets

public extension KeyCombo {
    /// ⌃⌥S
    static let sendSnapshot = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥N
    static let sendSnapshotWithNote = KeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥P
    static let pauseSharing = KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥Space
    static let captureAndAsk = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥C
    static let captureToComposer = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥A
    static let toggleAutoCapture = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
    /// ⌃⌥T
    static let showTandem = KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))
}

// MARK: - Codable

extension KeyCombo: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try container.decode(UInt32.self, forKey: .keyCode),
            modifiers: try container.decode(UInt32.self, forKey: .modifiers)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

extension KeyCombo: CustomStringConvertible {
    public var description: String { displayString }
}

// MARK: - Key tables

extension KeyCombo {
    /// Key codes of modifier keys, which can't be the key of a shortcut.
    static let modifierKeyCodes: Set<UInt32> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function
    ].map { UInt32($0) })

    /// F1–F20 in order.
    static let functionKeyCodes: [UInt32] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map { UInt32($0) }

    /// Names for keys whose label doesn't come from the keyboard layout.
    static let specialKeyNames: [UInt32: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_Help: "Help",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_ANSI_KeypadClear: "⌧",
            kVK_ANSI_KeypadDecimal: "Keypad .",
            kVK_ANSI_KeypadMultiply: "Keypad *",
            kVK_ANSI_KeypadPlus: "Keypad +",
            kVK_ANSI_KeypadDivide: "Keypad /",
            kVK_ANSI_KeypadMinus: "Keypad -",
            kVK_ANSI_KeypadEquals: "Keypad =",
            kVK_JIS_KeypadComma: "Keypad ,",
            kVK_ANSI_Keypad0: "Keypad 0",
            kVK_ANSI_Keypad1: "Keypad 1",
            kVK_ANSI_Keypad2: "Keypad 2",
            kVK_ANSI_Keypad3: "Keypad 3",
            kVK_ANSI_Keypad4: "Keypad 4",
            kVK_ANSI_Keypad5: "Keypad 5",
            kVK_ANSI_Keypad6: "Keypad 6",
            kVK_ANSI_Keypad7: "Keypad 7",
            kVK_ANSI_Keypad8: "Keypad 8",
            kVK_ANSI_Keypad9: "Keypad 9",
            kVK_JIS_Eisu: "英数",
            kVK_JIS_Kana: "かな"
        ]
        for (index, code) in functionKeyCodes.enumerated() {
            names[Int(code)] = "F\(index + 1)"
        }
        return Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.key), $0.value) })
    }()

    /// Spoken names for keys whose display name is a glyph.
    static let spokenKeyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: [
        (kVK_Return, "Return"),
        (kVK_Tab, "Tab"),
        (kVK_Delete, "Delete"),
        (kVK_ForwardDelete, "Forward Delete"),
        (kVK_Escape, "Escape"),
        (kVK_LeftArrow, "Left Arrow"),
        (kVK_RightArrow, "Right Arrow"),
        (kVK_UpArrow, "Up Arrow"),
        (kVK_DownArrow, "Down Arrow"),
        (kVK_Home, "Home"),
        (kVK_End, "End"),
        (kVK_PageUp, "Page Up"),
        (kVK_PageDown, "Page Down"),
        (kVK_ANSI_KeypadEnter, "Enter"),
        (kVK_ANSI_KeypadClear, "Clear")
    ].map { (UInt32($0.0), $0.1) })

    /// U.S. ANSI names for character keys; used when the layout can't be queried
    /// (off the main thread, or a layout without Unicode data).
    static let ansiKeyNames: [UInt32: String] = Dictionary(uniqueKeysWithValues: [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
        (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
        (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
        (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
        (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"), (kVK_ANSI_LeftBracket, "["),
        (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Semicolon, ";"),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"),
        (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"), (kVK_ISO_Section, "§")
    ].map { (UInt32($0.0), $0.1) })

    /// SwiftUI key equivalents for keys that aren't plain characters.
    static let specialKeyEquivalents: [UInt32: KeyEquivalent] = Dictionary(uniqueKeysWithValues: [
        (kVK_Space, KeyEquivalent.space),
        (kVK_Return, .return),
        (kVK_ANSI_KeypadEnter, KeyEquivalent(Character(UnicodeScalar(UInt8(NSEnterCharacter))))),
        (kVK_Tab, .tab),
        (kVK_Delete, .delete),
        (kVK_ForwardDelete, .deleteForward),
        (kVK_Escape, .escape),
        (kVK_LeftArrow, .leftArrow),
        (kVK_RightArrow, .rightArrow),
        (kVK_UpArrow, .upArrow),
        (kVK_DownArrow, .downArrow),
        (kVK_Home, .home),
        (kVK_End, .end),
        (kVK_PageUp, .pageUp),
        (kVK_PageDown, .pageDown),
        (kVK_ANSI_KeypadClear, .clear)
    ].map { (UInt32($0.0), $0.1) })

    /// Display name for a key code: special table, then current layout, then U.S. fallback.
    static func displayName(forKeyCode keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let translated = KeyboardLayoutTranslator.shared.characters(forKeyCode: keyCode),
           let display = displayForm(of: translated) {
            return display
        }
        if let ansi = ansiKeyNames[keyCode] { return ansi }
        return "Key \(keyCode)"
    }

    /// Uppercases a translated key label, rejecting control characters and whitespace.
    /// Keeps the original when uppercasing would change its length (ß → SS).
    static func displayForm(of translated: String) -> String? {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        return upper.count == trimmed.count ? upper : trimmed
    }
}

// MARK: - Keyboard layout translation

/// Translates key codes to the characters they produce in the current keyboard layout
/// using `UCKeyTranslate`, caching results until the input source changes.
///
/// Text Input Source APIs must run on the main thread (they assert on macOS 14+), so
/// uncached lookups from other threads return `nil` and callers fall back to U.S. names.
final class KeyboardLayoutTranslator: @unchecked Sendable {
    static let shared = KeyboardLayoutTranslator()

    /// Key code → translated characters (empty string when the key produces nothing).
    private let cache = OSAllocatedUnfairLock(initialState: [UInt32: String]())
    /// Only touched on the main thread.
    private var layoutObserver: NSObjectProtocol?

    private init() {}

    /// The unmodified characters `keyCode` types in the current layout, or `nil`.
    func characters(forKeyCode keyCode: UInt32) -> String? {
        if let cached = cache.withLock({ $0[keyCode] }) {
            return cached.isEmpty ? nil : cached
        }
        guard Thread.isMainThread else { return nil }
        installLayoutObserverIfNeeded()
        let translated = Self.translate(keyCode: keyCode) ?? ""
        cache.withLock { $0[keyCode] = translated }
        return translated.isEmpty ? nil : translated
    }

    /// Drops cached translations, e.g. after the keyboard layout changed.
    func invalidate() {
        cache.withLock { $0.removeAll() }
    }

    private func installLayoutObserverIfNeeded() {
        guard layoutObserver == nil else { return }
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    /// The layout used for key names: the current keyboard layout when it's ASCII-capable
    /// (matching how macOS labels shortcuts), otherwise the current ASCII-capable layout.
    private static func layoutInputSource() -> TISInputSource? {
        if let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           isASCIICapable(current), layoutData(of: current) != nil {
            return current
        }
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private static func layoutData(of source: TISInputSource) -> CFData? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func translate(keyCode: UInt32) -> String? {
        guard let source = layoutInputSource(), let data = layoutData(of: source) else { return nil }
        return withExtendedLifetime(source) {
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                layout,
                UInt16(truncatingIfNeeded: keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

// MARK: - Actions

/// The global actions Tandem exposes as configurable shortcuts.
public enum HotkeyAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case sendSnapshot
    case sendSnapshotWithNote
    case pauseSharing
    case captureAndAsk
    case captureToComposer
    case toggleAutoCapture
    case showTandem

    /// Which side of a Tandem session an action applies to.
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// The Mac sharing its screen.
        case source
        /// The Mac viewing the shared screen and talking to the assistant.
        case studio
        /// Either side.
        case both

        /// Whether an action with this role is available on a Mac acting as `role`.
        public func includes(_ role: Role) -> Bool {
            self == .both || role == .both || self == role
        }
    }

    /// Stable identifier; also the recommended ``HotKeyCenter`` registration id.
    public var id: String { rawValue }

    /// Short title for settings and menus.
    public var title: String {
        switch self {
        case .sendSnapshot: return "Send snapshot"
        case .sendSnapshotWithNote: return "Send snapshot with note…"
        case .pauseSharing: return "Pause sharing"
        case .captureAndAsk: return "Capture & ask"
        case .captureToComposer: return "Capture to composer"
        case .toggleAutoCapture: return "Toggle auto-capture"
        case .showTandem: return "Show Tandem"
        }
    }

    /// One-sentence explanation shown under the title in settings.
    public var detail: String {
        switch self {
        case .sendSnapshot:
            return "Sends a still of your shared screen to the studio right away."
        case .sendSnapshotWithNote:
            return "Captures your shared screen and lets you add a note before sending it."
        case .pauseSharing:
            return "Pauses or resumes sharing your screen with the studio."
        case .captureAndAsk:
            return "Captures the live screen and asks the assistant about it."
        case .captureToComposer:
            return "Attaches a capture of the live screen to the message you're writing."
        case .toggleAutoCapture:
            return "Turns automatic capturing of the live screen on or off."
        case .showTandem:
            return "Brings the Tandem window to the front."
        }
    }

    /// The shortcut used until the user picks another one.
    public var defaultCombo: KeyCombo {
        switch self {
        case .sendSnapshot: return .sendSnapshot
        case .sendSnapshotWithNote: return .sendSnapshotWithNote
        case .pauseSharing: return .pauseSharing
        case .captureAndAsk: return .captureAndAsk
        case .captureToComposer: return .captureToComposer
        case .toggleAutoCapture: return .toggleAutoCapture
        case .showTandem: return .showTandem
        }
    }

    /// Which side of a session the action belongs to.
    public var role: Role {
        switch self {
        case .sendSnapshot, .sendSnapshotWithNote, .pauseSharing: return .source
        case .captureAndAsk, .captureToComposer, .toggleAutoCapture: return .studio
        case .showTandem: return .both
        }
    }

    /// Actions available on a Mac acting as `role`, in declaration order.
    public static func actions(for role: Role) -> [HotkeyAction] {
        allCases.filter { $0.role.includes(role) }
    }
}
