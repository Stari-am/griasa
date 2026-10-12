import Foundation

enum LocalEngine: String, Codable, Sendable { case userServer, ollama, lmStudio, griasa }

struct LocalProbe: Equatable, Sendable {
    var userBaseURL: String
    var ollamaModels: [String]?
    var lmStudioModels: [String]?
    var griasaModelOnDisk: Bool
}

enum LocalEngineDecision: Equatable {
    case use(LocalEngine, model: String)
    case pullIntoOllama(tag: String)
    case download
}

/// Which runtime answers, given what is on this Mac.
///
/// In order: a server the person typed in (never touched — it may be a company
/// gateway); a running Ollama or LM Studio that already has a suitable model
/// (no download); a running Ollama without one (pull into it, so the Mac has
/// one runtime, not two); Griasa's own llama.cpp engine.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalEngineChoice {
    static func decide(_ probe: LocalProbe, entry: LocalModelEntry,
                       preferred: LocalEngine?) -> LocalEngineDecision {
        if !probe.userBaseURL.isEmpty { return .use(.userServer, model: "") }
        if preferred == .griasa, probe.griasaModelOnDisk { return .use(.griasa, model: entry.id) }

        let ollamaHit = probe.ollamaModels.flatMap { models in
            entry.ollamaTags.first(where: models.contains)
        }
        let lmHit = probe.lmStudioModels.flatMap { keys in
            keys.first { key in entry.lmStudioMatch.contains(where: key.contains) }
        }
        if preferred == .lmStudio, let lmHit { return .use(.lmStudio, model: lmHit) }
        if let ollamaHit { return .use(.ollama, model: ollamaHit) }
        if let lmHit { return .use(.lmStudio, model: lmHit) }
        if probe.griasaModelOnDisk { return .use(.griasa, model: entry.id) }
        if probe.ollamaModels != nil, let tag = entry.ollamaTags.first { return .pullIntoOllama(tag: tag) }
        return .download
    }
}
