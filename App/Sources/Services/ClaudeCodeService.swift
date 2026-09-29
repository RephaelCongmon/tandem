import Foundation
import Observation
import TandemCore

/// Tracks the Claude Code CLI on this Mac for the Claude Code provider: where it is and whether
/// it's signed in. Checks are a couple of short CLI calls, run on demand.
@MainActor
@Observable
final class ClaudeCodeService {
    /// The last check's result; `nil` until the first check finishes.
    private(set) var status: ClaudeCodeStatus?
    private(set) var isChecking = false
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// Only the latest check may publish its result.
    @ObservationIgnored private var generation = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// The executable to use right now: the last check's, or a quick look in the usual places.
    var executable: URL? {
        if let found = status?.executable, FileManager.default.isExecutableFile(atPath: found.path) { return found }
        return ClaudeCodeLocator.quickLocate(override: settings.claudeCodePath)
    }

    /// Whether the last check found a usable, signed-in CLI.
    var isReady: Bool { status?.isReady ?? false }

    func refresh() async {
        generation += 1
        let current = generation
        isChecking = true
        let result = await ClaudeCodeLocator.status(override: settings.claudeCodePath)
        guard current == generation else { return }
        isChecking = false
        if !Task.isCancelled { status = result }
    }

    func refreshInBackground() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in await self?.refresh() }
    }

    /// Sends one tiny question through the CLI and reports how it went, for Settings › AI.
    func test(model: String) async -> String {
        await refresh()
        guard let status, status.isReady, let executable = status.executable else {
            return status?.summary ?? ClaudeCodeStatus().summary
        }
        let started = Date()
        let client = AIClientFactory.make(endpoint: AIEndpoint(kind: .claudeCode, baseURL: executable, apiKey: ""))
        let request = AIRequest(
            model: model,
            systemPrompt: "Reply with exactly the word OK.",
            turns: [.user(.text("Say OK."))],
            maxOutputTokens: 64,
            effort: .low,
            includeReasoningSummary: false
        )
        do {
            var served: String?
            for try await event in client.stream(request) {
                if case .completed(let completion) = event { served = completion.servedModel }
            }
            let name = ModelCatalog.presets(for: .claudeCode).first { $0.id == (served ?? model) }?.displayName ?? served ?? model
            return "Working — \(name) answered in \(String(format: "%.1f", Date().timeIntervalSince(started))) s on your subscription."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
