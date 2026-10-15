import Foundation

/// Decides, in code, whose promise a quote is — from who spoke the line it came
/// from, not from the model's say-so.
///
/// A 9B model cannot tell which "Them" speaker said what and defaults to the
/// user: on a real meeting 17 of 19 promises came back as the user's own, where a
/// cloud model said 6. The transcript knows: "You" is the user's microphone, and
/// the finished notes label their speakers. So the rule is applied after the
/// quote is verified. Foundation only, for `test.sh`.
enum PromiseOwner {
    enum Speaker: Equatable {
        case you, them, named(String), unknown
    }

    struct Paragraph {
        var speaker: Speaker
        var text: String
        var seconds: Int?
    }

    struct Resolution: Equatable {
        var isMine: Bool
        var owner: String
        /// "mm:ss" of the line the quote came from, when it carries one.
        var at: String?
        /// Whether the quote was found in a line at all; false means the model's
        /// owner decided, guardedly.
        var located: Bool
    }

    /// The text split into who-said-what, built once and asked about per promise.
    struct Index {
        let paragraphs: [Paragraph]
        private let prepared: [String]
        let myName: String

        init(text: String, myName: String) {
            self.myName = myName
            paragraphs = PromiseOwner.paragraphs(of: text, myName: myName)
            prepared = paragraphs.map { QuoteMatch.prepare($0.text) }
        }

        /// Speakers of the line (or two or three consecutive lines) the quote is in.
        func locate(_ quote: String) -> [Paragraph]? {
            for width in 1...3 where prepared.count >= width {
                for start in 0...(prepared.count - width) {
                    let joined = prepared[start..<(start + width)].joined(separator: " ")
                    if QuoteMatch.contains(joined, quote: quote) {
                        return Array(paragraphs[start..<(start + width)])
                    }
                }
            }
            return nil
        }

        func resolve(quote: String?, modelOwner: String?, participants: [String]) -> Resolution {
            let owner = modelOwner?.trimmingCharacters(in: .whitespaces) ?? ""
            let me = myName.isEmpty ? "You" : myName
            func isMe(_ name: String) -> Bool { PromiseOwner.isMe(name, myName: myName) }
            func other(_ name: String) -> String? {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, !isMe(n),
                      participants.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return nil }
                return participants.first { $0.caseInsensitiveCompare(n) == .orderedSame }
            }
            // No quote, or no line to read it from: the model's owner, and the
            // user's only if the model said it is the user.
            let legacy = Resolution(isMine: isMe(owner), owner: isMe(owner) ? me : (other(owner) ?? (owner.isEmpty ? "Unknown" : "Them")),
                                    at: nil, located: false)
            guard let quote, !quote.isEmpty, let span = locate(quote) else { return legacy }

            let at = span.first?.seconds.map(RawLine.clock)
            let hasYou = span.contains { $0.speaker == .you }
            let named = span.compactMap { p -> String? in if case let .named(n) = p.speaker { return n }; return nil }
            let hasThem = span.contains { $0.speaker == .them } || !named.isEmpty
            let hasUnknown = span.contains { $0.speaker == .unknown }

            if hasYou && !hasThem { return Resolution(isMine: true, owner: me, at: at, located: true) }
            if hasThem && !hasYou {
                let who = Set(named.map { $0.lowercased() }).count == 1 ? named[0] : (other(owner) ?? "Them")
                return Resolution(isMine: false, owner: who, at: at, located: true)
            }
            if hasYou && hasThem {
                // Said across both: the user's only if the model says so and the user spoke in it.
                let mine = isMe(owner)
                return Resolution(isMine: mine, owner: mine ? me : (other(owner) ?? "Them"), at: at, located: true)
            }
            _ = hasUnknown
            var r = legacy
            r.at = at
            return r
        }
    }

    static func isMe(_ name: String, myName: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty { return false }
        return n == "you" || n == "me" || (!myName.isEmpty && n == myName.lowercased())
    }

    /// Raw dialogue (`[mm:ss] You: …`) and finished notes (`**Name:** …`,
    /// `> 📝 **Note…`) both become paragraphs with a speaker. Prose with no
    /// label — a summary — is `.unknown`, and a blank line or heading ends a speaker's turn.
    static func paragraphs(of text: String, myName: String) -> [Paragraph] {
        var out: [Paragraph] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
                out.append(Paragraph(speaker: .unknown, text: "", seconds: nil))
                continue
            }
            switch RawLine.parse(line) {
            case let .speech(seconds, speaker, body):
                out.append(Paragraph(speaker: speaker == "You" ? .you : .them, text: body, seconds: seconds))
                continue
            case let .note(seconds, body):
                out.append(Paragraph(speaker: .you, text: body, seconds: seconds))
                continue
            case .other:
                break
            }
            if line.hasPrefix(">"), line.contains("📝") {
                out.append(Paragraph(speaker: .you, text: line, seconds: nil))
            } else if let range = line.range(of: #"^(\[\d{1,3}:\d{2}(:\d{2})?\]\s*)?\*\*[^*\n]{1,40}:\*\*"#, options: .regularExpression) {
                let head = String(line[range])
                let label = head.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*: "))
                let body = String(line[range.upperBound...])
                let speaker: Speaker
                switch label.lowercased() {
                case "them": speaker = .them
                case "speaker", "unknown", "": speaker = .unknown
                default: speaker = isMe(label, myName: myName) ? .you : .named(label)
                }
                out.append(Paragraph(speaker: speaker, text: body, seconds: RawLine.timestamp(of: line)))
            } else if let last = out.last, last.speaker != .unknown || !last.text.isEmpty {
                // Continuation of the previous line.
                out[out.count - 1].text += " " + line
            } else {
                out.append(Paragraph(speaker: .unknown, text: line, seconds: nil))
            }
        }
        return out.filter { !$0.text.isEmpty }
    }
}
