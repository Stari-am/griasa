import Foundation
import Combine

/// A reusable text template expanded by typing its abbreviation anywhere or
/// picking it from the menu. Templates may contain dynamic placeholders —
/// see `SnippetEngine`.
struct Snippet: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Typed trigger, e.g. ";meet". Empty = menu-only.
    var abbreviation: String
    var template: String
    var enabled = true

    static let defaults: [Snippet] = [
        Snippet(name: "Propose a meeting", abbreviation: ";meet",
                template: "Would {slot} work for you? Here's my room: {meetlink}"),
        Snippet(name: "Three time options", abbreviation: ";slots",
                template: "I'm free at: {slots:3}. Pick what works and I'll send an invite."),
        Snippet(name: "Signature", abbreviation: ";sig",
                template: "Best regards,\nYour Name"),
        Snippet(name: "Today's date", abbreviation: ";today",
                template: "{date}"),
        commitmentsSnippet,
    ] + aiShowcase

    /// Added separately so existing installs get it too (see SnippetStore.init).
    static let commitmentsSnippet = Snippet(
        name: "My commitments", abbreviation: ";todos",
        template: "My open commitments:\n{commitments:mine}")

    /// {ai:} demos — the prompt sees live context via nested placeholders.
    static let aiShowcase: [Snippet] = [
        Snippet(name: "TL;DR of clipboard", abbreviation: ";tldr",
                template: "{ai: Summarize the following in 3 short bullet points, in its original language:\n{clipboard}}"),
        Snippet(name: "Clipboard → English", abbreviation: ";en",
                template: "{ai: Translate the following into natural English, keeping the formatting:\n{clipboard}}"),
    ]
}

/// Persists snippets and exposes them to the Settings editor, the menu, and
/// the typing expander.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published var snippets: [Snippet] = [] { didSet { save() } }

    private static let defaultsKey = "snippets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = decoded
        } else {
            snippets = Snippet.defaults
        }
        // One-time: installs that saved their snippet list before the
        // {commitments} placeholder existed get the new default too.
        if !UserDefaults.standard.bool(forKey: "snippetCommitmentsSeeded") {
            UserDefaults.standard.set(true, forKey: "snippetCommitmentsSeeded")
            if !snippets.contains(where: { $0.template.contains("{commitments") }) {
                snippets.append(Snippet.commitmentsSnippet)
                save()
            }
        }
        // Same for the {ai:}+{clipboard} showcase snippets.
        if !UserDefaults.standard.bool(forKey: "snippetAIShowcaseSeeded") {
            UserDefaults.standard.set(true, forKey: "snippetAIShowcaseSeeded")
            let fresh = Snippet.aiShowcase.filter { candidate in
                !snippets.contains { $0.abbreviation == candidate.abbreviation }
            }
            if !fresh.isEmpty {
                snippets.append(contentsOf: fresh)
                save()
            }
        }
    }

    var active: [Snippet] { snippets.filter { $0.enabled } }

    func add() {
        snippets.append(Snippet(name: "New snippet", abbreviation: "", template: ""))
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
