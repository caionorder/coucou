import Foundation

@main
enum ChatConversationsTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }

    static func agent(_ name: String, display: String? = nil) -> HermesAgent {
        HermesAgent(name: name, baseURL: "https://a.example.com", profile: name, modelName: "m", connection: nil, displayName: display)
    }

    static func main() {
        print("ConversationID.current")
        check("other provider is the shared conversation", ConversationID.current(hermesActive: false, agent: "alfred"), .shared)
        check("hermes is the conversation of the active agent", ConversationID.current(hermesActive: true, agent: "alfred"), .hermes("alfred"))
        check("two agents are two conversations", ConversationID.current(hermesActive: true, agent: "alfred") != .hermes("steve"), true)
        check("hermes without agent is not the shared one", ConversationID.current(hermesActive: true, agent: nil) != .shared, true)
        check("hermesAgent of shared", ConversationID.shared.hermesAgent, nil)
        check("hermesAgent of an agent", ConversationID.hermes("steve").hermesAgent, "steve")

        print("ConversationStore: separate conversations")
        var store = ConversationStore<[String]>(empty: [])
        store.mutate(.hermes("alfred")) { $0.append("question to alfred") }
        store.mutate(.hermes("steve")) { $0.append("question to steve") }
        store.mutate(.shared) { $0.append("question to claude") }
        check("alfred keeps its own", store[.hermes("alfred")], ["question to alfred"])
        check("steve keeps its own", store[.hermes("steve")], ["question to steve"])
        check("shared keeps its own", store[.shared], ["question to claude"])
        store.mutate(.hermes("alfred")) { $0.append("answer from alfred") }
        check("a turn finishing for alfred leaves steve alone", store[.hermes("steve")], ["question to steve"])
        check("unknown id reads empty", store[.hermes("nobody")], [])
        check("reading does not create", store.contains(.hermes("nobody")), false)

        print("ConversationStore: clearing")
        store.remove(.hermes("alfred"))
        check("clearing alfred empties alfred", store[.hermes("alfred")], [])
        check("clearing alfred keeps steve", store[.hermes("steve")], ["question to steve"])
        check("clearing alfred keeps shared", store[.shared], ["question to claude"])

        print("ConversationStore: removed agents")
        store.mutate(.hermes("alfred")) { $0.append("again") }
        let gone = store.removeHermes(except: ["steve"])
        check("alfred dropped", gone, ["alfred"])
        check("alfred is empty", store[.hermes("alfred")], [])
        check("steve kept", store[.hermes("steve")], ["question to steve"])
        check("shared never dropped with agents", store[.shared], ["question to claude"])
        check("no agent left drops every hermes conversation", store.removeHermes(except: []), ["steve"])
        check("shared still there", store[.shared], ["question to claude"])

        print("ConversationStore: default value is not shared between ids")
        var s2 = ConversationStore<[Int]>(empty: [])
        s2.mutate(.hermes("a")) { $0.append(1) }
        check("another id still empty", s2[.hermes("b")], [])
        check("values count", s2.values.count, 1)

        print("HermesAgentNames.clean")
        check("plain", HermesAgentNames.clean("Steve"), "Steve")
        check("trimmed", HermesAgentNames.clean("  Steve \n"), "Steve")
        check("empty clears", HermesAgentNames.clean(""), nil)
        check("only spaces clears", HermesAgentNames.clean("   "), nil)
        check("control characters removed", HermesAgentNames.clean("St\u{0007}e\u{0000}ve\u{009B}"), "Steve")
        check("zero width and direction marks removed", HermesAgentNames.clean("St\u{200B}e\u{200F}ve\u{202E}"), "Steve")
        check("only invisible characters clears", HermesAgentNames.clean("\u{200B}\u{202E}"), nil)
        check("line separators removed", HermesAgentNames.clean("a\u{2028}b\nc"), "abc")
        check("capped at 40 characters", HermesAgentNames.clean(String(repeating: "x", count: 60))?.count, 40)
        check("40 characters kept", HermesAgentNames.clean(String(repeating: "x", count: 40))?.count, 40)
        check("accents and emoji kept", HermesAgentNames.clean("Zoë 🤖"), "Zoë 🤖")

        print("HermesAgent display name")
        check("shown is the identity by default", agent("codex").shownName, "codex")
        check("shown is the display name when set", agent("codex", display: "Steve").shownName, "Steve")
        let legacy = #"[{"name":"alfred","baseURL":"https://a.example.com","profile":"alfred","modelName":"m"}]"#
        let decoded = HermesChat.decodeAgents(legacy)
        check("stored agent without the field still decodes", decoded.count, 1)
        check("and has no display name", decoded.first?.displayName, nil)
        let round = HermesChat.decodeAgents(HermesChat.encodeAgents([agent("codex", display: "Steve")]))
        check("display name round trips", round.first?.displayName, "Steve")
        check("encoding without display name omits the field", HermesChat.encodeAgents([agent("codex")]).contains("displayName"), false)
        check("same destination ignores the display name", agent("a").sameDestination(as: agent("a", display: "X")), true)
        var moved = agent("a"); moved.baseURL = "https://b.example.com"
        check("another address is another destination", agent("a").sameDestination(as: moved), false)

        print("HermesAgentNames.rename")
        let list = [agent("alfred"), agent("codex")]
        if case .success(let out) = HermesAgentNames.rename("codex", to: " Steve ", in: list) {
            check("renamed", out.map { $0.shownName }, ["alfred", "Steve"])
            check("identity untouched", out.map { $0.name }, ["alfred", "codex"])
            check("destination untouched", out[1].sameDestination(as: list[1]), true)
            if case .success(let cleared) = HermesAgentNames.rename("codex", to: "", in: out) {
                check("empty value clears", cleared[1].displayName, nil)
            } else { check("empty value clears", false, true) }
        } else { check("renamed", false, true) }
        check("another agent's shown name is refused", HermesAgentNames.rename("codex", to: "alfred", in: list), .failure(.taken("alfred")))
        check("refusal ignores case", HermesAgentNames.rename("codex", to: "ALFRED", in: list), .failure(.taken("ALFRED")))
        let named = [agent("alfred"), agent("codex", display: "Steve")]
        check("a display name is refused for the other agent", HermesAgentNames.rename("alfred", to: "steve", in: named), .failure(.taken("steve")))
        check("an agent may keep its own shown name", HermesAgentNames.rename("codex", to: "Steve", in: named) == .success(named), true)
        check("clearing refused when the identity is another agent's shown name",
              HermesAgentNames.rename("alfred", to: "x", in: [agent("alfred"), agent("codex", display: "x")]) == .failure(.taken("x")), true)
        check("unknown agent", HermesAgentNames.rename("nobody", to: "x", in: list), .failure(.unknownAgent))
        check("name equal to identity stores nothing", { () -> String? in
            if case .success(let o) = HermesAgentNames.rename("codex", to: "codex", in: list) { return o[1].displayName ?? "nil" }
            return "fail" }(), "nil")
        check("new agent name taken by a shown name", HermesAgentNames.isTaken("steve", in: named, except: nil), true)
        check("new agent name free", HermesAgentNames.isTaken("zed", in: named, except: nil), false)

        print("HermesAnnounce with several conversations")
        typealias H = HermesAnnounce
        check("chat of this agent on screen: nothing", H.decide(expanded: true, viewIsChat: true, cmuxPromptOpen: false, alertPending: false, chatIsOfThisAgent: true), .none)
        check("chat of another agent on screen: badge only", H.decide(expanded: true, viewIsChat: true, cmuxPromptOpen: false, alertPending: false, chatIsOfThisAgent: false), .badgeOnly)
        check("not on the chat: expand whoever is selected", H.decide(expanded: true, viewIsChat: false, cmuxPromptOpen: false, alertPending: false, chatIsOfThisAgent: false), .expand)
        check("collapsed: expand", H.decide(expanded: false, viewIsChat: true, cmuxPromptOpen: false, alertPending: false, chatIsOfThisAgent: false), .expand)
        check("card pending: badge only", H.decide(expanded: false, viewIsChat: false, cmuxPromptOpen: false, alertPending: true, chatIsOfThisAgent: false), .badgeOnly)
        check("default is this agent", H.decide(expanded: true, viewIsChat: true, cmuxPromptOpen: false, alertPending: false), .none)

        if failures > 0 { print("\n\(failures) FAILED"); exit(1) }
        print("\nAll tests passed")
    }
}
