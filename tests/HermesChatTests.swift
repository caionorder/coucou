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
