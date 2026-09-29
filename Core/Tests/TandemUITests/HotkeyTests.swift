import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import TandemUI

final class HotkeyTests: XCTestCase {
    /// Unusual combos nobody else should hold: ⌃⌥⇧⌘ + F16…F19.
    private static let hyper = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    private static let comboA = KeyCombo(keyCode: UInt32(kVK_F19), modifiers: hyper)
    private static let comboB = KeyCombo(keyCode: UInt32(kVK_F18), modifiers: hyper)
    private static let comboC = KeyCombo(keyCode: UInt32(kVK_F17), modifiers: hyper)
    private static let comboD = KeyCombo(keyCode: UInt32(kVK_F16), modifiers: hyper)

    /// Centers created by a test; torn down afterwards so no hot key outlives it.
    private var centers: [HotKeyCenter] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for center in centers {
                center.isSuspended = false
                center.unregisterAll()
            }
            centers.removeAll()
            HotKeyCenter.shared.unregisterAll()
        }
        super.tearDown()
    }

    @MainActor
    private func makeCenter() -> HotKeyCenter {
        let center = HotKeyCenter()
        centers.append(center)
        return center
    }

    // MARK: KeyCombo: Codable

    func testCodableRoundTrip() throws {
        let combos = HotkeyAction.allCases.map(\.defaultCombo) + [Self.comboA, KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0)]
        let data = try JSONEncoder().encode(combos)
        let decoded = try JSONDecoder().decode([KeyCombo].self, from: data)
        XCTAssertEqual(decoded, combos)

        let optional: KeyCombo? = .sendSnapshot
        let optionalData = try JSONEncoder().encode(optional)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo?.self, from: optionalData), optional)
    }

    func testDecodingUsesStableKeysAndDropsUnsupportedModifierBits() throws {
        let json = #"{"keyCode": 1, "modifiers": \#(UInt32(controlKey | optionKey) | UInt32(alphaLock) | 0x20000)}"#
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .sendSnapshot)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KeyCombo.sendSnapshot)) as? [String: Int]
        XCTAssertEqual(encoded, ["keyCode": kVK_ANSI_S, "modifiers": controlKey | optionKey])
    }

    // MARK: KeyCombo: modifiers

    func testCocoaToCarbonModifierConversion() {
        XCTAssertEqual(KeyCombo.carbonModifiers(from: []), 0)
        XCTAssertEqual(KeyCombo.carbonModifiers(from: .command), UInt32(cmdKey))
        XCTAssertEqual(KeyCombo.carbonModifiers(from: .option), UInt32(optionKey))
        XCTAssertEqual(KeyCombo.carbonModifiers(from: .control), UInt32(controlKey))
        XCTAssertEqual(KeyCombo.carbonModifiers(from: .shift), UInt32(shiftKey))
        XCTAssertEqual(
            KeyCombo.carbonModifiers(from: [.command, .option, .control, .shift]),
            UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
        // Non-shortcut flags are ignored.
        XCTAssertEqual(KeyCombo.carbonModifiers(from: [.capsLock, .function, .numericPad, .help]), 0)
        XCTAssertEqual(KeyCombo.carbonModifiers(from: [.control, .function, .numericPad]), UInt32(controlKey))
        XCTAssertEqual(KeyCombo(keyCode: 0, modifierFlags: [.option, .capsLock]).modifiers, UInt32(optionKey))
    }

    func testCarbonToCocoaModifierConversion() {
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: 0), [])
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: UInt32(cmdKey)), .command)
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: UInt32(optionKey)), .option)
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: UInt32(controlKey)), .control)
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: UInt32(shiftKey)), .shift)
        // Unknown bits (Caps Lock, Fn) are ignored.
        XCTAssertEqual(KeyCombo.modifierFlags(fromCarbon: UInt32(alphaLock) | 0x20000 | UInt32(cmdKey)), .command)
        XCTAssertEqual(KeyCombo.sendSnapshot.modifierFlags, [.control, .option])
    }

    func testModifierConversionRoundTripsForAllCombinations() {
        for mask in Self.allModifierMasks {
            let flags = KeyCombo.modifierFlags(fromCarbon: mask)
            XCTAssertEqual(KeyCombo.carbonModifiers(from: flags), mask, "mask \(mask)")
            XCTAssertEqual(KeyCombo(keyCode: 0, modifierFlags: flags).modifiers, mask)
            XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: mask).modifierFlags, flags)
        }
    }

    func testSwiftUIModifiers() {
        XCTAssertEqual(KeyCombo.sendSnapshot.swiftUIModifiers, [.control, .option])
        XCTAssertEqual(Self.comboA.swiftUIModifiers, [.control, .option, .shift, .command])
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_F1), modifiers: 0).swiftUIModifiers, [])
    }

    // MARK: KeyCombo: display

    func testDisplayOrderingForAllModifierCombinations() {
        let order: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")
        ]
        for mask in Self.allModifierMasks {
            let expectedSymbols = order.filter { mask & $0.0 != 0 }.map(\.1)
            let combo = KeyCombo(keyCode: UInt32(kVK_F5), modifiers: mask)
            XCTAssertEqual(combo.displayKeys, expectedSymbols + ["F5"], "mask \(mask)")
            XCTAssertEqual(combo.displayString, expectedSymbols.joined() + "F5")
            XCTAssertEqual(KeyCombo.modifierSymbols(for: combo.modifierFlags), expectedSymbols)
        }
        XCTAssertEqual(KeyCombo.captureAndAsk.displayString, "⌃⌥Space")
        XCTAssertEqual(KeyCombo.captureAndAsk.description, "⌃⌥Space")
    }

    func testSpecialKeyNames() {
        let expected: [(Int, String)] = [
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"),
            (kVK_ForwardDelete, "⌦"), (kVK_Escape, "⎋"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_ANSI_KeypadEnter, "⌤"), (kVK_ANSI_KeypadClear, "⌧"),
            (kVK_ANSI_Keypad0, "Keypad 0"), (kVK_ANSI_Keypad9, "Keypad 9"),
            (kVK_ANSI_KeypadPlus, "Keypad +"), (kVK_ANSI_KeypadMinus, "Keypad -"),
            (kVK_ANSI_KeypadMultiply, "Keypad *"), (kVK_ANSI_KeypadDivide, "Keypad /"),
            (kVK_ANSI_KeypadDecimal, "Keypad ."), (kVK_ANSI_KeypadEquals, "Keypad =")
        ]
        for (code, name) in expected {
            XCTAssertEqual(KeyCombo(keyCode: UInt32(code), modifiers: 0).keyDisplayName, name, "key code \(code)")
        }
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        for (index, code) in functionKeys.enumerated() {
            XCTAssertEqual(KeyCombo(keyCode: UInt32(code), modifiers: 0).keyDisplayName, "F\(index + 1)")
        }
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey)).displayKeys, ["⌃", "↑"])
    }

    func testCharacterKeysUseLayoutAndAreUppercased() {
        let letters = [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_Q, kVK_ANSI_Z, kVK_ANSI_M]
        for code in letters {
            let name = KeyCombo(keyCode: UInt32(code), modifiers: 0).keyDisplayName
            XCTAssertEqual(name.count, 1, "key code \(code) → \(name)")
            XCTAssertEqual(name, name.uppercased())
            XCTAssertFalse(name.hasPrefix("Key "))
        }
        XCTAssertEqual(KeyCombo.displayForm(of: "a"), "A")
        XCTAssertEqual(KeyCombo.displayForm(of: "é"), "É")
        XCTAssertEqual(KeyCombo.displayForm(of: "ß"), "ß", "uppercasing that changes length keeps the original")
        XCTAssertNil(KeyCombo.displayForm(of: "\u{1B}"))
        XCTAssertNil(KeyCombo.displayForm(of: " "))
        XCTAssertEqual(KeyCombo(keyCode: 0x7F, modifiers: 0).keyDisplayName.isEmpty, false)
    }

    func testKeyNamesOffMainThreadFallBackToUSLayout() {
        KeyboardLayoutTranslator.shared.invalidate()
        let done = expectation(description: "background lookup")
        nonisolated(unsafe) var name = ""
        nonisolated(unsafe) var keyEquivalent: KeyEquivalent?
        DispatchQueue.global().async {
            name = KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: 0).keyDisplayName
            keyEquivalent = KeyCombo(keyCode: UInt32(kVK_ANSI_Q), modifiers: 0).swiftUIKeyEquivalent
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(name, "Q")
        XCTAssertEqual(keyEquivalent, KeyEquivalent("q"))
    }

    func testAccessibilityDescription() {
        XCTAssertEqual(KeyCombo.captureAndAsk.accessibilityDescription, "Control Option Space")
        XCTAssertEqual(
            KeyCombo(keyCode: UInt32(kVK_Return), modifiers: UInt32(shiftKey | cmdKey)).accessibilityDescription,
            "Shift Command Return"
        )
    }

    // MARK: KeyCombo: validity

    func testIsValidGlobalShortcutRules() {
        func combo(_ key: Int, _ mods: Int = 0) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: UInt32(mods)) }

        XCTAssertTrue(combo(kVK_ANSI_S, controlKey | optionKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_ANSI_A, cmdKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_ANSI_A, optionKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_ANSI_A, controlKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_ANSI_A, shiftKey | cmdKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_Space, controlKey | optionKey).isValidGlobalShortcut)

        XCTAssertFalse(combo(kVK_ANSI_A).isValidGlobalShortcut, "a bare key isn't enough")
        XCTAssertFalse(combo(kVK_ANSI_A, shiftKey).isValidGlobalShortcut, "shift alone isn't enough")
        XCTAssertFalse(combo(kVK_Space).isValidGlobalShortcut)
        XCTAssertFalse(combo(kVK_Escape, shiftKey).isValidGlobalShortcut)

        // F-keys work alone or with any modifiers.
        XCTAssertTrue(combo(kVK_F1).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_F20).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_F5, shiftKey).isValidGlobalShortcut)
        XCTAssertTrue(combo(kVK_F13).isFunctionKey)
        XCTAssertFalse(combo(kVK_ANSI_F).isFunctionKey)

        // Modifier keys and out-of-range codes are never valid.
        XCTAssertFalse(combo(kVK_Command, controlKey).isValidGlobalShortcut)
        XCTAssertFalse(combo(kVK_Shift, cmdKey).isValidGlobalShortcut)
        XCTAssertFalse(combo(kVK_Function, optionKey).isValidGlobalShortcut)
        XCTAssertFalse(combo(0x80, cmdKey).isValidGlobalShortcut)
    }

    func testInitFromEvent() throws {
        let valid = try XCTUnwrap(Self.keyEvent(kVK_ANSI_S, [.control, .option, .capsLock]))
        XCTAssertEqual(KeyCombo(event: valid), .sendSnapshot)

        XCTAssertNil(KeyCombo(event: try XCTUnwrap(Self.keyEvent(kVK_ANSI_S, []))))
        XCTAssertNil(KeyCombo(event: try XCTUnwrap(Self.keyEvent(kVK_ANSI_S, .shift))))
        XCTAssertEqual(
            KeyCombo(event: try XCTUnwrap(Self.keyEvent(kVK_F6, .function))),
            KeyCombo(keyCode: UInt32(kVK_F6), modifiers: 0)
        )

        let mouse = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertNil(KeyCombo(event: mouse))
    }

    func testSwiftUIKeyEquivalents() throws {
        XCTAssertEqual(KeyCombo.captureAndAsk.swiftUIKeyEquivalent, .space)
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Return), modifiers: 0).swiftUIKeyEquivalent, .return)
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0).swiftUIKeyEquivalent, .escape)
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: 0).swiftUIKeyEquivalent, .upArrow)
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_ForwardDelete), modifiers: 0).swiftUIKeyEquivalent, .deleteForward)
        XCTAssertEqual(
            KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0).swiftUIKeyEquivalent,
            KeyEquivalent(Character(try XCTUnwrap(UnicodeScalar(UInt32(NSF5FunctionKey)))))
        )
        let letter = KeyCombo.sendSnapshot
        XCTAssertEqual(letter.swiftUIKeyEquivalent.map { String($0.character) }, letter.keyDisplayName.lowercased())
        XCTAssertEqual(letter.swiftUIKeyboardShortcut?.modifiers, [.control, .option])
    }

    // MARK: HotkeyAction

    func testHotkeyActionDefaultsAreUniqueAndValid() {
        let defaults = HotkeyAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(defaults).count, defaults.count, "default combos must be unique")
        XCTAssertEqual(Set(defaults.map(\.displayString)).count, defaults.count)
        for action in HotkeyAction.allCases {
            XCTAssertTrue(action.defaultCombo.isValidGlobalShortcut, "\(action)")
            XCTAssertEqual(action.id, action.rawValue)
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertTrue(action.detail.hasSuffix("."), "\(action) detail should be one sentence")
        }
        XCTAssertEqual(HotkeyAction.sendSnapshot.defaultCombo.displayString, "⌃⌥S")
        XCTAssertEqual(HotkeyAction.sendSnapshotWithNote.defaultCombo.displayString, "⌃⌥N")
        XCTAssertEqual(HotkeyAction.captureAndAsk.defaultCombo.displayString, "⌃⌥Space")
        XCTAssertEqual(HotkeyAction.toggleAutoCapture.defaultCombo.displayString, "⌃⌥A")
        XCTAssertEqual(HotkeyAction.pauseSharing.defaultCombo.displayString, "⌃⌥P")
        XCTAssertEqual(HotkeyAction.showTandem.defaultCombo.displayString, "⌃⌥T")
    }

    func testHotkeyActionRoles() {
        XCTAssertEqual(HotkeyAction.actions(for: .source), [.sendSnapshot, .sendSnapshotWithNote, .pauseSharing, .showTandem])
        XCTAssertEqual(HotkeyAction.actions(for: .studio), [.captureAndAsk, .captureToComposer, .toggleAutoCapture, .showTandem])
        XCTAssertEqual(HotkeyAction.actions(for: .both), HotkeyAction.allCases)
        XCTAssertEqual(HotkeyAction.showTandem.role, .both)
    }

    // MARK: Recorder input

    func testRecorderInterpretsKeys() {
        func input(_ key: Int, _ flags: NSEvent.ModifierFlags = []) -> HotkeyRecorderInput {
            HotkeyRecorderInput.interpret(keyCode: UInt32(key), modifierFlags: flags)
        }
        XCTAssertEqual(input(kVK_Escape), .cancel)
        XCTAssertEqual(input(kVK_Escape, .capsLock), .cancel)
        XCTAssertEqual(input(kVK_Delete), .clear)
        XCTAssertEqual(input(kVK_ForwardDelete, .function), .clear)
        XCTAssertEqual(input(kVK_ANSI_A), .invalid)
        XCTAssertEqual(input(kVK_ANSI_A, .shift), .invalid)
        XCTAssertEqual(input(kVK_Tab), .invalid)
        XCTAssertEqual(input(kVK_ANSI_S, [.control, .option]), .candidate(.sendSnapshot))
        XCTAssertEqual(input(kVK_F5), .candidate(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0)))
        XCTAssertEqual(
            input(kVK_Escape, .command),
            .candidate(KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey)))
        )
        XCTAssertEqual(
            input(kVK_Delete, [.command, .shift]),
            .candidate(KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey | shiftKey)))
        )
    }

    // MARK: HotKeyCenter

    @MainActor
    func testRegisterAndUnregister() throws {
        let center = makeCenter()
        try center.register(Self.comboA, for: "a") {}
        XCTAssertTrue(center.isRegistered("a"))
        XCTAssertEqual(center.combo(for: "a"), Self.comboA)
        XCTAssertFalse(center.isRegistered("b"))

        center.unregister("a")
        XCTAssertFalse(center.isRegistered("a"))
        XCTAssertNil(center.combo(for: "a"))
        center.unregister("missing")

        try center.register(Self.comboA, for: "a") {}
        try center.register(Self.comboB, for: "b") {}
        center.unregisterAll()
        XCTAssertFalse(center.isRegistered("a"))
        XCTAssertFalse(center.isRegistered("b"))
        // The system registration is gone too, so the combo can be taken again.
        try makeCenter().register(Self.comboA, for: "other") {}
    }

    @MainActor
    func testInvalidComboIsRejected() {
        let center = makeCenter()
        XCTAssertThrowsError(try center.register(KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)), for: "a") {}) {
            XCTAssertEqual($0 as? HotKeyError, .invalidCombo)
        }
        XCTAssertFalse(center.isRegistered("a"))
    }

    @MainActor
    func testDuplicateComboUnderAnotherIDIsRejected() throws {
        let center = makeCenter()
        try center.register(Self.comboA, for: "a") {}
        XCTAssertThrowsError(try center.register(Self.comboA, for: "b") {}) {
            XCTAssertEqual($0 as? HotKeyError, .duplicate(existingID: "a"))
        }
        XCTAssertFalse(center.isRegistered("b"))
        XCTAssertThrowsError(try center.validate(Self.comboA, for: "b")) {
            XCTAssertEqual($0 as? HotKeyError, .duplicate(existingID: "a"))
        }
        XCTAssertNoThrow(try center.validate(Self.comboA, for: "a"), "a combo doesn't conflict with itself")
        XCTAssertNoThrow(try center.validate(Self.comboB, for: "b"))
        XCTAssertFalse(center.isRegistered("b"), "validate doesn't register")
    }

    @MainActor
    func testRegisteringSameIDReplacesComboAndHandler() throws {
        let center = makeCenter()
        var calls: [String] = []
        try center.register(Self.comboA, for: "a") { calls.append("first") }
        let firstID = try XCTUnwrap(center.carbonID(for: "a"))

        try center.register(Self.comboB, for: "a") { calls.append("second") }
        XCTAssertEqual(center.combo(for: "a"), Self.comboB)
        let secondID = try XCTUnwrap(center.carbonID(for: "a"))
        XCTAssertNotEqual(firstID, secondID)

        XCTAssertFalse(center.handleHotKeyPressed(carbonID: firstID), "the old hot key is gone")
        XCTAssertTrue(center.handleHotKeyPressed(carbonID: secondID))
        XCTAssertEqual(calls, ["second"])

        // The old combo was released and is free for another id…
        try center.register(Self.comboA, for: "b") { calls.append("b") }
        // …and re-registering an identical combo just swaps the handler.
        try center.register(Self.comboB, for: "a") { calls.append("third") }
        XCTAssertEqual(center.carbonID(for: "a"), secondID)
        center.handleHotKeyPressed(carbonID: secondID)
        XCTAssertEqual(calls, ["second", "third"])
    }

    @MainActor
    func testComboHeldElsewhereMapsToAlreadyRegistered() throws {
        let owner = makeCenter()
        let other = makeCenter()
        try owner.register(Self.comboA, for: "a") {}

        XCTAssertThrowsError(try other.register(Self.comboA, for: "x") {}) {
            XCTAssertEqual($0 as? HotKeyError, .alreadyRegisteredBySystemOrOtherApp)
        }
        XCTAssertThrowsError(try other.validate(Self.comboA, for: "x")) {
            XCTAssertEqual($0 as? HotKeyError, .alreadyRegisteredBySystemOrOtherApp)
        }
        XCTAssertFalse(other.isRegistered("x"))
    }

    @MainActor
    func testFailedReplacementKeepsPreviousRegistration() throws {
        let center = makeCenter()
        let other = makeCenter()
        var fired = 0
        try center.register(Self.comboA, for: "a") { fired += 1 }
        try other.register(Self.comboC, for: "x") {}

        XCTAssertThrowsError(try center.register(Self.comboC, for: "a") {})
        XCTAssertEqual(center.combo(for: "a"), Self.comboA)
        center.handleHotKeyPressed(carbonID: try XCTUnwrap(center.carbonID(for: "a")))
        XCTAssertEqual(fired, 1)
        // comboA is still held by `center`.
        XCTAssertThrowsError(try other.register(Self.comboA, for: "y") {})
    }

    @MainActor
    func testSuspensionReleasesAndRestoresRegistrations() throws {
        let center = makeCenter()
        let other = makeCenter()
        var fired = 0
        try center.register(Self.comboA, for: "a") { fired += 1 }
        let carbonID = try XCTUnwrap(center.carbonID(for: "a"))

        center.isSuspended = true
        XCTAssertTrue(center.isRegistered("a"), "registrations survive suspension")
        XCTAssertFalse(center.handleHotKeyPressed(carbonID: carbonID), "handlers don't fire while suspended")
        XCTAssertEqual(fired, 0)
        // The system-level registration is released while suspended.
        try other.register(Self.comboA, for: "x") {}
        other.unregister("x")

        // Registering while suspended takes effect on restore.
        try center.register(Self.comboD, for: "d") {}
        try other.register(Self.comboD, for: "x") {}
        other.unregister("x")

        center.isSuspended = false
        XCTAssertTrue(center.handleHotKeyPressed(carbonID: carbonID))
        XCTAssertEqual(fired, 1)
        XCTAssertThrowsError(try other.register(Self.comboA, for: "x") {})
        XCTAssertThrowsError(try other.register(Self.comboD, for: "x") {})
    }

    @MainActor
    func testRestoreFailureIsReported() throws {
        let center = makeCenter()
        let thief = makeCenter()
        var failures: [(String, HotKeyError)] = []
        center.onRestoreFailure = { failures.append(($0, $1)) }
        try center.register(Self.comboA, for: "a") {}
        try center.register(Self.comboB, for: "b") {}

        center.isSuspended = true
        try thief.register(Self.comboA, for: "x") {}
        center.isSuspended = false

        XCTAssertEqual(failures.map(\.0), ["a"])
        XCTAssertEqual(failures.first?.1, .alreadyRegisteredBySystemOrOtherApp)
        XCTAssertFalse(center.isRegistered("a"))
        XCTAssertTrue(center.isRegistered("b"))
    }

    @MainActor
    func testSharedCenterAndErrorMessages() throws {
        let shared = HotKeyCenter.shared
        XCTAssertTrue(shared === HotKeyCenter.shared)
        try shared.register(Self.comboA, for: HotkeyAction.showTandem.id) {}
        XCTAssertThrowsError(try shared.register(Self.comboA, for: HotkeyAction.pauseSharing.id) {}) { error in
            XCTAssertEqual(error as? HotKeyCenter.HotKeyError, .duplicate(existingID: "showTandem"))
            XCTAssertEqual(error.localizedDescription, "This shortcut is already used for “Show Tandem”.")
        }
        XCTAssertEqual(HotKeyError.invalidCombo.errorDescription, HotkeyRecorderModel.missingModifierMessage + ".")
        XCTAssertNotNil(HotKeyError.registrationFailed(-50).errorDescription)
        XCTAssertFalse(HotKeyCenter.isUsedBySystem(Self.comboA))
    }

    // MARK: Helpers

    /// Every subset of ⌘ ⌥ ⌃ ⇧ as a Carbon mask.
    private static let allModifierMasks: [UInt32] = (0..<16).map { bits in
        let parts = [cmdKey, optionKey, controlKey, shiftKey]
        return parts.enumerated().reduce(UInt32(0)) { mask, part in
            bits & (1 << part.offset) != 0 ? mask | UInt32(part.element) : mask
        }
    }

    private static func keyEvent(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        )
    }
}
