import SwiftUI

/// Renders the Markdown the app itself produces — meeting notes, documents,
/// preset output — instead of showing the source. Block structure comes from
/// line prefixes; inline styling (`**bold**`, `` `code` ``, links) comes from
/// AttributedString's own Markdown parser, so there is no dependency here.
///
/// `inlineOnlyPreservingWhitespace` is deliberate: the full parser collapses
/// newlines and would fold a transcript into one paragraph.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .blank:
                    Spacer().frame(height: 6)
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(level <= 1 ? .title3.bold()
                              : level == 2 ? .headline
                              : .subheadline.bold())
                        .padding(.top, 6)
                case .bullet(let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(content)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote(let content):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(.tertiary).frame(width: 2)
                        Text(inline(content))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .paragraph(let content):
                    Text(inline(content)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private enum Block {
        case blank
        case heading(Int, String)
        case bullet(String)
        case quote(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        text.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .blank }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if hashes <= 6, !rest.isEmpty { return .heading(hashes, rest) }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(String(line.dropFirst(2)))
            }
            if line.hasPrefix("> ") {
                return .quote(String(line.dropFirst(2)))
            }
            return .paragraph(line)
        }
    }

    /// Falls back to the raw string when the line isn't valid Markdown, so a
    /// stray asterisk shows as itself rather than swallowing the line.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}
