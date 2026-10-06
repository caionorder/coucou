import Foundation
import Darwin
import Security

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

    /// Short label for the pill: the title cut before the first space that is followed by `(` or `[`
    /// ("Proteus (Swift Implementer) [names]" gives "Proteus"). Without that pattern the whole title.
    static func pillLabel(_ title: String) -> String {
        let chars = Array(title)
        guard chars.count > 2 else { return title }
        for i in 1..<(chars.count - 1) where chars[i] == " " && (chars[i + 1] == "(" || chars[i + 1] == "[") {
            let head = String(chars[..<i])
            return head.trimmingCharacters(in: .whitespaces).isEmpty ? title : head
        }
        return title
    }
}

// MARK: reply, new chat and icons

extension CmuxRouting {
    static let hubPillId = "integration_cmux"
    /// A task that is mid turn may be silent for hours; it is dropped only after this long.
    static let busyStaleAfter: TimeInterval = 6 * 3600
    static let launchTimeout: TimeInterval = 90
    static let maxPromptLength = 8000
    static let maxTranscript = 6
    static let maxRecentFolders = 8
    static let palette = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9", "#F97316", "#2DD4BF", "#F472B6", "#A78BFA"]
    /// Raw values of EyeShape; `pill` means no override.
    static let eyes = ["pill", "wide", "dot", "happy", "cup"]

    /// FNV-1a 64 bit. Stable across launches, unlike hashValue.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// Colour and eye of a session pill, derived from its surface key. The colour is probed linearly
    /// so two live sessions never share one while fewer than 8 are live.
    static func appearance(key: String, takenColors: Set<String>) -> (color: String, eye: String) {
        let h = fnv1a(key)
        let base = Int(h % UInt64(palette.count))
        var color = palette[base]
        for i in 0..<palette.count {
            let c = palette[(base + i) % palette.count]
            if !takenColors.contains(c) { color = c; break }
        }
        return (color, eyes[Int((h >> 16) % UInt64(eyes.count))])
    }

    /// Control characters become spaces (newline, tab, ESC, Ctrl-C…), trimmed, capped. nil when empty.
    static func preparePrompt(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F) { out.append(" ") } else { out.append(u) }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxPromptLength))
    }

    /// 1 to 120 chars of `A-Z a-z 0-9 space _ . / = : -`, first a letter or `/`. No shell syntax can pass.
    /// The first token (the program) holds no `=`: `NAME=value claude` would be an environment prefix.
    static func isValidLaunchCommand(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...120).contains(u.count) else { return false }
        func letter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        guard letter(u[0]) || u[0] == 0x2F else { return false }
        guard !u.prefix(while: { $0 != 0x20 }).contains(0x3D) else { return false }
        return u.allSatisfy {
            letter($0) || ($0 >= 0x30 && $0 <= 0x39) || [0x20, 0x5F, 0x2E, 0x2F, 0x3D, 0x3A, 0x2D].contains($0)
        }
    }

    /// Absolute, at most 1024 bytes, no control character (C0, DEL, C1), no `..` component.
    /// Existence is the caller's check.
    static func isValidFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
        guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !($0.value >= 0x7F && $0.value <= 0x9F) }) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// A folder is worth remembering only when it is valid and the directory exists.
    static func isExistingFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return isValidFolder(path) && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Chip labels: the last path component, plus the parent folder name when two chips share one.
    static func chipLabels(for folders: [String]) -> [String] {
        let last = folders.map { ($0 as NSString).lastPathComponent }
        return folders.enumerated().map { i, f in
            guard last.filter({ $0 == last[i] }).count > 1 else { return last[i] }
            let parent = ((f as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent.isEmpty || parent == "/" ? last[i] : parent + "/" + last[i]
        }
    }

    /// Params of `surface.send_text`. nil when an id is not valid.
    static func rpcParams(workspaceId: String, surfaceId: String, text: String) -> [String: String]? {
        guard isValidId(workspaceId), isValidId(surfaceId) else { return nil }
        return ["workspace_id": workspaceId, "surface_id": surfaceId, "text": text]
    }

    /// Params of `surface.send_key`. nil when an id is not valid.
    static func rpcParams(workspaceId: String, surfaceId: String, key: String) -> [String: String]? {
        guard isValidId(workspaceId), isValidId(surfaceId) else { return nil }
        return ["workspace_id": workspaceId, "surface_id": surfaceId, "key": key]
    }

    /// A new session takes focus only when the hub is Main, focus is nobody or the hub, and the view allows it.
    static func shouldFocusNewSession(mainPillId: String, focusId: String?, viewAllowsSteal: Bool) -> Bool {
        guard mainPillId == hubPillId, viewAllowsSteal else { return false }
        return focusId == nil || focusId == hubPillId
    }

    /// Where focus goes when a cmux task goes away: the most recent remaining session when the hub is
    /// Main, else Main.
    static func nextFocus(afterRemoving removed: String, mainPillId: String,
                          candidates: [(id: String, lastSeen: TimeInterval)]) -> String {
        guard mainPillId == hubPillId else { return mainPillId }
        let best = candidates.filter { $0.id != removed }.max { $0.lastSeen < $1.lastSeen }
        return best?.id ?? mainPillId
    }

    /// Send is off while the session waits on a dialog: Enter would answer it. `dialogMayBeOpen` is the
    /// per task marker of a request Coucou gave back to the terminal (see `dialogResolved`).
    static func canSend(state: String, holdsCard: Bool, dialogMayBeOpen: Bool = false) -> Bool {
        !(holdsCard || dialogMayBeOpen || state == "approval" || state == "question")
    }

    /// The marker of a permission or question dialog that may still be open in the terminal. `inputKey`
    /// is nil for a question (any PostToolUse of the tool resolves it).
    struct DialogMark: Equatable {
        var tool: String
        var inputKey: String?
    }

    /// True when `event` of the same session proves the dialog is gone: the matching tool call finished,
    /// or the turn / prompt / session moved on (a session that starts again on the surface included).
    static func dialogResolved(mark: DialogMark, event: String, tool: String, inputKey: String) -> Bool {
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            return mark.tool == tool && (mark.inputKey == nil || mark.inputKey == inputKey)
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "SessionStart":
            return true
        default:
            return false
        }
    }

    /// A card or question that reads EOF (the hook went away) before the late age was answered in the
    /// terminal: the dialog is gone. Only an older one, or the 115 s timer, leaves a dialog that may be open.
    static func eofLeavesDialogOpen(arrivedAt: TimeInterval, now: TimeInterval) -> Bool {
        isLateCard(arrivedAt: arrivedAt, now: now)
    }

    /// Tasks the stale prune must keep: those holding a card, and the one whose reply view is open.
    static func pruneProtected(holdingCard: Set<String>, openReplyTask: String?) -> Set<String> {
        guard let openReplyTask else { return holdingCard }
        return holdingCard.union([openReplyTask])
    }

    /// Idle tasks eviction may remove: never the one whose reply view is open.
    static func evictableIdle(_ idle: Set<String>, openReplyTask: String?) -> Set<String> {
        guard let openReplyTask else { return idle }
        return idle.subtracting([openReplyTask])
    }

    /// True when the answer of a session should appear in the open reply view instead of switching views.
    static func answerStaysInReply(prompt: CmuxPromptMode?, taskId: String, viewIsPrompt: Bool) -> Bool {
        viewIsPrompt && prompt == .reply(taskId: taskId)
    }

    /// A matched new chat moves focus only while the user is still in the New chat view and no approval
    /// or question card is on screen.
    static func launchMayTakeFocus(cardOpen: Bool, promptIsNewChat: Bool) -> Bool {
        !cardOpen && promptIsNewChat
    }

    static func recentFolders(adding folder: String, to list: [String]) -> [String] {
        var out = [folder]
        for f in list where f != folder { out.append(f) }
        return Array(out.prefix(maxRecentFolders))
    }

    /// 8-4-4-4-12 hex groups, 36 characters.
    static func isUUID(_ s: String) -> Bool {
        let hex = Set("0123456789abcdefABCDEF")
        let chars = Array(s)
        guard chars.count == 36 else { return false }
        return chars.enumerated().allSatisfy { i, c in
            [8, 13, 18, 23].contains(i) ? c == "-" : hex.contains(c)
        }
    }

    /// `workspace:N` out of the stdout of `new-workspace` (`OK workspace:10`): the first token is `OK`
    /// and the second is the ref, nothing else counts (a folder name echoed later cannot match).
    static func workspaceRef(inNewWorkspaceOutput text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2, tokens[0] == "OK", tokens[1].hasPrefix("workspace:") else { return nil }
        let digits = tokens[1].dropFirst("workspace:".count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tokens[1])
    }

    /// UUID of the workspace with this `ref` in the JSON of the rpc `workspace.list`
    /// (`{"workspaces":[{"id":…,"ref":"workspace:10",…}]}`, optionally under `result`).
    static func workspaceId(forRef ref: String, inListJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (root["workspaces"] as? [[String: Any]])
            ?? ((root["result"] as? [String: Any])?["workspaces"] as? [[String: Any]]) ?? []
        for item in list where (item["ref"] as? String) == ref {
            if let id = item["id"] as? String, isUUID(id) { return id }
        }
        return nil
    }
}

// MARK: draft notice and socket peer check

extension CmuxRouting {
    /// Notice of the folder fallback: names the session the draft will go to.
    static func folderDraftNotice(sessionName: String) -> String {
        let name = cleanLabel(sessionName) ?? "the new session"
        return "claude started in \(name). Check the prompt and press Send."
    }

    /// Connected, non-blocking-then-blocking probe socket to the unix socket at `path`. The caller closes it.
    /// nil when it cannot connect within `timeout`.
    private static func connectedProbe(path: String, timeout: TimeInterval) -> Int32? {
        guard isValidSocketPath(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var ok = false
        defer { if !ok { close(fd) } }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }
        ok = true
        return fd
    }

    /// Audit token (32 bytes) of the process that listens on the unix socket at `path`, read with
    /// LOCAL_PEERTOKEN on a probe connection that is closed without writing anything. Unlike a pid it
    /// carries the pid version, so it does not survive an exec or a pid reuse. nil when it cannot be read.
    static func socketPeerAuditToken(path: String, timeout: TimeInterval = 1) -> Data? {
        guard let fd = connectedProbe(path: path, timeout: timeout) else { return nil }
        defer { close(fd) }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0,
              Int(len) == MemoryLayout<audit_token_t>.size else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// pid held in an audit token (field 5). nil when the data is not a token.
    static func pid(ofAuditToken token: Data) -> pid_t? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let v = token.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5 * 4, as: UInt32.self) }
        return pid_t(bitPattern: v)
    }

    /// True when the process with this audit token satisfies the cmux code requirement.
    static func processIsCmux(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The listener of the socket is the cmux app. Run before a token leaves the process.
    /// Fails closed: no connection, no audit token, no code object or a failed requirement all give false.
    static func socketPeerIsCmux(path: String) -> Bool {
        guard let token = socketPeerAuditToken(path: path) else { return false }
        return processIsCmux(auditToken: token)
    }

    /// The title lookup may reuse a successful verification for this long; sends never do.
    static let verificationReuseInterval: TimeInterval = 60

    /// `verifiedAt` and `now` come from the same monotonic clock. A clock that went backwards is not fresh.
    static func verificationIsFresh(verifiedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let verifiedAt, now >= verifiedAt else { return false }
        return now - verifiedAt < verificationReuseInterval
    }
}

// MARK: session name (cmux tab title) and folder / branch line

extension CmuxRouting {
    static let maxTitleLength = 60
    static let metaRefreshInterval: TimeInterval = 5

    static let maxTitleScalars = 120

    /// Untrusted text: control characters (C0, DEL, C1, line and paragraph separators, bidi overrides)
    /// and every format character (Unicode category Cf: zero width, direction marks, tags) removed,
    /// trimmed, capped at `maxTitleLength` characters and `maxTitleScalars` unicode scalars.
    /// nil when nothing is left.
    static func cleanLabel(_ raw: String) -> String? {
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
        for ch in trimmed.prefix(maxTitleLength) {
            let n = ch.unicodeScalars.count
            if scalars + n > maxTitleScalars { break }
            result.append(ch)
            scalars += n
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Auto titled tabs start with a status glyph and a space: leading characters that are not a letter
    /// or a digit are dropped.
    static func stripLeadingGlyphs(_ s: String) -> String {
        let rest = s.unicodeScalars.drop { !CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(rest))
    }

    /// Title of the surface with this id in the JSON of the rpc `surface.list`
    /// (`{"surfaces":[{"id":"…","title":"…"}]}`, optionally under `result`). nil when absent or empty.
    static func tabTitle(forSurface surfaceId: String, inListJSON json: String) -> String? {
        guard !surfaceId.isEmpty, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (root["surfaces"] as? [[String: Any]])
            ?? ((root["result"] as? [String: Any])?["surfaces"] as? [[String: Any]]) ?? []
        for item in list {
            guard let id = item["id"] as? String, id.caseInsensitiveCompare(surfaceId) == .orderedSame else { continue }
            guard let title = item["title"] as? String else { return nil }
            return cleanLabel(stripLeadingGlyphs(title))
        }
        return nil
    }

    /// Params of `surface.list`. nil when the id is not valid.
    static func surfaceListParams(workspaceId: String) -> [String: String]? {
        isValidId(workspaceId) ? ["workspace_id": workspaceId] : nil
    }

    /// At most one refresh every `metaRefreshInterval` seconds per task.
    static func metaRefreshDue(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now < last || now - last >= metaRefreshInterval
    }

    /// Branch out of the content of a HEAD file: `ref: refs/heads/NAME` gives NAME, a detached HEAD gives
    /// the first 7 characters of the hash, anything else nil.
    static func branchName(fromHEAD content: String) -> String? {
        let line = (content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix) else { return nil }
            return cleanLabel(String(ref.dropFirst(prefix.count)))
        }
        let hex = Set("0123456789abcdefABCDEF")
        guard (40...64).contains(line.count), line.allSatisfy({ hex.contains($0) }) else { return nil }
        return String(line.prefix(7))
    }

    /// Target of a `.git` file (`gitdir: PATH`), relative paths resolved against `base`. nil when it is
    /// not a pointer.
    static func gitDirectory(fromPointer content: String, base: String) -> String? {
        let line = (content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
    }

    /// Up to 4 KB of a regular file, opened without following a symlink and without blocking (a FIFO
    /// named HEAD would otherwise hang the reader). nil for anything that is not a regular file.
    static func smallFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n >= 0 else { return nil }
        return String(data: Data(buf.prefix(n)), encoding: .utf8)
    }

    /// A `gitdir:` target is plausible when it is a `.git` folder (or a `*.git` one) or lies inside one.
    static func isPlausibleGitDir(_ path: String) -> Bool {
        let comps = (path as NSString).standardizingPath.split(separator: "/")
        guard let last = comps.last else { return false }
        return last.hasSuffix(".git") || comps.contains(".git")
    }

    /// Branch of the repository that holds `cwd`, without running a process: walks up to the first `.git`,
    /// follows a `gitdir:` pointer once (worktrees), reads HEAD. nil when there is no repository.
    static func gitBranch(cwd: String) -> String? {
        guard isValidFolder(cwd) else { return nil }
        var dir = (cwd as NSString).standardizingPath
        for _ in 0..<64 {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let pointer = smallFile(dotGit),
                          let target = gitDirectory(fromPointer: pointer, base: dir),
                          isPlausibleGitDir(target) else { return nil }
                    gitDir = target
                }
                guard let head = smallFile((gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
                return branchName(fromHEAD: head)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
        return nil
    }

    /// Second line of a cmux session: `folder (branch)`, the folder alone without a repository.
    static func folderLine(cwd: String, branch: String?) -> String? {
        let folder = (cwd as NSString).lastPathComponent
        guard !cwd.isEmpty, !folder.isEmpty, folder != "/",
              let name = cleanLabel(folder) else { return nil }
        guard let branch, !branch.isEmpty else { return name }
        return "\(name) (\(branch))"
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
    /// (lastSeen and sessionId are still refreshed). A live entry (it has a socket path and a
    /// capability) never gets another socket path while its stored socket file is still a socket owned by
    /// the user: the whole unit is refused and false is returned. When that file is gone (cmux restarted
    /// somewhere else without a termination notice), the new unit is accepted.
    @discardableResult
    mutating func note(taskId: String, surfaceId: String, workspaceId: String, socketPath: String,
                       capability: String, sessionId: String, now: TimeInterval,
                       isStoredSocketTrusted: (String) -> Bool = CmuxRouting.socketFileIsTrusted(path:)) -> Bool {
        var s = surfaces[taskId] ?? CmuxSurface(taskId: taskId, surfaceId: "", workspaceId: "",
                                                socketPath: "", capability: "", sessionId: "",
                                                lastSeen: now)
        var accepted = true
        if !capability.isEmpty {
            let live = !s.socketPath.isEmpty && !s.capability.isEmpty
            if live && s.socketPath != socketPath && isStoredSocketTrusted(s.socketPath) {
                accepted = false
            } else {
                s.surfaceId = surfaceId
                s.workspaceId = workspaceId
                s.socketPath = socketPath
                s.capability = capability
            }
        }
        if !sessionId.isEmpty { s.sessionId = sessionId }
        s.lastSeen = now
        surfaces[taskId] = s
        return accepted
    }

    func surface(for taskId: String) -> CmuxSurface? { surfaces[taskId] }

    mutating func remove(taskId: String) { surfaces[taskId] = nil }

    /// cmux quit: its tokens are dead. Entries and ids stay, so the next event restores them.
    mutating func clearCredentials() {
        for k in surfaces.keys { surfaces[k]?.capability = "" }
    }

    /// Credential order: the target's own token, else the freshest live token, else the stored
    /// password, else none. Only entries that can address a surface count.
    func credential(for taskId: String?, hasPassword: Bool) -> CmuxCredential {
        if let taskId, let own = surfaces[taskId], own.canFocusExactly { return .token(own) }
        let freshest = surfaces.values.filter { $0.canFocusExactly }
            .max { ($0.lastSeen, $0.taskId) < ($1.lastSeen, $1.taskId) }
        if let freshest { return .token(freshest) }
        return hasPassword ? .password : CmuxCredential.none
    }

    /// Credential for typing into `taskId`: its own token, else the freshest token on the same socket.
    /// Never the password: only a token proves the caller belongs to the cmux that owns the socket.
    func sendCredential(for taskId: String) -> CmuxCredential {
        guard let target = surfaces[taskId] else { return CmuxCredential.none }
        if target.canFocusExactly { return .token(target) }
        guard !target.socketPath.isEmpty else { return CmuxCredential.none }
        let same = surfaces.values.filter { $0.canFocusExactly && $0.socketPath == target.socketPath }
            .max { ($0.lastSeen, $0.taskId) < ($1.lastSeen, $1.taskId) }
        if let same { return .token(same) }
        return CmuxCredential.none
    }

    /// Entries not seen for `staleAfter`, whatever the task state, except the `protected` ones
    /// (a queued card, or the card on screen).
    /// A `busy` id (mid turn, hooks can stay silent for a long time) is stale only after `busyStaleAfter`.
    func staleTaskIds(now: TimeInterval, protected: Set<String>, busy: Set<String> = []) -> [String] {
        surfaces.values
            .filter {
                let limit = busy.contains($0.taskId) ? CmuxRouting.busyStaleAfter : CmuxRouting.staleAfter
                return now - $0.lastSeen > limit && !protected.contains($0.taskId)
            }
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

enum CmuxCredential: Equatable {
    case token(CmuxSurface)
    case password
    case none
}

enum CmuxPromptMode: Hashable {
    case reply(taskId: String)
    case newChat
}

/// A "New chat" waiting for the SessionStart of the surface it created. Memory only.
/// `workspaceId` is the workspace UUID resolved after `new-workspace` ("" when it could not be resolved),
/// `socketPath` the socket the token used ("" in password mode, where the CLI picks its own).
struct CmuxPendingLaunch: Equatable {
    var workspaceId: String
    var socketPath: String
    var cwd: String
    var prompt: String
    var createdAt: TimeInterval

    /// The prompt may be typed without a click only when the workspace and the socket are both known.
    var autoSendable: Bool { !workspaceId.isEmpty && !socketPath.isEmpty }

    private func fresh(isNewTask: Bool, now: TimeInterval) -> Bool {
        isNewTask && now >= createdAt && now - createdAt <= CmuxRouting.launchTimeout
    }

    /// New task, same workspace UUID (case insensitive) and same socket path. Empty ids never match.
    func matches(workspaceId: String, socketPath: String, isNewTask: Bool, now: TimeInterval) -> Bool {
        guard fresh(isNewTask: isNewTask, now: now), autoSendable, !workspaceId.isEmpty else { return false }
        return self.workspaceId.caseInsensitiveCompare(workspaceId) == .orderedSame && self.socketPath == socketPath
    }

    /// Fallback for a launch started with the socket password (no socket path): a new task in the same
    /// folder. It only focuses the session and offers the prompt as a draft, it never authorizes a send.
    /// A launch that used a token never takes this path: its workspace lookup failing is not a reason to
    /// trust a folder match.
    func matchesFolder(cwd: String, isNewTask: Bool, now: TimeInterval) -> Bool {
        guard fresh(isNewTask: isNewTask, now: now), socketPath.isEmpty, !cwd.isEmpty else { return false }
        return (self.cwd as NSString).standardizingPath == (cwd as NSString).standardizingPath
    }
}

/// Text kept for the field of one prompt mode. Restored only into that same mode.
struct CmuxDraft: Equatable {
    var mode: CmuxPromptMode
    var text: String
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
