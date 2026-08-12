import AppKit
import ScreenCaptureKit

/// Saves a PNG of one of the app's own windows, for documentation screenshots:
/// `Griasa --open history --shoot ~/Desktop/history.png`.
///
/// Two paths, in order. ScreenCaptureKit gives the real composited window —
/// correct rounded corners, transparency outside them, the titlebar as macOS
/// actually draws it — but needs the Screen Recording permission the app
/// already holds for system-audio capture. When that is unavailable the view
/// renders itself in-process, which needs no permission at all (a process may
/// always draw its own contents) at the cost of square corners.
@MainActor
enum WindowShot {
    static func save(window: NSWindow, to path: String) async -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = await captureComposited(window) ?? renderInProcess(window)
        guard let data else {
            FileHandle.standardError.write("shot: both capture paths failed\n".data(using: .utf8)!)
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
            print("\(url.path) (\(data.count) bytes)")
            return true
        } catch {
            FileHandle.standardError.write("shot: \(error.localizedDescription)\n".data(using: .utf8)!)
            return false
        }
    }

    /// The window as the compositor draws it. `SCContentFilter(desktopIndependentWindow:)`
    /// isolates one window, so nothing behind it leaks into the image.
    private static func captureComposited(_ window: NSWindow) async -> Data? {
        let windowID = CGWindowID(window.windowNumber)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.captureResolution = .best
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            return png(from: NSBitmapImageRep(cgImage: image))
        } catch {
            return nil
        }
    }

    /// Permission-free fallback: ask the window's frame view to draw itself.
    private static func renderInProcess(_ window: NSWindow) -> Data? {
        // contentView.superview is the theme frame, so the titlebar is included.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return png(from: rep)
    }

    private static func png(from rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }
}
