import Foundation

// MARK: - Harness

@main
enum ChatTurnTests {
    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("ChatSpeakers.showsHeader")
        let alfred = ChatSpeaker(name: "Alfred", colorHex: "#F97316")
        let steve = ChatSpeaker(name: "Steve", colorHex: "#22C55E")
        let anthropic = ChatSpeaker(name: "Anthropic", colorHex: "#E07950")
        let google = ChatSpeaker(name: "Google", colorHex: "#4285F4")

        checkTrue("1 first message of the list", ChatSpeakers.showsHeader(previous: nil, speaker: alfred))
        checkTrue("2 after a user message",
                  ChatSpeakers.showsHeader(previous: (isUser: true, speaker: nil), speaker: alfred))
        checkTrue("3 after a message of the same speaker: no header",
                  !ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred), speaker: alfred))
        checkTrue("4 after another speaker (provider switched)",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: anthropic), speaker: google))
        checkTrue("4b after another agent",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred), speaker: steve))
        checkTrue("5 a rename between two messages",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred),
                                           speaker: ChatSpeaker(name: "Alfredo", colorHex: alfred.colorHex)))
        checkTrue("5b a colour change between two messages",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred),
                                           speaker: ChatSpeaker(name: alfred.name, colorHex: "#3B82F6")))
        checkTrue("an assistant message with no known previous speaker shows a header",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: nil), speaker: alfred))

        print("ChatStreaming.shows")
        checkTrue("6 the last message of a running turn streams", ChatStreaming.shows(streamingLast: true, isLast: true, isNotice: false))
        checkTrue("6b an earlier message does not", !ChatStreaming.shows(streamingLast: true, isLast: false, isNotice: false))
        checkTrue("6c nothing streams when the turn is over", !ChatStreaming.shows(streamingLast: false, isLast: true, isNotice: false))
        checkTrue("6d an error sentence appended while a sibling turn runs never streams",
                  !ChatStreaming.shows(streamingLast: true, isLast: true, isNotice: true))

        print("ChatSegment")
        let seg = ChatSegment(id: 0, kind: .text("hi", role: .answer))
        checkTrue("a segment is equatable", seg == ChatSegment(id: 0, kind: .text("hi", role: .answer)))
        checkTrue("a segment differs by role", seg != ChatSegment(id: 0, kind: .text("hi", role: .interim)))
        let step = ChatStep(callId: "1", tool: "terminal", label: "ls", detail: nil, status: .running)
        checkTrue("a step is equatable", step == ChatStep(callId: "1", tool: "terminal", label: "ls", detail: nil, status: .running))

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }
}
