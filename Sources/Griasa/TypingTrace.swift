import Foundation

/// Appends a timestamped line to `~/Documents/Griasa Diagnostics/typing-trace.log`.
///
/// `NSLog` is not a usable diagnostic channel here: on this machine it reaches
/// neither the unified log nor anywhere else reachable, because a GUI app
/// launched from Finder has nowhere for stderr to go. Every "nothing appears in
/// the log" conclusion drawn from it was about the channel, not the code — so
/// the dictation path writes where the output can actually be read.
enum TypingTrace {
    private static let queue = DispatchQueue(label: "griasa.typing.trace")
    /// Keeps a long debugging session from growing without bound.
    private static let sizeLimit = 512 * 1024

    private static let url: URL = {
        let folder = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("typing-trace.log")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static var fileURL: URL { url }

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                if end > sizeLimit {
                    // Truncating alone leaves the write offset at the old end,
                    // so the next line would land past half a megabyte of NULs.
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
