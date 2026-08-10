import Foundation
import SwiftUI

/// A document skeleton (PRD, RFC…) the AI fills in from a spoken or pasted
/// brief. `<!-- … -->` comments guide the model and never survive into the
/// generated document.
struct DocTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var emoji: String
    var name: String
    var skeleton: String
}

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published var templates: [DocTemplate] { didSet { save() } }

    private static let key = "docTemplates"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([DocTemplate].self, from: data),
           !decoded.isEmpty {
            templates = decoded
        } else {
            templates = Self.defaults
        }
    }

    func add() {
        templates.append(DocTemplate(emoji: "📝", name: "New template",
                                     skeleton: "# {Title}\n\n## Section\n<!-- what belongs here -->\n"))
    }

    func delete(_ template: DocTemplate) {
        templates.removeAll { $0.id == template.id }
    }

    func restoreDefaults() {
        for preset in Self.defaults where !templates.contains(where: { $0.name == preset.name }) {
            templates.append(preset)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static let defaults: [DocTemplate] = [
        DocTemplate(emoji: "📘", name: "PRD", skeleton: """
        # {Product/feature name} — PRD

        ## Problem
        <!-- Who hurts, how badly, and how we know. Numbers or user quotes if the brief has them. -->

        ## Goals
        <!-- 2-4 measurable outcomes. What success looks like a quarter after launch. -->

        ## Non-goals
        <!-- What we are deliberately NOT doing this iteration, to guard scope. -->

        ## Users & scenarios
        <!-- Primary user types and the concrete moments they'd use this. -->

        ## Solution overview
        <!-- The shape of the product answer, one screen at a time. No implementation detail. -->

        ## Requirements
        <!-- Numbered, testable. Split into Must / Nice-to-have. -->

        ## Metrics
        <!-- How we'll measure the goals: events, targets, guardrails. -->

        ## Risks & open questions
        <!-- What could sink this and what we still need to find out. -->
        """),
        DocTemplate(emoji: "📗", name: "RFC", skeleton: """
        # RFC: {Change name}

        ## Summary
        <!-- Three sentences: what we're changing, why, and the cost of not doing it. -->

        ## Motivation
        <!-- The problem in the current system, with evidence. -->

        ## Design
        <!-- The proposed change: architecture, data flow, interfaces. Diagrams as ASCII if helpful. -->

        ## Alternatives considered
        <!-- 2-3 other ways, and why the chosen one wins. -->

        ## Compatibility & migration
        <!-- Breaking changes, rollout plan, rollback story. -->

        ## Security & privacy
        <!-- New surfaces, data handled, permissions touched — or "no change". -->

        ## Open questions
        """),
        DocTemplate(emoji: "📄", name: "One-pager", skeleton: """
        # {Idea name}

        ## What
        <!-- The idea in two sentences a busy exec understands. -->

        ## Why now
        <!-- The trigger: market shift, user pain spike, unlocked dependency. -->

        ## How
        <!-- The plan in 3-5 bullets, with rough effort. -->

        ## What it costs / what it returns
        <!-- Effort estimate vs expected impact, both honest. -->

        ## Ask
        <!-- The single decision or resource being requested. -->
        """),
        DocTemplate(emoji: "🧯", name: "Postmortem", skeleton: """
        # Postmortem: {Incident}

        ## Impact
        <!-- Who/what was affected, for how long, severity. Blameless throughout. -->

        ## Timeline
        <!-- Timestamped: detection → diagnosis → mitigation → resolution. -->

        ## Root cause
        <!-- The actual cause, not the trigger. Five-whys depth. -->

        ## What went well / what went poorly
        <!-- Both lists, honest. -->

        ## Action items
        <!-- Each with an owner and a due date. Prevention beats detection beats mitigation. -->
        """),
    ]
}

/// Fills a template's sections from the user's brief.
enum DocGenerator {
    static func generate(template: DocTemplate, brief: String) async throws -> String {
        let system = Prompts.text(.documentDraft).filling(["skeleton": template.skeleton])
        return try await AIFormatter.complete(system: system, user: brief,
                                              tier: .smart, maxTokens: 8192, timeout: 180)
    }
}
