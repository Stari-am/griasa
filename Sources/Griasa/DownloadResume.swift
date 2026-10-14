import Foundation

/// The decisions behind a model download that continues where it stopped,
/// kept apart from the networking so `test.sh` can check them.
///
/// A local model is 2.7 to 37 GB. Before, a Wi-Fi drop, a sleep or a quit
/// threw away everything fetched so far; now the bytes go to `<model>.part`
/// and the next attempt asks the server only for the rest (HTTP Range).
///
/// Foundation only.
enum DownloadResume {
    /// What to do with a `.part` already on disk before asking the server.
    enum Existing: Equatable {
        /// Ask for the bytes from this offset (0: no Range header at all).
        case requestFrom(Int64)
        /// The part is the whole size already: go straight to the check.
        case verifyNow
        /// Longer than the model can be: it is not a prefix of it.
        case discard
    }

    /// Bytes written since the last flush to disk at most; see `existing`.
    static let syncEvery: Int64 = 64 << 20

    /// `rewind` is for the first look after a launch: a power cut can leave
    /// the file's length ahead of what reached the disk, with zeros in the
    /// tail. Everything older than the last flush is safe, so the part is
    /// cut back by one flush interval before asking for the rest. Within a
    /// run (rewind 0) the bytes written are what the file holds.
    static func existing(partSize: Int64?, expectedSize: Int64, rewind: Int64 = 0) -> Existing {
        guard let partSize, partSize > 0 else { return .requestFrom(0) }
        if partSize > expectedSize { return .discard }
        if partSize == expectedSize { return .verifyNow }
        return .requestFrom(max(0, partSize - rewind))
    }

    /// What to do with the server's answer to a request from `offset`.
    enum Response: Equatable {
        /// Write the body after what is already on disk.
        case append
        /// The body is the whole file from byte 0: empty the part and write it.
        case restartFromZero
        /// The part does not fit what the server has: delete it and ask again
        /// from the start.
        case discardAndRetry
        /// Not the model, or not now (a captive portal's page, a proxy's
        /// answer, a server error): keep the part and try again like after a
        /// network drop.
        case retryLater
        case fail(status: Int)
    }

    /// - Parameters:
    ///   - contentLength: the body's length if the server said (nil if not).
    ///   - mimeType: the body's type if the server said.
    static func response(status: Int, requestedFrom offset: Int64, contentRangeStart: Int64?,
                         contentLength: Int64?, mimeType: String?, expectedSize: Int64) -> Response {
        // A web page is never a model: a hotel login page or a proxy's
        // notice, answered in place of the file.
        if (200...299).contains(status), mimeType?.lowercased().hasPrefix("text/html") == true {
            return .retryLater
        }
        switch status {
        case 200:
            // A 200 is the whole file from byte 0 — or something else that
            // answered. Only the model's exact length is taken for the file;
            // anything else leaves what is on disk alone.
            if offset == 0 {
                if let contentLength, contentLength != expectedSize { return .retryLater }
                return .append
            }
            return contentLength == expectedSize ? .restartFromZero : .retryLater
        case 206:
            // Partial content must start exactly where the part ends, or the
            // two would be stitched into a file nobody published.
            guard offset > 0, contentRangeStart == offset else { return .discardAndRetry }
            return .append
        case 416:
            // Range not satisfiable: the part is not a prefix of this file.
            return .discardAndRetry
        case 500, 502, 503, 504:
            // The CDN having a bad minute is waited out like the network.
            return .retryLater
        default:
            return .fail(status: status)
        }
    }

    /// The error a `retryLater` answer ends an attempt with; network-type.
    static let retryableError = NSError(domain: "GriasaDownload", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "The download server did not send the model. Try again later."
    ])

    /// The start offset in a `Content-Range: bytes 100-199/1000` header.
    static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header = header?.trimmingCharacters(in: .whitespaces).lowercased(),
              header.hasPrefix("bytes ") else { return nil }
        let range = header.dropFirst(6)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[range.startIndex..<dash].trimmingCharacters(in: .whitespaces))
    }

    /// Errors that mean the network went away, and so are worth waiting out.
    /// Anything else (a refused file, a full disk, a bad certificate) fails
    /// at once, as it did before.
    static func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == retryableError.domain, nsError.code == retryableError.code { return true }
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed]
            .contains(nsError.code)
    }

    /// Longest the network may stay away before the download gives up.
    static let maxWait: TimeInterval = 30 * 60

    /// Seconds to wait before attempt `failures + 1`, after `failures`
    /// network failures in a row with nothing received in between and
    /// `waited` seconds already spent waiting; nil means give up. 5 s, 15 s,
    /// 60 s, then every two minutes, for about half an hour in all.
    static func delay(afterFailures failures: Int, waited: TimeInterval) -> TimeInterval? {
        guard failures >= 1 else { return 0 }
        let schedule: [TimeInterval] = [5, 15, 60]
        let next = failures <= schedule.count ? schedule[failures - 1] : 120
        return waited + next <= maxWait ? next : nil
    }

    /// Whether a refresh continues a download by itself instead of asking.
    /// The person already said "Download" for this very model (or the
    /// organization turned on automatic downloads) and part of it is on disk:
    /// asking again after a quit would be asking twice. A "Not now" since
    /// then clears the yes, and a part of another model is no reason.
    ///
    /// At most once per launch for a model, unless the last try ended on the
    /// network: a download that failed for another reason (a file pulled, a
    /// full disk) would otherwise start again at every refresh and fail again,
    /// flipping the message the person was reading.
    static func resumesWithoutAsking(partSize: Int64?, consentedID: String?,
                                     entryID: String, autoDownload: Bool,
                                     resumedThisLaunch: Bool = false,
                                     lastFailureWasNetwork: Bool = false) -> Bool {
        guard let partSize, partSize > 0 else { return false }
        if resumedThisLaunch, !lastFailureWasNetwork { return false }
        return autoDownload || consentedID == entryID
    }

    /// Whether a new pick in Settings leaves the running download alone: it
    /// does when the pick still comes to the model being downloaded, on
    /// Griasa's own engine (or no engine preference). Stopping it then would
    /// only make the person wait for the same file again.
    static func keepsDownload(downloadingID: String?, resolvedID: String?, preferred: LocalEngine?) -> Bool {
        guard let downloadingID, downloadingID == resolvedID else { return false }
        return preferred == nil || preferred == .griasa
    }

    static func percent(have: Int64, of total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(have, total) * 100 / total)
    }
}
