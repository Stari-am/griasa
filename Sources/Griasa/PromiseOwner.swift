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
        /// Lines with a known speaker come first: a summary or an action-item list
        /// echoes the words of the transcript but says nothing of who spoke them.
        func locate(_ quote: String) -> [Paragraph]? {
            for knownOnly in [true, false] {
                for width in 1...3 where prepared.count >= width {
                    for start in 0...(prepared.count - width) {
                        let span = paragraphs[start..<(start + width)]
                        if knownOnly, span.contains(where: { $0.speaker == .unknown }) { continue }
                        let joined = prepared[start..<(start + width)].joined(separator: " ")
                        if QuoteMatch.contains(joined, quote: quote) { return Array(span) }
                    }
                }
            }
            return nil
        }

        func resolve(quote: String?, modelOwner: String?, participants: [String]) -> Resolution {
            var owner = PromiseOwner.normalizeOwner(modelOwner)
            let me = myName.isEmpty ? "You" : myName
            func isMe(_ name: String) -> Bool { PromiseOwner.isMe(name, myName: myName) }
            let others = participants.filter { !isMe($0) }
            func other(_ name: String) -> String? {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, !isMe(n) else { return nil }
                return others.first { PromiseOwner.sameName($0, n) }
            }
            // A participant the model named in its own spelling: their canonical name.
            if let canonical = other(owner) { owner = canonical }
            let generic = owner.isEmpty || ["them", "unknown", "speaker", "someone", "you"].contains(owner.lowercased())
                && !isMe(owner)
            let modelSaysMe = isMe(owner)
            // A name the model gave that is not the user's: kept even when it is
            // not on the participant list (a short name, a Cyrillic spelling).
            let modelNamesOther: String? = (modelSaysMe || generic) ? nil : (other(owner) ?? owner)

            // No quote, or no line to read it from: the model's owner.
            let legacy = Resolution(isMine: modelSaysMe, owner: modelSaysMe ? me : (modelNamesOther ?? "Unknown"),
                                    at: nil, located: false)
            guard let quote, !quote.isEmpty, let span = locate(quote) else { return legacy }

            let at = span.first?.seconds.map(RawLine.clock)
            let hasYou = span.contains { $0.speaker == .you }
            let named = span.compactMap { p -> String? in if case let .named(n) = p.speaker { return n }; return nil }
            let hasThem = span.contains { $0.speaker == .them } || !named.isEmpty
            let lineText = span.map(\.text).joined(separator: " ") + " " + quote
            // A participant other than the user who is addressed in the line.
            let addressee = others.first { PromiseOwner.mentions($0, in: lineText) }

            func result(mine: Bool, owner: String) -> Resolution {
                Resolution(isMine: mine, owner: owner, at: at, located: true)
            }
            if hasYou && !hasThem {
                // The user speaking: their own promise, unless they are handing the task to someone.
                if let who = modelNamesOther { return result(mine: false, owner: who) }
                if modelSaysMe { return result(mine: true, owner: me) }
                if let addressee { return result(mine: false, owner: addressee) }
                return result(mine: true, owner: me)
            }
            if hasThem && !hasYou {
                // Someone else speaking: the user's only when the model says so and
                // either the line names them or the call has one other person (it
                // can only be asking the user).
                if modelSaysMe, others.count == 1 || PromiseOwner.mentions(me == "You" ? "" : me, in: lineText) {
                    return result(mine: true, owner: me)
                }
                if Set(named.map { $0.lowercased() }).count == 1 { return result(mine: false, owner: named[0]) }
                return result(mine: false, owner: other(owner) ?? "Them")
            }
            if hasYou && hasThem {
                // Said across both: the user's only if the model says so and the user spoke in it.
                return result(mine: modelSaysMe, owner: modelSaysMe ? me : (other(owner) ?? "Them"))
            }
            var r = legacy
            r.at = at
            return r
        }
    }

    /// Whether a name — or a form of it ("Вика" → "Вике", "Вику") — is a word of the text.
    static func mentions(_ name: String, in text: String) -> Bool {
        let words = Set(QuoteMatch.normalize(text).split(separator: " ").map(String.init))
        for part in QuoteMatch.normalize(name).split(separator: " ") where part.count >= 3 {
            var stem = String(part)
            if stem.count >= 4, "аяйьуюеиыо".contains(stem.last!) { stem.removeLast() }
            if words.contains(where: { $0.hasPrefix(stem) && $0.count <= stem.count + 3 }) { return true }
        }
        return false
    }

    /// The owner string a model returned, cleaned: a trailing parenthetical is
    /// dropped ("Саша (Саша Файн…)" is "Саша"); a group ("все участники",
    /// "everyone", "team") is "Them"; "unknown", "неопределенно", "—" or nothing is "".
    static func normalizeOwner(_ raw: String?) -> String {
        var name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = name.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            name = String(name[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!—–- "))
        if ["все", "все участники", "всем", "всех", "everyone", "everybody", "all", "команда", "team", "them"].contains(key) { return "Them" }
        if ["", "неопределенно", "неопределённо", "неопределен", "неизвестно", "unknown", "n/a", "na", "none", "someone", "speaker"].contains(key) { return "" }
        return name
    }

    /// The same person by name: equal after folding, or the same first name.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.split(separator: " ").first == y.split(separator: " ").first
    }

    /// "Айк", "Aik" and "aïk" are one name: transliterated to Latin, folded for
    /// case and accents, with й/y read as i and x as ks ("Алекс" is "Alex").
    static func fold(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .replacingOccurrences(of: "j", with: "i").replacingOccurrences(of: "y", with: "i")
            .replacingOccurrences(of: "x", with: "ks")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The user's name, or its first word alone ("Aik" for "Aik Sargsian"), in
    /// any script; "you" and "me" too.
    static func isMe(_ name: String, myName: String) -> Bool {
        let n = fold(name)
        if n.isEmpty { return false }
        if n == fold("you") || n == "me" { return true }  // fold reads y as i
        let mine = fold(myName)
        guard !mine.isEmpty else { return false }
        let first = mine.split(separator: " ").first.map(String.init) ?? mine
        return n == mine || n == first
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
