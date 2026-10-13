import Foundation

/// How a failed request to a model on this Mac should be treated. Slow is not
/// gone: a timeout means the model is there and working, so it is reported and
/// never answered with a refresh-and-retry that would double the wait.
///
/// Foundation only, so `test.sh` can reach it.
enum LocalFailure {
    enum Kind: Equatable { case unreachable, slow, other }

    static func kind(of error: Error) -> Kind {
        if let error = error as? URLError {
            if error.code == .timedOut { return .slow }
            return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
                ? .unreachable : .other
        }
        let error = error as NSError
        return error.domain == "Griasa" && error.code == 6 ? .unreachable : .other
    }

    /// The timeout a request gets on a local engine Griasa manages. A model on
    /// this Mac writes a long summary far slower than a cloud model, which is
    /// what callers' timeouts were set for, so background jobs (a minute or
    /// more: summaries, promises) get three times as long. Short timeouts are
    /// interactive — dictation cleanup waits 10 s while the person waits for
    /// text — and stay as they are; the local fallback is better than 30 s.
    static let backgroundTimeout: TimeInterval = 60

    static func timeout(_ requested: TimeInterval, managedLocal: Bool) -> TimeInterval {
        managedLocal && requested >= backgroundTimeout ? requested * 3 : requested
    }
}
