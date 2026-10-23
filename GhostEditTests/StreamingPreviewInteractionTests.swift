import AppKit
import XCTest
@testable import GhostEditCore

final class StreamingPreviewInteractionTests: XCTestCase {
    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.compactMap { textView(in: $0) }.first
    }

    func testTitlebarCloseCancelsExactlyOnceAndInvalidatesRequest() {
        onMain {
            _ = NSApplication.shared
            var cancellations = 0
            let controller = StreamingPreviewController(originalText: "old", onAccept: { _ in
                XCTFail("Close must not accept")
            }, onCopy: { _ in }, onDismiss: { _ in cancellations += 1 }, onRegenerate: {})
            let request = controller.requestID
            controller.window?.performClose(nil)
            controller.cancelOperation(nil)
            controller.markComplete(correctedText: "late result")
            XCTAssertEqual(cancellations, 1)
            XCTAssertFalse(controller.isCurrentRequest(request))
            XCTAssertFalse(controller.isComplete)
        }
    }

    func testFailureCanRetryAndOldRequestCannotReplaceRetry() {
        onMain {
            _ = NSApplication.shared
            var retries = 0
            let controller = StreamingPreviewController(originalText: "old", onAccept: { _ in },
                onCopy: { _ in }, onDismiss: { _ in }, onRegenerate: { retries += 1 })
            let oldRequest = controller.requestID
            controller.showError("Server unavailable")
            let retry = buttons(in: controller.window!.contentView!).first { $0.keyEquivalent == "r" }!
            XCTAssertTrue(retry.isEnabled)
            retry.performClick(nil)
            XCTAssertEqual(retries, 1)
            XCTAssertFalse(controller.isCurrentRequest(oldRequest))
            XCTAssertTrue(controller.isCurrentRequest(controller.requestID))
            // This is the same admission check used by AppDelegate for chunks,
            // success/history and failure callbacks.
            if controller.isCurrentRequest(oldRequest) {
                controller.markComplete(correctedText: "obsolete")
            }
            XCTAssertFalse(controller.isComplete)
            controller.cancelOperation(nil)
        }
    }

    func testApplyRefusalKeepsResultThenAcceptsExactlyOnceWithoutCancelling() {
        onMain {
            _ = NSApplication.shared
            var accepted: [String] = []
            var cancellations = 0
            let controller = StreamingPreviewController(originalText: "old", onAccept: { accepted.append($0) },
                onCopy: { _ in }, onDismiss: { _ in cancellations += 1 }, onRegenerate: {})
            controller.markComplete(correctedText: "new")
            controller.validateAcceptance = { "Source changed" }
            let apply = buttons(in: controller.window!.contentView!).first { $0.keyEquivalent == "\r" }!
            apply.performClick(nil)
            XCTAssertTrue(accepted.isEmpty)
            XCTAssertFalse(controller.isDismissed)
            XCTAssertTrue(controller.isComplete)
            controller.validateAcceptance = { nil }
            let window = controller.window!
            window.makeFirstResponder(textView(in: window.contentView!))
            let applyShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            XCTAssertTrue(window.performKeyEquivalent(with: applyShortcut), "Apply must work while preview text has focus")
            apply.performClick(nil)
            controller.cancelOperation(nil)
            XCTAssertEqual(accepted, ["new"])
            XCTAssertEqual(cancellations, 0)
        }
    }

    func testCommandShortcutsWithTextViewFirstResponderAndUnchangedDismissal() {
        onMain {
            _ = NSApplication.shared
            var cancellations = 0
            var retries = 0
            let controller = StreamingPreviewController(originalText: "same", onAccept: { _ in
                XCTFail("An unchanged correction must not apply")
            }, onCopy: { _ in }, onDismiss: { _ in cancellations += 1 }, onRegenerate: { retries += 1 })
            controller.markComplete(correctedText: "same")
            let window = controller.window!
            window.makeFirstResponder(textView(in: window.contentView!))
            let controls = buttons(in: window.contentView!)
            XCTAssertFalse(controls.first { $0.keyEquivalent == "\r" }!.isEnabled)
            let retry = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
            XCTAssertTrue(window.performKeyEquivalent(with: retry))
            XCTAssertEqual(retries, 1)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            XCTAssertTrue(window.performKeyEquivalent(with: escape))
            XCTAssertEqual(cancellations, 1)
        }
    }

    func testUnchangedResultDismissesWithoutApplyingOrCancelling() {
        let dismissed = expectation(description: "Unchanged result fades away")
        var controller: StreamingPreviewController!
        var dismissals = 0
        onMain {
            controller = StreamingPreviewController(originalText: "Already correct.",
                onAccept: { _ in XCTFail("Unchanged text must not be applied") },
                onCopy: { _ in XCTFail("A green check must not change the clipboard") },
                onDismiss: { reason in
                    guard case .noChanges = reason else {
                        XCTFail("An unchanged result must finish as noChanges")
                        return
                    }
                    dismissals += 1
                    dismissed.fulfill()
                }, onRegenerate: {})
            controller.successDismissDelay = 0.02
            controller.markComplete(correctedText: "Already correct.")
        }
        wait(for: [dismissed], timeout: 3)
        onMain {
            XCTAssertTrue(controller.isDismissed, "The finished preview must release its request")
            controller.cancelOperation(nil)
            controller.markComplete(correctedText: "Late correction")
            XCTAssertEqual(dismissals, 1, "Fade, close and late results must not finish twice")
        }
    }

    func testRetryPreventsPreviousSuccessFadeFromClosingNewRequest() {
        let checked = expectation(description: "Previous fade deadline passed")
        var controller: StreamingPreviewController!
        var dismissals = 0
        onMain {
            controller = StreamingPreviewController(originalText: "Correct.",
                onAccept: { _ in XCTFail("A pending retry must not apply") },
                onCopy: { _ in }, onDismiss: { _ in dismissals += 1 }, onRegenerate: {})
            controller.successDismissDelay = 0.02
            controller.markComplete(correctedText: "Correct.")
            let oldRequest = controller.requestID
            let retry = buttons(in: controller.window!.contentView!).first { $0.keyEquivalent == "r" }!
            retry.performClick(nil)
            XCTAssertFalse(controller.isCurrentRequest(oldRequest), "Retry must invalidate the completed request")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertEqual(dismissals, 0, "The old success timer must not dismiss a retry")
                XCTAssertFalse(controller.isDismissed, "The retry must outlive the previous fade deadline")
                XCTAssertFalse(controller.isComplete, "Retry must still be awaiting its own result")
                checked.fulfill()
            }
        }
        wait(for: [checked], timeout: 3)
        onMain { controller.cancelOperation(nil) }
    }
}
