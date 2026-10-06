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
        case .invalidURL:    return "Enter a URL like https://hermes.example.com."
        case .insecureURL:   return "Use https:// for this host. http:// is only allowed for localhost and private addresses."
        case .unauthorized:  return "Hermes refused the API key. Each profile has its own key."
        case .notFound:      return "Hermes has no such profile at this URL. Check the profile name."
        case .busy:          return "The agent is busy. Try again in a moment."
        case .notHermes:     return "This URL doesn't answer like a Hermes API server. Use the API address, not the dashboard."
        case .unreachable(let host): return "Can't reach Hermes at \(host). Is the gateway running?"
        case .server(let m), .agentFailed(let m): return m
        case .notBound(let name): return "\(name) changed since it was connected, so its key was not sent. Disconnect it and connect it again in Settings → Chat."
        case .signInNeeded(let name): return "Sign in to \(name) again in Settings → Chat."
        case .signInFailed(let m): return m
        }
    }
}

/// Refuses every redirect: the Authorization header must never follow a 30x to another host,
/// and an SSO redirect means "not the API address" anyway.
final class HermesNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
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
        return "The agent stopped with an error."
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
            return .failure(.notBound(agent.name))
        }
        return .success(r.key)
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
        var rpcTimeout: TimeInterval = 30
        var pingInterval: TimeInterval = 15
        /// Per turn budget of text frames and bytes (ignored frames count); over it the turn ends like the text cap.
        var maxFrames = 100_000
        var maxBytes = 64 * 1024 * 1024
        static let standard = Limits()
    }

    static let interruptedNote = "(The answer was interrupted.)"
    static let tooLongNote = "(The answer was cut: it went over the size limit.)"
    static let tooSlowNote = "(The answer was cut: it took longer than 15 minutes.)"

    private static func session() -> URLSession { URLSession(configuration: .ephemeral) }

    static func hostLabel(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? "the server"
    }

    /// `GET /v1/models` with the key. The only request made during setup. Returns the model name.
    static func connect(baseURL: String, profile: String, key: String, limits: Limits = .standard) async -> Result<String, HermesChatError> {
        guard let url = modelsURL(baseURL: baseURL, profile: profile) else { return .failure(.invalidURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let s = session()
        defer { s.finishTasksAndInvalidate() }
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, r) = try await s.bytes(for: req, delegate: HermesNoRedirect())
            response = r
            for try await b in bytes {
                data.append(b)
                if data.count > limits.connectBodyBytes {
                    return .failure(.server("The server answer is too large for a Hermes API."))
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

        let s = session()
        defer { s.finishTasksAndInvalidate() }
        let host = hostLabel(agent.baseURL)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await s.bytes(for: req, delegate: HermesNoRedirect())
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HermesChatError.unreachable(host)
        }

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
            throw HermesChatError.agentFailed(state.failure ?? capNote ?? "The agent returned no text.")
        }
        // Some text arrived: keep it, and say so when the stream did not end normally.
        if let capNote { return text + "\n\n" + capNote }
        if broken || state.failure != nil || !state.complete { return text + "\n\n" + interruptedNote }
        return text
    }
}
