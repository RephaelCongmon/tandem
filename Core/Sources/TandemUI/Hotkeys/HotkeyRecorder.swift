import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A field for recording a global keyboard shortcut.
///
/// Idle, it shows the current combo as ``KeyCaps`` (or "Not set"), with a clear button
/// and — when the combo differs from `defaultCombo` — a reset button. Clicking it, or
/// pressing Space/Return while it has keyboard focus, starts recording:
///
/// - Held modifiers are shown live; the first key pressed with ⌘, ⌃ or ⌥ (or any
///   F-key) becomes the new combo.
/// - Esc cancels; Delete or Forward Delete without modifiers clears the shortcut.
/// - Combos without a modifier shake the field and explain why; so do combos for which
///   `validate` returns a message. In both cases recording continues.
/// - Clicking elsewhere, or the window losing key status, ends recording.
///
/// While recording, ``HotKeyCenter/shared`` is suspended so existing shortcuts can be
/// typed without firing. A typical `validate` closure:
///
/// ```swift
/// HotkeyRecorder(combo: $combo, defaultCombo: action.defaultCombo) { candidate in
///     do { try HotKeyCenter.shared.validate(candidate, for: action.id); return nil }
///     catch { return error.localizedDescription }
/// }
/// ```
public struct HotkeyRecorder: View {
    @Binding private var combo: KeyCombo?
    private let defaultCombo: KeyCombo?
    private let validate: ((KeyCombo) -> String?)?

    @StateObject private var model = HotkeyRecorderModel()
    @FocusState private var isFocused: Bool
    @State private var hovering = false
    @State private var pulse = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - combo: The shortcut being edited; `nil` means "not set".
    ///   - defaultCombo: Enables the reset button when `combo` differs from it.
    ///   - validate: Returns an error message to reject a combo (e.g. a conflict), or
    ///     `nil` to accept it. Also applied when resetting to the default.
    public init(combo: Binding<KeyCombo?>, defaultCombo: KeyCombo?, validate: ((KeyCombo) -> String?)? = nil) {
        _combo = combo
        self.defaultCombo = defaultCombo
        self.validate = validate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            field
                .modifier(ShakeEffect(animatableData: CGFloat(model.shakeCount)))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: model.shakeCount)
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.message)
        .onChange(of: model.shakeCount) { _, _ in
            if let message = model.message {
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { model.stop() }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: Spacing.xs) {
            mainArea
            accessories
        }
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xs)
        .frame(minWidth: 148, minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Theme.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(Color.primary.opacity(hovering && !model.isRecording && isEnabled ? 0.04 : 0))
                )
        )
        .overlay(border)
        .background(RecorderAnchor(model: model))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: model.isRecording)
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        let color: Color
        let width: CGFloat
        if model.message != nil && model.isRecording {
            color = Theme.danger
            width = 1.5
        } else if model.isRecording {
            color = Theme.accent
            width = 1.5
        } else if isFocused {
            color = Theme.accent.opacity(0.7)
            width = 1.5
        } else {
            color = Theme.stroke
            width = 1
        }
        return shape
            .strokeBorder(color, lineWidth: width)
            .shadow(color: model.isRecording ? color.opacity(0.55) : .clear, radius: 5)
            .allowsHitTesting(false)
    }

    private var mainArea: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { beginRecording() }
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard !model.isRecording else { return .ignored }
                beginRecording()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keyboard shortcut")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(model.isRecording ? "Press Escape to cancel." : "Records a new shortcut.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if model.isRecording { model.stop() } else { beginRecording() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRecording {
            HStack(spacing: Spacing.xs) {
                if !model.liveModifiers.isEmpty {
                    KeyCaps(KeyCombo.modifierSymbols(for: model.liveModifiers))
                }
                Text(model.liveModifiers.isEmpty ? "Type shortcut…" : "…")
                    .font(TandemFont.callout)
                    .foregroundStyle(Theme.accent)
                    .opacity(pulse ? 0.45 : 1)
            }
            .onAppear { startPulse() }
            .onDisappear { pulse = false }
        } else if let combo {
            KeyCaps(combo.displayKeys)
        } else {
            Text("Not set")
                .font(TandemFont.callout)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder
    private var accessories: some View {
        if model.isRecording {
            accessoryButton("xmark.circle.fill", help: "Cancel recording (Esc)") { model.stop() }
        } else {
            if let defaultCombo, combo != defaultCombo {
                accessoryButton("arrow.counterclockwise", help: "Reset to \(defaultCombo.displayString)") {
                    resetToDefault(defaultCombo)
                }
            }
            if combo != nil {
                accessoryButton("xmark.circle.fill", help: "Clear shortcut") {
                    model.message = nil
                    combo = nil
                }
            }
        }
    }

    private func accessoryButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        AccessoryButton(systemName: systemName, help: help, action: action)
    }

    private var accessibilityValue: String {
        if model.isRecording {
            let held = KeyCombo.spokenModifierNames(for: model.liveModifiers)
            return held.isEmpty ? "Recording" : "Recording, \(held.joined(separator: " "))"
        }
        return combo?.accessibilityDescription ?? "Not set"
    }

    // MARK: Actions

    private func beginRecording() {
        guard isEnabled, !model.isRecording else { return }
        isFocused = true
        let binding = $combo
        model.start(validate: validate) { newValue in
            binding.wrappedValue = newValue
        }
    }

    private func resetToDefault(_ defaultCombo: KeyCombo) {
        if let error = validate?(defaultCombo) {
            model.reject(error)
        } else {
            model.message = nil
            combo = defaultCombo
        }
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        pulse = false
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Model

/// What a key press means while recording.
enum HotkeyRecorderInput: Equatable {
    case cancel
    case clear
    case invalid
    case candidate(KeyCombo)

    /// Interprets a key press (Carbon key code + Cocoa flags) during recording.
    static func interpret(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> HotkeyRecorderInput {
        let combo = KeyCombo(keyCode: keyCode, modifierFlags: modifierFlags)
        if combo.modifiers == 0 {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: break
            }
        }
        return combo.isValidGlobalShortcut ? .candidate(combo) : .invalid
    }
}

/// Recording state and event plumbing for one ``HotkeyRecorder``.
@MainActor
final class HotkeyRecorderModel: ObservableObject {
    /// Shown when a combo has no ⌘/⌃/⌥.
    static let missingModifierMessage = "Use ⌘, ⌃ or ⌥ with a key"

    @Published private(set) var isRecording = false
    /// Modifiers currently held while recording.
    @Published private(set) var liveModifiers: NSEvent.ModifierFlags = []
    /// Inline error, if any.
    @Published var message: String?
    /// Incremented to trigger the shake animation.
    @Published private(set) var shakeCount = 0

    /// The view whose bounds count as "inside" for click-away detection.
    weak var anchorView: NSView? {
        didSet {
            guard anchorView !== oldValue, isRecording else { return }
            observeWindow()
        }
    }

    private var validate: ((KeyCombo) -> String?)?
    private var commit: ((KeyCombo?) -> Void)?
    private var eventMonitors: [Any] = []
    private var appObservers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?

    /// The model that's currently recording; only one recorder records at a time.
    private static weak var active: HotkeyRecorderModel?
    /// ``HotKeyCenter/isSuspended`` before recording began, restored afterwards.
    private static var suspensionBeforeRecording = false

    func start(validate: ((KeyCombo) -> String?)?, commit: @escaping (KeyCombo?) -> Void) {
        guard !isRecording else { return }
        if let other = Self.active, other !== self {
            other.stop()
        }
        Self.active = self
        Self.suspensionBeforeRecording = HotKeyCenter.shared.isSuspended
        HotKeyCenter.shared.isSuspended = true

        self.validate = validate
        self.commit = commit
        message = nil
        liveModifiers = NSEvent.modifierFlags.intersection(KeyCombo.supportedModifierFlags)
        isRecording = true
        installMonitors()
    }

    /// Ends recording without changing the combo.
    func stop() {
        guard isRecording else { return }
        removeMonitors()
        isRecording = false
        liveModifiers = []
        validate = nil
        commit = nil
        if Self.active === self {
            Self.active = nil
            HotKeyCenter.shared.isSuspended = Self.suspensionBeforeRecording
        }
    }

    /// Shows `message` and shakes the field.
    func reject(_ message: String) {
        self.message = message
        shakeCount += 1
    }

    private func finish(with combo: KeyCombo?) {
        let commit = commit
        message = nil
        stop()
        commit?(combo)
    }

    /// Handles a key event while recording. Returns `true` if it must not reach the app.
    private func consume(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            liveModifiers = event.modifierFlags.intersection(KeyCombo.supportedModifierFlags)
            return false
        case .keyDown:
            guard !event.isARepeat else { return true }
            switch HotkeyRecorderInput.interpret(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags) {
            case .cancel:
                message = nil
                stop()
            case .clear:
                finish(with: nil)
            case .invalid:
                reject(Self.missingModifierMessage)
            case .candidate(let combo):
                if let error = validate?(combo) {
                    reject(error)
                } else {
                    finish(with: combo)
                }
            }
            return true
        default:
            return false
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let anchor = anchorView, let window = anchor.window, event.window === window else {
            stop()
            return
        }
        let point = anchor.convert(event.locationInWindow, from: nil)
        if !anchor.bounds.contains(point) {
            stop()
        }
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }) {
            eventMonitors.append(keys)
        }
        if let clicks = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseDown(event)
                }
                return event
            }
        ) {
            eventMonitors.append(clicks)
        }
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observeWindow()
    }

    private func observeWindow() {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        guard let window = anchorView?.window else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func removeMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers.removeAll()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
    }
}

// MARK: - Pieces

/// A zero-size AppKit view that tells the model where the field is and which window
/// it lives in.
private struct RecorderAnchor: NSViewRepresentable {
    let model: HotkeyRecorderModel

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak model, weak view] in
            model?.anchorView = view
        }
        model.anchorView = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        if model.anchorView !== nsView {
            model.anchorView = nsView
        }
    }

    final class AnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Small borderless icon button used inside the field.
private struct AccessoryButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Horizontal shake; animate `animatableData` by whole numbers.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 5
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = travel * sin(animatableData * .pi * 2 * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}
