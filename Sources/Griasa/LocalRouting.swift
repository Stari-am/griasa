import Foundation

/// Which class of model a request needs. Cheap in-the-flow tasks (dictation
/// cleanup, classification, reminder parsing, reply drafts) use `fast`;
/// heavy ones (presets, summaries, Ask Project, meeting notes) use `smart`.
enum ModelTier {
    case fast
    case smart
}

enum LocalRoute: Equatable { case apple, localLLM }

/// Which on-device model answers a request.
///
/// Apple's built-in model costs no download, so short light jobs go there —
/// but only in English: it does not support Russian and throws on languages it
/// does not know, and its 4,096-token window holds the reply as well as the
/// input. Everything else goes to the downloaded model. Nothing here ever
/// chooses the cloud.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalRouting {
    static let appleMaxInputTokens = 2500
    static let englishConfidence = 0.8

    static func estimatedTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    static func route(tier: ModelTier, englishConfidence: Double,
                      inputTokens: Int, appleAvailable: Bool) -> LocalRoute {
        guard appleAvailable, tier == .fast,
              englishConfidence >= Self.englishConfidence,
              inputTokens <= appleMaxInputTokens else { return .localLLM }
        return .apple
    }
}
