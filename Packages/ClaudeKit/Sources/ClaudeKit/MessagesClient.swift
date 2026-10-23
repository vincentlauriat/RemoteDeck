import Foundation

/// Why a call to the API failed (Claude API errors: status code → error type). Messages are the
/// server's, never the key or the request body.
public enum AnthropicError: Error, Sendable, Equatable {
    /// 400 `invalid_request_error` (also a spend limit reached).
    case invalidRequest(String)
    /// 401 `authentication_error`: the key is malformed, revoked or expired.
    case authentication
    /// 402 `billing_error`.
    case billing
    /// 403 `permission_error`.
    case permission
    /// 404 `not_found_error` (unknown model, wrong path).
    case notFound
    /// 413 `request_too_large`: the conversation exceeds 32 MB.
    case requestTooLarge
    /// 429 `rate_limit_error`; `retryAfter` from the header, nil without one (a spend cap).
    case rateLimited(retryAfter: Duration?)
    /// 500, 504 and other 5xx.
    case server(status: Int)
    /// 529 `overloaded_error`.
    case overloaded
    /// Any other status.
    case http(status: Int, message: String)
    /// No answer: offline, DNS, TLS, timeout.
    case network(String)
    /// A 200 that is not a message.
    case unexpectedResponse(String)
    case cancelled

    /// Transient: worth another try after a pause. 4xx other than 429 never are.
    public var isRetryable: Bool {
        switch self {
        case .server, .overloaded, .network: true
        case .rateLimited(let retryAfter): retryAfter != nil   // a spend cap keeps failing
        default: false
        }
    }

    /// `retry-after` (seconds) or `retry-after-ms`, only when finite and not negative, capped at an
    /// hour before it becomes a `Duration` (`"inf"`, `"nan"` or `"1e30"` must not trap).
    static func retryDelay(seconds: String?, milliseconds: String?) -> Duration? {
        func parse(_ text: String?, scale: Double) -> Duration? {
            guard let value = text.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  value.isFinite, value >= 0 else { return nil }
            return .milliseconds(Int(min(value * scale, 3_600_000)))
        }
        return parse(milliseconds, scale: 1) ?? parse(seconds, scale: 1000)
    }

    init(status: Int, body: Data, retryAfter: Duration?) {
        let message = (try? JSONValue.decode(body))?["error"]?["message"]?.stringValue ?? ""
        switch status {
        case 400: self = .invalidRequest(message)
        case 401: self = .authentication
        case 402: self = .billing
        case 403: self = .permission
        case 404: self = .notFound
        case 413: self = .requestTooLarge
        case 429: self = .rateLimited(retryAfter: retryAfter)
        case 529: self = .overloaded
        case 500...599: self = .server(status: status)
        default: self = .http(status: status, message: message)
        }
    }
}

/// Sends one HTTP request. `URLSession` in the app; a fake in every test (no test ever reaches the
/// network or spends tokens).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Retries of transient failures: twice, as the official SDKs do, after `retry-after` when the server
/// sends one (capped), else 1 s then 2 s.
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var maxDelay: Duration
    /// Waits between tries; replaced in tests so they do not sleep.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(maxRetries: Int = 2, maxDelay: Duration = .seconds(30),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.maxRetries = maxRetries
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    func delay(after error: AnthropicError, attempt: Int) -> Duration {
        if case .rateLimited(let retryAfter?) = error { return min(retryAfter, maxDelay) }
        return min(.seconds(1 << attempt), maxDelay)
    }
}

/// Raw-HTTP Messages API client (there is no Anthropic Swift SDK: raw HTTP is the documented path).
/// Non-streaming: the assistant shows a turn once it is complete.
public struct MessagesClient: Sendable {
    public let transport: any HTTPTransport
    public let retry: RetryPolicy
    /// Request timeout; a non-streaming call must stay well under the API's 10 minutes.
    public var timeout: TimeInterval = 180

    public init(transport: any HTTPTransport = URLSessionTransport(), retry: RetryPolicy = RetryPolicy()) {
        self.transport = transport
        self.retry = retry
    }

    /// `POST /v1/messages` with `body` (a `Conversation.requestBody()`).
    public func send(body: Data, apiKey: String) async throws(AnthropicError) -> MessagesResponse {
        var request = URLRequest(url: ClaudeAPI.messagesURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in ClaudeAPI.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let data = try await perform(request)
        return try MessagesResponse(data: data)
    }

    /// The Settings Window's key check: `GET /v1/models?limit=1`, which bills no tokens. Throws
    /// `.authentication` for a key the API does not accept.
    public func checkKey(_ apiKey: String) async throws(AnthropicError) {
        var request = URLRequest(url: ClaudeAPI.modelsURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(ClaudeAPI.version, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        _ = try await perform(request)
    }

    /// One call with the retries; the body of a 2xx.
    private func perform(_ request: URLRequest) async throws(AnthropicError) -> Data {
        var attempt = 0
        while true {
            do {
                return try await performOnce(request)
            } catch {
                guard error.isRetryable, attempt < retry.maxRetries else { throw error }
                do {
                    try await retry.sleep(retry.delay(after: error, attempt: attempt))
                } catch {
                    throw .cancelled
                }
                attempt += 1
            }
        }
    }

    private func performOnce(_ request: URLRequest) async throws(AnthropicError) -> Data {
        if Task.isCancelled { throw .cancelled }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError {
            throw .network(error.localizedDescription)
        } catch {
            throw .network(String(describing: type(of: error)))
        }
        // A reply that arrived is returned even if the task was cancelled meanwhile: it is billed, and
        // the caller counts its usage and keeps its turn.
        guard (200..<300).contains(response.statusCode) else {
            throw AnthropicError(status: response.statusCode, body: data,
                                 retryAfter: AnthropicError.retryDelay(
                                    seconds: response.value(forHTTPHeaderField: "retry-after"),
                                    milliseconds: response.value(forHTTPHeaderField: "retry-after-ms")))
        }
        return data
    }
}
