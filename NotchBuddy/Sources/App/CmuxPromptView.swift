import SwiftUI

#if !APPSTORE

/// Carries a prompt mode through NotificationCenter.
final class CmuxPromptModeBox {
    let mode: CmuxPromptMode
    init(_ mode: CmuxPromptMode) { self.mode = mode }
}

/// Reply to a cmux session, or start a new chat in a new cmux workspace.
/// Shown in the `.prompt` slot while `state.cmuxPrompt` is set. Text reaches cmux only when the user
/// clicks Send or presses Return (plus the single deferred first prompt of a new chat).
struct CmuxPromptView: View {
    @ObservedObject var state: AppState
    @State private var text = ""
    @State private var folder = ""
    @State private var launching = false
    /// Folder lookups hit the file system: done on appear and when the lists change, not per render.
    @State private var folders: [String] = []
    @FocusState private var focused: Bool

    private var mode: CmuxPromptMode { state.cmuxPrompt ?? .newChat }

    private var replyTask: AgentTask? {
        if case .reply(let id) = mode { return state.tasks.first { $0.id == id } }
        return nil
    }

    private var isReply: Bool { if case .reply = mode { return true } else { return false } }

    /// Default folder first, then recent ones; only folders that still exist.
    private func loadFolders() {
        var out: [String] = []
        for f in [state.cmuxDefaultFolder] + state.cmuxRecentFolders where !f.isEmpty && !out.contains(f) {
            if CmuxRouting.isExistingFolder(f) { out.append(f) }
        }
        folders = out
        if !out.contains(folder) { folder = out.first ?? "" }
    }

    private var sessionCanReceive: Bool {
        guard let t = replyTask else { return false }
        return HookServer.shared.cmuxCanSend(t.id)
    }

    private var canSubmit: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.cmuxBusy else { return false }
        if isReply { return sessionCanReceive }
        return !launching && folders.contains(folder)
    }

    private var notice: String? {
        if let n = state.cmuxNotice { return n }
        if isReply, let t = replyTask, !sessionCanReceive {
            return (HookServer.shared.cmuxDialogMayBeOpen(t.id)
                    ? CmuxControl.Failure.dialogMayBeOpen : CmuxControl.Failure.blockedByDialog).message
        }
        return nil
    }

    private var transcript: [ChatMessage] {
        if case .reply(let id) = mode { return state.cmuxTranscripts[id] ?? [] }
        return []
    }

    private var typing: Bool {
        guard let t = replyTask else { return false }
        return [.thinking, .working, .searching].contains(t.state)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    AgentWho(task: replyTask, label: isReply ? "cmux · reply" : "New chat in cmux")
                    // Same second line as the overview card: folder and branch of the session.
                    if isReply, let line = replyTask?.subtitle {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 15)
                    }
                }
                .padding(.top, 4)

                if isReply { replyBody } else { newChatBody }

                if let notice {
                    HStack(spacing: 10) {
                        Text(notice)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(2)
                        if isReply, let t = replyTask, notice == CmuxControl.Failure.dialogMayBeOpen.message {
                            // Explicit click: the user says the request is gone (answered, then declined, in cmux).
                            Button("Answered") {
                                HookServer.shared.clearCmuxDialogMark(t.id)
                                state.cmuxNotice = nil
                                state.objectWillChange.send()
                            }
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#7DD3FC").opacity(0.85))
                            .buttonStyle(.plain)
                        }
                        if notice == CmuxControl.Failure.noCredential.message {
                            Button("Settings…") {
                                NotificationCenter.default.post(name: .openFullSettings, object: "agents")
                            }
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
                        }
                        if notice == CmuxControl.Failure.noCredential.message
                            || notice == CmuxControl.Failure.notRunning.message {
                            Button("Open cmux") { CmuxHub.openCmux() }
                                .font(.system(size: 11)).foregroundColor(Color(hex: "#7DD3FC").opacity(0.85))
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }

                HStack(spacing: 8) {
                    TextField(isReply ? "Reply…" : "First prompt…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { send() }

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(!canSubmit)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .padding(.bottom, 10)
        .onAppear {
            focused = true
            launching = HookServer.shared.cmuxPendingLaunch != nil
            loadFolders()
            takeDraft()
        }
        .onChange(of: state.cmuxDefaultFolder) { _, _ in loadFolders() }
        .onChange(of: state.cmuxRecentFolders) { _, _ in loadFolders() }
        .onChange(of: state.cmuxDraft) { _, _ in takeDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .islandSendMessage)) { _ in
            guard state.view == .prompt, state.cmuxPrompt != nil else { return }
            send()
        }
    }

    // MARK: bodies

    @ViewBuilder private var replyBody: some View {
        if !transcript.isEmpty || typing {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(transcript) { msg in
                            ChatBubble(message: msg).id(msg.id)
                        }
                        if typing {
                            HStack { TypingDotsView(); Spacer(minLength: 32) }.id("typing")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: transcript) { _, _ in scrollToEnd(proxy) }
                .onChange(of: typing) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
            .frame(maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if typing { proxy.scrollTo("typing", anchor: .bottom) }
        else if let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    @ViewBuilder private var newChatBody: some View {
        if folders.isEmpty {
            HStack(spacing: 10) {
                Text("Set a default folder in Settings.")
                    .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openFullSettings, object: "agents")
                }
                .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            Spacer()
        } else {
            let labels = CmuxRouting.chipLabels(for: folders)
            ChipFlowLayout(spacing: 6) {
                ForEach(Array(folders.enumerated()), id: \.element) { i, f in
                    let selected = f == folder
                    Button { folder = f } label: {
                        Text(labels[i])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(selected ? Color(hex: "#0B0C0E") : Color(hex: "#C5C8CD"))
                            .lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(selected ? Color(hex: "#F5F6F8") : Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(f)
                }
            }
            .padding(.horizontal, 10)
            Text("Runs: \(state.cmuxLaunchCommand)")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .padding(.horizontal, 10)
            Spacer()
        }
    }

    // MARK: actions

    /// A draft goes back into the field only in the mode it was stored for.
    private func takeDraft() {
        guard let draft = state.cmuxDraft, draft.mode == mode, !draft.text.isEmpty else { return }
        text = draft.text
        state.cmuxDraft = nil
        launching = false
    }

    /// Explicit user action only: Send click, Return, or the island send shortcut.
    private func send() {
        guard canSubmit else { return }
        let prompt = text
        state.cmuxNotice = nil
        switch mode {
        case .reply(let id):
            CmuxControl.send(text: prompt, to: id) { failure in
                if let failure {
                    state.cmuxNotice = failure.message
                    if failure != .enterNotSent { text = prompt } else { text = "" }
                } else {
                    text = ""
                }
            }
        case .newChat:
            let chosen = folder
            CmuxControl.newChat(folder: chosen, prompt: prompt) { failure in
                if let failure {
                    state.cmuxNotice = failure.message
                    text = prompt
                } else {
                    text = ""
                    launching = true
                }
            }
        }
    }
}

/// Small helpers shared by the hub card and the prompt view.
@MainActor
enum CmuxHub {
    /// Brings cmux to the front, or launches it. Never types anything.
    static func openCmux() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == CmuxRouting.bundleId }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    // LaunchServices and the process list are not cheap: the answers are cached for a few seconds, so a
    // view body that asks on every render does not repeat the lookup.
    private static var cache: (at: Date, installed: Bool, running: Bool)?
    private static let cacheTTL: TimeInterval = 3

    private static func lookup() -> (installed: Bool, running: Bool) {
        if let c = cache, Date().timeIntervalSince(c.at) < cacheTTL { return (c.installed, c.running) }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId) != nil
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == CmuxRouting.bundleId }
        cache = (Date(), installed, running)
        return (installed, running)
    }

    static func isInstalled() -> Bool { lookup().installed }

    static func isRunning() -> Bool { lookup().running }

    static func open(_ mode: CmuxPromptMode) {
        NotificationCenter.default.post(name: .openCmuxPrompt, object: CmuxPromptModeBox(mode))
    }
}

#endif
