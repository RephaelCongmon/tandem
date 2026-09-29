import AppKit
import Carbon.HIToolbox

/// Why a shortcut couldn't be registered.
public enum HotKeyError: Error, Equatable, LocalizedError {
    /// The combo fails ``KeyCombo/isValidGlobalShortcut``.
    case invalidCombo
    /// Another app (or macOS) already holds this shortcut.
    case alreadyRegisteredBySystemOrOtherApp
    /// The combo is already registered in Tandem under a different id.
    case duplicate(existingID: String)
    /// Carbon returned an unexpected status.
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCombo:
            return "Use ⌘, ⌃ or ⌥ with a key."
        case .alreadyRegisteredBySystemOrOtherApp:
            return "This shortcut is already used by macOS or another app."
        case .duplicate(let existingID):
            let name = HotkeyAction(rawValue: existingID)?.title ?? existingID
            return "This shortcut is already used for “\(name)”."
        case .registrationFailed(let status):
            return "The shortcut couldn't be registered (error \(status))."
        }
    }
}

/// Registers system-wide keyboard shortcuts with Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys are delivered while Tandem is in the background and need neither
/// Accessibility permission nor any App Sandbox entitlement. Shortcuts are registered
/// exclusively, so a combo another app already holds is reported as
/// ``HotKeyError/alreadyRegisteredBySystemOrOtherApp`` instead of silently sharing it.
///
/// Registrations are keyed by a caller-chosen string id (use ``HotkeyAction/id``);
/// registering again under the same id replaces the previous combo and handler.
/// Handlers run on the main actor. Everything is unregistered when the app terminates.
@MainActor
public final class HotKeyCenter {
    /// Why a shortcut couldn't be registered.
    public typealias HotKeyError = TandemUI.HotKeyError

    /// The app-wide center.
    public static let shared = HotKeyCenter()

    /// While `true`, every registration is temporarily removed from the system so its
    /// shortcut types normally (``HotkeyRecorder`` sets this while recording). Setting it
    /// back to `false` restores them. Registering, replacing and unregistering keep
    /// working while suspended and take effect on restore.
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                deactivateAll()
            } else {
                reactivateAll()
            }
        }
    }

    /// Called for each registration that couldn't be restored when ``isSuspended`` went
    /// back to `false` (another app grabbed the shortcut meanwhile). The registration has
    /// been removed by the time this is called.
    public var onRestoreFailure: ((_ id: String, _ error: HotKeyError) -> Void)?

    private struct Registration {
        var combo: KeyCombo
        var handler: @MainActor () -> Void
        /// Unique across all centers so events can't be misrouted between instances.
        var carbonID: UInt32
    }

    private var registrations: [String: Registration] = [:]
    private var idsByCarbonID: [UInt32: String] = [:]
    /// Live Carbon objects. A registration without an entry in `system.hotKeys` is
    /// suspended.
    private let system = SystemResources()

    /// Four-char code stamped on every hot key ID ('TNDM').
    nonisolated static let signature: OSType = 0x544E_444D
    private static var nextCarbonID: UInt32 = 1

    /// Creates an independent center. Apps should use ``shared``; separate instances
    /// exist for tests.
    init() {
        system.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tearDown()
            }
        }
    }

    deinit {
        system.releaseAll()
    }

    // MARK: Public API

    /// Registers `combo` as a global shortcut under `id`, replacing any existing
    /// registration with that id. `handler` runs on the main actor each time the
    /// shortcut is pressed.
    ///
    /// On failure the previous registration for `id` (if any) stays in place.
    /// - Throws: ``HotKeyError/invalidCombo``, ``HotKeyError/duplicate(existingID:)`` when
    ///   another id already uses `combo`, ``HotKeyError/alreadyRegisteredBySystemOrOtherApp``,
    ///   or ``HotKeyError/registrationFailed(_:)``.
    public func register(_ combo: KeyCombo, for id: String, handler: @escaping @MainActor () -> Void) throws {
        try checkCombo(combo, for: id)

        if var existing = registrations[id], existing.combo == combo {
            existing.handler = handler
            registrations[id] = existing
            return
        }

        let carbonID = Self.makeCarbonID()
        // Register the new combo before dropping the old one so a failure leaves the
        // previous registration untouched. While suspended this is a trial registration
        // that surfaces conflicts now rather than on restore.
        let hotKeyRef = try registerWithSystem(combo, carbonID: carbonID)
        if isSuspended {
            UnregisterEventHotKey(hotKeyRef)
        } else {
            system.hotKeys[carbonID] = hotKeyRef
        }

        removeRegistration(for: id)
        registrations[id] = Registration(combo: combo, handler: handler, carbonID: carbonID)
        idsByCarbonID[carbonID] = id
    }

    /// Checks whether `combo` could be registered under `id` without registering it.
    /// Useful as a ``HotkeyRecorder`` `validate` closure.
    ///
    /// Conflicts with other apps are detected with a momentary trial registration.
    /// - Throws: The same errors as ``register(_:for:handler:)``.
    public func validate(_ combo: KeyCombo, for id: String) throws {
        try checkCombo(combo, for: id)
        if let existing = registrations[id], existing.combo == combo { return }
        UnregisterEventHotKey(try registerWithSystem(combo, carbonID: 0))
    }

    /// Removes the registration for `id`, if any.
    public func unregister(_ id: String) {
        removeRegistration(for: id)
    }

    /// Removes every registration.
    public func unregisterAll() {
        for id in Array(registrations.keys) {
            removeRegistration(for: id)
        }
    }

    /// Whether a shortcut is registered under `id` (including while suspended).
    public func isRegistered(_ id: String) -> Bool {
        registrations[id] != nil
    }

    /// The combo registered under `id`, if any.
    public func combo(for id: String) -> KeyCombo? {
        registrations[id]?.combo
    }

    /// Whether `combo` matches an enabled macOS shortcut from System Settings › Keyboard ›
    /// Keyboard Shortcuts (e.g. ⌃Space for input sources, ⌘⇧3 for screenshots).
    ///
    /// Carbon doesn't report these as conflicts, and whether macOS swallows the keystroke
    /// depends on the shortcut, so this is advisory: show a warning, don't block.
    public static func isUsedBySystem(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        return entries.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let keyCode = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  keyCode >= 0, modifiers >= 0
            else { return false }
            return KeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(truncatingIfNeeded: modifiers)) == combo
        }
    }

    // MARK: Event dispatch

    /// The Carbon hot key ID currently assigned to `id` (it changes when the combo does).
    func carbonID(for id: String) -> UInt32? {
        registrations[id]?.carbonID
    }

    /// Runs the handler registered for a Carbon hot key ID. Returns `false` if the ID
    /// doesn't belong to this center (the event is then passed on).
    @discardableResult
    func handleHotKeyPressed(carbonID: UInt32) -> Bool {
        guard !isSuspended, let id = idsByCarbonID[carbonID], let registration = registrations[id] else {
            return false
        }
        registration.handler()
        return true
    }

    // MARK: Internals

    private func checkCombo(_ combo: KeyCombo, for id: String) throws {
        guard combo.isValidGlobalShortcut else { throw HotKeyError.invalidCombo }
        if let existingID = registrations.first(where: { $0.key != id && $0.value.combo == combo })?.key {
            throw HotKeyError.duplicate(existingID: existingID)
        }
    }

    private static func makeCarbonID() -> UInt32 {
        let id = nextCarbonID
        nextCarbonID = nextCarbonID == UInt32.max ? 1 : nextCarbonID + 1
        return id
    }

    /// Registers `combo` exclusively with Carbon, installing the event handler first if needed.
    private func registerWithSystem(_ combo: KeyCombo, carbonID: UInt32) throws -> EventHotKeyRef {
        try installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            EventHotKeyID(signature: Self.signature, id: carbonID),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        switch status {
        case noErr:
            guard let ref else { throw HotKeyError.registrationFailed(status) }
            return ref
        case OSStatus(eventHotKeyExistsErr):
            throw HotKeyError.alreadyRegisteredBySystemOrOtherApp
        default:
            throw HotKeyError.registrationFailed(status)
        }
    }

    private func installEventHandlerIfNeeded() throws {
        guard system.eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr, let handler else { throw HotKeyError.registrationFailed(status) }
        system.eventHandler = handler
    }

    private func removeRegistration(for id: String) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        idsByCarbonID[registration.carbonID] = nil
        if let ref = system.hotKeys.removeValue(forKey: registration.carbonID) {
            UnregisterEventHotKey(ref)
        }
    }

    private func deactivateAll() {
        for ref in system.hotKeys.values {
            UnregisterEventHotKey(ref)
        }
        system.hotKeys.removeAll()
    }

    private func reactivateAll() {
        var failures: [(String, HotKeyError)] = []
        for id in registrations.keys.sorted() {
            guard let registration = registrations[id], system.hotKeys[registration.carbonID] == nil else { continue }
            do {
                system.hotKeys[registration.carbonID] = try registerWithSystem(
                    registration.combo,
                    carbonID: registration.carbonID
                )
            } catch {
                removeRegistration(for: id)
                failures.append((id, error as? HotKeyError ?? .registrationFailed(OSStatus(paramErr))))
            }
        }
        for (id, error) in failures {
            onRestoreFailure?(id, error)
        }
    }

    private func tearDown() {
        unregisterAll()
        system.releaseAll()
    }
}

/// The Carbon objects a ``HotKeyCenter`` owns, boxed so the center's nonisolated
/// `deinit` can release them. Only accessed on the main thread (or from `deinit`,
/// when nothing else can reach the center).
private final class SystemResources: @unchecked Sendable {
    /// Carbon hot key ID → live registration.
    var hotKeys: [UInt32: EventHotKeyRef] = [:]
    var eventHandler: EventHandlerRef?
    var terminationObserver: NSObjectProtocol?

    /// Unregisters every hot key and removes the event handler and observers.
    func releaseAll() {
        for ref in hotKeys.values {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }
}

/// Carbon callback for `kEventHotKeyPressed` on the application event target.
/// `userData` is an unretained ``HotKeyCenter``; its handler is removed before it's freed.
private func hotKeyEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let carbonID = hotKeyID.id
    guard Thread.isMainThread else {
        // Application-target handlers run on the main thread; hop there just in case.
        Task { @MainActor in center.handleHotKeyPressed(carbonID: carbonID) }
        return noErr
    }
    let handled = MainActor.assumeIsolated { center.handleHotKeyPressed(carbonID: carbonID) }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
