import Foundation

// The turn of an agent as the chat shows it. Foundation only, in both builds, no flag.
// Display data only: nothing here is encoded, persisted, logged or sent to a server.

/// One tool call of a turn, as the server names it.
struct ChatStep: Equatable {
    var callId: String
    var tool: String                 // "terminal", "web_search"… as the server names it
    var label: String                // the server's one line preview, cut
    var detail: String?              // web socket only: the summary of the completion, cut
    var status: Status
    enum Status: Equatable { case running, done, stopped }   // stopped: the turn ended while it ran
}

/// One row of an agent turn.
struct ChatSegment: Identifiable, Equatable {
    let id: Int                      // order in the turn, never reused
    var kind: Kind
    enum Kind: Equatable {
        case text(String, role: TextRole)
        case step(ChatStep)
        case note(String)            // an already localized sentence: approval needed, answer cut…
        case hiddenSteps             // older steps were dropped (cap)
    }
    enum TextRole: Equatable { case open, interim, answer }
}

/// Who speaks in an agent block: a name and the colour of its pill.
struct ChatSpeaker: Equatable {
    var name: String
    var colorHex: String
}

enum ChatStreaming {
    /// Whether a message is parsed as a text that is still arriving: only the last one, only while a turn runs,
    /// and never a sentence the app wrote (an error kept in the chat).
    static func shows(streamingLast: Bool, isLast: Bool, isNotice: Bool) -> Bool {
        streamingLast && isLast && !isNotice
    }
}

enum ChatSpeakers {
    /// The header is drawn on the first agent message after a user message (or at the top), and again when
    /// the speaker changes (shared chat, provider switched in the middle, an agent renamed).
    static func showsHeader(previous: (isUser: Bool, speaker: ChatSpeaker?)?, speaker: ChatSpeaker) -> Bool {
        guard let previous else { return true }
        if previous.isUser { return true }
        return previous.speaker != speaker
    }
}
