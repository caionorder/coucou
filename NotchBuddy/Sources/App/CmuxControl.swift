import AppKit
import Security

#if !APPSTORE

/// Sends text to a cmux session and starts new chats, through the cmux CLI.
/// The CLI runs only from a bundle that passes the cmux signature check. User text travels as one
/// argv element holding JSON built by JSONSerialization, never through a shell. Tokens and the
/// socket password travel in the child's environment only: never argv, never logged, never on disk.
enum CmuxControl {
    static let passwordKey = "cmux-socket-password"

    enum Failure: Error, Equatable {
        case notRunning, notVerified, noCredential, blockedByDialog, dialogMayBeOpen, invalidInput, enterNotSent, busy
        case cli(Int32)

        var message: String {
            switch self {
            case .notRunning:      return String(localized: "cmux is not running.")
            case .notVerified:     return String(localized: "cmux could not be verified.")
            case .noCredential:    return String(localized: "No open cmux session. Add the socket password in Settings, or start one session in cmux.")
            case .blockedByDialog: return String(localized: "Answer the pending request first.")
            case .dialogMayBeOpen: return String(localized: "A request may still be open in cmux. Answer it there first.")
            case .invalidInput:    return String(localized: "Check the folder / command in Settings.")
            case .busy:            return String(localized: "Still sending, try again in a moment.")
            case .enterNotSent:    return String(localized: "Text is in the prompt, press Return in cmux.")
            case .cli(let code):   return String(localized: "cmux refused the command (code \(String(code))).")
            }
        }
    }

    /// Serial queue for everything that runs the CLI (one operation at a time).
    private static let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.cmux-control", qos: .userInitiated)

    // MARK: - socket password (Keychain, loaded once, memory afterwards)

    private final class PasswordCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var value: String?
        func get() -> String? {
            lock.lock(); defer { lock.unlock() }
            if !loaded { value = Keychain.load(key: CmuxControl.passwordKey); loaded = true }
            return value
        }
        func set(_ v: String?) {
            lock.lock(); defer { lock.unlock() }
            loaded = true
            value = v
            if let v { Keychain.save(key: CmuxControl.passwordKey, value: v) }
            else { Keychain.delete(key: CmuxControl.passwordKey) }
        }
    }
    private static let passwordCache = PasswordCache()

    static var hasPassword: Bool { !(passwordCache.get() ?? "").isEmpty }

    /// Empty string removes the stored password.
    static func setPassword(_ value: String) {
        passwordCache.set(value.isEmpty ? nil : value)
    }

    // MARK: - CLI

    /// Running cmux bundles first, else the installed one. Called on the main thread.
    @MainActor
    static func candidateBundles() -> (running: Bool, bundles: [URL]) {
        var urls = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == CmuxRouting.bundleId }
            .compactMap { $0.bundleURL }
        let running = !urls.isEmpty
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId),
           !urls.contains(installed) {
            urls.append(installed)
        }
        return (running, urls)
    }

    /// The CLI of the first bundle that passes the signature check. Hashes the bundle: off the main thread.
    nonisolated static func verifiedCLI(bundles: [URL]) -> URL? {
        for bundle in bundles where CmuxJump.bundleIsCmux(bundle) {
            let cli = bundle.appendingPathComponent("Contents/Resources/bin/cmux")
            if FileManager.default.isExecutableFile(atPath: cli.path) { return cli }
        }
        return nil
    }

    /// Environment of the child process, or nil when the credential cannot be used.
    nonisolated static func environment(for credential: CmuxCredential) -> [String: String]? {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        switch credential {
        case .token(let s):
            guard CmuxRouting.isValidSocketPath(s.socketPath),
                  CmuxRouting.socketFileIsTrusted(path: s.socketPath) else { return nil }
            env["CMUX_SOCKET_PATH"] = s.socketPath
            env["CMUX_SOCKET_CAPABILITY"] = s.capability
            env["CMUX_WORKSPACE_ID"] = s.workspaceId
            env["CMUX_SURFACE_ID"] = s.surfaceId
            return env
        case .password:
            // No socket path here: the CLI resolves its own. A path from a hook payload or from
            // UserDefaults could point the password at a listener the user never chose.
            guard let pw = passwordCache.get(), !pw.isEmpty else { return nil }
            env["CMUX_SOCKET_PASSWORD"] = pw
            return env
        case .none:
            return nil
        }
    }

    /// `environment(for:)` plus, for a token, the check that the listener of the socket is the cmux app:
    /// a token is never handed to a process that is not. Blocks up to a second: off the main thread.
    /// The failure tells the two causes apart: no usable credential, or a peer that is not verified.
    nonisolated static func verifiedEnvironment(for credential: CmuxCredential) -> Result<[String: String], Failure> {
        guard let env = environment(for: credential) else { return .failure(.noCredential) }
        if case .token(let s) = credential {
            guard CmuxRouting.socketPeerIsCmux(path: s.socketPath) else {
                appendAppLog("nb.log", "cmux socket peer not verified")
                return .failure(.notVerified)
            }
        }
        return .success(env)
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count < limit { bytes.append(chunk.prefix(limit - bytes.count)) }
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// Runs the CLI with a watchdog. status: exit code, -1 could not run, -2 timed out and killed.
    /// stdout is captured (capped at `captureLimit`, 64 KB by default) only when asked; stdin and stderr go to /dev/null.
    nonisolated static func run(cli: URL, args: [String], env: [String: String],
                                timeout: TimeInterval = 2, captureOutput: Bool = false,
                                captureLimit: Int = 65536)
        -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = env
        let pipe = captureOutput ? Pipe() : nil
        p.standardOutput = pipe ?? FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, "") }
        let box = OutputBox(limit: captureLimit)
        let reader = DispatchGroup()
        if let pipe {
            reader.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let h = pipe.fileHandleForReading
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    box.append(chunk)
                }
                reader.leave()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                // Ignored SIGTERM: the child holds the token in its environment, do not leave it running.
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            if captureOutput { _ = reader.wait(timeout: .now() + 1) }
            return (-2, "")
        }
        if captureOutput { _ = reader.wait(timeout: .now() + 1) }
        return (p.terminationStatus, String(data: box.data, encoding: .utf8) ?? "")
    }

    // MARK: - reply

    /// Types `text` into the session and presses Enter. Only ever called from an explicit user action
    /// (Send, Return) or from the single deferred first prompt of a new chat the user started.
    /// Typing always needs a token (the session's own, else the freshest on the same socket): the
    /// socket password is never used here, and there is no retry with another credential.
    @MainActor
    static func send(text: String, to taskId: String, completion: @escaping @MainActor (Failure?) -> Void) {
        let state = AppState.shared
        guard !state.cmuxBusy else { completion(.busy); return }
        guard CmuxRouting.isCmuxTaskId(taskId), let prepared = CmuxRouting.preparePrompt(text) else {
            completion(.invalidInput); return
        }
        let server = HookServer.shared
        guard server.cmuxCanSend(taskId) else {
            completion(server.cmuxDialogMayBeOpen(taskId) ? .dialogMayBeOpen : .blockedByDialog); return
        }
        guard let target = server.cmuxSurface(for: taskId), !target.surfaceId.isEmpty, !target.workspaceId.isEmpty else {
            completion(.noCredential); return
        }
        let credential = server.cmuxSendCredential(for: taskId)
        guard credential != CmuxCredential.none else { completion(.noCredential); return }
        let (running, bundles) = candidateBundles()
        guard running else { completion(.notRunning); return }
        guard let textParams = CmuxRouting.rpcParams(workspaceId: target.workspaceId, surfaceId: target.surfaceId, text: prepared),
              let keyParams = CmuxRouting.rpcParams(workspaceId: target.workspaceId, surfaceId: target.surfaceId, key: "enter"),
              let textJSON = json(textParams), let keyJSON = json(keyParams) else {
            completion(.invalidInput); return
        }
        state.cmuxBusy = true
        queue.async {
            let result = deliver(taskId: taskId, bundles: bundles, credential: credential,
                                 textJSON: textJSON, keyJSON: keyJSON)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppState.shared.cmuxBusy = false
                    if let result { appendAppLog("nb.log", "cmux send failed: \(result.message)") }
                    completion(result)
                }
            }
        }
    }

    /// The send gate, evaluated on the main thread from the serial queue. Main never waits on that queue.
    /// nil when sending is allowed, else the reason (the same pair `send` reports).
    private nonisolated static func sendGate(_ taskId: String) -> Failure? {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let server = HookServer.shared
                if server.cmuxCanSend(taskId) { return nil }
                return server.cmuxDialogMayBeOpen(taskId) ? .dialogMayBeOpen : .blockedByDialog
            }
        }
    }

    private nonisolated static func deliver(taskId: String, bundles: [URL], credential: CmuxCredential,
                                            textJSON: String, keyJSON: String) -> Failure? {
        // The signature check (it hashes the bundle, so it is slow) comes first; the gate is evaluated
        // after it and again right before Enter, so a dialog that opens meanwhile is not answered.
        guard let cli = verifiedCLI(bundles: bundles) else { return .notVerified }
        if let blocked = sendGate(taskId) { return blocked }
        // A token that cannot be shown to be talking to the real cmux never leaves the process.
        let env: [String: String]
        switch verifiedEnvironment(for: credential) {
        case .success(let e): env = e
        case .failure(let f): return f
        }
        let typed = run(cli: cli, args: ["rpc", "surface.send_text", textJSON], env: env, timeout: 3)
        // Any failure ends here, a timeout included: the text may already be typed, never retry.
        if typed.status != 0 { return .cli(typed.status) }
        Thread.sleep(forTimeInterval: 0.15)
        // A residual window of a few milliseconds remains between this check and the key press.
        guard sendGate(taskId) == nil else { return .enterNotSent }
        let enter = run(cli: cli, args: ["rpc", "surface.send_key", keyJSON], env: env, timeout: 3)
        return enter.status == 0 ? nil : .enterNotSent
    }

    // MARK: - new chat

    /// Creates a workspace in `folder` that runs the launch command. The prompt is not part of the
    /// command: it is kept in memory and typed when the SessionStart of the new surface arrives.
    /// The password is used only here, and only when no session token exists.
    @MainActor
    static func newChat(folder: String, prompt: String, completion: @escaping @MainActor (Failure?) -> Void) {
        let state = AppState.shared
        guard !state.cmuxBusy else { completion(.busy); return }
        guard let prepared = CmuxRouting.preparePrompt(prompt),
              CmuxRouting.isExistingFolder(folder),
              CmuxRouting.isValidLaunchCommand(state.cmuxLaunchCommand) else {
            completion(.invalidInput); return
        }
        let command = state.cmuxLaunchCommand
        let credential = HookServer.shared.cmuxCredential(for: nil, hasPassword: hasPassword)
        guard credential != CmuxCredential.none else { completion(.noCredential); return }
        let (running, bundles) = candidateBundles()
        guard running else { completion(.notRunning); return }
        state.cmuxBusy = true
        queue.async {
            let outcome = create(bundles: bundles, credential: credential, folder: folder, command: command)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let state = AppState.shared
                    state.cmuxBusy = false
                    switch outcome {
                    case .failure(let f):
                        appendAppLog("nb.log", "cmux new chat failed: \(f.message)")
                        completion(f)
                    case .success(let created):
                        state.cmuxRecentFolders = CmuxRouting.recentFolders(adding: folder, to: state.cmuxRecentFolders)
                        HookServer.shared.setCmuxPendingLaunch(
                            CmuxPendingLaunch(workspaceId: created.workspaceId, socketPath: created.socketPath,
                                              cwd: folder, prompt: prepared,
                                              createdAt: Date().timeIntervalSinceReferenceDate))
                        completion(nil)
                    }
                }
            }
        }
    }

    /// `workspaceId` is "" when the UUID could not be resolved; `socketPath` is "" in password mode.
    private struct Created { var workspaceId: String; var socketPath: String }

    private nonisolated static func create(bundles: [URL], credential: CmuxCredential,
                                           folder: String, command: String) -> Result<Created, Failure> {
        guard let cli = verifiedCLI(bundles: bundles) else { return .failure(.notVerified) }
        let env: [String: String]
        switch verifiedEnvironment(for: credential) {
        case .success(let e): env = e
        case .failure(let f): return .failure(f)
        }
        let r = run(cli: cli,
                    args: ["new-workspace", "--cwd", folder, "--command", command, "--focus", "false"],
                    env: env, timeout: 5, captureOutput: true)
        guard r.status == 0 else { return .failure(.cli(r.status)) }
        var socket = ""
        if case .token(let s) = credential { socket = s.socketPath }
        // stdout is `OK workspace:N`, a short ref. Its UUID comes from workspace.list on the same credential.
        var workspaceId = ""
        if let ref = CmuxRouting.workspaceRef(inNewWorkspaceOutput: r.output) {
            let list = run(cli: cli, args: ["--id-format", "uuids", "rpc", "workspace.list", "{}"],
                           env: env, timeout: 3, captureOutput: true)
            if list.status == 0 { workspaceId = CmuxRouting.workspaceId(forRef: ref, inListJSON: list.output) ?? "" }
        }
        return .success(Created(workspaceId: workspaceId, socketPath: socket))
    }

    // MARK: - session name and branch

    /// Own queue: a slow title lookup never delays a send.
    private static let metaQueue = DispatchQueue(label: "fr.louisraille.NotchBuddy.cmux-meta", qos: .utility)

    /// Tab title of the surface (through the CLI, with the task's own token) and git branch of `cwd`
    /// (read from the HEAD file). Either is nil when it cannot be read. Runs once per call, no timer.
    @MainActor
    static func fetchMeta(surface: CmuxSurface?, cwd: String,
                          completion: @escaping @MainActor (_ title: String?, _ branch: String?) -> Void) {
        let token: CmuxSurface? = (surface?.canFocusExactly == true) ? surface : nil
        let bundles = token == nil ? [] : candidateBundles().bundles
        metaQueue.async {
            let branch = CmuxRouting.gitBranch(cwd: cwd)
            let title = token.flatMap { fetchTitle(surface: $0, bundles: bundles) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(title, branch) } }
        }
    }

    /// What the last successful title lookup verified: the bundle signature (so the CLI) and the socket peer.
    /// Reused for `verificationReuseInterval` by the title lookup only; send, new chat and jump never read it.
    private final class TitleVerification: @unchecked Sendable {
        private let lock = NSLock()
        private var cli: URL?
        private var socketPath = ""
        private var at: TimeInterval?
        func reusable(socketPath path: String) -> URL? {
            lock.lock(); defer { lock.unlock() }
            guard let cli, socketPath == path,
                  CmuxRouting.verificationIsFresh(verifiedAt: at, now: ProcessInfo.processInfo.systemUptime),
                  FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
            return cli
        }
        func store(cli: URL, socketPath path: String) {
            lock.lock(); defer { lock.unlock() }
            self.cli = cli; socketPath = path; at = ProcessInfo.processInfo.systemUptime
        }
    }
    private static let titleVerification = TitleVerification()

    private nonisolated static func fetchTitle(surface: CmuxSurface, bundles: [URL]) -> String? {
        guard let params = CmuxRouting.surfaceListParams(workspaceId: surface.workspaceId),
              let paramsJSON = json(params) else { return nil }
        let cli: URL
        let env: [String: String]
        if let cached = titleVerification.reusable(socketPath: surface.socketPath),
           let e = environment(for: .token(surface)) {
            // Fresh enough: signature and peer were verified for this socket moments ago. The socket file
            // check inside `environment` still runs.
            cli = cached; env = e
        } else {
            guard let verified = verifiedCLI(bundles: bundles),
                  case .success(let e) = verifiedEnvironment(for: .token(surface)) else { return nil }
            titleVerification.store(cli: verified, socketPath: surface.socketPath)
            cli = verified; env = e
        }
        let r = run(cli: cli, args: ["--id-format", "uuids", "rpc", "surface.list", paramsJSON],
                    env: env, timeout: 3, captureOutput: true, captureLimit: 524288)
        guard r.status == 0 else { return nil }
        return CmuxRouting.tabTitle(forSurface: surface.surfaceId, inListJSON: r.output)
    }

    // MARK: - helpers

    private nonisolated static func json(_ params: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#endif
