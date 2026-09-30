import SwiftUI
import TandemCore
import TandemUI

/// One-click skills above the message field. Each sends a fresh screenshot, whatever is typed
/// (as extra context) and the skill's instructions.
struct SkillBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let skills = model.settings.skills
        let canSend = !model.chat.isBusy && !model.chat.isCapturingForSend
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                    Button {
                        model.chat.send(skill: skill)
                    } label: {
                        Label(skill.title, systemImage: skill.symbol)
                            .font(TandemFont.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.surfaceRaised))
                            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Theme.textPrimary : Theme.textTertiary)
                    .disabled(!canSend)
                    .help(help(for: skill, index: index))
                }
                Button {
                    model.openSettings(tab: "skills")
                } label: {
                    Image(systemName: skills.isEmpty ? "plus" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(skills.isEmpty ? "Add a skill" : "Edit skills")
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
    }

    private func help(for skill: PromptSkill, index: Int) -> String {
        let summary = skill.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? skill.title
        let shortcut = index < 9 ? " (⌘\(index + 1))" : ""
        return "\(summary)\(shortcut)\nAnything you've typed is sent as extra context."
    }
}

/// Shown on a user message that was sent with a skill.
struct SkillTag: View {
    let skill: PromptSkill

    var body: some View {
        Label(skill.title, systemImage: skill.symbol)
            .font(TandemFont.callout.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .help(skill.instructions)
    }
}

// MARK: - Settings

struct SkillSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PromptSkill?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                if settings.skills.isEmpty {
                    Text("No skills yet. Add one to get a button above the message field.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(settings.skills.enumerated()), id: \.element.id) { index, skill in
                    HStack(spacing: 10) {
                        Image(systemName: skill.symbol)
                            .frame(width: 22)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.title).font(TandemFont.body.weight(.medium))
                            Text(skill.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                                .font(TandemFont.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if index < 9 {
                            Text("⌘\(index + 1)").font(TandemFont.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Button { move(skill.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help("Move up")
                        Button { move(skill.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == settings.skills.count - 1)
                            .help("Move down")
                        Button("Edit…") { editing = skill }
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                Text("Skills are buttons above the message field. Each one sends a fresh screenshot (when Live screen is on), what was just said on the shared Mac (when Listen is on), anything you've typed as extra context, and the skill's instructions. In the thread you see just the skill's name. ⌘1–⌘9 send the first nine.")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Section {
                HStack {
                    Button("Add Skill") {
                        editing = PromptSkill(title: "", symbol: "sparkles", instructions: "")
                    }
                    Spacer()
                    Button("Restore Defaults") { settings.skills = PromptSkill.defaults }
                        .disabled(settings.skills == PromptSkill.defaults)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { skill in
            SkillEditor(
                skill: skill,
                isNew: !settings.skills.contains { $0.id == skill.id },
                onSave: { saved in
                    if let index = settings.skills.firstIndex(where: { $0.id == saved.id }) {
                        settings.skills[index] = saved
                    } else {
                        settings.skills.append(saved)
                    }
                },
                onDelete: { settings.skills.removeAll { $0.id == skill.id } }
            )
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        var skills = model.settings.skills
        guard let index = skills.firstIndex(where: { $0.id == id }), skills.indices.contains(index + offset) else { return }
        skills.swapAt(index, index + offset)
        model.settings.skills = skills
    }
}

private struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var skill: PromptSkill
    let isNew: Bool
    let onSave: (PromptSkill) -> Void
    let onDelete: () -> Void

    private var canSave: Bool {
        !skill.title.trimmingCharacters(in: .whitespaces).isEmpty && !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(isNew ? "New Skill" : "Edit Skill").font(TandemFont.title)
            HStack(spacing: 10) {
                Picker("Icon", selection: $skill.symbol) {
                    ForEach(PromptSkill.symbolChoices, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Name, e.g. Debug", text: $skill.title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions for the AI")
                    .font(TandemFont.caption)
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $skill.instructions)
                    .font(TandemFont.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 200)
                    .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.stroke))
            }
            Toggle("Attach a fresh screenshot of the shared screen", isOn: $skill.attachesScreenshot)
            Toggle("Include what was just said (when Listen is on)", isOn: $skill.attachesTranscript)
            HStack {
                if !isNew {
                    Button("Delete Skill", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    skill.title = skill.title.trimmingCharacters(in: .whitespaces)
                    onSave(skill)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 540)
    }
}
