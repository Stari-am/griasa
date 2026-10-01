import Foundation
import CryptoKit

/// The speech models Griasa downloads, and what each must be once it arrives.
///
/// Both come from Hugging Face. Before this, a download was accepted as long as
/// the server answered 200: a file replaced upstream, truncated on the way, or
/// swapped by anything sitting on the connection would have been handed
/// straight to the ggml parser — a parser with a history of buffer-overflow
/// bugs. A security review asked for a checksum; this is it.
///
/// Each model is pinned twice. The URL names a repository commit rather than
/// `main`, so the file cannot change underneath the app — an upstream update
/// would otherwise either break every new install against a stale hash or, if
/// the hash moved with it, check nothing at all. And the expected SHA-256 and
/// size are written here, taken from what Hugging Face publishes for that
/// commit and confirmed against copies already on disk.
///
/// Foundation and CryptoKit only, so `test.sh` can reach it.
struct PinnedModel: Equatable {
    let fileName: String
    let url: URL
    let sha256: String
    let size: Int64
}

enum ModelManifest {
    static let whisper = PinnedModel(
        fileName: "ggml-large-v3-turbo.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin")!,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        size: 1_624_555_275)

    static let vad = PinnedModel(
        fileName: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin")!,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        size: 885_098)

    static let all = [whisper, vad]

    enum Verdict: Equatable {
        case matches
        case wrongSize(Int64)
        case wrongDigest(String)
        case unreadable
    }

    /// Size first: it is free, and it catches the common failure — a download
    /// cut short — without reading 1.6 GB to find out.
    static func verdict(size: Int64?, digest: () -> String?, expected: PinnedModel) -> Verdict {
        guard let size else { return .unreadable }
        guard size == expected.size else { return .wrongSize(size) }
        guard let found = digest() else { return .unreadable }
        return found.lowercased() == expected.sha256.lowercased() ? .matches : .wrongDigest(found)
    }

    static func verify(_ file: URL, against expected: PinnedModel) -> Verdict {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
            .flatMap { $0 }?.int64Value
        return verdict(size: size, digest: { sha256(of: file) }, expected: expected)
    }

    /// Streamed in 8 MB reads, so checking the large model costs a couple of
    /// seconds and almost no memory rather than 1.6 GB of it.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // `read(upToCount:)` returns nil at end of file, not empty data, and
        // throws on a real read error. The two must not be confused: treating
        // end-of-file as failure made every file unreadable — every model
        // would have been refused and fetched again, for ever.
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 8 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One sentence for the person who was waiting on the download.
    static func explain(_ verdict: Verdict, model: PinnedModel) -> String {
        switch verdict {
        case .matches:
            return "\(model.fileName) is intact."
        case .wrongSize(let size):
            return "\(model.fileName) arrived at \(size) bytes instead of \(model.size) — the download was cut short or altered, so it was not installed. Try again."
        case .wrongDigest:
            return "\(model.fileName) does not match its published checksum, so it was not installed. The file was altered somewhere between Hugging Face and this Mac. Try again on another network."
        case .unreadable:
            return "\(model.fileName) could not be read back to check it, so it was not installed."
        }
    }
}
