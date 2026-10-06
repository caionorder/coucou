import AppKit
import Security

#if !APPSTORE

/// Brings the exact cmux workspace and surface of a task to the front.
@MainActor
enum CmuxJump {
    /// true when the task is a cmux task and the cmux app was activated (exact focus is best effort, async).
    /// The CLI runs only from a bundle signed by cmux's team, with a trusted socket file.
    static func jump(for task: AgentTask) -> Bool {
        guard CmuxRouting.isCmuxTaskId(task.id) else { return false }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == CmuxRouting.bundleId
        }
        guard let app = candidates.first else { return false }
        app.activate(options: .activateIgnoringOtherApps)

        // Ids or token missing: cmux is in front on whatever surface it had.
        guard let s = HookServer.shared.cmuxSurface(for: task.id), s.canFocusExactly,
              CmuxRouting.isValidSocketPath(s.socketPath) else { return true }
        let bundles = candidates.compactMap { $0.bundleURL }
        let workspace = s.workspaceId, surface = s.surfaceId
        DispatchQueue.global(qos: .userInitiated).async {
            // The signature check hashes the bundle and the peer check blocks up to a second: keep both
            // off the main thread. Only a bundle that passes the check is ever executed, and the token
            // is put in the environment only after the socket file and its listener are verified.
            guard let bundle = bundles.first(where: bundleIsCmux) else {
                appendAppLog("nb.log", "cmux focus skipped: app signature not verified")
                return
            }
            let cli = bundle.appendingPathComponent("Contents/Resources/bin/cmux")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
            // The capability goes through the child's environment only, never argv, never logged.
            guard case .success(let env) = CmuxControl.verifiedEnvironment(for: .token(s)) else {
                appendAppLog("nb.log", "cmux focus skipped: socket not verified")
                return
            }
            let first = CmuxControl.run(cli: cli, args: ["select-workspace", "--workspace", workspace], env: env).status
            if first != 0 { appendAppLog("nb.log", "cmux focus failed rc=\(first)"); return }
            let second = CmuxControl.run(cli: cli, args: ["focus-panel", "--panel", surface, "--workspace", workspace], env: env).status
            if second != 0 { appendAppLog("nb.log", "cmux focus failed rc=\(second)") }
        }
        return true
    }

    /// True when the bundle satisfies the cmux requirement (Developer ID, team 7WLXT3NR37).
    nonisolated static func bundleIsCmux(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(CmuxRouting.codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

#endif
