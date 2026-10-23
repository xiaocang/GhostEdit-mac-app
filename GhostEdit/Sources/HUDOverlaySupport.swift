import CoreGraphics
import Foundation

enum HUDOverlayState: Equatable {
    case working
    case success
    case successWithCount(Int)
    case successWithDiff([DiffSegment], toolsUsed: String)
    case error(String)
    case fallback
}

struct HUDOverlayContent: Equatable {
    let emoji: String
    let message: String
}

enum HUDOverlaySupport {
    // Layout
    static let windowWidth: CGFloat = 200
    static let windowHeight: CGFloat = 200
    static let cornerRadius: CGFloat = 18
    static let iconSize: CGFloat = 64
    static let messageFontSize: CGFloat = 14
    static let verticalSpacing: CGFloat = 12
    static let contentInset: CGFloat = 20

    // Timing
    static let fadeInDuration: CGFloat = 0.18
    static let fadeOutDuration: CGFloat = 0.25
    /// Brief confirmation fade. Corrections and failures are sticky instead.
    static let successAutoDismissDelay: TimeInterval = 1.0

    // Diff overlay layout
    static let diffWindowWidth: CGFloat = 360
    static let diffWindowMaxHeight: CGFloat = 280
    static let diffFontSize: CGFloat = 12
    static let diffContentInset: CGFloat = 12
    static let diffIconSize: CGFloat = 40

    static let defaultErrorMessage = "Something went wrong"

    // SVG path data for the ghost icon (from Remotion source, viewBox 197 152 630 630).
    static let ghostBodyPath = "M 512 175 C 654 175 742 280 742 430 L 742 660 C 742 720 720 760 684 760 C 648 760 630 700 598 700 C 566 700 548 760 512 760 C 476 760 458 700 426 700 C 394 700 376 760 340 760 C 304 760 282 720 282 660 L 282 430 C 282 280 370 175 512 175 Z"
    static let ghostMouthPath = "M 478 500 L 546 500 C 546 555 478 555 478 500 Z"
    static let ghostBridgePath = "M 498 385 Q 512 365 526 385"
    static let ghostLeftArmPath = "M 342 390 L 295 410"
    static let ghostRightArmPath = "M 682 390 L 729 410"
    static let ghostViewBoxOriginX: CGFloat = 197
    static let ghostViewBoxOriginY: CGFloat = 152
    static let ghostViewBoxSize: CGFloat = 630

    struct GhostEye: Equatable {
        let cx: CGFloat
        let cy: CGFloat
        let rx: CGFloat
        let ry: CGFloat
        let rotation: CGFloat
        let highlightCX: CGFloat
        let highlightCY: CGFloat
        let highlightR: CGFloat
        let lensR: CGFloat
    }

    static let ghostLeftEye = GhostEye(
        cx: 420, cy: 390, rx: 48, ry: 60, rotation: -8,
        highlightCX: 436, highlightCY: 370, highlightR: 13,
        lensR: 78
    )

    static let ghostRightEye = GhostEye(
        cx: 604, cy: 390, rx: 48, ry: 60, rotation: 8,
        highlightCX: 620, highlightCY: 370, highlightR: 13,
        lensR: 78
    )

    static let ghostStrokeWidth: CGFloat = 14

    static func content(for state: HUDOverlayState) -> HUDOverlayContent {
        switch state {
        case .working:
            return HUDOverlayContent(emoji: "\u{1F47B}", message: "Working on it...")
        case .success:
            return HUDOverlayContent(emoji: "\u{1F47B}", message: "Done!")
        case .successWithCount(let chars):
            return HUDOverlayContent(emoji: "\u{1F47B}", message: "Done! (\(chars) chars fixed)")
        case .successWithDiff:
            return HUDOverlayContent(emoji: "\u{1F47B}", message: "Done!")
        case .error(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty ? defaultErrorMessage : trimmed
            return HUDOverlayContent(emoji: "\u{1F47B}", message: message)
        case .fallback:
            return HUDOverlayContent(emoji: "\u{1F47B}", message: "Fixed (basic mode)")
        }
    }

    static func showsSpectacles(for state: HUDOverlayState) -> Bool {
        switch state {
        case .working:
            return true
        case .success, .successWithCount, .successWithDiff, .error, .fallback:
            return false
        }
    }

    /// Automatic fade delay for brief confirmations. Loading, correction, and
    /// failure states return nil because they stay until the next transition or
    /// until the user interacts outside the panel.
    static func autoDismissDelay(for state: HUDOverlayState) -> TimeInterval? {
        switch state {
        case .success, .successWithCount, .fallback:
            return successAutoDismissDelay
        case .working, .successWithDiff, .error:
            return nil
        }
    }

    /// Height for the correction overlay. Compact content uses the standard
    /// size, longer content may grow modestly, and the result is bounded by the
    /// visible screen; overflow scrolls inside the text views.
    static func diffPanelHeight(
        intrinsicContentHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> CGFloat {
        let compactMinimum: CGFloat = 220
        let screenBound = max(compactMinimum, visibleFrameHeight - 60)
        let growthBound = min(screenBound, diffWindowMaxHeight * 1.5)
        return min(max(intrinsicContentHeight, compactMinimum), growthBound)
    }

    /// Original-side rendering data for a correction.
    struct OriginalDiffDisplay {
        /// Original text, unchanged: only equal and deletion segments contribute.
        let text: String
        /// UTF-16 ranges of removed text, drawn with a red underline.
        let deletionRanges: [NSRange]
        /// UTF-16 ranges of adjacent original characters anchoring pure
        /// insertions that have no removed span to underline.
        let insertionAnchorRanges: [NSRange]
    }

    /// Build the original text and its highlight ranges without mutating it.
    /// Deletions are underlined directly; pure insertions underline the closest
    /// composed character (or punctuation) immediately before or after them.
    static func originalDiffDisplay(from segments: [DiffSegment]) -> OriginalDiffDisplay {
        var text = ""
        var offset = 0
        var pieces: [(kind: DiffSegmentKind, range: NSRange)] = []
        var insertionIndices: [Int] = []
        var deletionRanges: [NSRange] = []

        for segment in segments {
            switch segment.kind {
            case .insertion:
                insertionIndices.append(pieces.count)
            case .equal, .deletion:
                let length = (segment.text as NSString).length
                let range = NSRange(location: offset, length: length)
                pieces.append((kind: segment.kind, range: range))
                if segment.kind == .deletion, length > 0 {
                    deletionRanges.append(range)
                }
                text += segment.text
                offset += length
            }
        }

        let textBridge = text as NSString
        var anchorRanges: [NSRange] = []
        for index in insertionIndices {
            let previous: (kind: DiffSegmentKind, range: NSRange)? =
                index > 0 ? pieces[index - 1] : nil
            let next: (kind: DiffSegmentKind, range: NSRange)? =
                index < pieces.count ? pieces[index] : nil

            if let previous, previous.kind == .deletion, previous.range.length > 0 {
                continue
            }
            if let next, next.kind == .deletion, next.range.length > 0 {
                continue
            }

            var anchorRange: NSRange?
            if let previous, previous.kind == .equal, previous.range.length > 0 {
                anchorRange = textBridge.rangeOfComposedCharacterSequence(
                    at: NSMaxRange(previous.range) - 1
                )
            } else if let next, next.kind == .equal, next.range.length > 0 {
                anchorRange = textBridge.rangeOfComposedCharacterSequence(
                    at: next.range.location
                )
            }

            if let anchorRange, !anchorRanges.contains(anchorRange) {
                anchorRanges.append(anchorRange)
            }
        }

        return OriginalDiffDisplay(
            text: text,
            deletionRanges: deletionRanges,
            insertionAnchorRanges: anchorRanges
        )
    }


    static func windowOrigin(screenSize: CGSize) -> CGPoint {
        let x = (screenSize.width - windowWidth) / 2
        let y = (screenSize.height - windowHeight) / 2
        return CGPoint(x: x, y: y)
    }

    static func windowOrigin(screenSize: CGSize, windowSize: CGSize) -> CGPoint {
        let x = (screenSize.width - windowSize.width) / 2
        let y = (screenSize.height - windowSize.height) / 2
        return CGPoint(x: x, y: y)
    }
}
