import Foundation

/// Where the JSON stores live.
///
/// Normally `~/Library/Application Support/Griasa`. `GRIASA_STORE` points all of
/// them somewhere else, which is what the documentation screenshots use: an
/// invented team in a scratch directory, rather than swapping the real history
/// out of the way and hoping to put it back. Read once, so a store cannot move
/// underneath a running app.
enum StoreRoot {
    static let url: URL = {
        let override = ProcessInfo.processInfo.environment["GRIASA_STORE"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Griasa", isDirectory: true)
    }()

    /// True when the stores have been redirected — the roster then comes from a
    /// file beside them instead of from UserDefaults, which no environment
    /// variable can redirect because cfprefsd, not this process, opens it.
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["GRIASA_STORE"] ?? "").isEmpty
    }

    static func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
