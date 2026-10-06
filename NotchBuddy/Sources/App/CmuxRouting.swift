import Foundation
import Darwin

#if !APPSTORE

/// Pure logic for Claude Code sessions that run inside the cmux terminal:
/// task ids, labels, the in-memory surface registry and the queue of waiting cards.
enum CmuxRouting {
    static let bundleId = "com.cmuxterm.app"
    static let taskPrefix = "agent_cmux_"
    static let maxTasks = 6
    static let maxKeyLength = 36
    /// A registry entry (and its task) not seen for this long is dropped.
    static let staleAfter: TimeInterval = 30 * 60
    /// After a card is shown through promotion, answers are ignored for this long.
    static let promotionLock: TimeInterval = 0.7
    /// A card shown for longer than this has been closed by the hook's own timeout (118 s).
    static let lateCardAge: TimeInterval = 115
    /// Requirement the cmux app bundle must satisfy before its CLI is run (team id of Manaflow, Inc.).
    static let codeRequirement =
        "anchor apple generic and identifier \"com.cmuxterm.app\" and certificate leaf[subject.OU] = \"7WLXT3NR37\""

    static func isCmuxTaskId(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(taskPrefix)
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let filtered = raw.lowercased().filter { allowed.contains($0) }
        return String(filtered.prefix(maxKeyLength))
    }

    /// Key of a cmux task: the surface id, else the session id. nil when neither is usable.
    static func sessionKey(surfaceId: String, sessionId: String) -> String? {
        let surface = sanitize(surfaceId)
        if !surface.isEmpty { return surface }
        if sessionId.lowercased() == "unknown" { return nil }
        let session = sanitize(sessionId)
        return session.isEmpty ? nil : session
    }

    /// nil when the payload does not come from cmux.
    static func taskId(payload: [String: Any]) -> String? {
        let surface = (payload["cmux_surface_id"] as? String) ?? ""
        let bundle = ((payload["bundle_id"] as? String) ?? "").lowercased()
        guard !surface.isEmpty || bundle == bundleId else { return nil }
        let session = (payload["session_id"] as? String)
            ?? (payload["conversation_id"] as? String) ?? ""
        guard let key = sessionKey(surfaceId: surface, sessionId: session) else { return nil }
        return taskPrefix + key
    }

    // MARK: validation of the fields the hook relay sends

    /// One alphanumeric, then up to 63 of alphanumeric, colon, underscore, dash.
    static func isValidId(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...64).contains(u.count) else { return false }
        func alnum(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        guard alnum(u[0]) else { return false }
        return u.dropFirst().allSatisfy { alnum($0) || $0 == 0x3A || $0 == 0x5F || $0 == 0x2D }
    }

    /// Printable ASCII without spaces, at most 512 characters.
    static func isValidCapability(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return (1...512).contains(u.count) && u.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// Absolute, at most 103 bytes (sockaddr_un), ends with .sock, printable ASCII, no `..` component.
    static func isValidSocketPath(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count <= 103, s.hasPrefix("/"), s.hasSuffix(".sock") else { return false }
        guard u.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return false }
        return !s.split(separator: "/").contains("..")
    }

    /// The four fields travel as one unit: all valid, or none is used.
    static func isValidContext(surfaceId: String, workspaceId: String,
                               socketPath: String, capability: String) -> Bool {
        isValidId(surfaceId) && isValidId(workspaceId)
            && isValidSocketPath(socketPath) && isValidCapability(capability)
    }

    /// File type and owner check of the socket path (pure part, fed by lstat).
    static func isTrustedSocket(mode: UInt32, owner: UInt32, currentUid: UInt32) -> Bool {
        (mode & UInt32(S_IFMT)) == UInt32(S_IFSOCK) && owner == currentUid
    }

    /// lstat never follows a symlink, so a link reports S_IFLNK and fails the socket check.
    static func socketFileIsTrusted(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return isTrustedSocket(mode: UInt32(st.st_mode), owner: UInt32(st.st_uid), currentUid: UInt32(getuid()))
    }

    // MARK: timing and lifecycle decisions

    /// True while a card shown through promotion must not take clicks yet.
    static func inputLocked(promotedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = promotedAt else { return false }
        return now >= at && now - at < promotionLock
    }

    /// True when the card on screen is old enough that the hook has already given up on it.
    static func isLateCard(arrivedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - arrivedAt > lateCardAge
    }

    /// Events after which a task exists (processEvent and the request paths upsert it).
    static func eventCreatesTask(_ event: String) -> Bool {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "AskUserQuestion"].contains(event)
    }

    /// A registry entry is created only by an event that creates a task, or for a task that is live.
    static func mayRegister(event: String, taskIsLive: Bool) -> Bool {
        taskIsLive || eventCreatesTask(event)
    }

    /// Project folder name, suffixed ` 2`, ` 3`… when another live cmux task already shows it.
    static func displayName(base: String, taskId: String,
                            existing: [(id: String, name: String)]) -> String {
        let taken = Set(existing.filter { $0.id != taskId }.map { $0.name })
        if let own = existing.first(where: { $0.id == taskId })?.name, !taken.contains(own) {
            if own == base { return own }
            if own.hasPrefix(base + " "), Int(own.dropFirst(base.count + 1)) != nil { return own }
        }
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// One per live cmux task. The capability is a credential: memory only, never logged or persisted.
struct CmuxSurface: Equatable {
    var taskId: String
    var surfaceId: String
    var workspaceId: String
    var socketPath: String
    var capability: String
    var sessionId: String
    var lastSeen: TimeInterval

    var canFocusExactly: Bool {
        !surfaceId.isEmpty && !workspaceId.isEmpty && !socketPath.isEmpty && !capability.isEmpty
    }
}

struct CmuxRegistry {
    private(set) var surfaces: [String: CmuxSurface] = [:]

    /// Upsert. surfaceId, workspaceId, socketPath and capability are one unit: replaced together and
    /// only when the incoming capability is non empty. Without a capability they stay as they were
    /// (lastSeen and sessionId are still refreshed).
    mutating func note(taskId: String, surfaceId: String, workspaceId: String, socketPath: String,
                       capability: String, sessionId: String, now: TimeInterval) {
        var s = surfaces[taskId] ?? CmuxSurface(taskId: taskId, surfaceId: "", workspaceId: "",
                                                socketPath: "", capability: "", sessionId: "",
                                                lastSeen: now)
        if !capability.isEmpty {
            s.surfaceId = surfaceId
            s.workspaceId = workspaceId
            s.socketPath = socketPath
            s.capability = capability
        }
        if !sessionId.isEmpty { s.sessionId = sessionId }
        s.lastSeen = now
        surfaces[taskId] = s
    }

    func surface(for taskId: String) -> CmuxSurface? { surfaces[taskId] }

    mutating func remove(taskId: String) { surfaces[taskId] = nil }

    /// Entries not seen for `staleAfter`, whatever the task state, except the `protected` ones
    /// (a queued card, or the card on screen).
    func staleTaskIds(now: TimeInterval, protected: Set<String>) -> [String] {
        surfaces.values
            .filter { now - $0.lastSeen > CmuxRouting.staleAfter && !protected.contains($0.taskId) }
            .map { $0.taskId }
            .sorted()
    }

    /// Task ids to evict so that count <= maxTasks. Only ids listed in `idle`, oldest lastSeen first, never `keep`.
    func evictionCandidates(idle: Set<String>, keep: String?) -> [String] {
        let excess = surfaces.count - CmuxRouting.maxTasks
        guard excess > 0 else { return [] }
        let candidates = surfaces.values
            .filter { idle.contains($0.taskId) && $0.taskId != keep }
            .sorted { $0.lastSeen < $1.lastSeen }
            .map { $0.taskId }
        return Array(candidates.prefix(excess))
    }
}

enum CmuxCardKind { case approval, question }

struct CmuxQueuedCard: Equatable {
    var id: Int
    var kind: CmuxCardKind
    var taskId: String
    var sessionId: String
    var tool: String
    var inputKey: String
    var arrivedAt: TimeInterval
}

struct CmuxCardQueue {
    /// Older entries are not worth presenting (the hook gives up at 118 s).
    static let maxAge: TimeInterval = 110
    static let maxCards = 16
    static let maxCardsPerTask = 2
    private(set) var cards: [CmuxQueuedCard] = []
    private var nextId = 1

    /// False when the queue is full (16 in total, 2 per task): the request is answered "ask" at once.
    func canAccept(taskId: String) -> Bool {
        cards.count < Self.maxCards && cards.filter { $0.taskId == taskId }.count < Self.maxCardsPerTask
    }

    @discardableResult
    mutating func enqueue(kind: CmuxCardKind, taskId: String, sessionId: String, tool: String,
                          inputKey: String, now: TimeInterval, atFront: Bool = false,
                          arrivedAt: TimeInterval? = nil) -> Int {
        let id = nextId
        nextId += 1
        let card = CmuxQueuedCard(id: id, kind: kind, taskId: taskId, sessionId: sessionId,
                                  tool: tool, inputKey: inputKey, arrivedAt: arrivedAt ?? now)
        if atFront { cards.insert(card, at: 0) } else { cards.append(card) }
        return id
    }

    /// Pops the first non-expired card; `expired` lists the ids skipped (caller closes their fds).
    mutating func popNext(now: TimeInterval) -> (card: CmuxQueuedCard?, expired: [Int]) {
        var expired: [Int] = []
        while !cards.isEmpty {
            let card = cards.removeFirst()
            if now - card.arrivedAt > Self.maxAge {
                expired.append(card.id)
            } else {
                return (card, expired)
            }
        }
        return (nil, expired)
    }

    /// Ids resolved elsewhere. PostToolUse/PostToolUseFailure: same session + tool + inputKey.
    /// Stop/StopFailure/UserPromptSubmit/SessionEnd/Interrupt: every card of that session. Removes them.
    mutating func resolve(event: String, sessionId: String, tool: String, inputKey: String) -> [Int] {
        guard !sessionId.isEmpty else { return [] }
        let matches: (CmuxQueuedCard) -> Bool
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            matches = { $0.sessionId == sessionId && $0.tool == tool && $0.inputKey == inputKey }
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
            matches = { $0.sessionId == sessionId }
        default:
            return []
        }
        let ids = cards.filter(matches).map { $0.id }
        cards.removeAll(where: matches)
        return ids
    }

    @discardableResult
    mutating func remove(id: Int) -> CmuxQueuedCard? {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return nil }
        return cards.remove(at: i)
    }

    mutating func removeAll(taskId: String) -> [Int] {
        let ids = cards.filter { $0.taskId == taskId }.map { $0.id }
        cards.removeAll { $0.taskId == taskId }
        return ids
    }

    func hasCards(for taskId: String) -> Bool { cards.contains { $0.taskId == taskId } }
}

#endif
