import AppKit
import Observation
import TandemCore
import TandemUI

/// Registers the global shortcuts for the current role and runs their actions.
@MainActor
@Observable
final class HotkeyController {
    /// Registration problems per action (e.g. taken by another app).
    private(set) var errors: [HotkeyAction: String] = [:]
    @ObservationIgnored weak var model: AppModel?

    func registerAll() {
        guard let model, let role = model.settings.role else { return }
        let center = HotKeyCenter.shared
        center.unregisterAll()
        var problems: [HotkeyAction: String] = [:]
        for action in HotkeyAction.actions(for: role.hotkeyRole) where isAvailable(action, role: role) {
            guard let combo = model.settings.combo(for: action) else { continue }
            do {
                try center.register(combo, for: action.id) { [weak self] in self?.perform(action) }
            } catch {
                problems[action] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        errors = problems
    }

    /// Glance's shortcuts are only taken while there's a Glance, so the rest of the time they
    /// never shadow a shortcut of the app in use. `AppModel` re-registers when that changes.
    private func isAvailable(_ action: HotkeyAction, role: AppRole) -> Bool {
        guard let model else { return false }
        switch action {
        case .toggleGlance:
            return role == .source ? model.settings.allowGlance && model.source.glance.hasGlance : model.studio.glance.hasContent
        case .glanceScrollUp, .glanceScrollDown:
            return role == .studio && model.studio.glance.hasContent
        default:
            return true
        }
    }

    func unregisterAll() {
        HotKeyCenter.shared.unregisterAll()
    }

    /// Validates a candidate shortcut for Settings (returns an error message or nil).
    func validate(_ combo: KeyCombo, for action: HotkeyAction) -> String? {
        guard let model else { return nil }
        for other in HotkeyAction.allCases where other != action && other.role.includes(action.role) {
            if model.settings.combo(for: other) == combo { return "Already used for “\(other.title)”." }
        }
        if HotKeyCenter.isUsedBySystem(combo) { return "macOS uses this shortcut." }
        return nil
    }

    func perform(_ action: HotkeyAction) {
        guard let model else { return }
        switch action {
        case .sendSnapshot:
            Task {
                let feedback = await model.source.pushSnapshot(note: nil)
                model.toasts.showPush(feedback)
            }
        case .sendSnapshotWithNote:
            QuickNotePanelController.shared.present(model: model)
        case .pauseSharing:
            model.source.toggleSharing()
            model.toasts.show(
                model.source.isSharingEnabled ? "Sharing resumed" : "Sharing paused",
                systemImage: model.source.isSharingEnabled ? "play.circle.fill" : "pause.circle.fill"
            )
        case .captureAndAsk:
            if model.chat.canSendFromComposer {
                model.studio.captureAndAsk()
                model.toasts.show("Asking…", systemImage: "sparkles")
            } else {
                model.toasts.show("Add a question or select a picture first", systemImage: "exclamationmark.triangle.fill", style: .warning)
            }
        case .captureToComposer:
            model.studio.toggleRegionTool()
            if model.studio.isRegionToolOn { model.showMainWindow() }
        case .toggleAutoCapture:
            model.studio.toggleAutoCapture()
            model.toasts.show(
                model.settings.autoCaptureEnabled ? "Auto-capture on (every \(Formatters.interval(model.settings.autoCaptureInterval)))" : "Auto-capture off",
                systemImage: model.settings.autoCaptureEnabled ? "timer" : "timer.circle"
            )
        case .answerFollowUp:
            guard !model.chat.isBusy else {
                model.toasts.show("Still answering the previous question", systemImage: "hourglass", style: .warning)
                return
            }
            let followUp = model.settings.skills.first { $0.id == PromptSkill.defaults[2].id }
                ?? model.settings.skills.first { $0.title.localizedCaseInsensitiveContains("follow") }
                ?? PromptSkill.defaults[2]
            model.chat.send(skill: followUp)
            model.toasts.show("Answering the follow-up…", systemImage: followUp.symbol)
        case .toggleListening:
            model.studio.setListening(!model.settings.listen)
            model.toasts.show(
                model.settings.listen ? "Listening to the shared Mac" : "Stopped listening",
                systemImage: model.settings.listen ? "waveform" : "waveform.slash"
            )
        case .showTandem:
            model.showMainWindow()
        case .toggleGlance:
            if model.settings.role == .source {
                // Only registered while there's a Glance; nothing else to do or show here.
                guard model.source.glance.hasGlance else { return }
                model.source.glance.toggleHiddenHere()
            } else {
                let glance = model.studio.glance
                guard glance.hasContent else {
                    model.toasts.show("Nothing in the Glance yet", systemImage: "rectangle.inset.topright.filled", style: .warning)
                    return
                }
                glance.toggleVisible()
                let name = model.studio.sourceName ?? "the shared Mac"
                model.toasts.show(glance.layout.isVisible ? "Glance showing on \(name)" : "Glance hidden on \(name)",
                                  systemImage: glance.layout.isVisible ? "eye" : "eye.slash")
            }
        case .glanceScrollUp:
            model.studio.glance.scroll(.lineUp)
        case .glanceScrollDown:
            model.studio.glance.scroll(.lineDown)
        }
    }
}
