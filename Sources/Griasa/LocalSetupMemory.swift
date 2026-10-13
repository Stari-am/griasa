import Foundation

/// Which catalog entry a refresh works with, given what was set up before.
///
/// A setup that is already on this Mac wins over picking a tier again. The
/// pick reads free disk, and the download itself takes that disk: after a
/// 6 GB model arrives, the next launch would see less room, pick a smaller
/// tier, drop the working engine and offer a second download — or, with the
/// organization's auto-download on, quietly fetch it. So, in order: the entry
/// an organization or an expert pinned; the smaller entry Griasa stepped down
/// to after the model ran out of memory; the stored Griasa model if its file
/// is still there; the stored Ollama or LM Studio model mapped back to its
/// entry; a fresh pick for this Mac; and when even the smallest tier no longer
/// fits the disk, the largest one already downloaded, whose space is taken by
/// it anyway.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalSetupMemory {
    static func choose(pinnedID: String?, steppedDownID: String?,
                       storedEngine: LocalEngine?, storedModel: String?,
                       isDownloaded: (LocalModelEntry) -> Bool,
                       memoryGB: Int, freeDiskGB: Int) -> LocalModelEntry? {
        for id in [pinnedID, steppedDownID] {
            if let id, let entry = LocalModelCatalog.entry(id: id) { return entry }
        }
        if let storedModel, !storedModel.isEmpty {
            switch storedEngine {
            case .griasa:
                if let entry = LocalModelCatalog.entry(id: storedModel), isDownloaded(entry) { return entry }
            case .ollama:
                if let entry = LocalModelCatalog.entries.first(where: { $0.ollamaTags.contains(storedModel) }) {
                    return entry
                }
            case .lmStudio:
                // The same match the probe uses, so the entry found here finds
                // the same LM Studio model again.
                if let entry = LocalModelCatalog.entries.first(where: { entry in
                    entry.lmStudioMatch.contains(where: storedModel.contains)
                }) { return entry }
            case .userServer, nil:
                break
            }
        }
        if let fits = LocalModelCatalog.pick(memoryGB: memoryGB, freeDiskGB: freeDiskGB) { return fits }
        return LocalModelCatalog.runnable(memoryGB: memoryGB).reversed().first(where: isDownloaded)
    }
}

/// What a refresh does when the engine set up before is Ollama or LM Studio.
///
/// A runtime that does not answer a 1.5 s probe is usually one still starting
/// at login, not one that is gone. Treating it as gone dropped the working
/// setup, showed the download card, and with auto-download installed a second
/// runtime and a duplicate model. So the stored setup is kept while the
/// runtime is silent, and asked again after 5 s, 30 s and 120 s; only a
/// runtime that answers without the model, or one still silent after the last
/// wait, goes to the ordinary decision.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalRuntimeWait {
    enum Verdict: Equatable {
        /// Keep the stored engine and probe again after this many seconds.
        case keep(retryAfter: TimeInterval)
        /// Decide afresh from what the probe found.
        case decide
    }

    static let backoff: [TimeInterval] = [5, 30, 120]

    /// - Parameters:
    ///   - stored: the engine a previous refresh stored, if any.
    ///   - answered: whether that engine's runtime answered the probe at all
    ///     (an empty model list is an answer).
    ///   - waitsSoFar: how many times in a row it has already been kept.
    static func verdict(stored: LocalEngine?, answered: Bool, waitsSoFar: Int) -> Verdict {
        guard stored == .ollama || stored == .lmStudio, !answered,
              waitsSoFar < backoff.count else { return .decide }
        return .keep(retryAfter: backoff[waitsSoFar])
    }
}
