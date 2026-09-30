import Foundation
import Observation
import TandemCore

/// Tracks the Codex CLI on this Mac for the Codex provider: where it is and whether it's signed
/// in with ChatGPT. Checks are a couple of short CLI calls, run on demand.
@MainActor
@Observable
final class CodexService {
    /// The last check's result; `nil` until the first check finishes.
    private(set) var status: CodexStatus?
    private(set) var isChecking = false
    /// Models the signed-in account can use, from Codex itself (after a check or test).
    private(set) var models: [AIModelInfo] = []
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var executable: URL? {
        if let found = status?.executable, FileManager.default.isExecutableFile(atPath: found.path) { return found }
        return CodexLocator.quickLocate(override: settings.codexPath)
    }

    var isReady: Bool { status?.isReady ?? false }

    func refresh() async {
        generation += 1
        let current = generation
        isChecking = true
        let result = await CodexLocator.status(override: settings.codexPath)
        guard current == generation else { return }
        isChecking = false
        guard !Task.isCancelled else { return }
        status = result
        if result.isReady, let executable = result.executable, models.isEmpty {
            setModels((try? await CodexClient(executable: executable).listModels()) ?? [])
        }
    }

    func refreshInBackground() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in await self?.refresh() }
    }

    /// Sends one tiny question through Codex and reports how it went, for Settings › AI.
    func test(model: String) async -> String {
        await refresh()
        guard let status, status.isReady, let executable = status.executable else {
            return status?.summary ?? CodexStatus().summary
        }
        let started = Date()
        let client = CodexClient(executable: executable)
        let request = AIRequest(
            model: model,
            systemPrompt: "Reply with exactly the word OK.",
            turns: [.user(.text("Say OK."))],
            maxOutputTokens: 64,
            effort: .low,
            includeReasoningSummary: false
        )
        do {
            for try await _ in client.stream(request) {}
            setModels((try? await client.listModels()) ?? models)
            let name = displayName(for: model)
            let plan = status.usesChatGPT ? "on your ChatGPT plan" : "with Codex's sign-in"
            return "Working — \(name) answered in \(String(format: "%.1f", Date().timeIntervalSince(started))) s \(plan)."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setModels(_ list: [AIModelInfo]) {
        models = list
        settings.codexModelNames = Dictionary(list.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    func displayName(for model: String) -> String {
        ModelCatalog.presets(for: .codex).first { $0.id == model }?.displayName
            ?? models.first { $0.id == model }?.displayName
            ?? model
    }
}
