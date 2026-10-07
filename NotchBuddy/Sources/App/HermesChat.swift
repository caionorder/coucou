import Foundation

// MARK: - Hermes agents (self-hosted, OpenAI-compatible API server)

/// How an agent is reached: with the profile's API key (OpenAI-compatible server) or by signing in
/// with the Hermes server (dashboard gateway). A stored agent without the field reads as `apiKey`.
enum HermesConnection: String, Codable, Sendable {
    case apiKey
    case signIn
}

/// One configured Hermes agent. The API key (or sign-in session) is NOT part of this struct: it lives only in the Keychain.
struct HermesAgent: Codable, Equatable, Sendable {
    /// Unique id and label, e.g. "mark".
    var name: String
    /// Normalised origin, e.g. "https://agent.example.com" (no trailing slash).
    var baseURL: String
    /// "" or "default" = unprefixed routes.
    var profile: String
    /// Id returned by `GET /v1/models` at connect time, fallback "hermes-agent".
    var modelName: String
    /// `nil` reads as `.apiKey` (agents stored before the sign-in kind existed).
    var connection: HermesConnection?
    /// What the user reads instead of `name` (pill, chat, Settings). `nil` = the identity name. Not a secret; it never
    /// takes part in the Keychain binding, the pill id or the conversation, so renaming never disconnects an agent.
    var displayName: String?

    /// The name shown everywhere the agent appears.
    var shownName: String { displayName ?? name }

    /// Same agent at the same destination: ignores the display name, which is only a label.
    func sameDestination(as other: HermesAgent) -> Bool {
        name == other.name && baseURL == other.baseURL && profile == other.profile
            && modelName == other.modelName && connection == other.connection
    }
}

enum HermesChatError: Error, Equatable {
    case invalidURL
    case insecureURL
    case unauthorized
    case notFound
    case busy
    case notHermes
    /// Associated value is the host only (never the full URL).
    case unreachable(String)
    case server(String)
    case agentFailed(String)
    /// The stored agent no longer matches the destination its key was bound to. Associated value is the agent name.
    case notBound(String)
    /// No usable sign-in session for this agent. Associated value is the agent name.
    case signInNeeded(String)
    /// Associated value is a message that is safe to show (never a server text, token or URL).
    case signInFailed(String)

    var userMessage: String {
        switch self {
        case .invalidURL:    return String(localized: "Enter a URL like https://hermes.example.com.")
        case .insecureURL:   return String(localized: "Use https:// for this host. http:// is only allowed for localhost and private addresses.")
        case .unauthorized:  return String(localized: "Hermes refused the API key. Each profile has its own key.")
        case .notFound:      return String(localized: "Hermes has no such profile at this URL. Check the profile name.")
        case .busy:          return String(localized: "The agent is busy. Try again in a moment.")
        case .notHermes:     return String(localized: "This URL doesn't answer like a Hermes API server. Use the API address, not the dashboard.")
        case .unreachable(let host): return String(localized: "Can't reach Hermes at \(host). Is the gateway running?")
        case .server(let m), .agentFailed(let m): return m
        case .notBound(let name): return String(localized: "\(name) changed since it was connected, so its key was not sent. Disconnect it and connect it again in Settings → Chat.")
        case .signInNeeded(let name): return String(localized: "Sign in to \(name) again in Settings → Chat.")
        case .signInFailed(let m): return m
        }
    }
}

enum HermesChat {

    // MARK: URL handling

    /// Strips a trailing `/v1` and `/p/<profile>`. `profile` is set only when the URL ended in `/p/<profile>/v1`.
    private static func stripAPIPath(_ raw: String) -> (base: String, profile: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        let hadV1 = s.hasSuffix("/v1")
        if hadV1 { s = String(s.dropLast(3)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        var profile: String?
        // trailing /p/<profile>
        if let r = s.range(of: "/p/", options: .backwards),
           !s[r.upperBound...].contains("/"), !s[r.upperBound...].isEmpty {
            if hadV1 { profile = String(s[r.upperBound...]) }
            s = String(s[..<r.lowerBound])
        }
        return (s, profile)
    }

    /// The profile named by a pasted `.../p/NAME/v1` URL, when it is a valid profile name.
    static func profileInURL(_ raw: String) -> String? {
        guard let p = stripAPIPath(raw).profile, !p.isEmpty, isValidProfile(p) else { return nil }
        return p
    }

    static func normaliseBaseURL(_ raw: String) -> Result<String, HermesChatError> {
        let s = stripAPIPath(raw).base
        guard let url = safeWebURL(s),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return .failure(.invalidURL) }
        if scheme == "http" && !isLocalHost(host) { return .failure(.insecureURL) }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var out = "\(scheme)://\(hostPart)"
        if let port = url.port { out += ":\(port)" }
        var path = url.path
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        out += path
        return .success(out)
    }

    /// True for hosts where plain http is acceptable (loopback, private IP literals, 100.64.0.0/10,
    /// `.local` names and other single-label names). All-digit and `0x` single labels are rejected:
    /// a resolver may read them as a public IPv4 address.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        if let v4 = ipv4(h) {
            switch (v4[0], v4[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") {
            // IPv6 literal: fc00::/7 and fe80::/10
            guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first,
                  let word = UInt16(first.isEmpty ? "0" : String(first), radix: 16) else { return false }
            return (word & 0xFE00) == 0xFC00 || (word & 0xFFC0) == 0xFE80
        }
        // single-label hostname (e.g. "mac-mini")
        guard !h.contains(".") else { return false }
        if h.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        if h.hasPrefix("0x") { return false }
        return true
    }

    /// True when `baseURL` is plain http to a host that is a name (not an IP literal, not localhost):
    /// the key then travels unencrypted to whoever answers that name on the network.
    static func sendsKeyUnencryptedToName(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.contains(":") || ipv4(host) != nil { return false }
        return true
    }

    private static func ipv4(_ h: String) -> [Int]? {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), (0...255).contains(n), String(n) == p || p == "0" else { return nil }
            out.append(n)
        }
        return out
    }

    static func isValidProfile(_ p: String) -> Bool {
        if p.isEmpty { return true }
        guard p.count <= 64 else { return false }
        return p.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-"
        }
    }

    static func apiRoot(baseURL: String, profile: String) -> String {
        (profile.isEmpty || profile == "default") ? baseURL : "\(baseURL)/p/\(profile)"
    }

    static func chatURL(for agent: HermesAgent) -> URL? {
        guard isValidAgent(agent) else { return nil }
        return URL(string: apiRoot(baseURL: agent.baseURL, profile: agent.profile) + "/v1/chat/completions")
    }

    static func modelsURL(baseURL: String, profile: String) -> URL? {
        guard isValidProfile(profile) else { return nil }
        return URL(string: apiRoot(baseURL: baseURL, profile: profile) + "/v1/models")
    }

    // MARK: Parsing

    /// A chunk whose `finish_reason` is set and not "stop" means the agent failed after the stream started.
    static func parseStreamFailure(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let reason = choice["finish_reason"] as? String, reason != "stop" else { return nil }
        let err = (json["error"] as? [String: Any]) ?? (choice["error"] as? [String: Any])
        if let m = err?["message"] as? String, !m.isEmpty { return String(m.prefix(200)) }
        return String(localized: "The agent stopped with an error.")
    }

    static func error(status: Int, body: Data) -> HermesChatError {
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429, 503: return .busy
        case 300..<400: return .notHermes
        default:
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let m = (json["error"] as? [String: Any])?["message"] as? String, !m.isEmpty {
                return .server(String(m.prefix(200)))
            }
            return .server("HTTP \(status)")
        }
    }

    // MARK: Persistence encoding (agents → UserDefaults, keys → one Keychain item)

    /// An agent as stored: name set, base URL already in normalised form (so it round-trips) and a valid profile.
    static func isValidAgent(_ a: HermesAgent) -> Bool {
        guard !a.name.isEmpty, isValidProfile(a.profile),
              case .success(let n) = normaliseBaseURL(a.baseURL), n == a.baseURL else { return false }
        return true
    }

    /// Drops entries that do not round-trip through the URL and profile rules, and duplicate names (first wins).
    static func sanitiseAgents(_ agents: [HermesAgent]) -> [HermesAgent] {
        var seen = Set<String>()
        return agents.filter { isValidAgent($0) && seen.insert($0.name).inserted }
    }

    static func encodeAgents(_ agents: [HermesAgent]) -> String {
        guard let d = try? JSONEncoder().encode(agents) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    static func decodeAgents(_ s: String) -> [HermesAgent] {
        sanitiseAgents((try? JSONDecoder().decode([HermesAgent].self, from: Data(s.utf8))) ?? [])
    }

    /// What the Keychain holds per agent: the key and the destination it was connected to.
    struct KeyRecord: Codable, Equatable, Sendable {
        var key: String
        var baseURL: String
        var profile: String
    }

    static func encodeKeys(_ keys: [String: KeyRecord]) -> String {
        guard let d = try? JSONEncoder().encode(keys) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Reads the bound format. The previous format (name to key only) is returned with an empty
    /// `baseURL`, which never matches an agent: it counts as not bound.
    static func decodeKeys(_ s: String) -> [String: KeyRecord] {
        let data = Data(s.utf8)
        if let bound = try? JSONDecoder().decode([String: KeyRecord].self, from: data) { return bound }
        if let old = try? JSONDecoder().decode([String: String].self, from: data) {
            return old.mapValues { KeyRecord(key: $0, baseURL: "", profile: "") }
        }
        return [:]
    }

    /// The key for `agent`, only when the stored record is bound to exactly this base URL and profile.
    /// Otherwise the request must not be made.
    static func boundKey(for agent: HermesAgent, in keys: [String: KeyRecord]) -> Result<String, HermesChatError> {
        guard isValidAgent(agent),
              let r = keys[agent.name], !r.key.isEmpty,
              !r.baseURL.isEmpty, r.baseURL == agent.baseURL, r.profile == agent.profile else {
            return .failure(.notBound(agent.shownName))
        }
        return .success(r.key)
    }

    // MARK: Connection retry

    /// Retry policy for a connection that fails to OPEN. Pure data and functions: nothing here touches the network.
    /// An HTTP answer of any status, and anything after the first response byte, is never retried.
    struct ConnectRetry: Sendable, Equatable {
        /// What a repeat of the request can cause on the server.
        enum Rule: Sendable, Equatable {
            /// GET, WebSocket handshake, ticket POST: repeating changes nothing (a ticket request only mints one more
            /// single use ticket). Connect level errors and "connection lost" are retried.
            case idempotent
            /// A POST whose body has an effect (chat completions, token refresh): retried ONLY when it is certain that
            /// no body byte left the machine (`bytesSent == 0`) and the error is a connect level one.
            case sideEffects
        }

        /// Attempts in total (the first one included).
        var attempts = 3
        /// How long one attempt may wait for its connection to open (REST, WebSocket handshake, response headers).
        var attemptTimeout: TimeInterval = 6
        /// Wait before attempt 2, then before attempt 3.
        var backoff: [TimeInterval] = [0.3, 1]
        /// Total time one turn may spend opening connections (refresh, tickets, handshakes), ready waits excluded.
        /// Three attempts of one step (3 x 6 s + 1.3 s of backoff = 19.3 s) plus about 10 s of round trips that
        /// succeed (tickets) so that the third handshake attempt is still allowed on a real network.
        var budget: TimeInterval = 30
        static let standard = ConnectRetry()

        /// The wait before the next attempt after attempt `n` (1 based) failed; nil when no attempt is left.
        func delay(afterAttempt n: Int) -> TimeInterval? {
            guard n >= 1, n < attempts else { return nil }
            return backoff.isEmpty ? 0 : backoff[min(n - 1, backoff.count - 1)]
        }

        /// Whether a failure with `code` may be repeated. `bytesSent` is the number of request body bytes that left
        /// the machine, read from the task at the moment of the error; nil when it could not be read (unknown).
        /// - `.sideEffects`: "cannot connect", "cannot find host", DNS and TLS setup failures are retried unless the
        ///   task is known to have sent body bytes; "timed out" and "connection lost" only when `bytesSent == 0`
        ///   (known zero). Any error with bytes sent is final, whatever its code.
        /// - `.idempotent`: those and "connection lost"; a timeout only when no body byte went out (a timeout after
        ///   that means a slow server).
        func isRetryable(_ code: URLError.Code, rule: Rule, bytesSent: Int64?) -> Bool {
            switch code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                if rule == .sideEffects, let n = bytesSent, n > 0 { return false }
                return true
            case .networkConnectionLost:
                return rule == .idempotent || bytesSent == 0
            case .timedOut:
                return (bytesSent ?? (rule == .idempotent ? 0 : -1)) == 0
            default:
                return false
            }
        }

        /// Whether another attempt may start now, given the turn's connect deadline (nil: no deadline).
        func mayRetry(afterAttempt n: Int, now: ContinuousClock.Instant, deadline: ContinuousClock.Instant?) -> TimeInterval? {
            guard let d = delay(afterAttempt: n) else { return nil }
            if let deadline, now.advanced(by: .seconds(d + attemptTimeout)) > deadline { return nil }
            return d
        }
    }

    /// Step names and attempt counts only, never a URL, token or text. The app points it at nb.log.
    enum Diagnostics {
        private final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var fn: (@Sendable (String) -> Void)?
        }
        private static let sink = Sink()
        static func setSink(_ f: (@Sendable (String) -> Void)?) { sink.lock.withLock { sink.fn = f } }
        static func log(_ message: String) {
            let f = sink.lock.withLock { sink.fn }
            f?(message)
        }
        static func failed(step: String, attempts: Int) { log("hermes connect failed step=\(step) attempts=\(attempts)") }
        static func recovered(step: String, attempts: Int) { log("hermes connect recovered step=\(step) attempts=\(attempts)") }
        /// A request that failed for a reason that is not "the connection could not be opened" (or that was not safe to
        /// repeat): `sent` is true when body bytes had left the machine.
        static func requestFailed(step: String, attempts: Int, sent: Bool) {
            log("hermes request failed step=\(step) attempts=\(attempts) sent=\(sent)")
        }
    }

    /// Thrown inside a retried operation for a failure that happened before the request could have had any effect.
    struct ConnectFailure: Error { var code: URLError.Code }

    /// Runs `operation` (given its 1 based attempt number) up to `policy.attempts` times while it throws
    /// `ConnectFailure`. Any other error ends it at once. Cancellation is honoured before every attempt and during
    /// every backoff.
    static func withConnectRetry<T>(step: String, policy: ConnectRetry, deadline: ContinuousClock.Instant? = nil,
                                    _ operation: (Int) async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let v = try await operation(attempt)
                if attempt > 1 { Diagnostics.recovered(step: step, attempts: attempt) }
                return v
            } catch let f as ConnectFailure {
                if Task.isCancelled { throw CancellationError() }
                guard let wait = policy.mayRetry(afterAttempt: attempt, now: .now, deadline: deadline) else {
                    Diagnostics.failed(step: step, attempts: attempt)
                    throw f
                }
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    /// Task delegate for one request: refuses redirects and keeps the task, so that the number of body bytes that left
    /// the machine is read from the task itself at the moment of an error (not from a delegate callback that may still
    /// be queued). `didSendBodyData` only adds to that, as a second witness.
    final class RequestGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var sentSeen = false
        private var fired = false
        /// Body bytes sent so far; nil when the task was never seen (unknown).
        var bytesSent: Int64? {
            lock.withLock {
                if task == nil && !sentSeen { return nil }
                return max(task?.countOfBytesSent ?? 0, sentSeen ? 1 : 0)
            }
        }
        var watchdogFired: Bool { lock.withLock { fired } }
        func markWatchdog() { lock.withLock { fired = true } }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { self.task = task }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            lock.withLock { sentSeen = true; self.task = task }
        }
    }

    /// The response headers of one request, plus the session that owns the byte stream (the caller invalidates it).
    struct Opened: @unchecked Sendable {
        let session: URLSession
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
    }

    /// Opens `req` and returns at the response headers, retrying only connect level failures (see `ConnectRetry`).
    /// `rule` says what a repeat can cause: the default `.sideEffects` repeats only when no body byte left the machine.
    /// The connection gets `attemptTimeout` to open: until the body went out (a request that sent bytes is never cut
    /// short or repeated). A request without a body (GET) cannot tell "connecting" from "waiting for the server", so
    /// the first attempts are cut at `attemptTimeout` and the LAST one keeps the request's own timeout: a slow but
    /// healthy server answers within its old allowance, as it did before retries existed.
    /// Once a response arrived nothing is retried. Throws `unreachable(host)` or `CancellationError`.
    static func open(_ req: URLRequest, step: String, host: String, policy: ConnectRetry,
                     rule: ConnectRetry.Rule = .sideEffects,
                     deadline: ContinuousClock.Instant? = nil,
                     makeSession: @Sendable () -> URLSession) async throws -> Opened {
        do {
            return try await withConnectRetry(step: step, policy: policy, deadline: deadline) { attempt in
                let s = makeSession()
                let gate = RequestGate()
                let task = Task { try await s.bytes(for: req, delegate: gate) }
                let boundConnect = !(req.httpBody == nil && attempt >= policy.attempts)
                let watchdog = Task {
                    guard boundConnect else { return }
                    try? await Task.sleep(for: .seconds(policy.attemptTimeout))
                    if !Task.isCancelled, (gate.bytesSent ?? 0) == 0 { gate.markWatchdog(); task.cancel() }
                }
                defer { watchdog.cancel() }
                do {
                    let (bytes, response) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    return Opened(session: s, bytes: bytes, response: response)
                } catch {
                    // Decided here, from the task, at the moment of the error.
                    let sent = gate.bytesSent
                    s.invalidateAndCancel()
                    if Task.isCancelled { throw CancellationError() }
                    let code = gate.watchdogFired ? URLError.Code.timedOut : (error as? URLError)?.code
                    if let code, policy.isRetryable(code, rule: rule, bytesSent: sent) { throw ConnectFailure(code: code) }
                    Diagnostics.requestFailed(step: step, attempts: attempt, sent: (sent ?? 0) > 0)
                    throw HermesChatError.unreachable(host)
                }
            }
        } catch is ConnectFailure {
            throw HermesChatError.unreachable(host)
        }
    }

    // MARK: Network

    /// What one server may make the app buffer or wait for.
    struct Limits: Sendable {
        var connectBodyBytes = 64 * 1024
        var lineBytes = 256 * 1024
        var textChars = 200_000
        var duration: TimeInterval = 15 * 60
        // Sign-in transport only (HermesSignInNet).
        /// Retry once with the ticket in the query when the subprotocol form is refused.
        var allowQueryTicketFallback = true
        var readyTimeout: TimeInterval = 15
        /// How a connection that fails to open is retried (REST, WebSocket handshake, API key requests).
        var connectRetry = ConnectRetry.standard
        var rpcTimeout: TimeInterval = 30
        var pingInterval: TimeInterval = 15
        /// Per turn budget of text frames and bytes (ignored frames count); over it the turn ends like the text cap.
        var maxFrames = 100_000
        var maxBytes = 64 * 1024 * 1024
        static let standard = Limits()
    }

    static let interruptedNote = String(localized: "(The answer was interrupted.)")
    static let tooLongNote = String(localized: "(The answer was cut: it went over the size limit.)")
    static let tooSlowNote = String(localized: "(The answer was cut: it took longer than 15 minutes.)")

    private static func session() -> URLSession { URLSession(configuration: .ephemeral) }

    static func hostLabel(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? String(localized: "the server")
    }

    /// `GET /v1/models` with the key. The only request made during setup. Returns the model name.
    static func connect(baseURL: String, profile: String, key: String, limits: Limits = .standard) async -> Result<String, HermesChatError> {
        guard let url = modelsURL(baseURL: baseURL, profile: profile) else { return .failure(.invalidURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var data = Data()
        let response: URLResponse
        do {
            let opened = try await open(req, step: "models", host: hostLabel(baseURL), policy: limits.connectRetry,
                                        rule: .idempotent, makeSession: { session() })
            defer { opened.session.finishTasksAndInvalidate() }
            response = opened.response
            for try await b in opened.bytes {
                data.append(b)
                if data.count > limits.connectBodyBytes {
                    return .failure(.server(String(localized: "The server answer is too large for a Hermes API.")))
                }
            }
        } catch {
            return .failure(.unreachable(hostLabel(baseURL)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failure(error(status: status, body: data)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]],
              let id = list.first?["id"] as? String, !id.isEmpty else { return .failure(.notHermes) }
        return .success(id)
    }

    /// True when the line says the stream finished normally.
    static func isStreamComplete(_ line: String) -> Bool {
        guard line.hasPrefix("data: ") else { return false }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { return false }
        return (choice["finish_reason"] as? String) == "stop"
    }

    /// Text and end-of-stream state gathered from the SSE lines.
    private struct StreamState {
        var text = ""
        var chars = 0
        var failure: String?
        var complete = false
        var overLimit = false

        /// Returns true when the line added text.
        mutating func ingest(_ line: String, maxChars: Int) -> Bool {
            if let f = HermesChat.parseStreamFailure(line) { failure = f }
            if HermesChat.isStreamComplete(line) { complete = true }
            guard let delta = LocalChat.parseSSEDelta(line) else { return false }
            text += delta
            chars += delta.count
            if chars > maxChars {
                text = String(text.prefix(maxChars))
                chars = maxChars
                overLimit = true
            }
            return true
        }
    }

    static func streamChat(
        agent: HermesAgent,
        key: String,
        encodedBody: Data,
        limits: Limits = .standard,
        onToken: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        guard let url = chatURL(for: agent) else { throw HermesChatError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = encodedBody

        let host = hostLabel(agent.baseURL)
        let opened: Opened
        do {
            // The POST has side effects (it starts an agent turn): repeated ONLY when no body byte left the machine.
            // Only the opening is retried (never after the body went out); the stream keeps its long idle allowance.
            opened = try await open(req, step: "chat", host: host, policy: limits.connectRetry,
                                    rule: .sideEffects, makeSession: { session() })
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HermesChatError.unreachable(host)
        }
        defer { opened.session.finishTasksAndInvalidate() }
        let bytes = opened.bytes
        let response = opened.response

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = Data()
            do { for try await b in bytes { raw.append(b); if raw.count >= 4096 { break } } } catch {}
            throw error(status: status, body: raw)
        }

        var state = StreamState()
        var line: [UInt8] = []
        var lineTooLong = false
        var tooSlow = false
        var broken = false
        var lastUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(limits.duration))

        func emit(_ visibleSource: String) async {
            let visible = LocalChat.progressiveFilter(visibleSource)
            await MainActor.run { onToken(visible) }
        }

        do {
            // Lines are split here, not by `bytes.lines`, so a line can be capped.
            for try await byte in bytes {
                if clock.now >= deadline { tooSlow = true; break }
                if byte != 0x0A {
                    line.append(byte)
                    if line.count > limits.lineBytes { lineTooLong = true; break }
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if state.ingest(text, maxChars: limits.textChars) {
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) >= minInterval {
                        lastUpdate = now
                        await emit(state.text)
                    }
                }
                if state.overLimit { break }
            }
            if !lineTooLong, !tooSlow, !state.overLimit, !line.isEmpty {
                _ = state.ingest(String(decoding: line, as: UTF8.self), maxChars: limits.textChars)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            broken = true
        }
        if Task.isCancelled { throw CancellationError() }
        if broken && state.text.isEmpty { throw HermesChatError.unreachable(host) }
        await emit(state.text)

        let text = LocalChat.filterThinkingBlocks(state.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let capNote: String? = tooSlow ? tooSlowNote : (lineTooLong || state.overLimit) ? tooLongNote : nil
        if text.isEmpty {
            throw HermesChatError.agentFailed(state.failure ?? capNote ?? String(localized: "The agent returned no text."))
        }
        // Some text arrived: keep it, and say so when the stream did not end normally.
        if let capNote { return text + "\n\n" + capNote }
        if broken || state.failure != nil || !state.complete { return text + "\n\n" + interruptedNote }
        return text
    }
}
