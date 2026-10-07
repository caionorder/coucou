import Foundation
import CryptoKit
import Security

// MARK: - Hermes sign in (pure logic: PKCE, callback, tokens, JSON-RPC frames). No I/O here.

enum HermesSignIn {

    // MARK: PKCE (RFC 7636, as the Hermes Desktop does it)

    struct PKCE: Equatable, Sendable {
        var verifier: String
        var challenge: String
        var state: String
    }

    static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Never fall back to something predictable.
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Verifier = 32 random bytes, challenge = base64url(SHA256(verifier)), state = 24 random bytes.
    static func makePKCE(random: (Int) -> [UInt8] = HermesSignIn.secureRandom) -> PKCE {
        let verifier = base64URL(random(32))
        let challenge = base64URL(Array(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge, state: base64URL(random(24)))
    }

    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/callback" }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `base` is a normalised base URL (it may carry a path prefix).
    static func authorizeURL(baseURL: String, pkce: PKCE, redirectURI: String, provider: String?) -> URL? {
        var query = "code_challenge=\(enc(pkce.challenge))&code_challenge_method=S256"
            + "&redirect_uri=\(enc(redirectURI))&state=\(enc(pkce.state))"
        if let provider, !provider.isEmpty { query += "&provider=\(enc(provider))" }
        guard let base = endpoint(baseURL, "/auth/native/authorize") else { return nil }
        return URL(string: base.absoluteString + "?" + query)
    }

    // MARK: Callback

    static let refusedMessage = String(localized: "Hermes refused the sign in.")
    static let stateMessage = String(localized: "Sign in was rejected: the answer did not match this request.")

    private static func callbackItems(_ requestLine: String) -> [URLQueryItem]? {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/"),
              let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
              comps.path == "/callback" else { return nil }
        return comps.queryItems ?? []
    }

    /// True for a `GET /callback?…` whose `state` equals the expected one: the only request that ends a sign in.
    /// Favicon requests, other paths, a bare `/callback` and a request with another state are answered and ignored,
    /// so a stray or hostile request cannot cancel the flow.
    static func isCallback(requestLine: String, expectedState: String) -> Bool {
        guard let items = callbackItems(requestLine),
              let state = items.first(where: { $0.name == "state" })?.value else { return false }
        return constantTimeEqual(state, expectedState)
    }

    /// The code, only when `state` equals the expected one. The state is compared before anything else is used.
    static func parseCallback(requestLine: String, expectedState: String) -> Result<String, HermesChatError> {
        guard let items = callbackItems(requestLine) else { return .failure(.signInFailed(refusedMessage)) }
        func value(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        guard let state = value("state"), constantTimeEqual(state, expectedState) else {
            return .failure(.signInFailed(stateMessage))
        }
        if value("error") != nil { return .failure(.signInFailed(refusedMessage)) }
        guard let code = value("code"), !code.isEmpty, code.count <= 2048 else {
            return .failure(.signInFailed(refusedMessage))
        }
        return .success(code)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Session record (what the Keychain holds per agent)

    struct SessionRecord: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String
        /// Epoch seconds; 0 = unknown.
        var expiresAt: Double
        var provider: String
        var userID: String
        /// Display name or email, for Settings only.
        var label: String
        /// Normalised base URL the tokens were issued for. They are never sent anywhere else.
        var baseURL: String
    }

    /// Token and refresh answer. An empty or missing `refresh_token` keeps the previous one.
    static func parseTokenResponse(_ data: Data, baseURL: String, previous: SessionRecord?) -> Result<SessionRecord, HermesChatError> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, access.count >= 16, access.count <= 16_384,
              !access.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return .failure(.signInFailed(String(localized: "Hermes refused the sign in code. Try again.")))
        }
        let newRefresh = (json["refresh_token"] as? String) ?? ""
        var expires = (json["expires_at"] as? NSNumber)?.doubleValue ?? 0
        if !expires.isFinite || expires < 0 { expires = 0 }
        return .success(SessionRecord(
            accessToken: access,
            refreshToken: newRefresh.isEmpty ? (previous?.refreshToken ?? "") : newRefresh,
            expiresAt: expires,
            provider: (json["provider"] as? String) ?? previous?.provider ?? "",
            userID: (json["user_id"] as? String) ?? previous?.userID ?? "",
            label: previous?.label ?? "",
            baseURL: baseURL))
    }

    enum TokenAction: Equatable { case use, refresh, signInAgain }

    /// Refresh 60 s before expiry (as the Desktop does). Unknown expiry refreshes when a refresh token exists.
    static func tokenAction(_ r: SessionRecord, now: Double, skew: Double = 60) -> TokenAction {
        let hasRefresh = !r.refreshToken.isEmpty
        if r.expiresAt <= 0 { return hasRefresh ? .refresh : .use }
        if now < r.expiresAt - skew { return .use }
        if hasRefresh { return .refresh }
        return now < r.expiresAt ? .use : .signInAgain
    }

    static func encodeSessions(_ s: [String: SessionRecord]) -> String {
        guard let d = try? JSONEncoder().encode(s) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func decodeSessions(_ s: String) -> [String: SessionRecord] {
        (try? JSONDecoder().decode([String: SessionRecord].self, from: Data(s.utf8))) ?? [:]
    }

    /// The session for `agent`, only when the agent is a sign in agent and the record was issued for exactly its base URL.
    static func boundSession(for agent: HermesAgent, in sessions: [String: SessionRecord]) -> Result<SessionRecord, HermesChatError> {
        guard agent.connection == .signIn, HermesChat.isValidAgent(agent),
              let r = sessions[agent.name], !r.accessToken.isEmpty,
              !r.baseURL.isEmpty, r.baseURL == agent.baseURL else {
            return .failure(.signInNeeded(agent.shownName))
        }
        return .success(r)
    }

    // MARK: URLs

    /// Hosts where a sign in session may travel over plain http: loopback only.
    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    static let httpsOnlyMessage = String(localized: "Sign in needs https://. Plain http:// is only accepted for localhost.")

    /// The session is a full dashboard credential: https everywhere, plain http only to loopback
    /// (stricter than the API key rule, which also accepts private addresses and single label names).
    static func isAllowedSignInBase(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(), let host = url.host else { return false }
        return scheme == "https" || (scheme == "http" && isLoopbackHost(host))
    }

    /// `base` + `path`, only when `base` is already in normalised form and passes the sign in transport rule.
    /// Every REST call, the refresh, the authorize URL and the WebSocket URL come through here.
    static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        guard path.hasPrefix("/"), case .success(let n) = HermesChat.normaliseBaseURL(baseURL), n == baseURL,
              isAllowedSignInBase(baseURL) else { return nil }
        return URL(string: baseURL + path)
    }

    /// `https` becomes `wss`, `http` becomes `ws`. The ticket is added to the query only for the fallback form.
    static func socketURL(baseURL: String, queryTicket: String?) -> URL? {
        guard let http = endpoint(baseURL, "/api/ws"), var comps = URLComponents(url: http, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http": comps.scheme = "ws"
        default: return nil
        }
        if let t = queryTicket {
            // A ticket in a URL is only acceptable over TLS (or on this machine).
            guard isTicket(t), comps.scheme == "wss" || isLoopbackHost(comps.host ?? "") else { return nil }
            comps.queryItems = [URLQueryItem(name: "ticket", value: t)]
        }
        return comps.url
    }

    static func isTicket(_ t: String) -> Bool {
        guard (16...256).contains(t.utf8.count) else { return false }
        return t.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    /// `Sec-WebSocket-Protocol` values: the stable one and exactly one ticket protocol.
    static func ticketProtocols(_ ticket: String) -> [String]? {
        guard isTicket(ticket) else { return nil }
        return ["hermes-gateway-v1", "hermes-gateway-ticket.\(ticket)"]
    }

    static func parseTicket(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["ticket"] as? String, isTicket(t) else { return nil }
        return t
    }

    // MARK: Profiles

    struct Profile: Equatable, Sendable {
        var name: String
        var title: String
        var isDefault: Bool
    }

    static func parseProfiles(_ data: Data) -> [Profile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["profiles"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var out: [Profile] = []
        for p in list {
            guard let name = p["name"] as? String, !name.isEmpty, HermesChat.isValidProfile(name),
                  seen.insert(name).inserted else { continue }
            let display = (p["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(Profile(name: name, title: display.isEmpty ? name : String(display.prefix(80)),
                               isDefault: (p["is_default"] as? Bool) ?? false))
        }
        return out
    }

    /// Label for Settings from `GET /api/auth/me`.
    static func parseMe(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["display_name", "email", "user_id"] {
            if let v = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return String(v.prefix(80))
            }
        }
        return nil
    }

    /// A bad or expired bearer on `/api/*` answers 401 (never a redirect).
    static func isSessionExpired(status: Int, body: Data) -> Bool { status == 401 }

    // MARK: JSON-RPC frames

    static func request(id: Int, method: String, params: [String: Any]) -> String {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Every server request is refused with "method not found": nothing is ever approved or answered by Coucou.
    static func rejection(id: Any) -> String {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                  "error": ["code": -32601, "message": "Method not found"] as [String: Any]]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    enum Frame: Equatable, Sendable {
        case ready
        case start(session: String)
        case result(id: Int, [String: String])
        case failure(id: Int, code: Int, message: String)
        case delta(session: String, text: String)
        case complete(session: String, text: String, status: String, error: String?)
        case error(session: String, message: String)
        case serverRequest(id: String, method: String)
        case requestCancelled(method: String)
        case approvalHint
        case ignored
    }

    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= -9e15, d <= 9e15, d == d.rounded() else { return nil }
        return n.intValue
    }

    /// Never throws: unknown or malformed frames are `.ignored`.
    static func decode(_ text: String) -> Frame {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .ignored }
        let method = obj["method"] as? String
        if let method, method != "event", let rawID = obj["id"], !(rawID is NSNull) {
            if let s = rawID as? String { return .serverRequest(id: s, method: method) }
            if let n = intValue(rawID) { return .serverRequest(id: String(n), method: method) }
            return .ignored
        }
        if method == "event" {
            guard let params = obj["params"] as? [String: Any], let type = params["type"] as? String else { return .ignored }
            let session = (params["session_id"] as? String) ?? ""
            let payload = (params["payload"] as? [String: Any]) ?? [:]
            switch type {
            case "gateway.ready": return .ready
            case "message.start": return .start(session: session)
            case "message.delta":
                guard let t = payload["text"] as? String else { return .ignored }
                return .delta(session: session, text: t)
            case "message.complete":
                var err: String?
                if let e = payload["error"] as? String, !e.isEmpty { err = String(e.prefix(200)) }
                else if let e = payload["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty { err = String(m.prefix(200)) }
                let status = (payload["status"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "complete"
                return .complete(session: session, text: (payload["text"] as? String) ?? "", status: status, error: err)
            case "error":
                let m = (payload["message"] as? String) ?? ""
                return .error(session: session, message: String(m.prefix(200)))
            case "request.cancel":
                return .requestCancelled(method: (payload["method"] as? String) ?? "")
            case "tool.complete", "status.update":
                return mentionsWithdrawnApproval(payload) ? .approvalHint : .ignored
            default: return .ignored
            }
        }
        if obj["method"] == nil, let id = intValue(obj["id"]) {
            if let err = obj["error"] as? [String: Any] {
                return .failure(id: id, code: intValue(err["code"]) ?? 0, message: String((err["message"] as? String ?? "").prefix(200)))
            }
            if let result = obj["result"] as? [String: Any] {
                var strings: [String: String] = [:]
                for (k, v) in result { if let s = v as? String { strings[k] = s } }
                return .result(id: id, strings)
            }
            if obj["result"] != nil { return .result(id: id, [:]) }
        }
        return .ignored
    }

    private static func mentionsWithdrawnApproval(_ payload: [String: Any]) -> Bool {
        func scan(_ v: Any, _ depth: Int) -> Bool {
            if let s = v as? String { return s.lowercased().contains("approval was withdrawn") }
            guard depth < 3 else { return false }
            if let d = v as? [String: Any] { return d.values.contains { scan($0, depth + 1) } }
            if let a = v as? [Any] { return a.contains { scan($0, depth + 1) } }
            return false
        }
        return scan(payload, 0)
    }

    // MARK: Turn reducer (no I/O)

    static let approvalNote = String(localized: "(The agent needed an approval that Coucou cannot give yet. Approve it in the Hermes app.)")
    static let newSessionNote = String(localized: "(The previous session was no longer available, so a new one was started.)")

    struct Turn {
        /// Runtime session id. Frames for another non-empty session id are ignored; empty = not set yet.
        var session = ""
        var text = ""
        var completeText = ""
        var chars = 0
        var done = false
        var failure: String?
        var status = ""
        var overLimit = false
        var approval = false
        /// The submit was queued behind a running turn and its `message.start` has not arrived: every delta and
        /// terminal event until that start belongs to the earlier turn.
        var awaitingStart = false
        /// A `message.start` was seen on this socket (the server sends one at the start of every turn).
        var startSeen = false

        private func other(_ s: String) -> Bool { !session.isEmpty && !s.isEmpty && s != session }

        /// Text to show while the answer streams.
        var visibleSource: String { completeText.isEmpty ? text : completeText }

        /// True when the visible text grew.
        mutating func ingest(_ f: Frame, maxChars: Int) -> Bool {
            switch f {
            case .delta(let s, let t):
                guard !other(s), !done, !awaitingStart else { return false }
                text += t
                chars += t.count
                if chars > maxChars {
                    text = String(text.prefix(maxChars))
                    chars = maxChars
                    overLimit = true
                }
                return true
            case .complete(let s, let t, let status, let err):
                guard !other(s), !done, !awaitingStart else { return false }
                done = true
                self.status = status
                if status == "error" { failure = err ?? failure }
                if !t.isEmpty {
                    completeText = t.count > maxChars ? String(t.prefix(maxChars)) : t
                    if t.count > maxChars { overLimit = true }
                    return true
                }
                return false
            case .error(let s, let m):
                guard !other(s), !done, !awaitingStart else { return false }
                done = true
                status = "error"
                failure = m.isEmpty ? String(localized: "The agent stopped with an error.") : m
                return false
            case .start(let s):
                // A turn starts here: whatever came before on this socket belongs to an earlier turn.
                guard !other(s) else { return false }
                startSeen = true
                awaitingStart = false
                resetContent()
                return false
            case .serverRequest(_, let method):
                if method == "approval" { approval = true }
                return false
            case .requestCancelled(let method):
                if method == "approval" { approval = true }
                return false
            case .approvalHint:
                approval = true
                return false
            case .ready, .result, .failure, .ignored:
                return false
            }
        }

        private mutating func resetContent() {
            text = ""; completeText = ""; chars = 0
            done = false; failure = nil; status = ""; overLimit = false
        }

        /// The server accepted the message but queued it behind a running turn (`prompt.submit` answered `queued`).
        /// The boundary is the next `message.start`, not a terminal event: the earlier turn's terminal event may
        /// have gone to another socket. When that start already arrived, the state since it is ours and is kept.
        mutating func queuedBehindRunningTurn() {
            if startSeen { return }
            resetContent()
            awaitingStart = true
        }

        /// Mirrors `HermesChat.streamChat`: complete text first, else the deltas; notes appended in a fixed order.
        func finalText(tooSlow: Bool, closedEarly: Bool, resumedFresh: Bool) throws -> String {
            let source = completeText.isEmpty ? text : completeText
            let visible = LocalChat.filterThinkingBlocks(source).trimmingCharacters(in: .whitespacesAndNewlines)
            let capNote: String? = tooSlow ? HermesChat.tooSlowNote : overLimit ? HermesChat.tooLongNote : nil
            if visible.isEmpty {
                throw HermesChatError.agentFailed(failure ?? capNote ?? String(localized: "The agent returned no text."))
            }
            var notes: [String] = []
            if let capNote { notes.append(capNote) }
            else if status == "interrupted" || status == "error" || failure != nil || (closedEarly && !done) {
                notes.append(HermesChat.interruptedNote)
            }
            if approval { notes.append(approvalNote) }
            if resumedFresh { notes.append(newSessionNote) }
            return notes.isEmpty ? visible : visible + "\n\n" + notes.joined(separator: "\n")
        }
    }
}
