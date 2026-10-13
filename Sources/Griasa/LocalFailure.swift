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
}
