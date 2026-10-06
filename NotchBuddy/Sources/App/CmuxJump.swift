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
              CmuxRouting.isValidSocketPath(s.socketPath),
              CmuxRouting.socketFileIsTrusted(path: s.socketPath) else { return true }
        let bundles = candidates.compactMap { $0.bundleURL }

        // The capability goes through the child's environment only, never argv, never logged.
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "CMUX_SOCKET_PATH": s.socketPath,
            "CMUX_SOCKET_CAPABILITY": s.capability,
            "CMUX_WORKSPACE_ID": s.workspaceId,
            "CMUX_SURFACE_ID": s.surfaceId,
        ]
        let workspace = s.workspaceId, surface = s.surfaceId
        DispatchQueue.global(qos: .userInitiated).async {
            // The signature check hashes the bundle: keep it off the main thread.
            // Only a bundle that passes the check is ever executed; otherwise cmux was just activated.
            guard let bundle = bundles.first(where: bundleIsCmux) else {
                appendAppLog("nb.log", "cmux focus skipped: app signature not verified")
                return
            }
            let cli = bundle.appendingPathComponent("Contents/Resources/bin/cmux")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
            let first = run(cli: cli, args: ["select-workspace", "--workspace", workspace], env: env)
            if first != 0 { appendAppLog("nb.log", "cmux focus failed rc=\(first)"); return }
            let second = run(cli: cli, args: ["focus-panel", "--panel", surface, "--workspace", workspace], env: env)
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

    /// Runs the CLI with a 2 s watchdog. Returns the exit status, or -1 when it could not run.
    private nonisolated static func run(cli: URL, args: [String], env: [String: String]) -> Int32 {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return -1 }
        if done.wait(timeout: .now() + 2) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                // Ignored SIGTERM: the child holds the token in its environment, do not leave it running.
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            return -2
        }
        return p.terminationStatus
    }
}

#endif
