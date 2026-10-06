import Foundation

@main
enum CmuxRoutingTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        // ── taskId ─────────────────────────────────────────────────────────────
        print("CmuxRouting.taskId")
        let uuid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        check("surface id → lowercased key",
              CmuxRouting.taskId(payload: ["cmux_surface_id": uuid, "session_id": "s1"])
                == "agent_cmux_abcdef12-3456-7890-abcd-ef1234567890")
        check("bundle id only → keyed by session",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "Sess-9"])
                == "agent_cmux_sess-9")
        check("bundle id match is case-insensitive",
              CmuxRouting.taskId(payload: ["bundle_id": "COM.CmuxTerm.App", "session_id": "x1"])
                == "agent_cmux_x1")
        check("neither → nil",
              CmuxRouting.taskId(payload: ["session_id": "s1", "bundle_id": "com.microsoft.VSCode"]) == nil)
        check("session unknown and no surface → nil",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "unknown"]) == nil)
        check("odd characters stripped",
              CmuxRouting.taskId(payload: ["cmux_surface_id": "A_b/c d$1"]) == "agent_cmux_abcd1")
        check("key capped at 36",
              CmuxRouting.taskId(payload: ["cmux_surface_id": String(repeating: "a", count: 80)])
                == "agent_cmux_" + String(repeating: "a", count: 36))
        check("conversation_id fallback",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "conversation_id": "c7"])
                == "agent_cmux_c7")

        print("CmuxRouting.sessionKey")
        check("surface that sanitizes to empty → session id",
              CmuxRouting.sessionKey(surfaceId: "___///", sessionId: "Sess-1") == "sess-1")
        check("UNKNOWN upper case, no usable surface → nil",
              CmuxRouting.sessionKey(surfaceId: "", sessionId: "UNKNOWN") == nil)
        check("UNKNOWN upper case but surface usable → surface",
              CmuxRouting.sessionKey(surfaceId: "S1", sessionId: "UNKNOWN") == "s1")
        check("neither usable → nil",
              CmuxRouting.sessionKey(surfaceId: "@@", sessionId: "$$") == nil)

        // ── isCmuxTaskId ───────────────────────────────────────────────────────
        print("CmuxRouting.isCmuxTaskId")
        check("prefix → true", CmuxRouting.isCmuxTaskId("agent_cmux_abc"))
        check("agent_cmux (external agent) → false", !CmuxRouting.isCmuxTaskId("agent_cmux"))
        check("agent_codex → false", !CmuxRouting.isCmuxTaskId("agent_codex"))
        check("integration_claude → false", !CmuxRouting.isCmuxTaskId("integration_claude"))
        check("nil → false", !CmuxRouting.isCmuxTaskId(nil))

        // ── displayName ────────────────────────────────────────────────────────
        print("CmuxRouting.displayName")
        check("unique base unchanged",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_a", existing: []) == "api")
        check("second same base → 2",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api")]) == "api 2")
        check("same task keeps its name",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_a",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api")
        check("suffixed task keeps its suffix",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 2")
        check("third → 3",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_c",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 3")

        check("base changed for an existing task → new base",
              CmuxRouting.displayName(base: "web", taskId: "agent_cmux_a",
                                      existing: [("agent_cmux_a", "api")]) == "web")
        check("base changed while a suffixed name was held → new base",
              CmuxRouting.displayName(base: "web", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "web")
        check("folder really named 'api 2' keeps its name",
              CmuxRouting.displayName(base: "api 2", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_b", "api 2")]) == "api 2")
        check("folder named 'api 2' next to a task already called 'api 2' → 'api 2 2'",
              CmuxRouting.displayName(base: "api 2", taskId: "agent_cmux_c",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 2 2")

        // ── registry ───────────────────────────────────────────────────────────
        print("CmuxRegistry")
        var reg = CmuxRegistry()
        reg.note(taskId: "t1", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock",
                 capability: "tok1", sessionId: "sess", now: 10)
        check("insert", reg.surface(for: "t1")?.surfaceId == "s" && reg.surface(for: "t1")?.capability == "tok1")
        reg.note(taskId: "t1", surfaceId: "", workspaceId: "", socketPath: "", capability: "",
                 sessionId: "", now: 20)
        check("empty fields do not erase",
              reg.surface(for: "t1")?.capability == "tok1" && reg.surface(for: "t1")?.workspaceId == "w"
              && reg.surface(for: "t1")?.sessionId == "sess")
        check("lastSeen advances", reg.surface(for: "t1")?.lastSeen == 20)
        reg.note(taskId: "t1", surfaceId: "s2", workspaceId: "w2", socketPath: "/tmp/d.sock",
                 capability: "tok2", sessionId: "", now: 30)
        check("new capability replaces the whole unit",
              reg.surface(for: "t1")?.capability == "tok2" && reg.surface(for: "t1")?.surfaceId == "s2"
              && reg.surface(for: "t1")?.workspaceId == "w2" && reg.surface(for: "t1")?.socketPath == "/tmp/d.sock")
        reg.note(taskId: "t1", surfaceId: "evil", workspaceId: "evil", socketPath: "/tmp/evil.sock",
                 capability: "", sessionId: "sess2", now: 40)
        check("no capability: socket, ids and token unchanged",
              reg.surface(for: "t1")?.socketPath == "/tmp/d.sock" && reg.surface(for: "t1")?.surfaceId == "s2"
              && reg.surface(for: "t1")?.workspaceId == "w2" && reg.surface(for: "t1")?.capability == "tok2")
        check("no capability: sessionId and lastSeen still refresh",
              reg.surface(for: "t1")?.sessionId == "sess2" && reg.surface(for: "t1")?.lastSeen == 40)
        reg.note(taskId: "t9", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock",
                 capability: "", sessionId: "x", now: 50)
        check("entry created without capability cannot focus",
              reg.surface(for: "t9") != nil && reg.surface(for: "t9")?.canFocusExactly == false
              && reg.surface(for: "t9")?.socketPath == "")
        reg.remove(taskId: "t1")
        check("remove", reg.surface(for: "t1") == nil)

        // ── staleness ──────────────────────────────────────────────────────────
        print("CmuxRegistry.staleTaskIds")
        var st = CmuxRegistry()
        st.note(taskId: "old", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 0)
        st.note(taskId: "edge", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 100)
        st.note(taskId: "held", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 0)
        st.note(taskId: "fresh", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 1900)
        let nowT: TimeInterval = 100 + CmuxRouting.staleAfter
        check("staleAfter is 30 minutes", CmuxRouting.staleAfter == 1800)
        check("older than 30 min removed, exactly 30 min kept, protected kept, fresh kept",
              st.staleTaskIds(now: nowT, protected: ["held"]) == ["old"])
        check("nothing stale just under the limit", st.staleTaskIds(now: 1799, protected: []).isEmpty)
        check("protected entry stays however old",
              !st.staleTaskIds(now: 100_000, protected: ["held"]).contains("held"))

        // ── canFocusExactly ────────────────────────────────────────────────────
        print("CmuxSurface.canFocusExactly")
        let full = CmuxSurface(taskId: "t", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                               capability: "c", sessionId: "", lastSeen: 0)
        check("complete → true", full.canFocusExactly)
        var m = full; m.capability = ""
        check("no token → false", !m.canFocusExactly)
        m = full; m.surfaceId = ""
        check("no surface → false", !m.canFocusExactly)
        m = full; m.workspaceId = ""
        check("no workspace → false", !m.canFocusExactly)
        m = full; m.socketPath = ""
        check("no socket → false", !m.canFocusExactly)

        // ── evictionCandidates ─────────────────────────────────────────────────
        print("CmuxRegistry.evictionCandidates")
        var big = CmuxRegistry()
        for i in 1...6 {
            big.note(taskId: "t\(i)", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                     capability: "c", sessionId: "", now: TimeInterval(i))
        }
        let all = Set((1...6).map { "t\($0)" })
        check("none at 6", big.evictionCandidates(idle: all, keep: nil).isEmpty)
        big.note(taskId: "t7", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 7)
        let all7 = all.union(["t7"])
        check("at 7 → oldest idle", big.evictionCandidates(idle: all7, keep: "t7") == ["t1"])
        check("never returns keep", big.evictionCandidates(idle: all7, keep: "t1") == ["t2"])
        check("nothing when all busy", big.evictionCandidates(idle: [], keep: "t7").isEmpty)
        big.note(taskId: "t8", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 8)
        big.note(taskId: "t9", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 9)
        let all9 = all7.union(["t8", "t9"])
        check("excess 3 → three oldest idle in order",
              big.evictionCandidates(idle: all9, keep: "t9") == ["t1", "t2", "t3"])
        check("fewer idle than the excess → only the idle ones",
              big.evictionCandidates(idle: ["t4", "t6"], keep: "t9") == ["t4", "t6"])
        check("mix of idle and busy skips the busy oldest",
              big.evictionCandidates(idle: ["t3", "t5", "t8"], keep: "t9") == ["t3", "t5", "t8"])

        // ── queue ──────────────────────────────────────────────────────────────
        print("CmuxCardQueue")
        var q = CmuxCardQueue()
        let a = q.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k1", now: 100)
        let b = q.enqueue(kind: .question, taskId: "t2", sessionId: "s2", tool: "AskUserQuestion", inputKey: "k2", now: 101)
        check("FIFO order", q.popNext(now: 102).card?.id == a && q.popNext(now: 102).card?.id == b)
        check("empty queue pops nil", q.popNext(now: 102).card == nil)

        let c = q.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 200)
        let d = q.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 201,
                          atFront: true, arrivedAt: 150)
        let popped = q.popNext(now: 205)
        check("atFront pops first, keeps arrivedAt", popped.card?.id == d && popped.card?.arrivedAt == 150)
        check("front card not expired at 55 s", popped.expired.isEmpty)
        _ = c

        var qe = CmuxCardQueue()
        let old = qe.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let fresh = qe.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 100)
        let r = qe.popNext(now: 111)
        check("expired card skipped and reported", r.expired == [old] && r.card?.id == fresh)

        var qb = CmuxCardQueue()
        let edge = qb.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let atEdge = qb.popNext(now: 110)
        check("exactly 110 s is not expired", atEdge.card?.id == edge && atEdge.expired.isEmpty)
        var qb2 = CmuxCardQueue()
        let just = qb2.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        check("110.5 s is expired", qb2.popNext(now: 110.5).expired == [just])

        var qx = CmuxCardQueue()
        let x1 = qx.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let x2 = qx.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 1)
        let x3 = qx.enqueue(kind: .approval, taskId: "t3", sessionId: "s3", tool: "Bash", inputKey: "k", now: 2)
        let x4 = qx.enqueue(kind: .approval, taskId: "t4", sessionId: "s4", tool: "Bash", inputKey: "k", now: 200)
        let multi = qx.popNext(now: 210)
        check("several expired in a row are all reported, in order, then the live card",
              multi.expired == [x1, x2, x3] && multi.card?.id == x4)
        var qa = CmuxCardQueue()
        let a1 = qa.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let a2 = qa.enqueue(kind: .question, taskId: "t2", sessionId: "s2", tool: "AskUserQuestion", inputKey: "k", now: 5)
        let allGone = qa.popNext(now: 500)
        check("all expired → no card, every id reported, queue empty",
              allGone.card == nil && allGone.expired == [a1, a2] && qa.cards.isEmpty)

        print("CmuxCardQueue.canAccept")
        var qc = CmuxCardQueue()
        check("empty queue accepts", qc.canAccept(taskId: "t1"))
        _ = qc.enqueue(kind: .approval, taskId: "t1", sessionId: "s", tool: "Bash", inputKey: "1", now: 0)
        check("one card of the task: still accepts", qc.canAccept(taskId: "t1"))
        _ = qc.enqueue(kind: .approval, taskId: "t1", sessionId: "s", tool: "Bash", inputKey: "2", now: 0)
        check("two cards of the task: refuses a third", !qc.canAccept(taskId: "t1"))
        check("another task is still accepted", qc.canAccept(taskId: "t2"))
        for i in 0..<14 {
            _ = qc.enqueue(kind: .approval, taskId: "u\(i)", sessionId: "s", tool: "Bash", inputKey: "k", now: 0)
        }
        check("16 cards in total: refuses any task", qc.cards.count == 16 && !qc.canAccept(taskId: "new"))
        _ = qc.removeAll(taskId: "t1")
        check("room again after removals", qc.canAccept(taskId: "new"))

        // resolve
        var qe0 = CmuxCardQueue()
        _ = qe0.enqueue(kind: .approval, taskId: "t1", sessionId: "", tool: "Bash", inputKey: "k", now: 0)
        check("empty session id resolves nothing (Stop and PostToolUse)",
              qe0.resolve(event: "Stop", sessionId: "", tool: "", inputKey: "").isEmpty
              && qe0.resolve(event: "PostToolUse", sessionId: "", tool: "Bash", inputKey: "k").isEmpty
              && qe0.cards.count == 1)

        var qr = CmuxCardQueue()
        let r1 = qr.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "ka", now: 1)
        _ = qr.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "kb", now: 1)
        _ = qr.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "ka", now: 1)
        check("PostToolUse removes only same session+tool+input",
              qr.resolve(event: "PostToolUse", sessionId: "s1", tool: "Bash", inputKey: "ka") == [r1]
              && qr.cards.count == 2)
        check("PostToolUse other tool untouched",
              qr.resolve(event: "PostToolUseFailure", sessionId: "s1", tool: "Edit", inputKey: "kb").isEmpty)
        check("PreToolUse removes nothing",
              qr.resolve(event: "PreToolUse", sessionId: "s1", tool: "Bash", inputKey: "kb").isEmpty)
        for ev in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"] {
            var qs = CmuxCardQueue()
            let x = qs.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k1", now: 1)
            let y = qs.enqueue(kind: .question, taskId: "t1", sessionId: "s1", tool: "AskUserQuestion", inputKey: "k2", now: 1)
            let z = qs.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k1", now: 1)
            let gone = qs.resolve(event: ev, sessionId: "s1", tool: "", inputKey: "")
            check("\(ev) removes that session only", Set(gone) == Set([x, y]) && qs.cards.map { $0.id } == [z])
        }

        // remove / removeAll / hasCards
        var qm = CmuxCardQueue()
        let m1 = qm.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 1)
        let m2 = qm.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Edit", inputKey: "k", now: 1)
        let m3 = qm.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 1)
        check("hasCards true", qm.hasCards(for: "t1") && qm.hasCards(for: "t2"))
        check("remove(id:) returns the card", qm.remove(id: m1)?.id == m1 && qm.remove(id: m1) == nil)
        check("removeAll(taskId:)", qm.removeAll(taskId: "t1") == [m2])
        check("hasCards after removals", !qm.hasCards(for: "t1") && qm.hasCards(for: "t2"))
        _ = m3

        // ── validation ─────────────────────────────────────────────────────────
        print("CmuxRouting validation")
        check("id: uuid ok", CmuxRouting.isValidId("ABCDEF12-3456-7890-ABCD-EF1234567890"))
        check("id: colon and underscore ok", CmuxRouting.isValidId("workspace:3_a-b"))
        check("id: 64 chars ok, 65 refused",
              CmuxRouting.isValidId(String(repeating: "a", count: 64)) && !CmuxRouting.isValidId(String(repeating: "a", count: 65)))
        check("id: starts with a dash refused", !CmuxRouting.isValidId("--help") && !CmuxRouting.isValidId("-x"))
        check("id: starts with colon or underscore refused", !CmuxRouting.isValidId(":a") && !CmuxRouting.isValidId("_a"))
        check("id: empty, space, slash, newline refused",
              !CmuxRouting.isValidId("") && !CmuxRouting.isValidId("a b") && !CmuxRouting.isValidId("a/b")
              && !CmuxRouting.isValidId("a\nb"))
        check("id: non ASCII refused", !CmuxRouting.isValidId("é1"))

        check("capability: printable ascii ok", CmuxRouting.isValidCapability("Ab3-_.~=+/xyz"))
        check("capability: 512 ok, 513 refused",
              CmuxRouting.isValidCapability(String(repeating: "a", count: 512))
              && !CmuxRouting.isValidCapability(String(repeating: "a", count: 513)))
        check("capability: empty, space, control, non ASCII refused",
              !CmuxRouting.isValidCapability("") && !CmuxRouting.isValidCapability("a b")
              && !CmuxRouting.isValidCapability("a\u{7}b") && !CmuxRouting.isValidCapability("tökén"))

        check("socket: absolute .sock ok", CmuxRouting.isValidSocketPath("/tmp/cmux.sock"))
        check("socket: 103 bytes ok, 104 refused",
              CmuxRouting.isValidSocketPath("/" + String(repeating: "a", count: 97) + ".sock")
              && !CmuxRouting.isValidSocketPath("/" + String(repeating: "a", count: 98) + ".sock"))
        check("socket: relative, no suffix, empty refused",
              !CmuxRouting.isValidSocketPath("tmp/c.sock") && !CmuxRouting.isValidSocketPath("/tmp/c")
              && !CmuxRouting.isValidSocketPath(""))
        check("socket: dot-dot and space refused",
              !CmuxRouting.isValidSocketPath("/tmp/../etc/x.sock") && !CmuxRouting.isValidSocketPath("/tmp/a b.sock"))

        let okSock = "/tmp/cmux.sock"
        check("context: all valid",
              CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: "tok"))
        check("context: value starting with a dash drops everything",
              !CmuxRouting.isValidContext(surfaceId: "--help", workspaceId: "W1", socketPath: okSock, capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "-x", socketPath: okSock, capability: "tok"))
        check("context: bad socket or bad capability drops everything",
              !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: "/tmp/x", capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: "a b"))
        check("context: empty field drops everything",
              !CmuxRouting.isValidContext(surfaceId: "", workspaceId: "W1", socketPath: okSock, capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: ""))

        // ── socket file ────────────────────────────────────────────────────────
        print("CmuxRouting.isTrustedSocket")
        let uid = UInt32(getuid())
        check("socket owned by the user", CmuxRouting.isTrustedSocket(mode: UInt32(S_IFSOCK) | 0o600, owner: uid, currentUid: uid))
        check("other owner refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFSOCK) | 0o600, owner: uid + 1, currentUid: uid))
        check("regular file refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFREG) | 0o600, owner: uid, currentUid: uid))
        check("symlink refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFLNK) | 0o777, owner: uid, currentUid: uid))
        check("directory refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFDIR) | 0o700, owner: uid, currentUid: uid))

        let sockDir = "/tmp/cmuxrt-\(getpid())"
        mkdir(sockDir, 0o700)
        let sockPath = sockDir + "/real.sock"
        let linkPath = sockDir + "/link.sock"
        let filePath = sockDir + "/file.sock"
        let fdSock = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, sockPath, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fdSock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        symlink(sockPath, linkPath)
        FileManager.default.createFile(atPath: filePath, contents: Data())
        check("lstat: a real socket of the user is trusted", bound == 0 && CmuxRouting.socketFileIsTrusted(path: sockPath))
        check("lstat: a symlink to that socket is refused", !CmuxRouting.socketFileIsTrusted(path: linkPath))
        check("lstat: a regular file is refused", !CmuxRouting.socketFileIsTrusted(path: filePath))
        check("lstat: a missing path is refused", !CmuxRouting.socketFileIsTrusted(path: sockDir + "/none.sock"))
        close(fdSock)
        try? FileManager.default.removeItem(atPath: sockDir)

        // ── timing and lifecycle ───────────────────────────────────────────────
        print("CmuxRouting.inputLocked / isLateCard / mayRegister")
        check("lock window is 700 ms", CmuxRouting.promotionLock == 0.7)
        check("no promotion → never locked", !CmuxRouting.inputLocked(promotedAt: nil, now: 100))
        check("0 ms after promotion → locked", CmuxRouting.inputLocked(promotedAt: 100, now: 100))
        check("699 ms after promotion → locked", CmuxRouting.inputLocked(promotedAt: 100, now: 100.699))
        check("700 ms after promotion → free", !CmuxRouting.inputLocked(promotedAt: 100, now: 100.7))
        check("clock going backwards does not lock forever", !CmuxRouting.inputLocked(promotedAt: 100, now: 99))
        check("card shown 115 s is not late, 115.1 s is late",
              !CmuxRouting.isLateCard(arrivedAt: 0, now: 115) && CmuxRouting.isLateCard(arrivedAt: 0, now: 115.1))
        check("creating events register without a live task",
              ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "AskUserQuestion"]
                .allSatisfy { CmuxRouting.mayRegister(event: $0, taskIsLive: false) })
        check("other events do not create an entry for a dead task",
              ["PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStop", ""]
                .allSatisfy { !CmuxRouting.mayRegister(event: $0, taskIsLive: false) })
        check("any event registers for a live task",
              ["PostToolUse", "Stop", "SessionEnd"].allSatisfy { CmuxRouting.mayRegister(event: $0, taskIsLive: true) })
        check("requirement pins identifier and team",
              CmuxRouting.codeRequirement.contains("com.cmuxterm.app") && CmuxRouting.codeRequirement.contains("7WLXT3NR37")
              && CmuxRouting.codeRequirement.hasPrefix("anchor apple generic"))

        print(failures == 0 ? "\nAll cmux routing tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
