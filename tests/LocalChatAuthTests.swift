import Foundation

@main
enum LocalChatAuthTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected { print("  ✓ \(label)") }
        else {
            print("  ✗ \(label)\n    got:      \(got.debugDescription)\n    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() async {
        print("LocalChat.cleanKey")
        checkTrue("nil → nil",            LocalChat.cleanKey(nil) == nil)
        checkTrue("empty → nil",          LocalChat.cleanKey("") == nil)
        checkTrue("spaces only → nil",    LocalChat.cleanKey("  \n\t ") == nil)
        check("trims the ends",           LocalChat.cleanKey("  sk-abc \n") ?? "", "sk-abc")

        print("LocalChat.streamEndpoint — local server")
        let noKey = LocalChat.streamEndpoint(baseURL: "http://127.0.0.1:8000", apiKey: nil, isLocal: true)
        check("local, no key: URL keeps /v1",   noKey.url, "http://127.0.0.1:8000/v1/chat/completions")
        check("local, no key: Bearer ollama",   noKey.authorization, "Bearer ollama")
        let blank = LocalChat.streamEndpoint(baseURL: "http://127.0.0.1:8000", apiKey: "   ", isLocal: true)
        check("local, blank key = no key",      blank.authorization, "Bearer ollama")
        let withKey = LocalChat.streamEndpoint(baseURL: "http://127.0.0.1:8000", apiKey: " sk-local ", isLocal: true)
        check("local + key: URL keeps /v1",     withKey.url, "http://127.0.0.1:8000/v1/chat/completions")
        check("local + key: Bearer <key>",      withKey.authorization, "Bearer sk-local")

        print("LocalChat.streamEndpoint — cloud unchanged")
        let cloud = LocalChat.streamEndpoint(baseURL: "https://api.deepseek.com/v1", apiKey: "sk-deep", isLocal: false)
        check("cloud URL",                      cloud.url, "https://api.deepseek.com/v1/chat/completions")
        check("cloud key",                      cloud.authorization, "Bearer sk-deep")
        let cloudDefault = LocalChat.streamEndpoint(baseURL: "https://api.deepseek.com/v1", apiKey: "sk-deep")
        check("cloud, isLocal omitted: URL",    cloudDefault.url, cloud.url)
        check("cloud, isLocal omitted: key",    cloudDefault.authorization, cloud.authorization)

        print("LocalChat.localAuthorization")
        check("no key",    LocalChat.localAuthorization(apiKey: nil), "Bearer ollama")
        check("blank key", LocalChat.localAuthorization(apiKey: "  "), "Bearer ollama")
        check("key",       LocalChat.localAuthorization(apiKey: "sk-local"), "Bearer sk-local")

        print("LocalChat.authError")
        checkTrue("401 → unauthorized", { if case .unauthorized? = LocalChat.authError(status: 401) { return true }; return false }())
        checkTrue("403 → unauthorized", { if case .unauthorized? = LocalChat.authError(status: 403) { return true }; return false }())
        checkTrue("200 → nil",          LocalChat.authError(status: 200) == nil)
        checkTrue("404 → nil",          LocalChat.authError(status: 404) == nil)
        checkTrue("500 → nil",          LocalChat.authError(status: 500) == nil)
        checkTrue("message is not 'cannot reach'",
                  !LocalChatError.unauthorized.localizedDescription.contains("Cannot reach"))

        guard CommandLine.arguments.count > 1 else {
            print("\n(Skipping end-to-end tests — no server port provided.)")
            finish()
        }
        let baseURL = "http://127.0.0.1:\(CommandLine.arguments[1])"
        let goodKey = "sk-local-test-key"

        print("fetchModelsResult against a server that needs a key")
        switch await LocalChat.fetchModelsResult(baseURL: baseURL, apiKey: goodKey) {
        case .success(let m): checkTrue("right key lists the model", m.contains { $0.id == "omlx-model" })
        case .failure(let e): print("  ✗ right key failed: \(e)"); failures += 1
        }
        for (label, key) in [("no key", nil), ("wrong key", "sk-wrong"), ("forbidden key (403)", "sk-forbidden")] as [(String, String?)] {
            switch await LocalChat.fetchModelsResult(baseURL: baseURL, apiKey: key) {
            case .failure(.unauthorized): print("  ✓ \(label) → unauthorized")
            default: print("  ✗ \(label) should be .unauthorized"); failures += 1
            }
        }
        switch await LocalChat.fetchModelsResult(baseURL: "http://127.0.0.1:1") {
        case .failure(.serverUnreachable): print("  ✓ closed port → serverUnreachable")
        default: print("  ✗ closed port should be .serverUnreachable"); failures += 1
        }

        print("streamChat against a server that needs a key")
        do {
            let r = try await LocalChat.streamChat(
                baseURL: baseURL, model: "omlx-model",
                messages: [["role": "user", "content": "hi"]],
                apiKey: goodKey, isLocal: true, onToken: { _ in })
            check("right key streams the reply", r, "hello")
        } catch { print("  ✗ right key threw: \(error)"); failures += 1 }
        for (label, key) in [("no key", nil), ("wrong key", "sk-wrong"), ("forbidden key (403)", "sk-forbidden")] as [(String, String?)] {
            do {
                _ = try await LocalChat.streamChat(
                    baseURL: baseURL, model: "omlx-model",
                    messages: [["role": "user", "content": "hi"]],
                    apiKey: key, isLocal: true, onToken: { _ in })
                print("  ✗ \(label) should have thrown"); failures += 1
            } catch LocalChatError.unauthorized {
                print("  ✓ \(label) → unauthorized")
            } catch { print("  ✗ \(label) wrong error: \(error)"); failures += 1 }
        }

        finish()
    }

    static func finish() -> Never {
        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) FAILED."); exit(1)
    }
}
