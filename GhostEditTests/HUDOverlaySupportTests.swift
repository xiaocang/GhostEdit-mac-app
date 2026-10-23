import XCTest
import CoreGraphics
@testable import GhostEditCore

final class HUDOverlaySupportTests: XCTestCase {

    // MARK: - content(for:)

    func testContentForWorkingState() {
        let content = HUDOverlaySupport.content(for: .working)
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Working on it...")
    }

    func testContentForSuccessState() {
        let content = HUDOverlaySupport.content(for: .success)
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Done!")
    }

    func testContentForSuccessWithCountState() {
        let content = HUDOverlaySupport.content(for: .successWithCount(142))
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Done! (142 chars fixed)")
    }

    func testSuccessWithCountSpectaclesIsFalse() {
        XCTAssertFalse(HUDOverlaySupport.showsSpectacles(for: .successWithCount(50)))
    }

    func testSuccessWithCountAutoDismissDelay() {
        XCTAssertEqual(
            HUDOverlaySupport.autoDismissDelay(for: .successWithCount(50)),
            HUDOverlaySupport.successAutoDismissDelay
        )
    }

    func testContentForFallbackState() {
        let content = HUDOverlaySupport.content(for: .fallback)
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Fixed (basic mode)")
    }

    func testFallbackSpectaclesIsFalse() {
        XCTAssertFalse(HUDOverlaySupport.showsSpectacles(for: .fallback))
    }

    func testFallbackAutoDismissDelay() {
        XCTAssertEqual(
            HUDOverlaySupport.autoDismissDelay(for: .fallback),
            HUDOverlaySupport.successAutoDismissDelay
        )
    }

    func testContentForErrorStateWithDetail() {
        let content = HUDOverlaySupport.content(for: .error("Network timeout"))
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Network timeout")
    }

    func testContentForErrorStateWithEmptyStringFallsBack() {
        let content = HUDOverlaySupport.content(for: .error(""))
        XCTAssertEqual(content.message, HUDOverlaySupport.defaultErrorMessage)
    }

    func testContentForErrorStateWithWhitespaceFallsBack() {
        let content = HUDOverlaySupport.content(for: .error("   "))
        XCTAssertEqual(content.message, HUDOverlaySupport.defaultErrorMessage)
    }

    func testContentForErrorStateWithNewlinesFallsBack() {
        let content = HUDOverlaySupport.content(for: .error(" \n\t "))
        XCTAssertEqual(content.message, HUDOverlaySupport.defaultErrorMessage)
    }

    // MARK: - showsSpectacles(for:)

    func testShowsSpectaclesForWorkingIsTrue() {
        XCTAssertTrue(HUDOverlaySupport.showsSpectacles(for: .working))
    }

    func testShowsSpectaclesForSuccessIsFalse() {
        XCTAssertFalse(HUDOverlaySupport.showsSpectacles(for: .success))
    }

    func testShowsSpectaclesForErrorIsFalse() {
        XCTAssertFalse(HUDOverlaySupport.showsSpectacles(for: .error("x")))
    }

    // MARK: - autoDismissDelay(for:)

    func testAutoDismissDelayForWorkingIsNil() {
        XCTAssertNil(HUDOverlaySupport.autoDismissDelay(for: .working))
    }

    func testAutoDismissDelayForSuccess() {
        XCTAssertEqual(
            HUDOverlaySupport.autoDismissDelay(for: .success),
            HUDOverlaySupport.successAutoDismissDelay
        )
    }

    func testAutoDismissDelayForErrorIsNil() {
        XCTAssertNil(HUDOverlaySupport.autoDismissDelay(for: .error("oops")))
    }

    func testBriefConfirmationStatesAutoDismiss() {
        XCTAssertEqual(
            HUDOverlaySupport.autoDismissDelay(for: .successWithCount(10)),
            HUDOverlaySupport.successAutoDismissDelay
        )
        XCTAssertEqual(
            HUDOverlaySupport.autoDismissDelay(for: .fallback),
            HUDOverlaySupport.successAutoDismissDelay
        )
    }

    func testStickyStatesHaveNoAutoDismissDelay() {
        XCTAssertNil(HUDOverlaySupport.autoDismissDelay(for: .working))
        XCTAssertNil(HUDOverlaySupport.autoDismissDelay(for: .successWithDiff([], toolsUsed: "")))
        XCTAssertNil(HUDOverlaySupport.autoDismissDelay(for: .error("x")))
    }

    // MARK: - windowOrigin(screenSize:)

    func testWindowOriginCentersOnScreen() {
        let screenSize = CGSize(width: 1920, height: 1080)
        let origin = HUDOverlaySupport.windowOrigin(screenSize: screenSize)

        let expectedX = (1920 - HUDOverlaySupport.windowWidth) / 2
        let expectedY = (1080 - HUDOverlaySupport.windowHeight) / 2

        XCTAssertEqual(origin.x, expectedX)
        XCTAssertEqual(origin.y, expectedY)
    }

    func testWindowOriginWithSmallScreen() {
        let screenSize = CGSize(width: 400, height: 300)
        let origin = HUDOverlaySupport.windowOrigin(screenSize: screenSize)

        let expectedX = (400 - HUDOverlaySupport.windowWidth) / 2
        let expectedY = (300 - HUDOverlaySupport.windowHeight) / 2

        XCTAssertEqual(origin.x, expectedX)
        XCTAssertEqual(origin.y, expectedY)
    }

    func testWindowOriginWithExactWindowSizeScreen() {
        let screenSize = CGSize(width: HUDOverlaySupport.windowWidth, height: HUDOverlaySupport.windowHeight)
        let origin = HUDOverlaySupport.windowOrigin(screenSize: screenSize)
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
    }

    // MARK: - successWithDiff state

    func testContentForSuccessWithDiffState() {
        let segments = [DiffSegment(kind: .equal, text: "hi "), DiffSegment(kind: .insertion, text: "world")]
        let content = HUDOverlaySupport.content(for: .successWithDiff(segments, toolsUsed: "Claude"))
        XCTAssertEqual(content.emoji, "\u{1F47B}")
        XCTAssertEqual(content.message, "Done!")
    }

    func testSuccessWithDiffSpectaclesIsFalse() {
        let segments = [DiffSegment(kind: .insertion, text: "x")]
        XCTAssertFalse(HUDOverlaySupport.showsSpectacles(for: .successWithDiff(segments, toolsUsed: "")))
    }

    func testSuccessWithDiffAutoDismissDelayIsNil() {
        let segments = [DiffSegment(kind: .insertion, text: "x")]
        XCTAssertNil(
            HUDOverlaySupport.autoDismissDelay(for: .successWithDiff(segments, toolsUsed: ""))
        )
    }

    func testSuccessWithDiffEquatable() {
        let seg1 = [DiffSegment(kind: .equal, text: "a"), DiffSegment(kind: .insertion, text: "b")]
        let seg2 = [DiffSegment(kind: .equal, text: "a"), DiffSegment(kind: .insertion, text: "b")]
        let seg3 = [DiffSegment(kind: .deletion, text: "c")]

        XCTAssertEqual(
            HUDOverlayState.successWithDiff(seg1, toolsUsed: "t"),
            HUDOverlayState.successWithDiff(seg2, toolsUsed: "t")
        )
        XCTAssertNotEqual(
            HUDOverlayState.successWithDiff(seg1, toolsUsed: "t"),
            HUDOverlayState.successWithDiff(seg3, toolsUsed: "t")
        )
        XCTAssertNotEqual(
            HUDOverlayState.successWithDiff(seg1, toolsUsed: "a"),
            HUDOverlayState.successWithDiff(seg1, toolsUsed: "b")
        )
        XCTAssertNotEqual(
            HUDOverlayState.successWithDiff(seg1, toolsUsed: ""),
            HUDOverlayState.success
        )
    }

    // MARK: - windowOrigin(screenSize:windowSize:)

    func testWindowOriginWithCustomSize() {
        let screenSize = CGSize(width: 1920, height: 1080)
        let windowSize = CGSize(width: 360, height: 280)
        let origin = HUDOverlaySupport.windowOrigin(screenSize: screenSize, windowSize: windowSize)

        let expectedX = (1920 - 360.0) / 2
        let expectedY = (1080 - 280.0) / 2

        XCTAssertEqual(origin.x, expectedX)
        XCTAssertEqual(origin.y, expectedY)
    }

    func testWindowOriginWithCustomSizeExactFit() {
        let size = CGSize(width: 400, height: 300)
        let origin = HUDOverlaySupport.windowOrigin(screenSize: size, windowSize: size)
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
    }

    // MARK: - Constants sanity checks

    func testLayoutConstantsArePositive() {
        XCTAssertGreaterThan(HUDOverlaySupport.windowWidth, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.windowHeight, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.cornerRadius, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.iconSize, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.messageFontSize, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.verticalSpacing, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.contentInset, 0)
    }

    func testDiffLayoutConstantsArePositive() {
        XCTAssertGreaterThan(HUDOverlaySupport.diffWindowWidth, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.diffWindowMaxHeight, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.diffFontSize, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.diffContentInset, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.diffIconSize, 0)
    }


    // MARK: - diffPanelHeight

    func testDiffPanelHeightKeepsCompactMinimum() {
        let height = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: 100,
            visibleFrameHeight: 900
        )
        XCTAssertEqual(height, 220)
    }

    func testDiffPanelHeightGrowsForLongerContent() {
        let height = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: 320,
            visibleFrameHeight: 900
        )
        XCTAssertEqual(height, 320)
    }

    func testDiffPanelHeightCapsGrowthForVeryLongContent() {
        let height = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: 2000,
            visibleFrameHeight: 900
        )
        XCTAssertEqual(height, HUDOverlaySupport.diffWindowMaxHeight * 1.5)
    }

    func testDiffPanelHeightNeverExceedsVisibleScreen() {
        let height = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: 2000,
            visibleFrameHeight: 400
        )
        XCTAssertEqual(height, 340)
    }

    func testDiffPanelHeightOnShortScreen() {
        let height = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: 2000,
            visibleFrameHeight: 200
        )
        XCTAssertEqual(height, 220)
    }

    // MARK: - originalDiffDisplay

    func testOriginalDiffDisplayKeepsOriginalTextAndDeletionRanges() {
        let segments = [
            DiffSegment(kind: .equal, text: "a"),
            DiffSegment(kind: .deletion, text: "bad"),
            DiffSegment(kind: .equal, text: "c"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "abadc", "The original erroneous text must remain unchanged")
        XCTAssertEqual(display.deletionRanges, [NSRange(location: 1, length: 3)])
        XCTAssertTrue(display.insertionAnchorRanges.isEmpty)
    }

    func testOriginalDiffDisplayAnchorsTrailingPureInsertionToPreviousCharacter() {
        let segments = [
            DiffSegment(kind: .equal, text: "Hello "),
            DiffSegment(kind: .insertion, text: "world"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "Hello ")
        XCTAssertEqual(display.deletionRanges, [])
        XCTAssertEqual(display.insertionAnchorRanges, [NSRange(location: 5, length: 1)])
    }

    func testOriginalDiffDisplayAnchorsLeadingPureInsertionToNextCharacter() {
        let segments = [
            DiffSegment(kind: .insertion, text: "Hi "),
            DiffSegment(kind: .equal, text: "there"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "there")
        XCTAssertEqual(display.insertionAnchorRanges, [NSRange(location: 0, length: 1)])
    }

    func testOriginalDiffDisplaySkipsAnchorWhenInsertionFollowsDeletion() {
        let segments = [
            DiffSegment(kind: .equal, text: "a"),
            DiffSegment(kind: .deletion, text: "b"),
            DiffSegment(kind: .insertion, text: "x"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "ab")
        XCTAssertEqual(display.deletionRanges, [NSRange(location: 1, length: 1)])
        XCTAssertTrue(display.insertionAnchorRanges.isEmpty)
    }

    func testOriginalDiffDisplaySkipsAnchorWhenInsertionPrecedesDeletion() {
        let segments = [
            DiffSegment(kind: .equal, text: "a"),
            DiffSegment(kind: .insertion, text: "x"),
            DiffSegment(kind: .deletion, text: "b"),
            DiffSegment(kind: .equal, text: "c"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "abc")
        XCTAssertEqual(display.deletionRanges, [NSRange(location: 1, length: 1)])
        XCTAssertTrue(display.insertionAnchorRanges.isEmpty)
    }

    func testOriginalDiffDisplayWithoutOriginalTextHasNoAnchor() {
        let display = HUDOverlaySupport.originalDiffDisplay(
            from: [DiffSegment(kind: .insertion, text: "new")]
        )
        XCTAssertEqual(display.text, "")
        XCTAssertTrue(display.deletionRanges.isEmpty)
        XCTAssertTrue(display.insertionAnchorRanges.isEmpty)
    }

    func testOriginalDiffDisplayDeduplicatesAnchorForAdjacentInsertions() {
        let segments = [
            DiffSegment(kind: .equal, text: "a"),
            DiffSegment(kind: .insertion, text: "x"),
            DiffSegment(kind: .insertion, text: "y"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.insertionAnchorRanges, [NSRange(location: 0, length: 1)])
    }

    func testOriginalDiffDisplayAnchorKeepsComposedCharacterWhole() {
        let emoji = "👨‍👩‍👧"
        let segments = [
            DiffSegment(kind: .equal, text: "a\(emoji)"),
            DiffSegment(kind: .insertion, text: "!"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        let textLength = (display.text as NSString).length
        XCTAssertEqual(display.insertionAnchorRanges.count, 1)
        let anchor = display.insertionAnchorRanges[0]
        XCTAssertGreaterThan(anchor.length, 1)
        XCTAssertEqual(NSMaxRange(anchor), textLength)
    }

    func testOriginalDiffDisplayIgnoresEmptyDeletion() {
        let segments = [
            DiffSegment(kind: .equal, text: "a"),
            DiffSegment(kind: .deletion, text: ""),
            DiffSegment(kind: .equal, text: "b"),
        ]
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        XCTAssertEqual(display.text, "ab")
        XCTAssertTrue(display.deletionRanges.isEmpty)
    }


    func testFadeOutIsLongerThanFadeIn() {
        XCTAssertGreaterThanOrEqual(
            HUDOverlaySupport.fadeOutDuration,
            HUDOverlaySupport.fadeInDuration
        )
    }

    func testDefaultErrorMessageIsNonEmpty() {
        XCTAssertFalse(HUDOverlaySupport.defaultErrorMessage.isEmpty)
    }

    // MARK: - Ghost SVG data sanity checks

    func testGhostPathsAreNonEmpty() {
        XCTAssertFalse(HUDOverlaySupport.ghostBodyPath.isEmpty)
        XCTAssertFalse(HUDOverlaySupport.ghostMouthPath.isEmpty)
        XCTAssertFalse(HUDOverlaySupport.ghostBridgePath.isEmpty)
        XCTAssertFalse(HUDOverlaySupport.ghostLeftArmPath.isEmpty)
        XCTAssertFalse(HUDOverlaySupport.ghostRightArmPath.isEmpty)
    }

    func testGhostViewBoxValuesArePositive() {
        XCTAssertGreaterThan(HUDOverlaySupport.ghostViewBoxSize, 0)
        XCTAssertGreaterThan(HUDOverlaySupport.ghostStrokeWidth, 0)
    }

    func testGhostEyePropertiesArePositive() {
        let leftEye = HUDOverlaySupport.ghostLeftEye
        XCTAssertGreaterThan(leftEye.rx, 0)
        XCTAssertGreaterThan(leftEye.ry, 0)
        XCTAssertGreaterThan(leftEye.highlightR, 0)
        XCTAssertGreaterThan(leftEye.lensR, 0)

        let rightEye = HUDOverlaySupport.ghostRightEye
        XCTAssertGreaterThan(rightEye.rx, 0)
        XCTAssertGreaterThan(rightEye.ry, 0)
        XCTAssertGreaterThan(rightEye.highlightR, 0)
        XCTAssertGreaterThan(rightEye.lensR, 0)
    }

    func testGhostEyesAreSymmetric() {
        let left = HUDOverlaySupport.ghostLeftEye
        let right = HUDOverlaySupport.ghostRightEye
        XCTAssertEqual(left.rx, right.rx)
        XCTAssertEqual(left.ry, right.ry)
        XCTAssertEqual(left.highlightR, right.highlightR)
        XCTAssertEqual(left.lensR, right.lensR)
        XCTAssertEqual(left.rotation, -right.rotation)
    }

    func testGhostBodyPathStartsWithMove() {
        XCTAssertTrue(HUDOverlaySupport.ghostBodyPath.hasPrefix("M"))
    }

    func testGhostBodyPathEndsWithClose() {
        XCTAssertTrue(HUDOverlaySupport.ghostBodyPath.hasSuffix("Z"))
    }

    // MARK: - Equatable conformance

    func testHUDOverlayStateEquatable() {
        XCTAssertEqual(HUDOverlayState.working, HUDOverlayState.working)
        XCTAssertEqual(HUDOverlayState.success, HUDOverlayState.success)
        XCTAssertEqual(HUDOverlayState.successWithCount(10), HUDOverlayState.successWithCount(10))
        XCTAssertEqual(HUDOverlayState.error("a"), HUDOverlayState.error("a"))
        XCTAssertNotEqual(HUDOverlayState.working, HUDOverlayState.success)
        XCTAssertNotEqual(HUDOverlayState.successWithCount(10), HUDOverlayState.successWithCount(20))
        XCTAssertNotEqual(HUDOverlayState.success, HUDOverlayState.successWithCount(10))
        XCTAssertNotEqual(HUDOverlayState.error("a"), HUDOverlayState.error("b"))
        XCTAssertNotEqual(HUDOverlayState.working, HUDOverlayState.error("a"))
        XCTAssertNotEqual(HUDOverlayState.success, HUDOverlayState.error("a"))
        XCTAssertEqual(HUDOverlayState.fallback, HUDOverlayState.fallback)
        XCTAssertNotEqual(HUDOverlayState.fallback, HUDOverlayState.success)
        XCTAssertNotEqual(HUDOverlayState.fallback, HUDOverlayState.working)
    }

    func testHUDOverlayContentEquatable() {
        let a = HUDOverlayContent(emoji: "X", message: "hello")
        let b = HUDOverlayContent(emoji: "X", message: "hello")
        let c = HUDOverlayContent(emoji: "Y", message: "hello")
        let d = HUDOverlayContent(emoji: "X", message: "world")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    // MARK: - Content consistency

    func testAllStatesProduceNonEmptyContent() {
        let diffState = HUDOverlayState.successWithDiff(
            [DiffSegment(kind: .insertion, text: "hello")], toolsUsed: "test"
        )
        for state: HUDOverlayState in [.working, .success, .successWithCount(99), diffState, .error("test"), .fallback] {
            let content = HUDOverlaySupport.content(for: state)
            XCTAssertFalse(content.emoji.isEmpty, "emoji should not be empty for \(state)")
            XCTAssertFalse(content.message.isEmpty, "message should not be empty for \(state)")
        }
    }

    func testWorkingAndSuccessHaveDifferentMessages() {
        let working = HUDOverlaySupport.content(for: .working)
        let success = HUDOverlaySupport.content(for: .success)
        XCTAssertNotEqual(working.message, success.message)
    }

    func testGhostEyeEquatable() {
        let eye1 = HUDOverlaySupport.ghostLeftEye
        let eye2 = HUDOverlaySupport.GhostEye(
            cx: 420, cy: 390, rx: 48, ry: 60, rotation: -8,
            highlightCX: 436, highlightCY: 370, highlightR: 13,
            lensR: 78
        )
        let eye3 = HUDOverlaySupport.ghostRightEye
        XCTAssertEqual(eye1, eye2)
        XCTAssertNotEqual(eye1, eye3)
    }
}
