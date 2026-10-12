import Foundation

/// The local models Griasa offers, one per memory tier, each pinned like the
/// speech models: a repository commit, a SHA-256 and a size, checked before
/// the file is used.
///
/// One model per tier, not a menu. The people this is for do not know what a
/// quantization is and should not have to; the list is chosen for them from
/// how much memory the Mac has, then stepped down if the disk is short.
/// Experts can still pick any model this Mac can run in Settings → Advanced.
///
/// Reviewed every few months: open-weight models move fast. Sources and the
/// reasoning for each pick are in the 2026-10 research note. All Apache-2.0.
///
/// Foundation only, so `test.sh` can reach it.
struct LocalModelEntry: Equatable, Sendable {
    let id: String
    let displayName: String
    let pinned: PinnedModel
    let minMemoryGB: Int
    let contextTokens: Int
    let ollamaTags: [String]
    let lmStudioMatch: [String]
    let license: String
}

enum LocalModelCatalog {
    /// Space left free after the download: macOS slows badly on a full disk,
    /// and the recordings folder keeps growing.
    static let diskHeadroomGB = 2

    private static func hf(_ repo: String, _ commit: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(commit)/\(file)")!
    }

    // Commits, sizes and SHA-256 read from the Hugging Face tree API at each
    // commit on 2026-10-12.
    static let entries: [LocalModelEntry] = [
        LocalModelEntry(
            id: "qwen3.5-4b-q4", displayName: "Qwen3.5 4B",
            pinned: PinnedModel(fileName: "Qwen3.5-4B-Q4_K_M.gguf",
                                url: hf("unsloth/Qwen3.5-4B-GGUF", "e87f176479d0855a907a41277aca2f8ee7a09523", "Qwen3.5-4B-Q4_K_M.gguf"),
                                sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                                size: 2_740_937_888),
            minMemoryGB: 8, contextTokens: 32768,
            ollamaTags: ["qwen3.5:4b"], lmStudioMatch: ["qwen3.5-4b"], license: "Apache-2.0"),
        LocalModelEntry(
            id: "qwen3.5-9b-q4", displayName: "Qwen3.5 9B",
            pinned: PinnedModel(fileName: "Qwen3.5-9B-Q4_K_M.gguf",
                                url: hf("unsloth/Qwen3.5-9B-GGUF", "3885219b6810b007914f3a7950a8d1b469d598a5", "Qwen3.5-9B-Q4_K_M.gguf"),
                                sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
                                size: 5_680_522_464),
            minMemoryGB: 12, contextTokens: 32768,
            ollamaTags: ["qwen3.5:9b"], lmStudioMatch: ["qwen3.5-9b"], license: "Apache-2.0"),
        LocalModelEntry(
            id: "gemma4-12b-q8", displayName: "Gemma 4 12B",
            pinned: PinnedModel(fileName: "gemma-4-12b-it-Q8_0.gguf",
                                url: hf("unsloth/gemma-4-12b-it-GGUF", "fc034cfff751157913579611efad8462ac1be606", "gemma-4-12b-it-Q8_0.gguf"),
                                sha256: "f20e7ff1be28c283eeeb18fc895733791c56a5851d5cd3fe9691b7f7d12afa72",
                                size: 12_669_647_680),
            minMemoryGB: 20, contextTokens: 32768,
            ollamaTags: ["gemma4:12b"], lmStudioMatch: ["gemma-4-12b"], license: "Apache-2.0"),
        LocalModelEntry(
            id: "qwen3.6-35b-a3b-q4", displayName: "Qwen3.6 35B-A3B",
            pinned: PinnedModel(fileName: "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
                                url: hf("unsloth/Qwen3.6-35B-A3B-GGUF", "a483e9e6cbd595906af30beda3187c2663a1118c", "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"),
                                sha256: "ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61",
                                size: 22_134_528_992),
            minMemoryGB: 28, contextTokens: 32768,
            ollamaTags: ["qwen3.6:35b-a3b"], lmStudioMatch: ["qwen3.6-35b-a3b"], license: "Apache-2.0"),
        LocalModelEntry(
            id: "qwen3.6-35b-a3b-q8", displayName: "Qwen3.6 35B-A3B (high precision)",
            pinned: PinnedModel(fileName: "Qwen3.6-35B-A3B-Q8_0.gguf",
                                url: hf("unsloth/Qwen3.6-35B-A3B-GGUF", "a483e9e6cbd595906af30beda3187c2663a1118c", "Qwen3.6-35B-A3B-Q8_0.gguf"),
                                sha256: "d1a395809f65a43a13ad119eb4e7acdef1ac6d68120f39902c8ab96e72794a59",
                                size: 36_903_140_320),
            minMemoryGB: 56, contextTokens: 32768,
            ollamaTags: ["qwen3.6:35b-a3b-q8_0"], lmStudioMatch: ["qwen3.6-35b-a3b"], license: "Apache-2.0"),
    ]

    static func entry(id: String) -> LocalModelEntry? { entries.first { $0.id == id } }

    static func runnable(memoryGB: Int) -> [LocalModelEntry] {
        let fits = entries.filter { $0.minMemoryGB <= memoryGB }
        return fits.isEmpty ? Array(entries.prefix(1)) : fits
    }

    /// Highest tier the memory allows, then down until the file plus headroom
    /// fits the disk. Nil when even the smallest does not fit the disk.
    static func pick(memoryGB: Int, freeDiskGB: Int) -> LocalModelEntry? {
        for entry in runnable(memoryGB: memoryGB).reversed() {
            let needGB = Int((Double(entry.pinned.size) / 1_000_000_000).rounded(.up)) + diskHeadroomGB
            if needGB <= freeDiskGB { return entry }
        }
        return nil
    }
}
