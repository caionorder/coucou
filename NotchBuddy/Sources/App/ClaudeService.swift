import Foundation
import Security

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (reads each key ONCE at launch; all subsequent access via dict)

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let allKeys = [
        "anthropic-api-key",
        "google-api-key",
        "openai-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
        "hermes-agent-keys",
        "hermes-agent-sessions",
    ]

    private init() {
        // Called once, on main thread (AppDelegate triggers shared at launch).
        for key in Self.allKeys {
            if let v = Keychain.load(key: key) { cache[key] = v }
        }
    }

    /// Thread-safe read — never touches the Keychain.
    func get(_ key: String) -> String? {
        lock.withLock { cache[key] }
    }

    /// Updates cache + persists to Keychain.
    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value }
        Keychain.save(key: key, value: value)
    }

    /// Removes from cache + Keychain only if the key was previously set.
    func remove(_ key: String) {
        let had = lock.withLock { () -> Bool in
            let exists = cache[key] != nil
            cache[key] = nil
            return exists
        }
        if had { Keychain.delete(key: key) }
    }
}

// MARK: - Claude API

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    // MARK: - Model list

    /// Fetches available models from the Anthropic API in the order the API returns them
    /// (newest first). Returns an empty array on any error — callers fall back to a static list.
    static func fetchModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return (id: id, label: name)
        }
    }

    /// Fetches Gemini models via the OpenAI-compatible endpoint.
    /// Strips the "models/" prefix that the API sometimes returns and filters non-chat models.
    static func fetchGoogleModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "imagen", "veo", "aqa", "tts", "audio", "live"]
        return items.compactMap { item in
            guard let raw = item["id"] as? String else { return nil }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let lower = id.lowercased()
            guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
            return (id: id, label: id)
        }
    }

    /// Fetches chat models from the OpenAI API, sorted newest-first by creation date.
    /// Excludes non-chat model families.
    static func fetchOpenAIModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "tts", "whisper", "dall-e", "audio", "realtime", "moderat",
                        "codex", "computer-use", "transcribe", "image", "sora",
                        "babbage", "davinci", "instruct"]
        return items
            .compactMap { item -> (id: String, created: Int)? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return (id: id, created: item["created"] as? Int ?? 0)
            }
            .sorted { $0.created > $1.created }
            .map { (id: $0.id, label: $0.id) }
    }

    /// Chosen in Settings; falls back to the default when the field is left empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AppState.defaultClaudeModel : m
    }

    var apiKey: String? { KeychainStore.shared.get("anthropic-api-key") }

    // Multi-turn conversation messages (for API)
    private var conversationMessages: [[String: Any]] = []

    /// Bumped on every clear: a request that started before a clear must not touch the new conversation.
    private var conversationGeneration = 0
    /// Hermes turns in flight, by id. A second message may start while the first still runs.
    private struct HermesTurn {
        var task: Task<String, Error>?
        var hasText = false
    }
    private var hermesTurns: [UUID: HermesTurn] = [:]
    /// Stored server session of the current conversation with a signed-in Hermes agent (nil = none yet).
    private var hermesServerSession: String?

    func clearConversation() {
        conversationMessages = []
        hermesServerSession = nil
        conversationGeneration += 1
        for turn in hermesTurns.values { turn.task?.cancel() }
        hermesTurns = [:]
    }

    /// The typing dots show while a running turn has not produced text yet. Every override this code sets (dots, or
    /// the error left by a failed sibling turn) is dropped by the rule in `HermesAnnounce.typingOverride`.
    private func refreshHermesTyping(_ state: AppState) {
        let current: HermesAnnounce.Override
        switch state.stateOverride {
        case nil: current = .none
        case .some(.thinking): current = .thinking
        case .some(.error): current = .error
        default: current = .other
        }
        let next = HermesAnnounce.typingOverride(current: current, anyTurnWaiting: hermesTurns.values.contains { !$0.hasText })
        guard next != current else { return }
        switch next {
        case .none: state.stateOverride = nil
        case .thinking: state.stateOverride = .thinking
        case .error, .other: break
        }
    }

    /// Resolved once: NSFullUserName() is a system call, and the name cannot change under us
    /// while the app runs.
    private let systemPrompt = ClaudeService.makeSystemPrompt()

    /// Greets the user by their macOS first name when there is one worth using, and stays
    /// neutral otherwise — same wording as the Windows build.
    private nonisolated static func makeSystemPrompt() -> String {
        let opening = if let firstName = resolveUserFirstName() {
            "You are Mochi, \(firstName)'s personal AI assistant embedded in the notch of their Mac."
        } else {
            "You are Mochi, a personal AI assistant embedded in the notch of the user's Mac."
        }
        return """
        \(opening) \
        You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
        Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
        Use light Markdown when it helps: short paragraphs, bullet lists, **bold**, `inline code` and fenced code blocks. Avoid tables and big headings: the chat window is small.
        """
    }

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    // MARK: - Chat (multi-turn, natural text + web search)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        if state.chatProvider == .hermes { await chatHermes(query: query, context: context, state: state); return }
        guard state.chatProvider == .anthropic else {
            await chatOpenAICompatible(query: query, context: context, state: state)
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            await showError(String(localized: "API key missing. Open settings."), state: state)
            return
        }

        // Build user content for this turn
        var userContent: [[String: Any]] = []

        // Add file/window context on first message only
        if conversationMessages.isEmpty, let context = context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url = url { text += ", URL: \(url)" }
                userContent.append(["type": "text", "text": text])
            case .file(let name, let fileURL):
                if let fileURL = fileURL, let block = readFileAsBlock(url: fileURL) {
                    userContent.append(block)
                }
                userContent.append(["type": "text", "text": "File: \(name)"])
            }
        }
        userContent.append(["type": "text", "text": query])

        conversationMessages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "tools": webSearchTools,
            "system": systemPrompt,
            "messages": conversationMessages,
        ]

        do {
            let data = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleChatResult(data, state: state)
        } catch {
            if !conversationMessages.isEmpty { conversationMessages.removeLast() }
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - OpenAI-compatible chat (Google Gemini / OpenAI / Ollama / LM Studio)

    func chatOpenAICompatible(query: String, context: PromptContext?, state: AppState) async {
        let provider = state.chatProvider
        guard provider != .anthropic else { return }

        let baseURL: String
        if provider == .ollama {
            baseURL = LocalChat.normaliseURL(state.ollamaServerURL)
        } else if provider == .lmstudio {
            baseURL = LocalChat.normaliseURL(state.lmstudioServerURL)
        } else {
            switch provider {
            case .google:  baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
            case .openai:  baseURL = "https://api.openai.com/v1"
            case .anthropic, .ollama, .lmstudio, .hermes: baseURL = ""
            }
        }

        guard !baseURL.isEmpty else {
            if provider.isLocal {
                let name = provider == .ollama ? "Ollama" : "LM Studio"
                await showError(String(localized: "Connect \(name) in Settings → Chat first."), state: state)
            }
            return
        }
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return }

        // Auth header
        let authHeader: String
        if provider.isLocal {
            authHeader = "Bearer ollama"
        } else {
            guard let key = KeychainStore.shared.get(provider.keychainKey), !key.isEmpty else {
                await showError(String(localized: "\(provider.displayName) API key missing. Configure it in Settings."), state: state)
                return
            }
            authHeader = "Bearer \(key)"
        }

        // Build messages
        var msgs: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in conversationMessages {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }
        let userText = openAIUserText(query: query, context: context, inlineFiles: provider.isLocal)
        msgs.append(["role": "user", "content": userText])
        conversationMessages.append(["role": "user", "content": userText])

        let useStream = provider.isLocal
        var body: [String: Any] = [
            "model": state.activeChatModel,
            "max_tokens": 4096,
            "messages": msgs,
        ]
        if useStream { body["stream"] = true }

        var req = URLRequest(url: url, timeoutInterval: useStream ? 120 : 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if useStream {
            // Add placeholder (hidden until first token via ChatBubble empty-content guard)
            let placeholder = ChatMessage(role: .assistant, content: "")
            let msgId = placeholder.id
            state.chatHistory.append(placeholder)
            state.stateOverride = .thinking
            let modelCopy = state.activeChatModel
            let streamBody: [String: Any] = [
                "model": modelCopy,
                "messages": msgs,
                "stream": true,
                "max_tokens": 4096,
            ]
            let encodedBody = (try? JSONSerialization.data(withJSONObject: streamBody)) ?? Data()
            do {
                let final = try await LocalChat.streamChat(
                    baseURL: baseURL,
                    encodedBody: encodedBody,
                    model: modelCopy
                ) { [state, msgId] visible in
                    if !visible.isEmpty, state.stateOverride == .thinking {
                        state.stateOverride = nil   // hide typing dots on first visible text
                    }
                    if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                        state.chatHistory[idx].content = visible
                    }
                }
                conversationMessages.append(["role": "assistant", "content": final])
                if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                    state.chatHistory[idx].content = final
                }
                state.stateOverride = nil
                state.view = .prompt
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch let e as LocalChatError {
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                let msg: String
                switch e {
                case .serverUnreachable:
                    msg = provider == .ollama
                        ? String(localized: "Ollama isn't running. Open it, then ask again.")
                        : String(localized: "Start the local server in LM Studio, then ask again.")
                case .modelNotFound(let m):
                    msg = String(localized: "\(m) isn't installed. Pick another model above the chat box.")
                case .serverError(let s):
                    msg = s
                }
                await showError(msg, state: state)
            } catch {
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                await showError(error.localizedDescription, state: state)
            }
        } else {
            // Non-streaming (Google, OpenAI)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = (json["error"] as? [String: Any])?["message"] as? String {
                        throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: err])
                    }
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Unexpected response format")])
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                conversationMessages.append(["role": "assistant", "content": trimmed])
                state.chatHistory.append(ChatMessage(role: .assistant, content: trimmed))
                state.stateOverride = nil
                state.view = .prompt
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                await showError(error.localizedDescription, state: state)
            }
        }
    }

    /// User text for the first turn of an OpenAI-style chat: window/file context prepended to the query.
    /// `inlineFiles` inlines text files (up to 24 000 chars); otherwise only the file name is sent.
    private func openAIUserText(query: String, context: PromptContext?, inlineFiles: Bool) -> String {
        var userText = query
        if conversationMessages.isEmpty, let ctx = context {
            switch ctx {
            case .window(let app, let title, let url):
                var prefix = "Context — App: \(app), Window: \(title)"
                if let u = url { prefix += ", URL: \(u)" }
                userText = prefix + "\n\n" + query
            case .file(let name, let fileURL):
                if inlineFiles, let fileURL = fileURL {
                    let ext = fileURL.pathExtension.lowercased()
                    let binaryExts = ["pdf", "jpg", "jpeg", "png", "gif", "webp"]
                    if !binaryExts.contains(ext),
                       let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
                        let truncated = text.count > 24_000
                            ? String(text.prefix(24_000)) + "\n[truncated]"
                            : text
                        userText = "File: \(name)\n\n\(truncated)\n\n" + query
                    } else {
                        userText = "File: \(name)\n\n" + query
                    }
                } else {
                    userText = "File: \(name)\n\n" + query
                }
            }
        }
        return userText
    }

    // MARK: - Hermes agents (stateless, streamed, no Mochi system prompt)

    func chatHermes(query: String, context: PromptContext?, state: AppState) async {
        guard let agent = state.activeHermesAgent else {
            await showError(String(localized: "Connect a Hermes agent in Settings → Chat first."), state: state)
            return
        }
        let signIn = agent.connection == .signIn
        var key = ""
        if signIn {
            // No session for this agent (or for this address): nothing is sent.
            if case .failure(let e) = HermesSignIn.boundSession(for: agent, in: HermesSignIn.decodeSessions(KeychainStore.shared.get("hermes-agent-sessions") ?? "")) {
                await showError(e.userMessage, state: state)
                return
            }
        } else {
            switch HermesChat.boundKey(for: agent, in: HermesChat.decodeKeys(KeychainStore.shared.get("hermes-agent-keys") ?? "")) {
            case .success(let k): key = k
            case .failure(let e):
                // The key is never sent: the stored agent does not match what the key was connected to.
                await showError(e.userMessage, state: state)
                return
            }
        }

        // No system message: Hermes layers it over the agent's own prompt.
        var msgs: [[String: Any]] = []
        for m in conversationMessages {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }
        let userText = openAIUserText(query: query, context: context, inlineFiles: true)
        msgs.append(["role": "user", "content": userText])
        conversationMessages.append(["role": "user", "content": userText])

        let placeholder = ChatMessage(role: .assistant, content: "")
        let msgId = placeholder.id
        state.chatHistory.append(placeholder)
        let turnId = UUID()
        hermesTurns[turnId] = HermesTurn(task: nil, hasText: false)
        refreshHermesTyping(state)
        state.setHermesPillBusy(agentName: agent.name, true)
        defer { state.setHermesPillBusy(agentName: agent.name, false) }
        let startedAt = Date()
        appendAppLog("nb.log", "hermes turn started signIn=\(signIn)")
        let body: [String: Any] = ["model": agent.modelName, "messages": msgs, "stream": true]
        let encodedBody = signIn ? Data() : ((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        let generation = conversationGeneration
        let storedSession = hermesServerSession
        let task = Task { [state, msgId] () async throws -> String in
            let onToken: @MainActor (String) -> Void = { visible in
                if !visible.isEmpty, self.hermesTurns[turnId]?.hasText == false {
                    self.hermesTurns[turnId]?.hasText = true   // hide typing dots once no turn waits for text
                    appendAppLog("nb.log", "hermes turn first text after=\(Self.seconds(since: startedAt))s")
                    self.refreshHermesTyping(state)
                }
                if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                    state.chatHistory[idx].content = visible
                }
            }
            if signIn {
                // The server keeps the history: only the new text is sent, the session is resumed by id.
                return try await HermesSignInNet.streamTurn(
                    agent: agent, sessions: HermesSessions.shared, storedSession: storedSession, text: userText,
                    onSession: { id in
                        if generation == self.conversationGeneration { self.hermesServerSession = id.isEmpty ? nil : id }
                    },
                    onToken: onToken)
            }
            return try await HermesChat.streamChat(agent: agent, key: key, encodedBody: encodedBody, onToken: onToken)
        }
        hermesTurns[turnId]?.task = task
        do {
            let final = try await task.value
            hermesTurns[turnId] = nil
            guard generation == conversationGeneration else {
                appendAppLog("nb.log", "hermes turn discarded (conversation cleared) after=\(Self.seconds(since: startedAt))s")
                refreshHermesTyping(state)
                return
            }
            conversationMessages.append(["role": "assistant", "content": final])
            if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                state.chatHistory[idx].content = final
            }
            refreshHermesTyping(state)
            appendAppLog("nb.log", "hermes turn finished duration=\(Self.seconds(since: startedAt))s chars=\(final.count)")
            // Chat on screen: nothing changes. Otherwise sound, badge and back to the chat.
            state.announceHermesTurn(agentName: agent.name, failed: false, view: .prompt)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            hermesTurns[turnId] = nil
            guard generation == conversationGeneration else {
                // Cleared meanwhile: leave the new conversation alone, only stop the typing dots
                // when no newer Hermes request is still waiting for its first text.
                appendAppLog("nb.log", "hermes turn discarded (conversation cleared) after=\(Self.seconds(since: startedAt))s")
                refreshHermesTyping(state)
                return
            }
            // Remove this turn's own message: a sibling turn may have added its own after it.
            if let own = conversationMessages.lastIndex(where: { ($0["role"] as? String) == "user" && ($0["content"] as? String) == userText }) {
                conversationMessages.remove(at: own)
            }
            state.chatHistory.removeAll { $0.id == msgId }
            refreshHermesTyping(state)
            let msg = (error as? HermesChatError)?.userMessage ?? String(localized: "Hermes request failed.")
            appendAppLog("nb.log", "hermes turn failed after=\(Self.seconds(since: startedAt))s error=\(Self.errorCaseName(error))")
            let outcome = state.announceHermesTurn(agentName: agent.name, failed: true, view: .note)
            // A card on screen keeps the screen: the error is only signalled by the sound and the pill badge.
            if outcome == .badgeOnly {
                // The text waits in the chat for when it is next shown.
                state.chatHistory.append(ChatMessage(role: .assistant, content: msg))
            } else { await showError(msg, state: state) }
        }
    }

    private static func seconds(since start: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }

    /// Case name of an error, never its associated values (they may carry a host or a server text).
    private static func errorCaseName(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is HermesChatError { return String(String(describing: error).prefix { $0 != "(" }) }
        return "other"
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError(String(localized: "Anthropic API key missing. Open settings to configure it."), state: state)
            return
        }

        var userContent: [[String: Any]] = []
        switch context {
        case .window(let appName, let title, let url):
            var text = "App: \(appName)\nWindow title: \(title)"
            if let url = url { text += "\nURL: \(url)" }
            text += "\n\nRequest: \(query)"
            userContent.append(["type": "text", "text": text])
        case .file(let name, let fileURL):
            if let fileURL = fileURL, let fileBlock = readFileAsBlock(url: fileURL) {
                userContent.append(fileBlock)
            }
            userContent.append(["type": "text", "text": "File: \(name)\n\nRequest: \(query)"])
        case nil:
            userContent.append(["type": "text", "text": query])
        }

        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let tools: [[String: Any]] = [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": tools,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
        ]

        do {
            let result = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleResult(result, state: state)
        } catch {
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String, beta: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Parse Anthropic error format: {"type":"error","error":{"type":"…","message":"…"}}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let errType = err["type"] as? String,
               let errMsg = err["message"] as? String {
                if errType == "not_found_error" {
                    let id = AppState.shared.claudeModel
                    throw NSError(domain: "Claude", code: 0,
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "Model not found: \(id). Pick another one in Settings.")])
                }
                throw NSError(domain: "Claude", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            let msg = String(data: data, encoding: .utf8) ?? String(localized: "unknown error")
            throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            await showError(String(localized: "Unexpected API response."), state: state)
            return
        }

        // Store full content (includes tool_use/tool_result blocks) for correct multi-turn context
        conversationMessages.append(["role": "assistant", "content": content])

        guard let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String, !text.isEmpty else {
            await showError(String(localized: "No response text."), state: state)
            return
        }

        // Add to display history
        state.chatHistory.append(ChatMessage(role: .assistant, content: text.trimmingCharacters(in: .whitespacesAndNewlines)))

        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Extract text from Anthropic response (may contain tool_use / web_search_tool_result blocks)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            await showError(String(localized: "Unexpected API response."), state: state)
            return
        }

        // Strip markdown code fences if present, then extract JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        // Try to parse as our JSON format
        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? String(localized: "Result")
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            // Fallback: show raw text in 3-line chunks
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            state.searchResult = SearchResult(
                title: String(localized: "Claude's response"),
                items: lines.map { ResultItem(label: $0, detail: "", url: nil) },
                note: nil
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    // MARK: - File content block builder

    private func readFileAsBlock(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let base64 = data.base64EncodedString()

        if ext == "pdf" {
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": base64]]
        } else if ["jpg", "jpeg"].contains(ext) {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
        } else if ext == "png" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]]
        } else if ext == "gif" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/gif", "data": base64]]
        } else if ext == "webp" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/webp", "data": base64]]
        } else {
            // Text/code — inline as text if <= 200 KB
            guard data.count <= 200_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return ["type": "text", "text": "File contents:\n\(text)"]
        }
    }
}
