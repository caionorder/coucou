import Foundation

// MARK: - Test harness

@main
enum HermesChatTests {

    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got)")
            print("    expected: \(expected)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func norm(_ s: String) -> String {
        switch HermesChat.normaliseBaseURL(s) {
        case .success(let u): return u
        case .failure(let e): return "ERR:\(e)"
        }
    }

    static func isUnreachable(_ e: HermesChatError?) -> Bool {
        if case .unreachable = e { return true }
        return false
    }

    final class Box: @unchecked Sendable {
        var calls = 0
        var last = ""
    }

    static func headerValue(_ url: URL, _ key: String, _ name: String, body: String) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: name)
    }

    static func main() async {
        let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0"
        let base = "http://127.0.0.1:\(port)"

        // ── Unit tests ───────────────────────────────────────────────────────
        print("normaliseBaseURL")
        check("trailing slash", norm("https://agent.example.com/"), "https://agent.example.com")
        check("/v1", norm("https://agent.example.com/v1"), "https://agent.example.com")
        check("/p/mark/v1", norm("https://agent.example.com/p/mark/v1"), "https://agent.example.com")
        check("/p/mark", norm("https://agent.example.com/p/mark/"), "https://agent.example.com")
        check("whitespace", norm("  https://agent.example.com  "), "https://agent.example.com")
        check("keeps port", norm("https://agent.example.com:8443/"), "https://agent.example.com:8443")
        check("ftp", norm("ftp://agent.example.com"), "ERR:invalidURL")
        check("file", norm("file:///etc/passwd"), "ERR:invalidURL")
        check("user-info", norm("https://user:pw@agent.example.com"), "ERR:invalidURL")
        check("query", norm("https://agent.example.com/?a=1"), "ERR:invalidURL")
        check("empty", norm(""), "ERR:invalidURL")
        check("http public", norm("http://example.com"), "ERR:insecureURL")
        check("http localhost", norm("http://localhost:8642"), "http://localhost:8642")
        check("http LAN", norm("http://192.168.1.10:8642"), "http://192.168.1.10:8642")
        check("http tailscale", norm("http://100.101.1.2:8642"), "http://100.101.1.2:8642")
        check("http 172.32 public", norm("http://172.32.0.1"), "ERR:insecureURL")
        check("http 172.16 private", norm("http://172.16.0.1"), "http://172.16.0.1")
        check("http .local", norm("http://mac-mini.local:8642"), "http://mac-mini.local:8642")
        check("http single label", norm("http://mac-mini:8642"), "http://mac-mini:8642")
        check("http all-digit host", norm("http://134744072"), "ERR:insecureURL")
        check("http 0x host", norm("http://0x08080808"), "ERR:insecureURL")
        check("http digit host with port", norm("http://134744072:8642"), "ERR:insecureURL")
        check("https all-digit host untouched", norm("https://134744072"), "https://134744072")
        check("http loopback v6", norm("http://[::1]:8642"), "http://[::1]:8642")
        check("http public v6", norm("http://[2001:db8::1]"), "ERR:insecureURL")
        check("http ULA v6", norm("http://[fd00::1]:8642"), "http://[fd00::1]:8642")
        check("http 100.128 public", norm("http://100.128.0.1"), "ERR:insecureURL")

        print("host classification")
        checkTrue("loopback", HermesChat.isLocalHost("127.0.0.1"))
        checkTrue("private 10", HermesChat.isLocalHost("10.1.2.3"))
        checkTrue("100.64/10", HermesChat.isLocalHost("100.100.1.1"))
        checkTrue("name.local", HermesChat.isLocalHost("mac-mini.local"))
        checkTrue("single label", HermesChat.isLocalHost("mac-mini"))
        checkTrue("digits are not a label", !HermesChat.isLocalHost("134744072"))
        checkTrue("0x is not a label", !HermesChat.isLocalHost("0x08080808"))
        checkTrue("0X is not a label", !HermesChat.isLocalHost("0X7f000001"))
        checkTrue("public name", !HermesChat.isLocalHost("example.com"))
        checkTrue("localhost.attacker", !HermesChat.isLocalHost("localhost.attacker.example"))
        checkTrue("unencrypted: single label name", HermesChat.sendsKeyUnencryptedToName("http://mac-mini:8642"))
        checkTrue("unencrypted: .local name", HermesChat.sendsKeyUnencryptedToName("http://mac-mini.local"))
        checkTrue("not unencrypted: https", !HermesChat.sendsKeyUnencryptedToName("https://agent.example.com"))
        checkTrue("not unencrypted: IPv4 literal", !HermesChat.sendsKeyUnencryptedToName("http://192.168.1.10:8642"))
        checkTrue("not unencrypted: tailscale IP", !HermesChat.sendsKeyUnencryptedToName("http://100.101.1.2"))
        checkTrue("not unencrypted: IPv6 literal", !HermesChat.sendsKeyUnencryptedToName("http://[fd00::1]:8642"))
        checkTrue("not unencrypted: localhost", !HermesChat.sendsKeyUnencryptedToName("http://localhost:8642"))

        print("profileInURL")
        check("/p/mark/v1", HermesChat.profileInURL("https://agent.example.com/p/mark/v1"), "mark")
        check("/p/mark/v1/", HermesChat.profileInURL("https://agent.example.com/p/mark/v1/"), "mark")
        checkTrue("/p/mark without v1", HermesChat.profileInURL("https://agent.example.com/p/mark") == nil)
        checkTrue("plain /v1", HermesChat.profileInURL("https://agent.example.com/v1") == nil)
        checkTrue("invalid name", HermesChat.profileInURL("https://agent.example.com/p/a%20b/v1") == nil)

        print("isValidProfile")
        checkTrue("mark", HermesChat.isValidProfile("mark"))
        checkTrue("a/b", !HermesChat.isValidProfile("a/b"))
        checkTrue("../x", !HermesChat.isValidProfile("../x"))
        checkTrue("empty", HermesChat.isValidProfile(""))
        checkTrue("65 chars", !HermesChat.isValidProfile(String(repeating: "a", count: 65)))

        print("apiRoot / chatURL")
        check("empty", HermesChat.apiRoot(baseURL: "https://h.io", profile: ""), "https://h.io")
        check("default", HermesChat.apiRoot(baseURL: "https://h.io", profile: "default"), "https://h.io")
        check("mark", HermesChat.apiRoot(baseURL: "https://h.io", profile: "mark"), "https://h.io/p/mark")
        let a = HermesAgent(name: "mark", baseURL: "https://h.io", profile: "mark", modelName: "mark")
        check("chatURL", HermesChat.chatURL(for: a)?.absoluteString ?? "", "https://h.io/p/mark/v1/chat/completions")
        check("modelsURL", HermesChat.modelsURL(baseURL: "https://h.io", profile: "")?.absoluteString ?? "", "https://h.io/v1/models")
        checkTrue("bad profile → nil", HermesChat.modelsURL(baseURL: "https://h.io", profile: "../x") == nil)

        print("parseStreamFailure")
        checkTrue("stop", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == nil)
        checkTrue("null", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{"content":"x"},"finish_reason":null}]}"#) == nil)
        check("error + message", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"error"}],"error":{"message":"boom"}}"#) ?? "", "boom")
        check("error no message", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"error"}]}"#) ?? "", "The agent stopped with an error.")
        checkTrue("non-data", HermesChat.parseStreamFailure(": keepalive") == nil)
        checkTrue("named event data", HermesChat.parseStreamFailure(#"data: {"tool":"terminal"}"#) == nil)

        print("error(status:body:)")
        let env = Data(#"{"error":{"message":"kaput","type":"x","code":"y"}}"#.utf8)
        check("401", HermesChat.error(status: 401, body: env), .unauthorized)
        check("404", HermesChat.error(status: 404, body: env), .notFound)
        check("429", HermesChat.error(status: 429, body: env), .busy)
        check("500 envelope", HermesChat.error(status: 500, body: env), .server("kaput"))
        check("500 bare", HermesChat.error(status: 500, body: Data()), .server("HTTP 500"))
        check("302", HermesChat.error(status: 302, body: Data()), .notHermes)

        print("agents / keys JSON")
        let agents = [a, HermesAgent(name: "x", baseURL: "http://localhost:1", profile: "", modelName: "hermes-agent")]
        check("agents round-trip", HermesChat.decodeAgents(HermesChat.encodeAgents(agents)), agents)
        check("agents garbage", HermesChat.decodeAgents("not json"), [])
        let keys = [
            "mark": HermesChat.KeyRecord(key: "k1", baseURL: "https://h.io", profile: "mark"),
            "x": HermesChat.KeyRecord(key: "k2", baseURL: "http://localhost:1", profile: ""),
        ]
        check("keys round-trip", HermesChat.decodeKeys(HermesChat.encodeKeys(keys)), keys)
        check("keys garbage", HermesChat.decodeKeys("nope"), [:])
        checkTrue("agents JSON has no key material", !HermesChat.encodeAgents(agents).contains("k1"))

        print("sanitiseAgents")
        let dup = HermesAgent(name: "mark", baseURL: "https://other.io", profile: "", modelName: "m")
        check("duplicate name dropped, first wins", HermesChat.sanitiseAgents([a, dup]), [a])
        let httpPublic = HermesAgent(name: "p", baseURL: "http://example.com", profile: "", modelName: "m")
        let slash = HermesAgent(name: "s", baseURL: "https://h.io/", profile: "", modelName: "m")
        let badProfile = HermesAgent(name: "b", baseURL: "https://h.io", profile: "../x", modelName: "m")
        let digits = HermesAgent(name: "d", baseURL: "http://134744072", profile: "", modelName: "m")
        let noName = HermesAgent(name: "", baseURL: "https://h.io", profile: "", modelName: "m")
        check("http public, non-normal, bad profile, digit host, no name dropped",
              HermesChat.sanitiseAgents([httpPublic, slash, badProfile, digits, noName, a]), [a])
        let tampered = HermesChat.encodeAgents([HermesAgent(name: "mark", baseURL: "https://attacker.example/", profile: "", modelName: "m")])
        check("loaded entry that does not round-trip is dropped", HermesChat.decodeAgents(tampered), [])
        check("chatURL refuses an invalid stored agent", HermesChat.chatURL(for: httpPublic) == nil, true)

        print("boundKey")
        func bound(_ agent: HermesAgent, _ k: [String: HermesChat.KeyRecord]) -> String {
            switch HermesChat.boundKey(for: agent, in: k) {
            case .success(let key): return key
            case .failure(let e): return "ERR:\(e)"
            }
        }
        let good = ["mark": HermesChat.KeyRecord(key: "k1", baseURL: "https://h.io", profile: "mark")]
        check("matching binding returns the key", bound(a, good), "k1")
        check("different host refused", bound(HermesAgent(name: "mark", baseURL: "https://attacker.example", profile: "mark", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("different profile refused", bound(HermesAgent(name: "mark", baseURL: "https://h.io", profile: "other", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("scheme change refused", bound(HermesAgent(name: "mark", baseURL: "http://localhost:1", profile: "mark", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("no record refused", bound(a, [:]), "ERR:notBound(\"mark\")")
        check("empty key refused", bound(a, ["mark": HermesChat.KeyRecord(key: "", baseURL: "https://h.io", profile: "mark")]), "ERR:notBound(\"mark\")")
        let oldFormat = HermesChat.decodeKeys(#"{"mark":"k1"}"#)
        check("previous format decodes with the key", oldFormat["mark"]?.key ?? "", "k1")
        check("previous format counts as not bound", bound(a, oldFormat), "ERR:notBound(\"mark\")")
        checkTrue("notBound message asks to reconnect", HermesChatError.notBound("mark").userMessage.contains("connect it again"))

        // ── Integration against the fake server ──────────────────────────────
        print("connect")
        func conn(_ profile: String, _ key: String, _ b: String = base) async -> (String?, HermesChatError?) {
            switch await HermesChat.connect(baseURL: b, profile: profile, key: key) {
            case .success(let m): return (m, nil)
            case .failure(let e): return (nil, e)
            }
        }
        var r = await conn("", "test-key-default")
        check("default ok", r.0 ?? "", "hermes-agent")
        r = await conn("mark", "test-key-mark")
        check("mark ok", r.0 ?? "", "mark")
        r = await conn("mark", "test-key-default")
        check("default key on /p/mark → unauthorized", r.1, .unauthorized)
        r = await conn("mark", "")
        check("empty key → unauthorized", r.1, .unauthorized)
        r = await conn("nobody", "test-key-mark")
        check("unknown profile → notFound", r.1, .notFound)
        r = await conn("", "test-key-default", base + "/dashboard")
        check("html page → notHermes", r.1, .notHermes)
        r = await conn("", "test-key-default", base + "/sso")
        check("redirect not followed → notHermes", r.1, .notHermes)
        r = await conn("", "test-key-default", "http://127.0.0.1:1")
        checkTrue("closed port → unreachable", isUnreachable(r.1))

        print("streamChat")
        func body(_ text: String, model: String = "mark") -> Data {
            let b: [String: Any] = ["model": model, "stream": true, "messages": [["role": "user", "content": text]]]
            return (try? JSONSerialization.data(withJSONObject: b)) ?? Data()
        }
        let markAgent = HermesAgent(name: "mark", baseURL: base, profile: "mark", modelName: "mark")
        let tokens = Box()
        do {
            let text = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi")) { visible in
                tokens.calls += 1; tokens.last = visible
            }
            check("exact text, frames skipped", text, "Hello from mark.")
            checkTrue("onToken called", tokens.calls >= 1)
            check("last onToken is the full text", tokens.last, "Hello from mark.")
        } catch { print("  ✗ unexpected: \(error)"); failures += 1 }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("fail")) { _ in }
            print("  ✗ fail: expected throw"); failures += 1
        } catch { check("fail → agentFailed(boom)", error as? HermesChatError, .agentFailed("boom")) }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("busy")) { _ in }
            print("  ✗ busy: expected throw"); failures += 1
        } catch { check("busy → busy", error as? HermesChatError, .busy) }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "wrong", encodedBody: body("hi")) { _ in }
            print("  ✗ 401: expected throw"); failures += 1
        } catch { check("wrong key → unauthorized", error as? HermesChatError, .unauthorized) }

        do {
            let dead = HermesAgent(name: "d", baseURL: "http://127.0.0.1:1", profile: "", modelName: "hermes-agent")
            _ = try await HermesChat.streamChat(agent: dead, key: "k", encodedBody: body("hi")) { _ in }
            print("  ✗ closed port: expected throw"); failures += 1
        } catch { checkTrue("closed port → unreachable", isUnreachable(error as? HermesChatError)) }

        print("interrupted streams keep the text and say so")
        func run(_ prompt: String, limits: HermesChat.Limits = .standard) async -> (String?, HermesChatError?, Double) {
            let t0 = Date()
            do {
                let t = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body(prompt), limits: limits) { _ in }
                return (t, nil, Date().timeIntervalSince(t0))
            } catch { return (nil, error as? HermesChatError, Date().timeIntervalSince(t0)) }
        }
        var rr = await run("content_error")
        check("content then error: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)
        rr = await run("content_closed")
        check("content then closed socket: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)
        rr = await run("content_reset")
        check("content then reset: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)

        print("limits")
        var small = HermesChat.Limits()
        small.lineBytes = 2048
        rr = await run("longline", limits: small)
        check("line over the cap, no text → message", rr.1, .agentFailed(HermesChat.tooLongNote))
        small = HermesChat.Limits()
        small.textChars = 1000
        rr = await run("bigtext", limits: small)
        checkTrue("text over the cap: kept, truncated, noted", (rr.0 ?? "").hasSuffix(HermesChat.tooLongNote) && (rr.0 ?? "").hasPrefix("Start. yyy") && (rr.0 ?? "").count < 1100)
        small = HermesChat.Limits()
        small.duration = 0.6
        rr = await run("slow", limits: small)
        check("duration cap: text kept + note", rr.0 ?? "", "Slow start.\n\n" + HermesChat.tooSlowNote)
        checkTrue("duration cap ended the turn well before the server did", rr.2 < 5)
        small = HermesChat.Limits()
        small.connectBodyBytes = 1000
        switch await HermesChat.connect(baseURL: base + "/big", profile: "", key: "test-key-default", limits: small) {
        case .failure(let e): check("connect body over the cap", e, .server("The server answer is too large for a Hermes API."))
        case .success: print("  ✗ connect body over the cap: expected failure"); failures += 1
        }
        switch await HermesChat.connect(baseURL: base + "/big", profile: "", key: "test-key-default") {
        case .success(let m): check("100 KB body under no small cap is refused by the 64 KB default", m, "never")
        case .failure(let e): check("connect body over the 64 KB default", e, .server("The server answer is too large for a Hermes API."))
        }

        print("connect retry policy (pure)")
        let std = HermesChat.ConnectRetry.standard
        check("3 attempts", std.attempts, 3)
        check("6 s per attempt", std.attemptTimeout, 6)
        check("wait after attempt 1", std.delay(afterAttempt: 1), 0.3)
        check("wait after attempt 2", std.delay(afterAttempt: 2), 1)
        check("no attempt after the 3rd", std.delay(afterAttempt: 3), nil)
        check("attempt 0 is not a thing", std.delay(afterAttempt: 0), nil)
        let connectLevel: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
        // A POST with side effects: retried only when it is certain that no body byte left the machine.
        for c in connectLevel {
            checkTrue("sideEffects: \(c.rawValue) with 0 bytes sent is retried", std.isRetryable(c, rule: .sideEffects, bytesSent: 0))
            checkTrue("sideEffects: \(c.rawValue) with the bytes unknown is retried (no byte can leave before it connects)", std.isRetryable(c, rule: .sideEffects, bytesSent: nil))
            checkTrue("sideEffects: \(c.rawValue) with bytes sent is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 1))
        }
        for c in [URLError.Code.timedOut, .networkConnectionLost] {
            checkTrue("sideEffects: \(c.rawValue) with 0 bytes sent is retried", std.isRetryable(c, rule: .sideEffects, bytesSent: 0))
            checkTrue("sideEffects: \(c.rawValue) after the body went out is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 1))
            checkTrue("sideEffects: \(c.rawValue) after the whole body went out is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 4096))
            checkTrue("sideEffects: \(c.rawValue) with the bytes unknown is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: nil))
        }
        // Idempotent (GET, WebSocket handshake, ticket POST): connection lost is retried as well.
        for c in connectLevel + [.networkConnectionLost] {
            checkTrue("idempotent: \(c.rawValue) is retried", std.isRetryable(c, rule: .idempotent, bytesSent: 0))
            checkTrue("idempotent: \(c.rawValue) is retried, bytes unknown", std.isRetryable(c, rule: .idempotent, bytesSent: nil))
        }
        checkTrue("idempotent: a timeout before any body byte is retried", std.isRetryable(.timedOut, rule: .idempotent, bytesSent: 0))
        checkTrue("idempotent: a timeout after the body went out is a slow server, not retried", !std.isRetryable(.timedOut, rule: .idempotent, bytesSent: 10))
        for rule in [HermesChat.ConnectRetry.Rule.idempotent, .sideEffects] {
            for c in [URLError.Code.cancelled, .badServerResponse, .cannotParseResponse, .serverCertificateUntrusted, .badURL, .unsupportedURL, .notConnectedToInternet, .dataLengthExceedsMaximum] {
                checkTrue("never retried (\(rule)): \(c.rawValue)", !std.isRetryable(c, rule: rule, bytesSent: 0))
            }
        }
        let t0c = ContinuousClock.now
        check("deadline far away: waits", std.mayRetry(afterAttempt: 1, now: t0c, deadline: t0c.advanced(by: .seconds(20))), 0.3)
        check("no deadline: waits", std.mayRetry(afterAttempt: 2, now: t0c, deadline: nil), 1)
        check("an attempt that cannot finish before the deadline does not start", std.mayRetry(afterAttempt: 1, now: t0c, deadline: t0c.advanced(by: .seconds(6))), nil)
        check("no attempts left", std.mayRetry(afterAttempt: 3, now: t0c, deadline: nil), nil)
        checkTrue("the budget leaves room for three attempts of a step plus about 10 s of successful round trips",
                  std.budget >= Double(std.attempts) * std.attemptTimeout + std.backoff.reduce(0, +) + 10)

        print("connect retry (API key path)")
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var v: [String] = []
            func add(_ s: String) { lock.withLock { v.append(s) } }
            var all: [String] { lock.withLock { v } }
            func reset() { lock.withLock { v = [] } }
        }
        let lines = Lines()
        HermesChat.Diagnostics.setSink { lines.add($0) }
        func ctl(_ path: String, _ json: [String: Any] = [:]) async {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
            _ = try? await URLSession.shared.data(for: req)
        }
        func hits(_ k: String) async -> Int {
            guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/state")!),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Int] else { return -1 }
            return j[k] ?? -1
        }
        /// Runs `op`; nil when it does not finish within `seconds` (a retry that never gives up would hang the suite).
        func within<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
            await withTaskGroup(of: T?.self) { g in
                g.addTask { await op() }
                g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first
            }
        }
        let sseAnswer = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"Hello from the listener.\"},\"finish_reason\":null}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let modelsJSON = "{\"object\":\"list\",\"data\":[{\"id\":\"listener-model\"}]}"
        let modelsAnswer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(modelsJSON.utf8.count)\r\n\r\n" + modelsJSON
        @Sendable func agentAt(_ port: UInt16) -> HermesAgent {
            HermesAgent(name: "mark", baseURL: "http://127.0.0.1:\(port)", profile: "", modelName: "", connection: nil)
        }
        @Sendable func chatTo(_ port: UInt16, _ limits: HermesChat.Limits) async -> Result<String, HermesChatError> {
            do {
                return .success(try await HermesChat.streamChat(agent: agentAt(port), key: "test-key-mark", encodedBody: body("hi"), limits: limits) { _ in })
            } catch { return .failure((error as? HermesChatError) ?? .unreachable("?")) }
        }
        func limits(backoff: [TimeInterval]) -> HermesChat.Limits {
            var l = HermesChat.Limits.standard
            l.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.5, backoff: backoff, budget: 20)
            return l
        }
        let fast = limits(backoff: [0.05, 0.1])
        let late = limits(backoff: [0.3, 0.6])
        func isUnreachableResult(_ r: Result<String, HermesChatError>?) -> Bool {
            if case .failure(let e)? = r { return isUnreachable(e) }
            return false
        }

        // GET /v1/models is idempotent: connection lost is retried. URLSession itself repeats an idempotent GET up to
        // twice when the connection closes without an answer, so the server may see more than one request per Coucou
        // attempt: those counts are bounds, not exact.
        await ctl("/_test/reset")
        await ctl("/_test/config", ["models_drop": 2])
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success(let m): check("GET models: two lost connections, then the answer", m, "hermes-agent")
        case .failure(let e): print("  ✗ connect after 2 drops: \(e)"); failures += 1
        }
        checkTrue("GET models: the lost connections reached the server before the answer", await hits("models_hits") >= 3)

        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["models_drop": 100])
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success: print("  ✗ connect: expected failure"); failures += 1
        case .failure(let e): checkTrue("GET models: all attempts lost → unreachable", isUnreachable(e))
        }
        let modelHits = await hits("models_hits")
        checkTrue("GET models: three attempts, no more (URLSession itself repeats a GET up to twice)", modelHits >= 3 && modelHits <= 9)
        checkTrue("GET models: the connect failure is logged with step and attempts", lines.all.contains("hermes connect failed step=models attempts=3"))
        checkTrue("the log carries no URL, host or key", lines.all.allSatisfy { !$0.contains("127.0.0.1") && !$0.contains("test-key") && !$0.contains("http") })

        await ctl("/_test/reset")
        switch await HermesChat.connect(baseURL: base, profile: "", key: "wrong", limits: fast) {
        case .success: print("  ✗ 401: expected failure"); failures += 1
        case .failure(let e): check("GET models: an HTTP answer (401) is final", e, .unauthorized)
        }
        check("GET models: a 401 is not retried", await hits("models_hits"), 1)

        // A slow but healthy server: the first attempts are cut at attemptTimeout, the last keeps the old allowance.
        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["models_stall": 1.2, "models_stall_count": 3])
        let tSlow = Date()
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success(let m): check("GET models: a server that answers after 1.2 s (> attempt timeout) still works", m, "hermes-agent")
        case .failure(let e): print("  ✗ slow healthy GET failed: \(e)"); failures += 1
        }
        checkTrue("GET models: it took the last attempt's longer allowance, not a failure", Date().timeIntervalSince(tSlow) >= 1.2)
        check("GET models: three requests (two cut, the last answered)", await hits("models_hits"), 3)

        // POST chat, a server that READS THE WHOLE BODY and then drops the connection: exactly one request.
        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["chat_drop": 3])
        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            print("  ✗ chat: expected failure"); failures += 1
        } catch { checkTrue("chat: body delivered, connection dropped → unreachable", isUnreachable(error as? HermesChatError)) }
        check("chat: the server saw exactly ONE request (a request that reached it is never sent again)", await hits("chat_hits"), 1)
        checkTrue("chat: logged as a failed request with the body sent, not as a connect failure",
                  lines.all.contains("hermes request failed step=chat attempts=1 sent=true") && !lines.all.contains { $0.hasPrefix("hermes connect failed") })

        await ctl("/_test/reset")
        await ctl("/_test/config", ["chat_status": 500])
        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            print("  ✗ 500: expected failure"); failures += 1
        } catch { check("chat: a 500 is reported as is", error as? HermesChatError, .server("injected")) }
        check("chat: a request that got a response (500) is never retried", await hits("chat_hits"), 1)

        await ctl("/_test/reset")
        await ctl("/_test/config", ["chat_stall": 1.5, "chat_stall_count": 1])
        do {
            let t = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            check("chat: a slow answer after the request went out still arrives", t, "Hello from mark.")
        } catch { print("  ✗ chat slow headers: \(error)"); failures += 1 }
        check("chat: the slow answer is not a connect failure, so the turn is not started twice", await hits("chat_hits"), 1)

        // POST chat, a connection that is refused (nothing listens): nothing left the machine, so it is retried.
        lines.reset()
        if let dead = StallingListener.closedPort() {
            let tRef = Date()
            let r = await within(8) { await chatTo(dead, fast) }
            check("chat: connection refused on every attempt → unreachable", isUnreachableResult(r), true)
            checkTrue("chat: refused is retried three times", lines.all.contains("hermes connect failed step=chat attempts=3"))
            checkTrue("chat: ... and quickly", Date().timeIntervalSince(tRef) < 4)

            // ... and it recovers when the server comes up between attempts.
            lines.reset()
            let revive = Task { () -> StallingListener? in
                try? await Task.sleep(for: .seconds(0.15))
                let l = StallingListener(port: dead)
                l?.serve(sseAnswer)
                return l
            }
            let got = await within(8) { await chatTo(dead, late) }
            let srv = await revive.value
            if case .success(let t)? = got { check("chat: refused, then the server is up: the answer arrives", t, "Hello from the listener.") }
            else { print("  ✗ chat after refused: \(String(describing: got))"); failures += 1 }
            check("chat: the body reached the server once", srv?.requests, 1)
            checkTrue("chat: the recovery is logged", lines.all.contains { $0.hasPrefix("hermes connect recovered step=chat attempts=") })
            srv?.stop()
        } else { print("  ✗ no free port"); failures += 1 }

        // The reported failure mode: a connection that never completes (the kernel drops the SYN).
        print("connect retry (connection that never completes)")
        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let t = Date()
            let r = await within(8) { await chatTo(hang.port, fast) }
            let took = Date().timeIntervalSince(t)
            check("chat: never completes → unreachable after the attempts (without retries this waits the 300 s request timeout)",
                  isUnreachableResult(r), true)
            checkTrue("chat: three attempts, each cut at the attempt timeout (\(String(format: "%.1f", took)) s)", took >= 1.5 && took < 5)
            checkTrue("chat: logged as a connect failure with three attempts", lines.all.contains("hermes connect failed step=chat attempts=3"))
            check("chat: no request ever reached the server", hang.requests, 0)
            hang.stop()
        } else { print("  ✗ could not build the stalled listener"); failures += 1 }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let release = Task { try? await Task.sleep(for: .seconds(0.2)); hang.serve(sseAnswer) }
            let r = await within(8) { await chatTo(hang.port, fast) }
            await release.value
            if case .success(let t)? = r { check("chat: the first connection hangs, a later attempt gets through", t, "Hello from the listener.") }
            else { print("  ✗ chat after a hang: \(String(describing: r))"); failures += 1 }
            check("chat: the body reached the server exactly once", hang.requests, 1)
            hang.stop()
        }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let t = Date()
            let m = await within(20) { await HermesChat.connect(baseURL: "http://127.0.0.1:\(hang.port)", profile: "", key: "test-key-default", limits: fast) }
            let took = Date().timeIntervalSince(t)
            if case .failure(let e)? = m { checkTrue("GET models: never completes → unreachable", isUnreachable(e)) }
            else { print("  ✗ GET models on a hang: \(String(describing: m))"); failures += 1 }
            checkTrue("GET models: two attempts cut at the attempt timeout, the last is not cut at 0.5 s but runs on the request's own 10 s timeout (\(String(format: "%.1f", took)) s)",
                      took >= 5 && took < 14)
            checkTrue("GET models: logged with three attempts", lines.all.contains("hermes connect failed step=models attempts=3"))
            hang.stop()
        }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let release = Task { try? await Task.sleep(for: .seconds(0.2)); hang.serve(modelsAnswer) }
            let m = await within(8) { await HermesChat.connect(baseURL: "http://127.0.0.1:\(hang.port)", profile: "", key: "test-key-default", limits: fast) }
            await release.value
            if case .success(let id)? = m { check("GET models: a hung connection, then the answer", id, "listener-model") }
            else { print("  ✗ GET models after a hang: \(String(describing: m))"); failures += 1 }
            hang.stop()
        }

        // Cancellation during a backoff (a refused connection is retried; nothing else is needed to get there).
        if let dead = StallingListener.closedPort() {
            var sb = HermesChat.Limits.standard
            sb.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.5, backoff: [30, 30], budget: 100)
            let slowBackoff = sb
            let cs = Task { await chatTo(dead, slowBackoff) }
            let cs2 = Task { try await HermesChat.streamChat(agent: agentAt(dead), key: "test-key-mark", encodedBody: body("hi"), limits: slowBackoff) { _ in } }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let tc = Date()
            cs.cancel(); cs2.cancel()
            do { _ = try await cs2.value; print("  ✗ cancelled retry returned"); failures += 1 }
            catch { checkTrue("chat: cancelling during the backoff throws CancellationError", error is CancellationError) }
            _ = await cs.value
            checkTrue("chat: ... at once, not after the 30 s backoff", Date().timeIntervalSince(tc) < 2)
        }
        HermesChat.Diagnostics.setSink(nil)
        await ctl("/_test/reset")

        print("cancellation")
        let t0 = Date()
        let task = Task { try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("slow")) { _ in } }
        try? await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do { _ = try await task.value; print("  ✗ cancelled stream returned"); failures += 1 }
        catch { checkTrue("cancelled stream throws CancellationError", error is CancellationError) }
        checkTrue("cancel ended the turn promptly", Date().timeIntervalSince(t0) < 4)

        print("request shape (model field, no system message)")
        if let url = HermesChat.chatURL(for: markAgent) {
            check("model echoed", await headerValue(url, "test-key-mark", "X-Test-Model", body: String(decoding: body("hi", model: "mark"), as: UTF8.self)) ?? "", "mark")
            check("no system message", await headerValue(url, "test-key-mark", "X-Test-System", body: String(decoding: body("hi"), as: UTF8.self)) ?? "", "0")
        }

        finish()
    }

    private static func finish() -> Never {
        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed.")
        exit(1)
    }
}
