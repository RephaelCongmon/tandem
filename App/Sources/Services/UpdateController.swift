import AppKit
import Foundation
import Observation
import os
import TandemCore

/// Finds new Tandem releases in the (private) GitHub repository and installs them in place:
/// download, check the code signature, swap the app, relaunch.
///
/// GitHub access comes from a saved access token, or else the GitHub CLI's own sign-in.
@MainActor
@Observable
final class UpdateController {
    enum Access: Equatable {
        case unknown
        case token
        case githubCLI
        /// Neither a token nor a signed-in GitHub CLI.
        case none
    }

    /// The newest release, when it's newer than this app.
    private(set) var latest: ReleaseInfo?
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    /// Why the last check failed, if it did.
    private(set) var checkError: String?
    private(set) var access: Access = .unknown
    /// Set while an update is being downloaded and installed (e.g. "Downloading…").
    private(set) var installPhase: String?
    private(set) var installError: String?
    /// A release the user put off with "Later"; its bar stays hidden until a newer one appears.
    private(set) var postponed: AppVersion?
    private(set) var hasToken = false
    /// The toolbar's update panel is open.
    var isPanelPresented = false

    let currentVersion: AppVersion
    let buildNumber: String
    let repository: String

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let tokens: KeychainItemStore
    @ObservationIgnored private var automaticChecks: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.rofel.tandem", category: "Updates")

    static let checkInterval: TimeInterval = 6 * 3600

    init(settings: SettingsStore) {
        self.settings = settings
        tokens = KeychainItemStore(service: "\(AppEnvironment.keychainPrefix).github")
        currentVersion = AppVersion.current ?? AppVersion("0")!
        buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        repository = AppEnvironment.updateRepository
        hasToken = !(tokens.read(account: "token")?.isEmpty ?? true)
    }

    var isUpdating: Bool { installPhase != nil }

    /// Whether the toolbar's Update button should be visible.
    var showsBar: Bool {
        if installPhase != nil || installError != nil { return true }
        guard let latest else { return false }
        return latest.version != postponed
    }

    var versionDescription: String { "\(currentVersion) (\(buildNumber))" }

    // MARK: Checking

    func startAutomaticChecks() {
        automaticChecks?.cancel()
        guard settings.autoCheckUpdates, AppEnvironment.updatesEnabled else { return }
        automaticChecks = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: UInt64(Self.checkInterval * 1_000_000_000))
            }
        }
    }

    func stopAutomaticChecks() {
        automaticChecks?.cancel()
        automaticChecks = nil
    }

    func check() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }
        guard let feed = await makeFeed() else {
            checkError = nil
            return
        }
        do {
            let release = try await feed.latestRelease()
            lastChecked = Date()
            checkError = nil
            latest = release.version > currentVersion ? release : nil
            if let latest { log.notice("Tandem \(latest.version.description, privacy: .public) is available") }
        } catch {
            checkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Update check failed: \(self.checkError ?? "", privacy: .public)")
        }
    }

    func postpone() {
        postponed = latest?.version
        installError = nil
    }

    // MARK: Access

    func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            tokens.delete(account: "token")
        } else {
            try tokens.write(Data(trimmed.utf8), account: "token", label: "Tandem GitHub access token")
        }
        hasToken = !trimmed.isEmpty
        access = .unknown
    }

    /// A saved token wins (it was set on purpose); otherwise the GitHub CLI's sign-in.
    private func makeFeed() async -> UpdateFeed? {
        if let data = tokens.read(account: "token"), let token = String(data: data, encoding: .utf8), !token.isEmpty {
            access = .token
            return GitHubAPIFeed(repository: repository, token: token, userAgent: "Tandem/\(currentVersion)")
        }
        if let gh = await GitHubCLIFeed.locate() {
            let feed = GitHubCLIFeed(repository: repository, executable: gh)
            if await feed.isSignedIn() {
                access = .githubCLI
                return feed
            }
        }
        access = .none
        return nil
    }

    // MARK: Installing

    /// Downloads, verifies and installs `latest`, then relaunches into it.
    func updateNow() async {
        guard let release = latest, !isUpdating else { return }
        installError = nil
        guard let archive = release.appArchive else { return fail(UpdateError.missingArchive) }
        guard let team = CodeSignature.currentTeamIdentifier() else {
            return fail(UpdateError.invalidPackage("This copy of Tandem isn't signed by a developer team, so it can't verify updates."))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TandemUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let feed = await makeFeed() else {
                throw UpdateError.accessDenied("Tandem can't reach its releases on GitHub. Add access in Settings › General › Updates.")
            }
            installPhase = "Downloading…"
            let file = try await feed.download(archive, of: release, to: folder)
            installPhase = "Checking the signature…"
            let app = try await UpdateInstaller.prepare(
                archive: file,
                expectedVersion: release.version,
                bundleIdentifier: AppEnvironment.bundleIdentifier,
                teamIdentifier: team
            )
            installPhase = "Installing…"
            let target = UpdateInstaller.installLocation(for: Bundle.main.bundleURL)
            try UpdateInstaller.install(app, at: target)
            try? FileManager.default.removeItem(at: folder)
            log.notice("Installed Tandem \(release.version.description, privacy: .public) at \(target.path, privacy: .public); relaunching")
            installPhase = "Restarting…"
            try relaunch(into: target)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        installPhase = nil
        installError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        log.error("Update failed: \(self.installError ?? "", privacy: .public)")
    }

    /// Quits, and reopens `app` once this process has exited.
    private func relaunch(into app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let arguments = CommandLine.arguments.dropFirst().map(Self.shellQuoted).joined(separator: " ")
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \(Self.shellQuoted(app.path))"
        if !arguments.isEmpty { script += " --args \(arguments)" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed("The update is installed, but Tandem couldn't restart itself. Quit and reopen it.")
        }
        NSApp.terminate(nil)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
