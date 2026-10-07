import SwiftUI

// What a chat shows for an agent: one block per turn, with the speaker's name and colour, over the rows of the
// turn (text, tool steps, notes). The user's message stays a `ChatBubble`. In both builds, no flag.

// MARK: - The block of one agent turn

/// Header (dot and name), then a rail in the speaker colour beside the rows. Equatable and used with `.equatable()`:
/// a message that does not change is not laid out again while another one streams.
struct AgentTurnBlock: View, Equatable {
    let speaker: ChatSpeaker
    let showsHeader: Bool
    let segments: [ChatSegment]
    /// No text yet: the typing dots take the place of the rows.
    var typing = false

    nonisolated static func == (a: AgentTurnBlock, b: AgentTurnBlock) -> Bool {
        a.speaker == b.speaker && a.showsHeader == b.showsHeader && a.segments == b.segments && a.typing == b.typing
    }

    private var color: Color { Color(hex: speaker.colorHex) }

    /// Hermes can run tools in parallel: only the last running step shimmers, the others show a static row.
    private var shimmerId: Int? {
        segments.last { if case .step(let s) = $0.kind { return s.status == .running }; return false }?.id
    }

    /// Space above a row (the stack has none): 6 between rows, 2 between two steps in a row so many steps stay
    /// compact, and an answer that follows interim text or steps gets a little more air.
    private func topPadding(_ index: Int, _ segment: ChatSegment) -> CGFloat {
        guard index > 0 else { return 0 }
        if case .step = segment.kind, case .step = segments[index - 1].kind { return 2 }
        if case .text(_, role: .answer) = segment.kind { return 12 }
        return 6
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if showsHeader {
                    HStack(spacing: 7) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(verbatim: speaker.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        row(segment)
                            .padding(.top, topPadding(index, segment))
                    }
                    if typing { TypingDotsView().padding(.top, segments.isEmpty ? 0 : 6) }
                }
                // The rail starts 3 pt in (under the centre of the dot) and the rows start at 15 pt, under the
                // first letter of the name.
                .padding(.leading, 15)
                .background(alignment: .leading) {
                    Capsule().fill(color.opacity(0.5)).frame(width: 2).padding(.leading, 3)
                }
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func row(_ segment: ChatSegment) -> some View {
        switch segment.kind {
        case .text(let text, let role):
            ChatMarkdownView(markdown: text, style: role == .interim ? .interim : .answer, streaming: role == .open)
                .equatable()
        case .step(let step):
            ChatStepRow(step: step, shimmer: segment.id == shimmerId)
        case .note(let note):
            Text(verbatim: note)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .hiddenSteps:
            Text("Earlier steps hidden")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
        }
    }
}

// MARK: - One tool step

/// A tool call as a compact row: state glyph, the tool name, the server's one line preview. Tool names and
/// previews are server data: drawn verbatim, never looked up in the string catalog, never read as markdown.
struct ChatStepRow: View, Equatable {
    let step: ChatStep
    /// The running row of the turn that shimmers (one `TimelineView`); other running rows are static.
    var shimmer = false

    nonisolated static func == (a: ChatStepRow, b: ChatStepRow) -> Bool { a.step == b.step && a.shimmer == b.shimmer }

    private let dim = Color(hex: "#6B7079")

    var body: some View {
        HStack(spacing: 6) {
            glyph.frame(width: 12, alignment: .center)
            Text(verbatim: step.tool)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(dim)
                .lineLimit(1)
                .layoutPriority(1)
            if !step.label.isEmpty && step.label != step.tool {
                if step.status == .running && shimmer {
                    TickerShimmerText(text: step.label, size: 11.5)
                } else {
                    Text(verbatim: step.label)
                        .font(.system(size: 11.5))
                        .foregroundColor(dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let detail = step.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 18, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        switch step.status {
        case .running:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(hex: "#8E939C"))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .regular))
                .foregroundColor(Color(hex: "#454850"))
        case .stopped:
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .regular))
                .foregroundColor(Color(hex: "#454850"))
        }
    }
}

// MARK: - The shared list body

/// The messages of a chat: the user's bubble, or the block of the agent, with a larger gap between turns than
/// between two paragraphs. The three chat lists (shared chat, Hermes chat, cmux reply) draw their body with this.
/// The scroll anchors stay as they were: `.id(message.id)` on each row and `"typing"` on the dots.
struct ChatTurnList: View {
    let messages: [ChatMessage]
    /// Who wrote an agent message; nil asks for the speaker who is about to answer (the typing dots).
    let speaker: (ChatMessage?) -> ChatSpeaker
    /// The last message is still arriving (a finished text is parsed as written).
    let streamingLast: Bool
    let typing: Bool

    private func visible(_ m: ChatMessage) -> Bool { !m.content.isEmpty || !m.segments.isEmpty }

    var body: some View {
        let shown = messages.filter(visible)
        let position = Dictionary(shown.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let lastID = messages.last?.id
        // A message with no provider of its own (Hermes, cmux, an old message) has the speaker who is about to
        // answer: resolved once per pass instead of once per message.
        let fallback = speaker(nil)
        let who: (ChatMessage) -> ChatSpeaker = { $0.provider == nil ? fallback : speaker($0) }
        // The placeholder of the turn that waits is the last message, empty: the dots sit in its block, and its
        // scroll anchor sits below them.
        let pending = typing ? messages.last.flatMap { $0.role == .assistant && !visible($0) ? $0 : nil } : nil
        // Spacing is padding on the rows (12 pt between turns), so a message with nothing to show can still carry
        // its scroll anchor as a zero height row without adding a gap.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(messages) { message in
                if let index = position[message.id] {
                    Group {
                        if message.role == .user {
                            ChatBubble(message: message)
                        } else {
                            let speaker = who(message)
                            AgentTurnBlock(
                                speaker: speaker,
                                showsHeader: header(for: speaker, after: index > 0 ? shown[index - 1] : nil, who: who),
                                segments: Self.segments(of: message, streaming: ChatStreaming.shows(
                                    streamingLast: streamingLast, isLast: message.id == lastID, isNotice: message.isNotice)))
                                .equatable()
                        }
                    }
                    .padding(.top, index == 0 ? 0 : 12)
                    .id(message.id)
                } else if message.id != pending?.id {
                    Color.clear.frame(height: 0).id(message.id)
                }
            }
            if typing {
                let speaker = pending.map(who) ?? fallback
                AgentTurnBlock(speaker: speaker, showsHeader: header(for: speaker, after: shown.last, who: who),
                               segments: [], typing: true)
                    .equatable()
                    .padding(.top, shown.isEmpty ? 0 : 12)
                    .id("typing")
                if let pending { Color.clear.frame(height: 0).id(pending.id) }
            }
        }
    }

    private func header(for current: ChatSpeaker, after previous: ChatMessage?,
                        who: (ChatMessage) -> ChatSpeaker) -> Bool {
        guard let previous else { return ChatSpeakers.showsHeader(previous: nil, speaker: current) }
        let was: ChatSpeaker? = previous.role == .user ? nil : who(previous)
        return ChatSpeakers.showsHeader(previous: (isUser: previous.role == .user, speaker: was), speaker: current)
    }

    /// The rows of a message: its own segments, or one text made from `content` (every provider but Hermes, an
    /// error text, the cmux transcript). A text that is still arriving is `open`: held back and closed where needed.
    static func segments(of message: ChatMessage, streaming: Bool) -> [ChatSegment] {
        if !message.segments.isEmpty { return message.segments }
        return [ChatSegment(id: 0, kind: .text(message.content, role: streaming ? .open : .answer))]
    }
}
