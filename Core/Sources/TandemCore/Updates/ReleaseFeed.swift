import Foundation

/// A downloadable file attached to a release.
public struct ReleaseAsset: Sendable, Hashable {
    public var name: String
    /// The GitHub REST URL of the asset (downloaded with `Accept: application/octet-stream`).
    public var apiURL: URL?
    public var size: Int

    public init(name: String, apiURL: URL? = nil, size: Int = 0) {
        self.name = name
        self.apiURL = apiURL
        self.size = size
    }
}

/// A published Tandem release.
public struct ReleaseInfo: Sendable, Hashable, Identifiable {
    public var tag: String
    public var version: AppVersion
    public var title: String
    /// Release notes (Markdown).
    public var notes: String
    public var publishedAt: Date?
    public var assets: [ReleaseAsset]

    public var id: String { tag }

    public init(tag: String, version: AppVersion, title: String, notes: String, publishedAt: Date?, assets: [ReleaseAsset]) {
        self.tag = tag
        self.version = version
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// The app archive made by `scripts/build-release.sh`: `Tandem-<version>.zip`.
    public var appArchive: ReleaseAsset? {
        assets.first { $0.name == "Tandem-\(version).zip" }
            ?? assets.first { $0.name.hasPrefix("Tandem") && $0.name.hasSuffix(".zip") }
    }
}

public enum UpdateError: Error, LocalizedError, Sendable, Equatable {
    /// GitHub refused the credentials.
    case accessDenied(String)
    /// No published release, or the credentials can't see the repository.
    case noRelease(String)
    case network(String)
    /// The release has no app archive.
    case missingArchive
    /// The downloaded app isn't the expected app, version or signer.
    case invalidPackage(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let message), .noRelease(let message), .network(let message),
             .invalidPackage(let message), .installFailed(let message):
            return message
        case .missingArchive:
            return "The latest release has no app download attached."
        }
    }
}

/// Where Tandem looks for new releases.
public protocol UpdateFeed: Sendable {
    func latestRelease() async throws -> ReleaseInfo
    /// Downloads `asset` into `directory` and returns the file.
    func download(_ asset: ReleaseAsset, of release: ReleaseInfo, to directory: URL) async throws -> URL
}

// MARK: - Decoding

enum ReleaseDecoding {
    private struct RESTRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var url: URL?
            var size: Int?
        }
        var tag_name: String
        var name: String?
        var body: String?
        var published_at: Date?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    private struct CLIRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var apiUrl: URL?
            var size: Int?
        }
        var tagName: String
        var name: String?
        var body: String?
        var publishedAt: Date?
        var assets: [Asset]
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A release from the GitHub REST API (`GET /repos/{owner}/{repo}/releases/latest`).
    static func rest(_ data: Data) throws -> ReleaseInfo {
        let release = try decoder.decode(RESTRelease.self, from: data)
        return try make(tag: release.tag_name, title: release.name, notes: release.body, publishedAt: release.published_at,
                        assets: release.assets.map { ReleaseAsset(name: $0.name, apiURL: $0.url, size: $0.size ?? 0) })
    }

    /// A release from `gh release view --json tagName,name,body,publishedAt,assets`.
    static func cli(_ data: Data) throws -> ReleaseInfo {
        let release = try decoder.decode(CLIRelease.self, from: data)
        return try make(tag: release.tagName, title: release.name, notes: release.body, publishedAt: release.publishedAt,
                        assets: release.assets.map { ReleaseAsset(name: $0.name, apiURL: $0.apiUrl, size: $0.size ?? 0) })
    }

    private static func make(tag: String, title: String?, notes: String?, publishedAt: Date?, assets: [ReleaseAsset]) throws -> ReleaseInfo {
        guard let version = AppVersion(tag) else {
            throw UpdateError.noRelease("The latest release tag “\(tag)” isn't a version number.")
        }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ReleaseInfo(tag: tag, version: version, title: name.isEmpty ? "Tandem \(version)" : name,
                           notes: notes ?? "", publishedAt: publishedAt, assets: assets)
    }
}

// MARK: - GitHub REST API (token)

/// Reads releases of a private repository with a GitHub token.
public struct GitHubAPIFeed: UpdateFeed {
    public let repository: String
    let token: String
    let session: URLSession
    let userAgent: String

    public init(repository: String, token: String, session: URLSession = .shared, userAgent: String = "Tandem") {
        self.repository = repository
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.userAgent = userAgent
    }

    func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public func latestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.noRelease("“\(repository)” isn't a GitHub repository name.")
        }
        let (data, response) = try await load(request(url, accept: "application/vnd.github+json"))
        try Self.check(response, repository: repository)
        return try ReleaseDecoding.rest(data)
    }

    public func download(_ asset: ReleaseAsset, of release: ReleaseInfo, to directory: URL) async throws -> URL {
        guard let url = asset.apiURL else { throw UpdateError.missingArchive }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request(url, accept: "application/octet-stream"), delegate: RedirectGuard())
        } catch {
            throw UpdateError.network("Couldn't download the update: \(error.localizedDescription)")
        }
        try Self.check(response, repository: repository)
        let destination = directory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw UpdateError.network("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    static func check(_ response: URLResponse, repository: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw UpdateError.accessDenied("GitHub rejected the access token. Paste a new one in Settings › General › Updates.")
        case 403: throw UpdateError.accessDenied("The access token isn't allowed to read \(repository), or GitHub's rate limit was reached.")
        case 404: throw UpdateError.noRelease("No release found in \(repository), or the access token can't read it.")
        default: throw UpdateError.network("GitHub answered with HTTP \(http.statusCode).")
        }
    }

    /// Asset downloads redirect to a signed storage URL on another host; the token must not
    /// follow the redirect there.
    static func redirected(_ request: URLRequest, from original: URLRequest) -> URLRequest {
        guard request.url?.host != original.url?.host else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return request
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let original = task.originalRequest else { return completionHandler(request) }
            completionHandler(GitHubAPIFeed.redirected(request, from: original))
        }
    }
}

// MARK: - GitHub CLI

/// Reads releases through the GitHub CLI (`gh`), which uses its own sign-in.
public struct GitHubCLIFeed: UpdateFeed {
    public let repository: String
    public let executable: URL

    public init(repository: String, executable: URL) {
        self.repository = repository
        self.executable = executable
    }

    /// Where Homebrew and the official installer put `gh`, most common first.
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"]
    }

    public static func locate() async -> URL? {
        await CommandLineTool.locate("gh", candidates: candidatePaths())
    }

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Whether `gh` is signed in to github.com.
    public func isSignedIn() async -> Bool {
        let result = await ChildProcess.run(executable, arguments: ["auth", "status", "--hostname", "github.com"], environment: Self.environment, timeout: 15)
        return result?.status == 0
    }

    public func latestRelease() async throws -> ReleaseInfo {
        guard let result = await ChildProcess.run(
            executable,
            arguments: ["release", "view", "--repo", repository, "--json", "tagName,name,body,publishedAt,assets"],
            environment: Self.environment,
            timeout: 30
        ) else { throw UpdateError.network("The GitHub CLI didn't answer.") }
        guard result.status == 0 else {
            let detail = Self.lastLine(result.errors)
            if detail.localizedCaseInsensitiveContains("not found") {
                throw UpdateError.noRelease("No release found in \(repository), or your GitHub account can't read it.")
            }
            throw UpdateError.network(detail.isEmpty ? "The GitHub CLI couldn't read \(repository)." : "GitHub CLI: \(detail)")
        }
        return try ReleaseDecoding.cli(Data(result.output.utf8))
    }

    public func download(_ asset: ReleaseAsset, of release: ReleaseInfo, to directory: URL) async throws -> URL {
        guard let result = await ChildProcess.run(
            executable,
            arguments: ["release", "download", release.tag, "--repo", repository, "--pattern", asset.name, "--dir", directory.path, "--clobber"],
            environment: Self.environment,
            timeout: 900
        ) else { throw UpdateError.network("The download didn't finish.") }
        let file = directory.appendingPathComponent(asset.name)
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            let detail = Self.lastLine(result.errors)
            throw UpdateError.network(detail.isEmpty ? "Couldn't download the update." : "Couldn't download the update: \(detail)")
        }
        return file
    }

    static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }
}
