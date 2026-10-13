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

    static func existing(partSize: Int64?, expectedSize: Int64) -> Existing {
        guard let partSize, partSize > 0 else { return .requestFrom(0) }
        if partSize > expectedSize { return .discard }
        if partSize == expectedSize { return .verifyNow }
        return .requestFrom(partSize)
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
        case fail(status: Int)
    }

    static func response(status: Int, requestedFrom offset: Int64, contentRangeStart: Int64?) -> Response {
        switch status {
        case 200:
            // A server that ignored the Range sends the whole file.
            return offset == 0 ? .append : .restartFromZero
        case 206:
            // Partial content must start exactly where the part ends, or the
            // two would be stitched into a file nobody published.
            guard offset > 0, contentRangeStart == offset else { return .discardAndRetry }
            return .append
        case 416:
            // Range not satisfiable: the part is not a prefix of this file.
            return .discardAndRetry
        default:
            return .fail(status: status)
        }
    }

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

    static func percent(have: Int64, of total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(have, total) * 100 / total)
    }
}
