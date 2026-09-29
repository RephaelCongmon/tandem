import Foundation

/// Creates the right ``AIClient`` for an endpoint.
public enum AIClientFactory {
    /// Shared session for AI requests (see ``makeDefaultSession()``).
    public static let defaultSession: URLSession = makeDefaultSession()

    /// A session suited to long streamed completions: ephemeral (no disk state), a 90 s idle
    /// timeout between bytes, a 15 min cap per request, and no URL cache or cookies.
    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 900
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Returns a client for `endpoint.kind`.
    /// - Parameters:
    ///   - endpoint: Provider kind, base URL, and key.
    ///   - session: Session to use; `nil` uses ``defaultSession``. Tests inject stubbed sessions.
    public static func make(endpoint: AIEndpoint, session: URLSession? = nil) -> any AIClient {
        let session = session ?? defaultSession
        switch endpoint.kind {
        case .anthropic: return AnthropicClient(endpoint: endpoint, session: session)
        case .openAI: return OpenAIResponsesClient(endpoint: endpoint, session: session)
        case .openAICompatible: return ChatCompletionsClient(endpoint: endpoint, session: session)
        case .claudeCode: return ClaudeCodeClient(executable: endpoint.baseURL)
        }
    }
}
