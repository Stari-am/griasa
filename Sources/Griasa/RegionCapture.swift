import AppKit

/// Drags a rectangle anywhere on screen using the OS interactive screenshot
/// selector (the same crosshair ⌘⇧4 uses) — no custom overlay to maintain.
/// Returns nil when the user cancels with Esc (no file is written).
enum RegionCapture {
    static func capture() async -> NSImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("griasa-region-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ran = await run(to: tmp)
        // On cancel, screencapture writes nothing — the file check is the
        // reliable signal regardless of exit status.
        guard ran, FileManager.default.fileExists(atPath: tmp.path),
              let image = NSImage(contentsOf: tmp) else { return nil }
        return image
    }

    private static func run(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i interactive region select, -x no capture sound.
            process.arguments = ["-i", "-x", url.path]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
