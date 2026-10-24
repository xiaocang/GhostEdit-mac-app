import Foundation

enum FallbackSupport {
    /// Returns the next cached model after the current one. Returns nil when the
    /// current model is missing or last. The list comes from the refreshed catalog,
    /// never from a compiled-in model list.
    static func nextFallbackModel(currentModel: String, models: [String]) -> String? {
        guard let idx = models.firstIndex(of: currentModel) else { return nil }
        let nextIdx = idx + 1
        guard nextIdx < models.count else { return nil }
        return models[nextIdx]
    }

    /// Determines whether the given error is retriable with a different model.
    static func isRetriable(_ error: Error) -> Bool {
        guard let shellError = error as? ShellRunnerError else {
            return false
        }
        switch shellError {
        case .processFailed, .timedOut, .emptyResponse:
            return true
        case .cliNotFound, .authenticationRequired, .launchFailed, .protectedTokensModified:
            return false
        }
    }
}
