import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Screenshots the frontmost window of whatever app currently has focus.
/// Used by "Draft reply" to read the visible chat via OCR. Reuses the Screen
/// Recording permission Griasa already holds for system-audio capture.
///
/// The image itself comes from ScreenCaptureKit. `CGWindowListCreateImage` was
/// the obvious call here, but it is not merely deprecated — it is *obsoleted* as
/// of macOS 15, and only a deployment target of 14.0 keeps it compiling at all:
/// raise the minimum by one version and the build fails outright. The window is
/// still *chosen* with `CGWindowListCopyWindowInfo`, which is not deprecated and
/// is the only one of the two that reports windows front-to-back — the order
/// `SCShareableContent.windows` comes back in is not documented as z-order, so
/// trusting it would trade a working heuristic for a guess.
enum WindowCapture {
    static func captureFrontWindow() async -> NSImage? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // The list is front-to-back; take the frontmost normal window (layer 0)
        // owned by the focused app.
        let match = windows.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
        }

        guard let match,
              let windowID = match[kCGWindowNumber as String] as? CGWindowID
        else { return nil }

        do {
            // `onScreenWindowsOnly: true` keeps this list to what the CGWindowList
            // call above already filtered for, so the id lookup can't match a
            // window the user cannot see.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                TypingTrace.log("window capture — window \(windowID) vanished between listing and capture")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Ask for the pixel size the display actually uses, or OCR reads a
            // downscaled image on a Retina screen and starts inventing letters.
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.captureResolution = .best
            // The pointer is not part of the conversation being read.
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: filter.contentRect.size)
        } catch {
            TypingTrace.log("window capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
