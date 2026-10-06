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

        // ── pillLabel ──────────────────────────────────────────────────────────
        print("CmuxRouting.pillLabel")
        check("name, role and tag cut to the name",
              CmuxRouting.pillLabel("Proteus (Swift Implementer) [names]") == "Proteus")
        check("bracket after space", CmuxRouting.pillLabel("Zeus [codex]") == "Zeus")
        check("plain title kept whole", CmuxRouting.pillLabel("cmux") == "cmux")
        check("title with spaces but no marker kept", CmuxRouting.pillLabel("Integração com cmux") == "Integração com cmux")
        check("no space before paren kept", CmuxRouting.pillLabel("coucou(feat)") == "coucou(feat)")
        check("marker at start kept whole", CmuxRouting.pillLabel(" (x)") == " (x)")
        check("empty and short", CmuxRouting.pillLabel("") == "" && CmuxRouting.pillLabel("a") == "a")
        check("multi word head", CmuxRouting.pillLabel("My project (x)") == "My project")

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
        let rotated = reg.note(taskId: "t1", surfaceId: "s2", workspaceId: "w2", socketPath: "/tmp/c.sock",
                               capability: "tok2", sessionId: "", now: 30)
        check("new capability on the same socket replaces the whole unit",
              rotated && reg.surface(for: "t1")?.capability == "tok2" && reg.surface(for: "t1")?.surfaceId == "s2"
              && reg.surface(for: "t1")?.workspaceId == "w2" && reg.surface(for: "t1")?.socketPath == "/tmp/c.sock")
        let moved = reg.note(taskId: "t1", surfaceId: "s3", workspaceId: "w3", socketPath: "/tmp/d.sock",
                             capability: "tok3", sessionId: "", now: 35, isStoredSocketTrusted: { _ in true })
        check("live entry: a different socket path refuses the whole unit while the stored socket is trusted",
              !moved && reg.surface(for: "t1")?.socketPath == "/tmp/c.sock" && reg.surface(for: "t1")?.capability == "tok2"
              && reg.surface(for: "t1")?.surfaceId == "s2" && reg.surface(for: "t1")?.workspaceId == "w2")
        var rb = CmuxRegistry()
        rb.note(taskId: "x", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock", capability: "T", sessionId: "", now: 1)
        rb.clearCredentials()
        check("entry without a live token accepts a new socket path (cmux restarted)",
              rb.note(taskId: "x", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/e.sock", capability: "T2", sessionId: "", now: 2)
              && rb.surface(for: "x")?.socketPath == "/tmp/e.sock")
        var rg = reg
        let healed = rg.note(taskId: "t1", surfaceId: "s4", workspaceId: "w4", socketPath: "/tmp/d.sock",
                             capability: "tok4", sessionId: "", now: 36, isStoredSocketTrusted: { _ in false })
        check("live entry: the new unit is accepted when the stored socket file is gone or not a user socket",
              healed && rg.surface(for: "t1")?.socketPath == "/tmp/d.sock" && rg.surface(for: "t1")?.capability == "tok4")
        check("trust is asked about the stored path, not the new one",
              { var asked: [String] = []
                var r2 = reg
                r2.note(taskId: "t1", surfaceId: "s5", workspaceId: "w5", socketPath: "/tmp/z.sock",
                        capability: "t5", sessionId: "", now: 37, isStoredSocketTrusted: { asked.append($0); return true })
                return asked == ["/tmp/c.sock"] }())
        reg.note(taskId: "t1", surfaceId: "evil", workspaceId: "evil", socketPath: "/tmp/evil.sock",
                 capability: "", sessionId: "sess2", now: 40)
        check("no capability: socket, ids and token unchanged",
              reg.surface(for: "t1")?.socketPath == "/tmp/c.sock" && reg.surface(for: "t1")?.surfaceId == "s2"
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


        // ── cmux as Main: reply, new chat, icons ───────────────────────────────
        do {
        print("hub pill id")
        check("hub id is not a cmux task id", !CmuxRouting.isCmuxTaskId(CmuxRouting.hubPillId))
        check("taskId never returns the hub id",
              CmuxRouting.taskId(payload: ["cmux_surface_id": "integration_cmux"]) != CmuxRouting.hubPillId
              && CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "integration_cmux"]) != CmuxRouting.hubPillId)

        print("fnv1a / appearance")
        check("fnv1a empty", CmuxRouting.fnv1a("") == 0xcbf29ce484222325)
        check("fnv1a a", CmuxRouting.fnv1a("a") == 0xaf63dc4c8601ec8c)
        let a1 = CmuxRouting.appearance(key: "abc", takenColors: [])
        let a2 = CmuxRouting.appearance(key: "abc", takenColors: [])
        let sameColor = a1.color == a2.color
        let sameEye = a1.eye == a2.eye
        check("appearance deterministic", sameColor && sameEye)
        let a3 = CmuxRouting.appearance(key: "abc", takenColors: [a1.color])
        check("taken colour is skipped", a3.color != a1.color && CmuxRouting.palette.contains(a3.color))
        check("eye of the probed result is unchanged", a3.eye == a1.eye)
        check("all 8 taken → base colour",
              CmuxRouting.appearance(key: "abc", takenColors: Set(CmuxRouting.palette)).color == a1.color)
        var live = Set<String>()
        var distinct = true
        for i in 0..<8 {
            let c = CmuxRouting.appearance(key: "surface-\(i)", takenColors: live).color
            if live.contains(c) { distinct = false }
            live.insert(c)
        }
        check("8 live sessions get 8 different colours", distinct && live.count == 8)
        check("eye always in the list",
              (0..<200).allSatisfy { CmuxRouting.eyes.contains(CmuxRouting.appearance(key: "k\($0)", takenColors: []).eye) })

        print("preparePrompt")
        check("newline, CR, tab become spaces",
              CmuxRouting.preparePrompt("a\nb\rc\td") == "a b c d")
        check("ESC, 0x03, 0x7F become spaces",
              CmuxRouting.preparePrompt("x\u{1B}y\u{03}z\u{7F}w") == "x y z w")
        check("C1 control becomes a space", CmuxRouting.preparePrompt("a\u{85}b") == "a b")
        check("literal backslash-n kept", CmuxRouting.preparePrompt("a\\nb") == "a\\nb")
        check("quotes, $(), backticks, ; kept verbatim",
              CmuxRouting.preparePrompt("say \"hi\" $(id) `ls`; 'x'") == "say \"hi\" $(id) `ls`; 'x'")
        check("whitespace only → nil", CmuxRouting.preparePrompt(" \n\t ") == nil && CmuxRouting.preparePrompt("") == nil)
        check("capped at 8000", CmuxRouting.preparePrompt(String(repeating: "a", count: 9000))?.count == 8000)

        print("isValidLaunchCommand / isValidFolder")
        check("accepts claude", CmuxRouting.isValidLaunchCommand("claude"))
        check("accepts flag", CmuxRouting.isValidLaunchCommand("claude --dangerously-skip-permissions"))
        check("accepts path and =", CmuxRouting.isValidLaunchCommand("/opt/bin/claude --model=opus"))
        check("rejects empty", !CmuxRouting.isValidLaunchCommand(""))
        check("rejects shell syntax",
              [";", "&&", "|", "$", "`", "\"", "'", "\n", "(", ">", "\\"].allSatisfy { !CmuxRouting.isValidLaunchCommand("claude\($0)x") })
        check("rejects leading dash", !CmuxRouting.isValidLaunchCommand("-claude"))
        check("rejects an environment prefix (= in the first token)",
              !CmuxRouting.isValidLaunchCommand("ANTHROPIC_BASE_URL=http://host claude")
              && !CmuxRouting.isValidLaunchCommand("A=b")
              && CmuxRouting.isValidLaunchCommand("claude --model=opus"))
        check("121 chars rejected, 120 accepted",
              !CmuxRouting.isValidLaunchCommand(String(repeating: "a", count: 121))
              && CmuxRouting.isValidLaunchCommand(String(repeating: "a", count: 120)))
        check("folder absolute ok", CmuxRouting.isValidFolder("/Users/me/Dev/app"))
        check("folder relative rejected", !CmuxRouting.isValidFolder("Dev/app"))
        check("folder .. rejected", !CmuxRouting.isValidFolder("/Users/me/../root"))
        check("folder control char rejected", !CmuxRouting.isValidFolder("/Users/me\n/x"))
        check("folder C1 control char rejected", !CmuxRouting.isValidFolder("/Users/me/\u{85}x") && !CmuxRouting.isValidFolder("/Users/me/\u{9F}x"))
        check("folder DEL rejected", !CmuxRouting.isValidFolder("/Users/me/\u{7F}x"))
        check("folder with accents ok", CmuxRouting.isValidFolder("/Users/me/Projetos/açaí"))
        check("existing folder: / yes, missing no, invalid no",
              CmuxRouting.isExistingFolder("/tmp") && !CmuxRouting.isExistingFolder("/no/such/dir/at/all")
              && !CmuxRouting.isExistingFolder("tmp") && !CmuxRouting.isExistingFolder("/tmp/../etc"))
        check("chip labels: last component, parent when two share it",
              CmuxRouting.chipLabels(for: ["/a/x/coucou", "/b/y/api", "/c/z/coucou"]) == ["x/coucou", "api", "z/coucou"]
              && CmuxRouting.chipLabels(for: ["/a/app", "/b/web"]) == ["app", "web"])
        check("folder over 1024 bytes rejected", !CmuxRouting.isValidFolder("/" + String(repeating: "a", count: 1030)))

        print("rpcParams")
        check("invalid ids give nil",
              CmuxRouting.rpcParams(workspaceId: "", surfaceId: "s1", text: "x") == nil
              && CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "a b", text: "x") == nil
              && CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "../x", key: "enter") == nil)
        let nasty = "q\"uote \\ back $(id) `x` é 🙂 \\n"
        if let p = CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "s1", text: nasty),
           let data = try? JSONSerialization.data(withJSONObject: p),
           let back = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            check("text round trips byte for byte", back["text"] == nasty && back["surface_id"] == "s1")
        } else { check("text round trips byte for byte", false) }
        check("key params", CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "s1", key: "enter")?["key"] == "enter")

        print("credential / clearCredentials")
        var cr = CmuxRegistry()
        cr.note(taskId: "a", surfaceId: "sa", workspaceId: "w", socketPath: "/s.sock", capability: "TA", sessionId: "x", now: 10)
        cr.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB", sessionId: "y", now: 20)
        cr.note(taskId: "c", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "z", now: 30)
        if case .token(let s) = cr.credential(for: "a", hasPassword: true) { check("own token wins", s.taskId == "a") }
        else { check("own token wins", false) }
        if case .token(let s) = cr.credential(for: "c", hasPassword: true) { check("entry without token → freshest other", s.taskId == "b") }
        else { check("entry without token → freshest other", false) }
        if case .token(let s) = cr.credential(for: nil, hasPassword: false) { check("no target → freshest token", s.taskId == "b") }
        else { check("no target → freshest token", false) }
        cr.clearCredentials()
        check("clear keeps entries and ids, empties tokens",
              cr.surfaces.count == 3 && cr.surface(for: "a")?.surfaceId == "sa"
              && cr.surface(for: "a")?.capability == "" && cr.surface(for: "a")?.canFocusExactly == false)
        check("password when no token", cr.credential(for: "a", hasPassword: true) == .password)
        check("none without token or password", cr.credential(for: "a", hasPassword: false) == CmuxCredential.none)

        print("staleTaskIds busy")
        var sb = CmuxRegistry()
        sb.note(taskId: "busy", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        sb.note(taskId: "idle", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        sb.note(taskId: "held", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        check("busy at 31 min kept, idle stale",
              sb.staleTaskIds(now: 31 * 60, protected: ["held"], busy: ["busy"]) == ["idle"])
        check("busy at 6 h + 1 s stale, protected never",
              sb.staleTaskIds(now: 6 * 3600 + 1, protected: ["held"], busy: ["busy"]) == ["busy", "idle"])

        print("CmuxPendingLaunch")
        let pl = CmuxPendingLaunch(workspaceId: "AB12", socketPath: "/s.sock", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("workspace and socket match", pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("workspace id compared case insensitively", pl.matches(workspaceId: "ab12", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("workspace mismatch", !pl.matches(workspaceId: "W2", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("socket path mismatch", !pl.matches(workspaceId: "AB12", socketPath: "/other.sock", isNewTask: true, now: 105))
        check("empty incoming workspace id never matches", !pl.matches(workspaceId: "", socketPath: "/s.sock", isNewTask: true, now: 105))
        let unresolved = CmuxPendingLaunch(workspaceId: "", socketPath: "/s.sock", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("empty stored workspace id never matches, even with an empty one",
              !unresolved.matches(workspaceId: "", socketPath: "/s.sock", isNewTask: true, now: 105)
              && !unresolved.matches(workspaceId: "Z", socketPath: "/s.sock", isNewTask: true, now: 105))
        let noSocket = CmuxPendingLaunch(workspaceId: "AB12", socketPath: "", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("password mode (no socket path) is not auto sendable",
              !noSocket.autoSendable && !noSocket.matches(workspaceId: "AB12", socketPath: "", isNewTask: true, now: 105))
        check("autoSendable needs both", pl.autoSendable && !unresolved.autoSendable)
        check("existing task (/clear) never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: false, now: 105))
        check("expired never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 191))
        check("90 s boundary still matches", pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 190))
        check("clock before creation never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 99))
        check("folder match only for a launch started with the password (no socket path)",
              noSocket.matchesFolder(cwd: "/a/b/", isNewTask: true, now: 105)
              && !unresolved.matchesFolder(cwd: "/a/b", isNewTask: true, now: 105)
              && !pl.matchesFolder(cwd: "/a/b", isNewTask: true, now: 105))
        check("folder match: other folder, existing task, expired, empty cwd all refused",
              !noSocket.matchesFolder(cwd: "/a/c", isNewTask: true, now: 105)
              && !noSocket.matchesFolder(cwd: "/a/b", isNewTask: false, now: 105)
              && !noSocket.matchesFolder(cwd: "/a/b", isNewTask: true, now: 191)
              && !noSocket.matchesFolder(cwd: "", isNewTask: true, now: 105))
        check("folder notice names the session",
              CmuxRouting.folderDraftNotice(sessionName: "Hera (Code Reviewer)")
                == "claude started in Hera (Code Reviewer). Check the prompt and press Send."
              && CmuxRouting.folderDraftNotice(sessionName: "") == "claude started in the new session. Check the prompt and press Send.")

        print("workspace ref / UUID parsers")
        let wsUUID = "7A1B2C3D-0000-4abc-8def-0123456789AB"
        check("ref from stdout", CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:10\n") == "workspace:10")
        check("ref: none, junk, empty digits",
              CmuxRouting.workspaceRef(inNewWorkspaceOutput: "") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "Error: nope") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:1a") == nil)
        check("ref: anchored, the first token is OK and the second is the ref",
              CmuxRouting.workspaceRef(inNewWorkspaceOutput: "workspace:3") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "x workspace:3 y") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK /tmp/x workspace:3 y") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "ERR workspace:3") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:3 workspace:4") == "workspace:3"
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "  OK\tworkspace:12\r\n") == "workspace:12")
        let listJSON = "{\"workspaces\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"ref\":\"workspace:9\",\"title\":\"a\",\"current_directory\":\"/x\"},{\"id\":\"\(wsUUID)\",\"ref\":\"workspace:10\",\"title\":\"b\",\"current_directory\":\"/y\"}]}"
        check("UUID from the list by ref", CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: listJSON) == wsUUID)
        check("UUID: unknown ref, bad JSON, id that is not a UUID",
              CmuxRouting.workspaceId(forRef: "workspace:11", inListJSON: listJSON) == nil
              && CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "not json") == nil
              && CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "{\"workspaces\":[{\"id\":\"workspace:10\",\"ref\":\"workspace:10\"}]}") == nil)
        check("UUID under a result wrapper",
              CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "{\"result\":\(listJSON)}") == wsUUID)

        print("sendCredential (never the password)")
        var sc = CmuxRegistry()
        sc.note(taskId: "a", surfaceId: "sa", workspaceId: "w", socketPath: "/s.sock", capability: "TA", sessionId: "", now: 10)
        sc.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB", sessionId: "", now: 20)
        sc.note(taskId: "o", surfaceId: "so", workspaceId: "w", socketPath: "/other.sock", capability: "TO", sessionId: "", now: 30)
        if case .token(let t) = sc.sendCredential(for: "a") { check("own token", t.taskId == "a") } else { check("own token", false) }
        check("unknown task: none", sc.sendCredential(for: "zzz") == CmuxCredential.none)
        sc.clearCredentials()
        check("no token anywhere: none, even with a password stored", sc.sendCredential(for: "a") == CmuxCredential.none)
        sc.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB2", sessionId: "", now: 40)
        if case .token(let t) = sc.sendCredential(for: "a") { check("no own token: freshest on the same socket", t.taskId == "b") }
        else { check("no own token: freshest on the same socket", false) }
        sc.note(taskId: "o", surfaceId: "so", workspaceId: "w", socketPath: "/other.sock", capability: "TO2", sessionId: "", now: 50)
        if case .token(let t) = sc.sendCredential(for: "a") { check("a fresher token on another socket is not used", t.taskId == "b") }
        else { check("a fresher token on another socket is not used", false) }
        var sd = CmuxRegistry()
        sd.note(taskId: "d", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "x", now: 1)
        sd.note(taskId: "e", surfaceId: "se", workspaceId: "w", socketPath: "/s.sock", capability: "TE", sessionId: "", now: 2)
        check("entry that never had a socket: none", sd.sendCredential(for: "d") == CmuxCredential.none)
        check("password is never a send credential",
              ["a", "b", "o", "zzz"].allSatisfy { sc.sendCredential(for: $0) != .password })

        print("shouldFocusNewSession / nextFocus / canSend")
        let hub = CmuxRouting.hubPillId
        check("hub main, focus nil, allowed", CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: nil, viewAllowsSteal: true))
        check("hub main, focus hub, allowed", CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: hub, viewAllowsSteal: true))
        check("hub main, focus on a session, never", !CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: "agent_cmux_x", viewAllowsSteal: true))
        check("view does not allow", !CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: nil, viewAllowsSteal: false))
        check("VS Code main never", !CmuxRouting.shouldFocusNewSession(mainPillId: "integration_claude", focusId: nil, viewAllowsSteal: true))
        check("nextFocus: most recent remaining",
              CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: hub,
                                    candidates: [(id: "a", lastSeen: 1), (id: "b", lastSeen: 5), (id: "c", lastSeen: 9)]) == "b")
        check("nextFocus: none left → hub", CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: hub, candidates: [(id: "c", lastSeen: 9)]) == hub)
        check("nextFocus: VS Code main → main",
              CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: "integration_claude", candidates: [(id: "a", lastSeen: 1)]) == "integration_claude")
        check("canSend", CmuxRouting.canSend(state: "idle", holdsCard: false) && CmuxRouting.canSend(state: "thinking", holdsCard: false)
              && !CmuxRouting.canSend(state: "approval", holdsCard: false) && !CmuxRouting.canSend(state: "question", holdsCard: false)
              && !CmuxRouting.canSend(state: "idle", holdsCard: true))
        check("canSend false while a dialog may be open in the terminal",
              !CmuxRouting.canSend(state: "working", holdsCard: false, dialogMayBeOpen: true)
              && CmuxRouting.canSend(state: "working", holdsCard: false, dialogMayBeOpen: false))

        print("dialogResolved (marker of a dialog left in the terminal)")
        let permMark = CmuxRouting.DialogMark(tool: "Bash", inputKey: "{\"command\":\"ls\"}")
        let askMark = CmuxRouting.DialogMark(tool: "AskUserQuestion", inputKey: nil)
        check("matching PostToolUse / PostToolUseFailure resolves",
              CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Bash", inputKey: "{\"command\":\"ls\"}")
              && CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUseFailure", tool: "Bash", inputKey: "{\"command\":\"ls\"}"))
        check("another tool or another input does not resolve",
              !CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Read", inputKey: "{\"command\":\"ls\"}")
              && !CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Bash", inputKey: "{\"command\":\"rm\"}"))
        check("Stop, StopFailure, UserPromptSubmit, SessionEnd, SessionStart resolve",
              ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "SessionStart"].allSatisfy {
                  CmuxRouting.dialogResolved(mark: permMark, event: $0, tool: "", inputKey: "") })
        check("PreToolUse, Notification, SubagentStop, Interrupt do not resolve",
              ["PreToolUse", "Notification", "SubagentStop", "SubagentStart", "Interrupt", "PermissionRequest"].allSatisfy {
                  !CmuxRouting.dialogResolved(mark: permMark, event: $0, tool: "Bash", inputKey: "{\"command\":\"ls\"}") })
        check("question mark: any PostToolUse of AskUserQuestion resolves, other tools do not",
              CmuxRouting.dialogResolved(mark: askMark, event: "PostToolUse", tool: "AskUserQuestion", inputKey: "anything")
              && !CmuxRouting.dialogResolved(mark: askMark, event: "PostToolUse", tool: "Bash", inputKey: ""))

        print("prune / eviction protection, answer in place, launch focus")
        check("pruneProtected adds the open reply task",
              CmuxRouting.pruneProtected(holdingCard: ["a"], openReplyTask: "b") == ["a", "b"]
              && CmuxRouting.pruneProtected(holdingCard: ["a"], openReplyTask: nil) == ["a"])
        check("evictableIdle drops the open reply task",
              CmuxRouting.evictableIdle(["a", "b"], openReplyTask: "a") == ["b"]
              && CmuxRouting.evictableIdle(["a", "b"], openReplyTask: nil) == ["a", "b"])
        var ev = CmuxRegistry()
        for i in 0..<7 { ev.note(taskId: "t\(i)", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: Double(i)) }
        check("eviction never picks the open reply task even when it is the oldest",
              ev.evictionCandidates(idle: CmuxRouting.evictableIdle(["t0", "t1", "t2"], openReplyTask: "t0"), keep: "t6") == ["t1"])
        check("stale prune never picks the open reply task",
              ev.staleTaskIds(now: 99999, protected: CmuxRouting.pruneProtected(holdingCard: [], openReplyTask: "t0")).contains("t0") == false)
        check("answer stays in the reply view of that session only",
              CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "a", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "b", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "a", viewIsPrompt: false)
              && !CmuxRouting.answerStaysInReply(prompt: .newChat, taskId: "a", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: nil, taskId: "a", viewIsPrompt: true))
        check("matched launch takes focus only from the New chat view with no card open",
              CmuxRouting.launchMayTakeFocus(cardOpen: false, promptIsNewChat: true)
              && !CmuxRouting.launchMayTakeFocus(cardOpen: true, promptIsNewChat: true)
              && !CmuxRouting.launchMayTakeFocus(cardOpen: false, promptIsNewChat: false))

        print("recentFolders / firstUUID")
        check("recent: most recent first, deduped",
              CmuxRouting.recentFolders(adding: "/b", to: ["/a", "/b", "/c"]) == ["/b", "/a", "/c"])
        check("recent: capped at 8",
              CmuxRouting.recentFolders(adding: "/n", to: (0..<12).map { "/f\($0)" }).count == 8)
        let u1 = "0A1B2C3D-4e5f-6789-abcd-ef0123456789"
        check("isUUID", CmuxRouting.isUUID(u1) && !CmuxRouting.isUUID("workspace:3") && !CmuxRouting.isUUID("")
              && !CmuxRouting.isUUID(u1 + "0") && !CmuxRouting.isUUID("0A1B2C3D_4e5f-6789-abcd-ef0123456789")
              && !CmuxRouting.isUUID("0G1B2C3D-4e5f-6789-abcd-ef0123456789"))

        // ── EOF of a card, tab title, folder and branch, socket peer ───────────
        print("EOF of a young card")
        check("EOF younger than the late age: answered in the terminal, no marker",
              !CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 130)
              && !CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 215))
        check("EOF older than the late age may leave a dialog open",
              CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 216))

        print("cleanLabel / tab title")
        check("clean: format characters (Cf) dropped",
              CmuxRouting.cleanLabel("a\u{200B}b\u{200E}c\u{200F}d\u{061C}e\u{FEFF}f\u{2060}g\u{E0041}h") == "abcdefgh")
        check("clean: only format characters gives nil", CmuxRouting.cleanLabel("\u{200B}\u{200E}\u{E0041}") == nil)
        check("clean: 60 characters of combining marks are cut at 120 scalars",
              { let t = String(repeating: "e\u{301}\u{302}\u{303}\u{304}", count: 60)
                guard let r = CmuxRouting.cleanLabel(t) else { return false }
                return r.unicodeScalars.count <= 120 && r.count <= 60 && r.unicodeScalars.count >= 100 }())
        check("clean: one cluster of thousands of marks gives nil",
              CmuxRouting.cleanLabel("e" + String(repeating: "\u{301}", count: 5000)) == nil)
        check("clean: the 60 character cap still holds", CmuxRouting.cleanLabel(String(repeating: "é", count: 90))?.count == 60)
        check("title: Cf in a tab title",
              CmuxRouting.tabTitle(forSurface: "S", inListJSON: #"{"surfaces":[{"id":"S","title":"✳ Pro\u200Beus"}]}"#) == "Proeus")
        check("title: two live sessions with the same title get the suffix",
              CmuxRouting.displayName(base: "Proteus", taskId: "b", existing: [(id: "a", name: "Proteus"), (id: "b", name: "x")]) == "Proteus 2"
              && CmuxRouting.displayName(base: "Proteus", taskId: "c", existing: [(id: "a", name: "Proteus"), (id: "b", name: "Proteus 2")]) == "Proteus 3"
              && CmuxRouting.displayName(base: "Proteus", taskId: "b", existing: [(id: "a", name: "Proteus"), (id: "b", name: "Proteus 2")]) == "Proteus 2"
              && CmuxRouting.displayName(base: "Proteus", taskId: "a", existing: [(id: "a", name: "Proteus")]) == "Proteus")
        check("clean: control characters, trim, nil when empty",
              CmuxRouting.cleanLabel("  Hera\u{1B}[31m\n(Code)\u{7F}\u{85}  ") == "Hera[31m(Code)"
              && CmuxRouting.cleanLabel(" \t\n ") == nil && CmuxRouting.cleanLabel("\u{1B}\u{07}") == nil
              && CmuxRouting.cleanLabel("a\u{202E}b\u{2028}c") == "abc")
        check("clean: capped at 60",
              CmuxRouting.cleanLabel(String(repeating: "x", count: 100))?.count == 60)
        check("glyph prefix stripped",
              CmuxRouting.stripLeadingGlyphs("◐ Hera (Code Reviewer)") == "Hera (Code Reviewer)"
              && CmuxRouting.stripLeadingGlyphs("✳ Zeus") == "Zeus"
              && CmuxRouting.stripLeadingGlyphs("✶  ⠂ Ana") == "Ana"
              && CmuxRouting.stripLeadingGlyphs("Hera") == "Hera"
              && CmuxRouting.stripLeadingGlyphs("3rd run") == "3rd run"
              && CmuxRouting.stripLeadingGlyphs("★ ✦") == "")
        let sid = "786BDC8E-A27B-4555-83FE-2734DA1721CC"
        let surfJSON = "{\"surfaces\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"title\":\"other\"},{\"id\":\"\(sid)\",\"title\":\"✳ Hera (Code Reviewer) [re-review 2]\",\"focused\":true},{\"id\":\"22222222-2222-4222-8222-222222222222\"}]}"
        check("title of the matching surface, glyph removed",
              CmuxRouting.tabTitle(forSurface: sid, inListJSON: surfJSON) == "Hera (Code Reviewer) [re-review 2]")
        check("surface id matched case insensitively",
              CmuxRouting.tabTitle(forSurface: sid.lowercased(), inListJSON: surfJSON) == "Hera (Code Reviewer) [re-review 2]")
        check("title: other surface, missing title, unknown id, empty id, bad JSON all nil",
              CmuxRouting.tabTitle(forSurface: "22222222-2222-4222-8222-222222222222", inListJSON: surfJSON) == nil
              && CmuxRouting.tabTitle(forSurface: "33333333-3333-4333-8333-333333333333", inListJSON: surfJSON) == nil
              && CmuxRouting.tabTitle(forSurface: "", inListJSON: surfJSON) == nil
              && CmuxRouting.tabTitle(forSurface: sid, inListJSON: "nope") == nil
              && CmuxRouting.tabTitle(forSurface: sid, inListJSON: "{\"surfaces\":\"x\"}") == nil)
        check("title that is only glyphs or control characters is nil",
              CmuxRouting.tabTitle(forSurface: sid, inListJSON: "{\"surfaces\":[{\"id\":\"\(sid)\",\"title\":\"✳ \\u0007\"}]}") == nil)
        check("title: control characters removed and capped",
              CmuxRouting.tabTitle(forSurface: sid, inListJSON: "{\"surfaces\":[{\"id\":\"\(sid)\",\"title\":\"A\\u001b[2Jb\\n\(String(repeating: "z", count: 90))\"}]}")?.count == 60
              && CmuxRouting.tabTitle(forSurface: sid, inListJSON: "{\"surfaces\":[{\"id\":\"\(sid)\",\"title\":\"A\\u001b[2Jb\"}]}") == "A[2Jb")
        check("title under a result wrapper",
              CmuxRouting.tabTitle(forSurface: sid, inListJSON: "{\"result\":\(surfJSON)}") == "Hera (Code Reviewer) [re-review 2]")
        check("surface.list params need a valid workspace id",
              CmuxRouting.surfaceListParams(workspaceId: "ABC-1")?["workspace_id"] == "ABC-1"
              && CmuxRouting.surfaceListParams(workspaceId: "") == nil
              && CmuxRouting.surfaceListParams(workspaceId: "a b") == nil)
        check("refresh throttled to once per 5 s",
              CmuxRouting.metaRefreshDue(last: nil, now: 10) && !CmuxRouting.metaRefreshDue(last: 10, now: 14.9)
              && CmuxRouting.metaRefreshDue(last: 10, now: 15) && CmuxRouting.metaRefreshDue(last: 10, now: 5))

        print("git branch")
        let hash = "0123456789abcdef0123456789abcdef01234567"
        check("HEAD: branch ref", CmuxRouting.branchName(fromHEAD: "ref: refs/heads/feat/cmux-integration\n") == "feat/cmux-integration")
        check("HEAD: detached gives 7 characters", CmuxRouting.branchName(fromHEAD: hash + "\n") == "0123456")
        check("HEAD: garbage, other ref, short hash, empty are nil",
              CmuxRouting.branchName(fromHEAD: "banana") == nil && CmuxRouting.branchName(fromHEAD: "ref: refs/tags/v1") == nil
              && CmuxRouting.branchName(fromHEAD: "0123456") == nil && CmuxRouting.branchName(fromHEAD: "") == nil
              && CmuxRouting.branchName(fromHEAD: "ref: refs/heads/\n") == nil)
        check("HEAD: control characters stripped, capped at 60",
              CmuxRouting.branchName(fromHEAD: "ref: refs/heads/a\u{1B}b") == "ab"
              && CmuxRouting.branchName(fromHEAD: "ref: refs/heads/" + String(repeating: "q", count: 90))?.count == 60)
        check("gitdir pointer: absolute, relative, garbage",
              CmuxRouting.gitDirectory(fromPointer: "gitdir: /r/.git/worktrees/w\n", base: "/x") == "/r/.git/worktrees/w"
              && CmuxRouting.gitDirectory(fromPointer: "gitdir: ../r/.git/worktrees/w", base: "/x/y") == "/x/y/../r/.git/worktrees/w"
              && CmuxRouting.gitDirectory(fromPointer: "hello", base: "/x") == nil
              && CmuxRouting.gitDirectory(fromPointer: "gitdir:", base: "/x") == nil)
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("coucou-git-\(getpid())")
        try? fm.removeItem(atPath: tmp)
        func write(_ path: String, _ text: String) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        write(tmp + "/repo/.git/HEAD", "ref: refs/heads/feat/x\n")
        try? fm.createDirectory(atPath: tmp + "/repo/a/b/c", withIntermediateDirectories: true)
        check("branch: walks up from a subfolder", CmuxRouting.gitBranch(cwd: tmp + "/repo/a/b/c") == "feat/x")
        check("branch: at the repo root", CmuxRouting.gitBranch(cwd: tmp + "/repo") == "feat/x")
        write(tmp + "/det/.git/HEAD", hash + "\n")
        check("branch: detached HEAD", CmuxRouting.gitBranch(cwd: tmp + "/det") == "0123456")
        write(tmp + "/main/.git/worktrees/wt/HEAD", "ref: refs/heads/wt-branch\n")
        write(tmp + "/wt/.git", "gitdir: " + tmp + "/main/.git/worktrees/wt\n")
        check("branch: .git file pointing to a worktree gitdir", CmuxRouting.gitBranch(cwd: tmp + "/wt") == "wt-branch")
        write(tmp + "/relwt/.git", "gitdir: ../main/.git/worktrees/wt\n")
        check("branch: relative gitdir pointer", CmuxRouting.gitBranch(cwd: tmp + "/relwt") == "wt-branch")
        write(tmp + "/bad/.git/HEAD", "###\u{1}garbage")
        check("branch: garbage HEAD is nil", CmuxRouting.gitBranch(cwd: tmp + "/bad") == nil)
        write(tmp + "/badptr/.git", "not a pointer")
        check("branch: garbage .git file is nil", CmuxRouting.gitBranch(cwd: tmp + "/badptr") == nil)
        write(tmp + "/nohead/.git/config", "x")
        check("branch: .git without HEAD is nil", CmuxRouting.gitBranch(cwd: tmp + "/nohead") == nil)
        check("branch: not absolute or missing folder is nil",
              CmuxRouting.gitBranch(cwd: "relative/dir") == nil && CmuxRouting.gitBranch(cwd: "") == nil)
        check("branch: a pointer is followed once only",
              { write(tmp + "/loop/.git", "gitdir: " + tmp + "/loop2\n")
                write(tmp + "/loop2/.git", "gitdir: " + tmp + "/loop\n")
                return CmuxRouting.gitBranch(cwd: tmp + "/loop") == nil }())
        // Symlinks, FIFOs and gitdir targets
        write(tmp + "/real/HEAD", "ref: refs/heads/secret\n")
        try? fm.createDirectory(atPath: tmp + "/symhead/.git", withIntermediateDirectories: true)
        symlink(tmp + "/real/HEAD", tmp + "/symhead/.git/HEAD")
        check("branch: a symlinked HEAD is refused", CmuxRouting.gitBranch(cwd: tmp + "/symhead") == nil)
        write(tmp + "/ptrtarget/x/.git/HEAD", "ref: refs/heads/linked\n")
        try? fm.createDirectory(atPath: tmp + "/symptr", withIntermediateDirectories: true)
        write(tmp + "/ptrreal", "gitdir: " + tmp + "/ptrtarget/x/.git\n")
        symlink(tmp + "/ptrreal", tmp + "/symptr/.git")
        check("branch: a symlinked .git pointer file is refused", CmuxRouting.gitBranch(cwd: tmp + "/symptr") == nil)
        write(tmp + "/odd/target/HEAD", "ref: refs/heads/odd\n")
        write(tmp + "/oddptr/.git", "gitdir: " + tmp + "/odd/target\n")
        check("branch: a gitdir that is not a .git folder is refused", CmuxRouting.gitBranch(cwd: tmp + "/oddptr") == nil)
        write(tmp + "/bare.git/HEAD", "ref: refs/heads/bare\n")
        write(tmp + "/bareptr/.git", "gitdir: " + tmp + "/bare.git\n")
        check("branch: a gitdir ending in .git is accepted", CmuxRouting.gitBranch(cwd: tmp + "/bareptr") == "bare")
        check("gitdir plausibility",
              CmuxRouting.isPlausibleGitDir("/r/.git") && CmuxRouting.isPlausibleGitDir("/r/.git/worktrees/w")
              && CmuxRouting.isPlausibleGitDir("/r/x.git") && !CmuxRouting.isPlausibleGitDir("/etc")
              && !CmuxRouting.isPlausibleGitDir("/r/.git/../etc") && !CmuxRouting.isPlausibleGitDir("/r/.github")
              && !CmuxRouting.isPlausibleGitDir("/"))
        try? fm.createDirectory(atPath: tmp + "/fifohead/.git", withIntermediateDirectories: true)
        mkfifo(tmp + "/fifohead/.git/HEAD", 0o600)
        let fifoStart = Date()
        let fifoBranch = CmuxRouting.gitBranch(cwd: tmp + "/fifohead")
        check("branch: a FIFO named HEAD returns nil, promptly", fifoBranch == nil && Date().timeIntervalSince(fifoStart) < 2)
        try? fm.createDirectory(atPath: tmp + "/fifoptr", withIntermediateDirectories: true)
        mkfifo(tmp + "/fifoptr/.git", 0o600)
        let fifoStart2 = Date()
        let fifoBranch2 = CmuxRouting.gitBranch(cwd: tmp + "/fifoptr")
        check("branch: a FIFO named .git returns nil, promptly", fifoBranch2 == nil && Date().timeIntervalSince(fifoStart2) < 2)
        try? fm.removeItem(atPath: tmp)
        check("folder line: folder and branch, folder alone, nothing",
              CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou", branch: "feat/cmux-integration") == "coucou (feat/cmux-integration)"
              && CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou/", branch: nil) == "coucou"
              && CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou", branch: "") == "coucou"
              && CmuxRouting.folderLine(cwd: "", branch: "main") == nil
              && CmuxRouting.folderLine(cwd: "/", branch: "main") == nil)

        print("socket peer (LOCAL_PEERTOKEN, audit token)")
        let sockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("cp\(getpid()).sock")
        unlink(sockPath)
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        var la = sockaddr_un()
        la.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &la.sun_path) { raw in
            for (i, b) in Array(sockPath.utf8).enumerated() { raw[i] = b }
        }
        let bound = withUnsafePointer(to: &la) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0 && listen(lfd, 4) == 0
        if bound && CmuxRouting.isValidSocketPath(sockPath) {
            let token = CmuxRouting.socketPeerAuditToken(path: sockPath)
            check("audit token of a local listener is 32 bytes", token?.count == 32)
            check("audit token names this process", token.flatMap { CmuxRouting.pid(ofAuditToken: $0) } == getpid())
            check("a listener that is not cmux is refused", !CmuxRouting.socketPeerIsCmux(path: sockPath))
        } else {
            print("  - skipped: temp socket path not usable here")
        }
        close(lfd)
        unlink(sockPath)
        check("peer: missing socket, bad path give no token",
              CmuxRouting.socketPeerAuditToken(path: "/tmp/does-not-exist-\(getpid()).sock") == nil
              && CmuxRouting.socketPeerAuditToken(path: "relative.sock") == nil && !CmuxRouting.socketPeerIsCmux(path: ""))
        check("an unreadable or short audit token fails closed",
              !CmuxRouting.processIsCmux(auditToken: Data()) && !CmuxRouting.processIsCmux(auditToken: Data(count: 31))
              && !CmuxRouting.processIsCmux(auditToken: Data(count: 32)) && CmuxRouting.pid(ofAuditToken: Data(count: 5)) == nil)
        check("verification reuse: fresh inside 60 s, stale after, never after a backwards clock, none without a stamp",
              CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 100)
              && CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 159.9)
              && !CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 160)
              && !CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 99)
              && !CmuxRouting.verificationIsFresh(verifiedAt: nil, now: 100))
        }

        // ── launchers ──────────────────────────────────────────────────────────
        print("CmuxLauncher")
        check("four launchers in order: Claude, Codex, Grok, Agy",
              CmuxLauncher.all.map { $0.name } == ["Claude", "Codex", "Grok", "Agy"]
              && CmuxLauncher.all.map { $0.id.rawValue } == ["claude", "codex", "grok", "agy"])
        check("default commands",
              CmuxLauncher.all.map { $0.defaultCommand }
                == ["claude --dangerously-skip-permissions", "codex", "grok", "agy"])
        check("every default command passes the launch command validation",
              CmuxLauncher.all.allSatisfy { CmuxRouting.isValidLaunchCommand($0.defaultCommand) })
        check("prompt flags: only Agy has one (-i)",
              CmuxLauncher.all.map { $0.promptFlag } == ["", "", "", "-i"])
        check("only Claude reports its session start",
              CmuxLauncher.all.map { $0.reportsSessionStart } == [true, false, false, false])
        check("defaults keys are distinct, the legacy key is not one of them",
              Set(CmuxLauncher.all.map { $0.defaultsKey }).count == 4
              && !CmuxLauncher.all.map { $0.defaultsKey }.contains(CmuxLauncher.legacyDefaultsKey))
        check("launcher(id) finds each one", CmuxLauncher.Id.allCases.allSatisfy { CmuxLauncher.launcher($0).id == $0 })

        print("CmuxLauncher.resolvedCommand (migration)")
        let claude = CmuxLauncher.claude
        check("nothing stored → new Claude default", claude.resolvedCommand(stored: nil, legacy: nil) == "claude --dangerously-skip-permissions")
        check("an explicitly stored old `claude` stays `claude` (no silent permission skipping)",
              claude.resolvedCommand(stored: nil, legacy: "claude") == "claude"
              && claude.resolvedCommand(stored: "claude", legacy: nil) == "claude"
              && claude.resolvedCommand(stored: "claude", legacy: "claude --model=opus") == "claude")
        check("any other old value is kept as the Claude command",
              claude.resolvedCommand(stored: nil, legacy: "claude --model=opus") == "claude --model=opus"
              && claude.resolvedCommand(stored: nil, legacy: "Claude") == "Claude"
              && claude.resolvedCommand(stored: nil, legacy: "/opt/bin/claude") == "/opt/bin/claude")
        check("an invalid old value is not kept", claude.resolvedCommand(stored: nil, legacy: "claude; rm -rf /") == claude.defaultCommand)
        check("a stored new value wins over the legacy one",
              claude.resolvedCommand(stored: "claude -x", legacy: "claude --model=opus") == "claude -x")
        check("a stored invalid new value falls back", claude.resolvedCommand(stored: "a;b", legacy: nil) == claude.defaultCommand)
        let codex = CmuxLauncher.launcher(.codex)
        check("the legacy command never reaches another launcher",
              codex.resolvedCommand(stored: nil, legacy: "claude --model=opus") == "codex"
              && codex.resolvedCommand(stored: "codex --x", legacy: nil) == "codex --x")

        print("CmuxLauncher.acceptsPrompt / launchLine")
        let agy = CmuxLauncher.launcher(.agy)
        let grok = CmuxLauncher.launcher(.grok)
        let W = "/var/folders/ab/cd_ef-1234/T/coucou-launch/launch.sh"
        let P = "/var/folders/ab/cd_ef-1234/T/coucou-launch/prompt-0123456789abcdef0123456789abcdef.txt"
        check("launch line: /bin/sh, wrapper, prompt file, command; Agy adds -i last",
              codex.launchLine(command: "codex", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) codex"
              && grok.launchLine(command: "grok", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) grok"
              && agy.launchLine(command: "agy", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) agy -i"
              && codex.launchLine(command: "/opt/bin/codex --model=x", wrapperPath: W, promptFile: P)
                == "/bin/sh \(W) \(P) /opt/bin/codex --model=x")
        let lines = [codex, grok, agy].compactMap { $0.launchLine(command: $0.defaultCommand, wrapperPath: W, promptFile: P) }
        check("every launch line stays in the launch command charset (same meaning in sh, bash, zsh, fish)",
              lines.count == 3 && lines.allSatisfy { l in
                  l.utf8.allSatisfy { c in
                      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                          || [0x20, 0x5F, 0x2E, 0x2F, 0x3D, 0x3A, 0x2D].contains(c)
                  }
              })
        check("an invalid command produces no line",
              codex.launchLine(command: "codex; id", wrapperPath: W, promptFile: P) == nil
              && codex.launchLine(command: "", wrapperPath: W, promptFile: P) == nil
              && codex.launchLine(command: "A=b codex", wrapperPath: W, promptFile: P) == nil)
        check("an unsafe wrapper or prompt path produces no line",
              codex.launchLine(command: "codex", wrapperPath: "/tmp/a b/launch.sh", promptFile: P) == nil
              && codex.launchLine(command: "codex", wrapperPath: W, promptFile: "/tmp/it's") == nil
              && codex.launchLine(command: "codex", wrapperPath: W, promptFile: "relative/p.txt") == nil)
        check("Claude never gets a launch line (its prompt is typed after SessionStart)",
              claude.launchLine(command: "claude", wrapperPath: W, promptFile: P) == nil)
        check("isSafePath: charset, absolute, no space, no .., bounded",
              CmuxLaunchFiles.isSafePath(W) && CmuxLaunchFiles.isSafePath("/a")
              && !CmuxLaunchFiles.isSafePath("") && !CmuxLaunchFiles.isSafePath("a/b")
              && !CmuxLaunchFiles.isSafePath("/a b") && !CmuxLaunchFiles.isSafePath("/a/../b")
              && !CmuxLaunchFiles.isSafePath("/a'b") && !CmuxLaunchFiles.isSafePath("/a\\b")
              && !CmuxLaunchFiles.isSafePath("/a$b") && !CmuxLaunchFiles.isSafePath("/a\nb")
              && !CmuxLaunchFiles.isSafePath("/ação")
              && !CmuxLaunchFiles.isSafePath("/" + String(repeating: "a", count: 400)))
        check("a prompt starting with a dash is refused by every command line launcher",
              !codex.acceptsPrompt("-x") && !grok.acceptsPrompt("--help") && !agy.acceptsPrompt("-p hi")
              && !codex.acceptsPrompt("-\u{0301}x"))
        check("a dash inside the prompt is fine", codex.acceptsPrompt("fix a - b") && agy.acceptsPrompt("x-y"))
        check("a prompt that is a whole subcommand name is refused for codex and grok, not when longer",
              !codex.acceptsPrompt("exec") && !codex.acceptsPrompt("resume") && !grok.acceptsPrompt("login")
              && !grok.acceptsPrompt("update") && codex.acceptsPrompt("exec the tests") && grok.acceptsPrompt("login page")
              && codex.acceptsPrompt("Exec") && agy.acceptsPrompt("exec"))
        check("Claude accepts any prompt (it is typed, not parsed)", claude.acceptsPrompt("-x") && claude.acceptsPrompt("exec"))

        print("CmuxLaunchFiles (private directory, files, wrapper)")
        func runProcess(_ exe: String, _ args: [String]) -> (status: Int32, out: [UInt8])? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, Array(out))
        }
        func modeOf(_ path: String) -> UInt16? {
            var st = stat()
            return lstat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-launch-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        print("  real per user temporary directory: \(FileManager.default.temporaryDirectory.path)")
        check("the per user temporary directory passes the path check",
              CmuxLaunchFiles.isSafePath(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/coucou-launch/launch.sh"))
        if let prep = CmuxLaunchFiles.prepare(prompt: "hello", baseDirectory: base) {
            let dir = (prep.wrapperPath as NSString).deletingLastPathComponent
            check("directory is named coucou-launch with mode 0700", dir.hasSuffix("/coucou-launch") && modeOf(dir) == 0o700)
            check("wrapper has mode 0700 and the exact script text",
                  modeOf(prep.wrapperPath) == 0o700
                  && (try? String(contentsOfFile: prep.wrapperPath, encoding: .utf8)) == CmuxLaunchFiles.wrapperScript)
            check("prompt file has mode 0600, a random name, and the exact prompt",
                  modeOf(prep.promptFile) == 0o600 && prep.promptFile.hasPrefix(dir + "/prompt-")
                  && (try? String(contentsOfFile: prep.promptFile, encoding: .utf8)) == "hello")
            let second = CmuxLaunchFiles.prepare(prompt: "hello", baseDirectory: base)
            check("a second launch gets another prompt file and the same wrapper",
                  second != nil && second!.promptFile != prep.promptFile && second!.wrapperPath == prep.wrapperPath)
            // Stale files: older than 10 minutes go at the next launch, fresh ones stay.
            let old = dir + "/old.txt", fresh = dir + "/fresh.txt"
            FileManager.default.createFile(atPath: old, contents: Data("x".utf8))
            FileManager.default.createFile(atPath: fresh, contents: Data("x".utf8))
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: old)
            _ = CmuxLaunchFiles.prepare(prompt: "again", baseDirectory: base)
            check("files older than 10 minutes are deleted at the next launch, fresh ones are kept",
                  !FileManager.default.fileExists(atPath: old) && FileManager.default.fileExists(atPath: fresh)
                  && FileManager.default.fileExists(atPath: prep.promptFile))
            CmuxLaunchFiles.discard(prep.promptFile)
            check("discard removes the prompt file", !FileManager.default.fileExists(atPath: prep.promptFile))
        } else { check("prepare works in a private base directory", false) }
        check("an empty prompt prepares nothing", CmuxLaunchFiles.prepare(prompt: "", baseDirectory: base) == nil)
        // Fail closed: a directory with group/other permission, a symlink, a base path with a space.
        let loose = base.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: loose.appendingPathComponent("coucou-launch"), withIntermediateDirectories: true)
        chmod(loose.path + "/coucou-launch", 0o755)
        check("a coucou-launch directory with group/other permission fails closed",
              CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: loose) == nil)
        let linkBase = base.appendingPathComponent("linked")
        try? FileManager.default.createDirectory(at: linkBase, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: linkBase.path + "/coucou-launch", withDestinationPath: base.path)
        check("a coucou-launch symlink fails closed", CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: linkBase) == nil)
        let spaced = base.appendingPathComponent("with space")
        try? FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        check("a temporary directory path with a space fails closed",
              CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: spaced) == nil
              && !FileManager.default.fileExists(atPath: spaced.path + "/coucou-launch"))

        // The real wrapper under /bin/sh, with a stub agent that writes its argv (NUL separated) to argv.bin next to itself.
        print("CmuxLaunchFiles.wrapperScript (real /bin/sh, stub agent)")
        let stubDir = base.appendingPathComponent("stub")
        try? FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let stub = stubDir.path + "/agent"
        let outFile = stubDir.path + "/argv.bin"
        FileManager.default.createFile(atPath: stub, contents: Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$(dirname \"$0\")/argv.bin\"\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        let promptCases: [(String, String)] = [
            ("plain", "fix the login bug"),
            ("quotes", "don't \"x\" ''' ` '"),
            ("backslashes", "a\\b \\\\ \\n \\' \\\""),
            ("dollar parens", "$(touch \(stubDir.path)/PWNED) $HOME ${PATH} $((1+1))"),
            ("backticks", "`touch \(stubDir.path)/PWNED2` ``"),
            ("trailing backslash", "ends with a backslash \\"),
            ("leading space", "  leading spaces"),
            ("shell syntax", "a; b | c && d > e < f & # g * ? [a-z] ~ !! {a,b}"),
            ("looks like an option", "x --dangerously-skip-permissions -i"),
            ("unicode", "olá, ação ✓ 日本語 🙂 e\u{0301} \u{00E1}"),
            ("embedded newline", "line one\nline two"),
            ("trailing newlines", "text\n\n"),
            ("only a quote", "'"),
            ("8000 characters", String(String(repeating: "word 'q' \\ $x ", count: 800).prefix(CmuxRouting.maxPromptLength))),
        ]
        var wrapperOK = true
        var wrapperFirstBad = ""
        for (label, text) in promptCases {
            // Newlines are stripped upstream by preparePrompt; the file is written raw here to show it holds anyway.
            guard let prep = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base),
                  (try? Data(text.utf8).write(to: URL(fileURLWithPath: prep.promptFile))) != nil else {
                wrapperOK = false; wrapperFirstBad = label; break
            }
            try? FileManager.default.removeItem(atPath: outFile)
            guard let r = runProcess("/bin/sh", [prep.wrapperPath, prep.promptFile, stub, "-i"]) else {
                wrapperOK = false; wrapperFirstBad = label; break
            }
            let got = (try? Data(contentsOf: URL(fileURLWithPath: outFile))).map { Array($0) } ?? []
            let want = Array("-i".utf8) + [0] + Array(text.utf8) + [0]
            if r.status != 0 || got != want || FileManager.default.fileExists(atPath: prep.promptFile) {
                wrapperOK = false; wrapperFirstBad = label; break
            }
        }
        check("wrapper under /bin/sh passes each prompt as ONE last argument, byte for byte, and removes the file"
              + " (\(promptCases.count) cases)" + (wrapperOK ? "" : " (first mismatch: \(wrapperFirstBad))"), wrapperOK)
        check("no command was executed by the dollar paren and backtick prompts",
              !FileManager.default.fileExists(atPath: stubDir.path + "/PWNED")
              && !FileManager.default.fileExists(atPath: stubDir.path + "/PWNED2"))
        try? FileManager.default.removeItem(atPath: outFile)
        if let missing = runProcess("/bin/sh", [W, "/nonexistent/prompt.txt", stub]) {
            check("a missing prompt file: the wrapper exits and starts nothing", missing.status != 0 && !FileManager.default.fileExists(atPath: outFile))
        }
        if let wrapper = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base)?.wrapperPath,
           let missing = runProcess("/bin/sh", [wrapper, "/nonexistent/prompt.txt", stub]) {
            check("the real wrapper with a missing prompt file exits 1 and starts nothing",
                  missing.status == 1 && !FileManager.default.fileExists(atPath: outFile))
        }
        // The typed line, read by each shell with -c: hostile prompt, delivered as one argument.
        func lineRun(_ shell: String, _ args: [String]) -> Bool {
            guard let prep = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base) else { return false }
            let text = "it's $(id) `id` \\' \\\\ ; & | > done \\"
            guard (try? Data(text.utf8).write(to: URL(fileURLWithPath: prep.promptFile))) != nil else { return false }
            let command = stub
            guard let line = CmuxLauncher.launcher(.agy).launchLine(command: command, wrapperPath: prep.wrapperPath, promptFile: prep.promptFile)
            else { return false }
            try? FileManager.default.removeItem(atPath: outFile)
            guard let r = runProcess(shell, args + [line]), r.status == 0 else { return false }
            let got = (try? Data(contentsOf: URL(fileURLWithPath: outFile))).map { Array($0) } ?? []
            return got == Array("-i".utf8) + [0] + Array(text.utf8) + [0] && !FileManager.default.fileExists(atPath: prep.promptFile)
        }
        for (shell, args) in [("/bin/zsh", ["-f", "-c"]), ("/bin/bash", ["-c"]), ("/bin/sh", ["-c"])] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { print("  - skipped: \(shell) not installed"); continue }
            check("the typed line run by \(shell) -c delivers the hostile prompt as one argument", lineRun(shell, args))
        }
        if let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            check("the typed line run by \(fish) -c delivers the hostile prompt as one argument", lineRun(fish, ["-c"]))
        } else {
            print("  - fish NOT RUN: neither /opt/homebrew/bin/fish nor /usr/local/bin/fish exists on this machine")
        }

        print(failures == 0 ? "\nAll cmux routing tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
