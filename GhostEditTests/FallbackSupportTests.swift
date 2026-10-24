import XCTest
@testable import GhostEditCore

final class FallbackSupportTests: XCTestCase {
    // MARK: - nextFallbackModel

    func testNextFallbackModelReturnsTheFollowingCachedModel() {
        let models = ["haiku", "sonnet", "opus"]
        XCTAssertEqual(FallbackSupport.nextFallbackModel(currentModel: "haiku", models: models), "sonnet")
        XCTAssertEqual(FallbackSupport.nextFallbackModel(currentModel: "sonnet", models: models), "opus")
    }

    func testNextFallbackModelReturnsNilWhenMissingOrLast() {
        let models = ["grok-4.7", "grok-4.6"]
        XCTAssertNil(FallbackSupport.nextFallbackModel(currentModel: "missing", models: models))
        XCTAssertNil(FallbackSupport.nextFallbackModel(currentModel: "grok-4.6", models: models))
        XCTAssertNil(FallbackSupport.nextFallbackModel(currentModel: "haiku", models: []))
    }

    // MARK: - isRetriable

    func testIsRetriableProcessFailed() {
        let error = ShellRunnerError.processFailed(exitCode: 1, stderr: "error")
        XCTAssertTrue(FallbackSupport.isRetriable(error))
    }

    func testIsRetriableTimedOut() {
        let error = ShellRunnerError.timedOut(seconds: 60)
        XCTAssertTrue(FallbackSupport.isRetriable(error))
    }

    func testIsRetriableEmptyResponse() {
        let error = ShellRunnerError.emptyResponse
        XCTAssertTrue(FallbackSupport.isRetriable(error))
    }

    func testIsNotRetriableCLINotFound() {
        let error = ShellRunnerError.cliNotFound(provider: .claude)
        XCTAssertFalse(FallbackSupport.isRetriable(error))
    }

    func testIsNotRetriableAuthRequired() {
        let error = ShellRunnerError.authenticationRequired(provider: .claude)
        XCTAssertFalse(FallbackSupport.isRetriable(error))
    }

    func testIsNotRetriableLaunchFailed() {
        let error = ShellRunnerError.launchFailed("error")
        XCTAssertFalse(FallbackSupport.isRetriable(error))
    }

    func testIsNotRetriableProtectedTokensModified() {
        let error = ShellRunnerError.protectedTokensModified
        XCTAssertFalse(FallbackSupport.isRetriable(error))
    }

    func testIsNotRetriableGenericError() {
        struct GenericError: Error {}
        XCTAssertFalse(FallbackSupport.isRetriable(GenericError()))
    }
}
