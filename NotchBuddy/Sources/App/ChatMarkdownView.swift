import SwiftUI

// MARK: - Markdown renderer for chat assistant messages

/// Equatable on what it draws, and used with `.equatable()`: while a text streams, only the block that grows is
/// parsed and laid out again.
struct ChatMarkdownView: View, Equatable {
    enum Style: Equatable {
        /// The answer: bright text.
        case answer
        /// Text written between tools: same layout, dimmer.
        case interim
    }

    let markdown: String
    var style: Style = .answer
    /// The text is still arriving: a half written marker is held back or closed (`ChatMarkdown.parse`).
    var streaming = false

    nonisolated static func == (a: ChatMarkdownView, b: ChatMarkdownView) -> Bool {
        a.markdown == b.markdown && a.style == b.style && a.streaming == b.streaming
    }

    private var textColor: Color { Color(hex: style == .answer ? "#C9CDD4" : "#8A8F98") }
    private var boldColor: Color { Color(hex: style == .answer ? "#F1F2F4" : "#C9CDD4") }

    var body: some View {
        let blocks = ChatMarkdown.parse(markdown, streaming: streaming)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let safe = safeWebURL(url.absoluteString) else { return .discarded }
            NSWorkspace.shared.open(safe)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(.system(size: Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, isFirst ? 0 : 4)

        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .codeBlock(let lang, let code):
            ChatCodeBlock(lang: lang, code: code)

        case .listItem(let prefix, let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: prefix)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(minWidth: prefix.count > 2 ? Self.longMarkerWidth : Self.markerWidth, alignment: .leading)
                Text(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .taskItem(let checked, let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: checked ? "#22C55E" : "#6B7079"))
                    .frame(minWidth: Self.markerWidth, alignment: .leading)
                    .padding(.top, 1)
                Text(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color(hex: "#4B5563"))
                    .frame(width: 2)
                    .clipShape(Capsule())
                Text(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider().opacity(0.3)

        case .table(let header, let align, let rows):
            ChatTableView(header: header, align: align, rows: rows,
                          bodyAttributed: { inlineAttributed($0) },
                          headerAttributed: { inlineAttributed($0, bold: Color(hex: "#F1F2F4")) },
                          bodyColor: textColor)

        case .hiddenRows(let count):
            Text("Rows hidden: \(count)")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .textSelection(.enabled)
        }
    }

    /// The text of bullet, task and numbered items starts at one left edge per level.
    private static let markerWidth: CGFloat = 16
    private static let longMarkerWidth: CGFloat = 24

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 14
        case 3: return 13
        default: return 12.5
        }
    }

    /// Markdown inline syntax (`AttributedString`), then one pass over the runs for the colours: inline code,
    /// bold and links. A link is only ever opened through `safeWebURL` (the `openURL` action above).
    private func inlineAttributed(_ text: String, bold: Color? = nil) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        // Override and isolate characters inside inline code are dropped for display (code blocks are cleaned by the parser).
        let shownText = ChatMarkdown.withoutBidiControlsInCodeSpans(text)
        var attributed = (try? AttributedString(markdown: shownText, options: options)) ?? AttributedString(shownText)
        let strong = bold ?? boldColor
        for run in Array(attributed.runs) {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { attributed[run.range].foregroundColor = strong }
                if intent.contains(.code) {
                    attributed[run.range].font = .system(size: 11.5, design: .monospaced)
                    attributed[run.range].foregroundColor = Color(hex: "#E8E9EC")
                    attributed[run.range].backgroundColor = Color.white.opacity(0.1)
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Color(hex: "#60A5FA")
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

// MARK: - Code block

/// Header strip (language, Copy) over the code. Long lines scroll sideways; each line is cut for display at
/// `maxCodeLineChars`, Copy gives the whole code.
private struct ChatCodeBlock: View {
    let lang: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !lang.isEmpty {
                    Text(verbatim: lang)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                CopyButton(text: code)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: shown)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#C8CDD4"))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0D0E12"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var shown: String {
        let limit = ChatMarkdown.maxCodeLineChars
        guard code.utf8.count > limit else { return code }
        return code.components(separatedBy: "\n").map { line in
            line.utf8.count > limit ? String(line.prefix(limit)) + "…" : line
        }.joined(separator: "\n")
    }
}

// MARK: - Table

private struct ChatTableView: View {
    let header: [String]
    let align: [MDAlign]
    let rows: [[String]]
    let bodyAttributed: (String) -> AttributedString
    let headerAttributed: (String) -> AttributedString
    let bodyColor: Color

    private static let maxColumnWidth: CGFloat = 220

    private func alignment(_ column: Int) -> Alignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        Text(headerAttributed(cell))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#F1F2F4"))
                            .multilineTextAlignment(textAlignment(column))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.maxColumnWidth, alignment: alignment(column))
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Color.white.opacity(0.06).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(bodyAttributed(cell))
                                .font(.system(size: 12.5))
                                .foregroundColor(bodyColor)
                                .multilineTextAlignment(textAlignment(column))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: Self.maxColumnWidth, alignment: alignment(column))
                                .frame(maxWidth: .infinity, alignment: alignment(column))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
            }
            // The frame hugs the table, not the width of the chat.
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(copied ? Color(hex: "#22C55E") : Color(hex: "#6B7079"))
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
