import Foundation

/// Which conversation a chat message belongs to. The non Hermes providers (Anthropic, Google, OpenAI, Ollama,
/// LM Studio) share one conversation; every Hermes agent has its own, keyed by the agent identity name.
/// A conversation of one id is never read, sent or cleared through another id.
enum ConversationID: Hashable, Sendable {
    case shared
    case hermes(String)

    /// The conversation on screen: the one of the active agent when the Hermes chat is selected, else the shared one.
    static func current(hermesActive: Bool, agent: String?) -> ConversationID {
        hermesActive ? .hermes(agent ?? "") : .shared
    }

    /// The agent name of a Hermes conversation, nil for the shared one.
    var hermesAgent: String? {
        if case .hermes(let name) = self { return name }
        return nil
    }
}

/// In memory conversations by id. A missing id reads as `empty`; nothing here is ever written to disk.
struct ConversationStore<Value> {
    private var items: [ConversationID: Value] = [:]
    private let empty: Value

    init(empty: Value) { self.empty = empty }

    subscript(id: ConversationID) -> Value { items[id] ?? empty }

    func contains(_ id: ConversationID) -> Bool { items[id] != nil }

    var values: [Value] { Array(items.values) }

    mutating func set(_ id: ConversationID, _ value: Value) { items[id] = value }

    /// Changes one conversation in place; the others are untouched.
    mutating func mutate(_ id: ConversationID, _ body: (inout Value) -> Void) {
        let fallback = empty
        body(&items[id, default: fallback])
    }

    mutating func remove(_ id: ConversationID) { items[id] = nil }

    /// Drops the Hermes conversations whose agent is not in `names`; returns the dropped agent names.
    @discardableResult
    mutating func removeHermes(except names: Set<String>) -> [String] {
        let gone = items.keys.compactMap { $0.hermesAgent }.filter { !names.contains($0) }
        for name in gone { items[.hermes(name)] = nil }
        return gone.sorted()
    }
}

/// Display names of Hermes agents. The identity (`HermesAgent.name`) never changes: Keychain binding, pill id,
/// conversation and selection all hang on it. The display name is only what the user reads.
enum HermesAgentNames {
    static let maxLength = 40
    private static let maxScalars = 120

    /// Control characters (C0, DEL, C1, line and paragraph separators, bidi overrides) and every format character
    /// (category Cf) removed, trimmed, capped at `maxLength` characters. nil when nothing is left (clears the name).
    static func clean(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            let v = u.value
            if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029
                || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
                || u.properties.generalCategory == .format { continue }
            out.append(u)
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var scalars = 0
        for ch in trimmed.prefix(maxLength) {
            let n = ch.unicodeScalars.count
            if scalars + n > maxScalars { break }
            result.append(ch)
            scalars += n
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func shown(_ agent: HermesAgent) -> String { agent.shownName }

    /// True when some agent other than `identity` already shows `name` (case and diacritics insensitive).
    static func isTaken(_ name: String, in agents: [HermesAgent], except identity: String?) -> Bool {
        agents.contains { $0.name != identity && sameName($0.shownName, name) }
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    enum RenameError: Error, Equatable {
        case unknownAgent
        /// Another agent already shows this name.
        case taken(String)
    }

    /// The agent list with `identity` renamed to `raw` (an empty value clears the display name). Nothing else changes.
    static func rename(_ identity: String, to raw: String, in agents: [HermesAgent]) -> Result<[HermesAgent], RenameError> {
        guard let i = agents.firstIndex(where: { $0.name == identity }) else { return .failure(.unknownAgent) }
        var display = clean(raw)
        if display == identity { display = nil }
        let newShown = display ?? identity
        if isTaken(newShown, in: agents, except: identity) { return .failure(.taken(newShown)) }
        var out = agents
        out[i].displayName = display
        return .success(out)
    }
}
