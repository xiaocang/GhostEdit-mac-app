import AppKit

final class StreamingPreviewController: NSWindowController, NSWindowDelegate {
    enum DismissalReason {
        case cancelled
        case noChanges
        case focusChanged
    }

    private let originalText: String
    private let onAccept: (String) -> Void
    private let onCopy: (String) -> Void
    private let onDismiss: (DismissalReason) -> Void
    var onRegenerate: () -> Void
    var validateAcceptance: (() -> String?)?
    /// Delay before an unchanged result fades away. The panel stays visible until
    /// this elapses; any explicit interaction cancels the pending dismissal.
    var successDismissDelay: TimeInterval = 1.0
    private(set) var requestID = UUID()
    private(set) var isDismissed = false

    func isCurrentRequest(_ id: UUID) -> Bool {
        !isDismissed && requestID == id
    }

    private let leftTextView = NSTextView(frame: .zero)
    private let rightTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let phaseIcon = NSImageView()
    private let acceptButton: NSButton
    private let copyButton: NSButton
    private let regenerateButton: NSButton
    private let cancelButton: NSButton
    private let leftScrollView = NSScrollView()
    private let rightScrollView = NSScrollView()
    private let statsLabel = NSTextField(labelWithString: "")

    private let dismissMonitor = FloatingPanelDismissMonitor()
    private var pendingAutoDismiss: DispatchWorkItem?
    private weak var panelBackground: FloatingPanelBackgroundView?

    private var latestCorrectedText = ""
    private(set) var isComplete = false
    private var failureMessage: String?

    // Change navigation (Item 31)
    private let prevChangeButton = NSButton()
    private let nextChangeButton = NSButton()
    private var changeRanges: [(left: NSRange, right: NSRange)] = []
    private var currentChangeIndex: Int = -1

    init(
        originalText: String,
        onAccept: @escaping (String) -> Void,
        onCopy: @escaping (String) -> Void,
        onDismiss: @escaping (DismissalReason) -> Void,
        onRegenerate: @escaping () -> Void
    ) {
        self.originalText = originalText
        self.onAccept = onAccept
        self.onCopy = onCopy
        self.onDismiss = onDismiss
        self.onRegenerate = onRegenerate
        self.acceptButton = NSButton(title: "Apply (⌘↩)", target: nil, action: nil)
        self.copyButton = NSButton(title: "Copy", target: nil, action: nil)
        self.regenerateButton = NSButton(title: "Retry (⌘R)", target: nil, action: nil)
        self.cancelButton = NSButton(title: "Cancel (Esc)", target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Correction Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.setFrameAutosaveName("GhostEditStreamingPreview")
        if !window.setFrameUsingName("GhostEditStreamingPreview") { window.center() }
        window.minSize = NSSize(width: 600, height: 380)
        super.init(window: window)
        window.delegate = self
        acceptButton.target = self
        acceptButton.action = #selector(acceptClicked)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerateClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("StreamingPreviewController does not support NSCoder") }

    func updateStreaming(accumulatedText: String) {
        guard !isDismissed, !isComplete, failureMessage == nil else { return }
        setLoadingPhase(status: StreamingPreviewSupport.streamingStatus(charCount: accumulatedText.count))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        rightTextView.textStorage?.setAttributedString(
            NSAttributedString(string: accumulatedText, attributes: attrs)
        )
    }

    func markComplete(correctedText: String) {
        guard !isDismissed else { return }
        cancelPendingAutoDismiss()
        isComplete = true
        failureMessage = nil
        latestCorrectedText = correctedText

        let wordDiff = DiffSupport.wordDiff(old: originalText, new: correctedText)
        let isUnchanged = originalText == correctedText
        let changeCount = StreamingPreviewSupport.changeCount(from: wordDiff)
        // Whitespace-only corrections can report zero word changes; the texts
        // still differ, so keep them applyable/copyable instead of green-checking.
        let effectiveChangeCount = isUnchanged ? 0 : max(changeCount, 1)
        var status = StreamingPreviewSupport.completedStatus(changeCount: effectiveChangeCount)
        if !isUnchanged { status += " · ⇧⌘C copies" }
        statusLabel.stringValue = status
        statusLabel.toolTip = nil
        acceptButton.isEnabled = !isUnchanged
        cancelButton.title = isUnchanged ? "Done (Esc)" : "Cancel (Esc)"
        regenerateButton.isEnabled = true
        setResultPhase(changeCount: effectiveChangeCount)

        // Stats bar
        let summary = DiffSupport.changeSummary(segments: wordDiff)
        let displayedSummary = (!isUnchanged && changeCount == 0) ? "Text changed" : summary
        let similarity = computeSimilarity(old: originalText, new: correctedText, diff: wordDiff)
        statsLabel.stringValue = "\(displayedSummary) · \(similarity)% similarity"
        statsLabel.isHidden = false

        // Character-level diff for precise highlighting
        let charDiff = DiffSupport.charDiff(old: originalText, new: correctedText)

        // Side-by-side: left keeps the original string intact and underlines the
        // erroneous spans in red; right highlights inserted corrections in green.
        leftTextView.textStorage?.setAttributedString(buildOriginalSide(from: charDiff))
        rightTextView.textStorage?.setAttributedString(buildCorrectedSide(from: charDiff))

        // Build change ranges for navigation
        changeRanges = buildChangeRanges(from: charDiff)
        currentChangeIndex = -1
        updateNavButtonStates()

        startDismissMonitor()
        if isUnchanged { scheduleNoChangesDismissal() }
    }

    private func computeSimilarity(old: String, new: String, diff: [DiffSegment]) -> Int {
        let maxLen = max(old.count, new.count)
        guard maxLen > 0 else { return 100 }
        let equalChars = diff.reduce(0) { total, segment in
            total + (segment.kind == .equal ? segment.text.count : 0)
        }
        return Int(round(Double(equalChars) / Double(maxLen) * 100))
    }

    func resetForRegeneration() {
        guard !isDismissed else { return }
        cancelPendingAutoDismiss()
        dismissMonitor.stop()
        requestID = UUID()
        restoreBackgroundOpacity()
        cancelButton.title = "Cancel (Esc)"
        isComplete = false
        failureMessage = nil
        latestCorrectedText = ""
        acceptButton.isEnabled = false
        copyButton.isEnabled = false
        regenerateButton.isEnabled = false
        statusLabel.toolTip = nil
        statsLabel.isHidden = true
        changeRanges = []
        currentChangeIndex = -1
        updateNavButtonStates()
        setLoadingPhase(status: "Regenerating...")

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        rightTextView.textStorage?.setAttributedString(
            NSAttributedString(string: "Waiting for response...", attributes: attrs)
        )

        // Reset the original side back to plain
        let origAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        leftTextView.textStorage?.setAttributedString(
            NSAttributedString(string: originalText, attributes: origAttrs)
        )
    }

    func showError(_ message: String) {
        guard !isDismissed else { return }
        cancelPendingAutoDismiss()
        isComplete = false
        failureMessage = message
        latestCorrectedText = ""
        acceptButton.isEnabled = false
        copyButton.isEnabled = false
        cancelButton.title = "Cancel (Esc)"
        statsLabel.isHidden = true
        regenerateButton.isEnabled = true
        statusLabel.stringValue = "Failed: \(message) — Retry or Cancel."
        statusLabel.toolTip = message
        setFailurePhase()
        startDismissMonitor()
    }

    // MARK: - Phase Display

    private func setLoadingPhase(status: String) {
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        phaseIcon.image = nil
        phaseIcon.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        copyButton.isEnabled = false
    }

    private func setResultPhase(changeCount: Int) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        let hasChanges = changeCount > 0
        phaseIcon.image = NSImage(
            systemSymbolName: hasChanges ? "text.badge.checkmark" : "checkmark.circle.fill",
            accessibilityDescription: hasChanges ? "Corrections ready" : "No changes needed"
        )
        phaseIcon.contentTintColor = .systemGreen
        phaseIcon.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
        copyButton.isEnabled = hasChanges
    }

    private func setFailurePhase() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        phaseIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Correction failed"
        )
        phaseIcon.contentTintColor = .systemOrange
        phaseIcon.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Dismissal

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissAsCancelled()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        dismissAsCancelled()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissed, isComplete || failureMessage != nil else { return }
        dismiss(reason: .focusChanged)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelClicked()
    }

    private func dismissAsCancelled() {
        dismiss(reason: .cancelled, closingWindow: false)
    }

    /// Exactly one dismissal callback per controller lifecycle. Explicit
    /// acceptance marks the controller dismissed itself and never reaches here.
    private func dismiss(reason: DismissalReason, closingWindow: Bool = true) {
        guard !isDismissed else { return }
        isDismissed = true
        cancelPendingAutoDismiss()
        dismissMonitor.stop()
        requestID = UUID()
        if closingWindow { window?.close() }
        onDismiss(reason)
    }

    private func startDismissMonitor() {
        guard let window else { return }
        dismissMonitor.start(for: window) { [weak self] in
            guard let self, !self.isDismissed else { return }
            guard self.isComplete || self.failureMessage != nil else { return }
            self.dismiss(reason: .focusChanged)
        }
    }

    private func scheduleNoChangesDismissal() {
        cancelPendingAutoDismiss()
        let id = requestID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingAutoDismiss != nil else { return }
            guard !self.isDismissed, self.requestID == id, self.isComplete else { return }
            self.fadeOutAndDismiss(requestID: id)
        }
        pendingAutoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissDelay, execute: work)
    }

    private func cancelPendingAutoDismiss() {
        guard pendingAutoDismiss != nil else { return }
        pendingAutoDismiss?.cancel()
        pendingAutoDismiss = nil
        restoreBackgroundOpacity()
    }

    private func fadeOutAndDismiss(requestID id: UUID) {
        guard !isDismissed, requestID == id else { return }
        guard let window, window.isVisible, let background = panelBackground else {
            dismiss(reason: .noChanges)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            background.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.pendingAutoDismiss != nil else { return }
            guard !self.isDismissed, self.requestID == id else { return }
            self.dismiss(reason: .noChanges)
        })
    }

    private func restoreBackgroundOpacity() {
        guard let background = panelBackground else { return }
        background.layer?.removeAllAnimations()
        background.alphaValue = 1
    }

    private func buildUI() {
        guard let window = window, let existingContentView = window.contentView else { return }

        // Single rounded material behind every control; the window itself stays clear.
        let background = FloatingPanelBackgroundView(frame: existingContentView.bounds)
        window.contentView = background
        panelBackground = background
        let root = background

        // Status row: spinner while a request is in flight, phase icon once it settles.
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Waiting for response..."
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityIdentifier("preview.loading")
        spinner.setAccessibilityLabel("Loading correction")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        phaseIcon.imageScaling = .scaleProportionallyDown
        phaseIcon.setAccessibilityIdentifier("preview.phase")
        phaseIcon.isHidden = true
        phaseIcon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(phaseIcon)

        // Column headers with tinted backgrounds
        let originalHeaderBg = NSView()
        originalHeaderBg.wantsLayer = true
        originalHeaderBg.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.06).cgColor
        originalHeaderBg.layer?.cornerRadius = 4
        originalHeaderBg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(originalHeaderBg)

        let originalHeader = NSTextField(labelWithString: "Original")
        originalHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        originalHeader.textColor = .systemRed.withAlphaComponent(0.8)
        originalHeader.translatesAutoresizingMaskIntoConstraints = false
        originalHeaderBg.addSubview(originalHeader)

        let correctedHeaderBg = NSView()
        correctedHeaderBg.wantsLayer = true
        correctedHeaderBg.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.06).cgColor
        correctedHeaderBg.layer?.cornerRadius = 4
        correctedHeaderBg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(correctedHeaderBg)

        let correctedHeader = NSTextField(labelWithString: "Corrected")
        correctedHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        correctedHeader.textColor = .systemGreen.withAlphaComponent(0.8)
        correctedHeader.translatesAutoresizingMaskIntoConstraints = false
        correctedHeaderBg.addSubview(correctedHeader)

        // Left scroll view (original text)
        leftTextView.setAccessibilityIdentifier("preview.original")
        configureTextView(leftTextView, in: leftScrollView)
        root.addSubview(leftScrollView)

        // Right scroll view (corrected text)
        rightTextView.setAccessibilityIdentifier("preview.corrected")
        configureTextView(rightTextView, in: rightScrollView)
        root.addSubview(rightScrollView)

        // Populate left side with original text
        let origAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        leftTextView.textStorage?.setAttributedString(
            NSAttributedString(string: originalText, attributes: origAttrs)
        )

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        // Buttons - Accept uses the accent tint without painting an opaque layer.
        acceptButton.keyEquivalent = "\r"
        acceptButton.keyEquivalentModifierMask = [.command]
        acceptButton.bezelStyle = .rounded
        acceptButton.contentTintColor = .systemGreen
        acceptButton.isEnabled = false
        acceptButton.translatesAutoresizingMaskIntoConstraints = false

        copyButton.keyEquivalent = "C"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Copy corrected text (⇧⌘C)"
        copyButton.isEnabled = false
        copyButton.setAccessibilityIdentifier("preview.copy")
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        regenerateButton.isEnabled = false
        regenerateButton.keyEquivalent = "r"
        regenerateButton.keyEquivalentModifierMask = [.command]
        regenerateButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        // Stats bar (hidden until completion)
        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.isHidden = true
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statsLabel)

        // Change navigation buttons (Item 31)
        prevChangeButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Change")
        prevChangeButton.bezelStyle = .rounded
        prevChangeButton.isBordered = true
        prevChangeButton.toolTip = "Previous Change"
        prevChangeButton.isEnabled = false
        prevChangeButton.target = self
        prevChangeButton.action = #selector(prevChangeClicked)
        prevChangeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(prevChangeButton)

        nextChangeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Change")
        nextChangeButton.bezelStyle = .rounded
        nextChangeButton.isBordered = true
        nextChangeButton.toolTip = "Next Change"
        nextChangeButton.isEnabled = false
        nextChangeButton.target = self
        nextChangeButton.action = #selector(nextChangeClicked)
        nextChangeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(nextChangeButton)

        root.addSubview(acceptButton)
        root.addSubview(copyButton)
        root.addSubview(regenerateButton)
        root.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // 36pt clears the transparent titlebar (and its traffic lights).
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            spinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            spinner.topAnchor.constraint(equalTo: statusLabel.topAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            phaseIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            phaseIcon.topAnchor.constraint(equalTo: statusLabel.topAnchor),
            phaseIcon.widthAnchor.constraint(equalToConstant: 16),
            phaseIcon.heightAnchor.constraint(equalToConstant: 16),

            // Original header background
            originalHeaderBg.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            originalHeaderBg.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            originalHeader.topAnchor.constraint(equalTo: originalHeaderBg.topAnchor, constant: 3),
            originalHeader.bottomAnchor.constraint(equalTo: originalHeaderBg.bottomAnchor, constant: -3),
            originalHeader.leadingAnchor.constraint(equalTo: originalHeaderBg.leadingAnchor, constant: 8),
            originalHeader.trailingAnchor.constraint(equalTo: originalHeaderBg.trailingAnchor, constant: -8),

            // Corrected header background
            correctedHeaderBg.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            correctedHeaderBg.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 4),
            correctedHeader.topAnchor.constraint(equalTo: correctedHeaderBg.topAnchor, constant: 3),
            correctedHeader.bottomAnchor.constraint(equalTo: correctedHeaderBg.bottomAnchor, constant: -3),
            correctedHeader.leadingAnchor.constraint(equalTo: correctedHeaderBg.leadingAnchor, constant: 8),
            correctedHeader.trailingAnchor.constraint(equalTo: correctedHeaderBg.trailingAnchor, constant: -8),

            leftScrollView.topAnchor.constraint(equalTo: originalHeaderBg.bottomAnchor, constant: 4),
            leftScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            leftScrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            leftScrollView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -6),
            leftScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            divider.topAnchor.constraint(equalTo: originalHeaderBg.bottomAnchor, constant: 4),
            divider.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -6),

            rightScrollView.topAnchor.constraint(equalTo: correctedHeaderBg.bottomAnchor, constant: 4),
            rightScrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4),
            rightScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            rightScrollView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -6),
            rightScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            statsLabel.leadingAnchor.constraint(equalTo: nextChangeButton.trailingAnchor, constant: 8),
            statsLabel.bottomAnchor.constraint(equalTo: acceptButton.topAnchor, constant: -6),

            // Change navigation buttons - left side of stats bar
            prevChangeButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            prevChangeButton.centerYAnchor.constraint(equalTo: statsLabel.centerYAnchor),
            prevChangeButton.widthAnchor.constraint(equalToConstant: 28),

            nextChangeButton.leadingAnchor.constraint(equalTo: prevChangeButton.trailingAnchor, constant: 2),
            nextChangeButton.centerYAnchor.constraint(equalTo: statsLabel.centerYAnchor),
            nextChangeButton.widthAnchor.constraint(equalToConstant: 28),

            acceptButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            acceptButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            acceptButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            regenerateButton.trailingAnchor.constraint(equalTo: acceptButton.leadingAnchor, constant: -8),
            regenerateButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            regenerateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            cancelButton.trailingAnchor.constraint(equalTo: regenerateButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            copyButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        setLoadingPhase(status: "Waiting for response...")
    }

    private func configureTextView(_ textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        scrollView.drawsBackground = false

        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false

        // Line numbers (Item 29)
        scrollView.hasHorizontalRuler = false
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler

        scrollView.documentView = textView
    }

    private func buildOriginalSide(from segments: [DiffSegment]) -> NSAttributedString {
        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        let result = NSMutableAttributedString(string: display.text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
        let errorStyle: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.10),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemRed
        ]
        for range in display.deletionRanges {
            result.addAttributes(errorStyle, range: range)
        }
        for range in display.insertionAnchorRanges {
            result.addAttributes(errorStyle, range: range)
        }
        return result
    }

    private func buildCorrectedSide(from segments: [DiffSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)
        for segment in segments {
            switch segment.kind {
            case .equal:
                result.append(NSAttributedString(string: segment.text, attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor
                ]))
            case .insertion:
                result.append(NSAttributedString(string: segment.text, attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.systemGreen,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.12),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
            case .deletion:
                break // Don't show deletions on the corrected side
            }
        }
        return result
    }

    // MARK: - Change Navigation (Item 31)

    private func buildChangeRanges(from segments: [DiffSegment]) -> [(left: NSRange, right: NSRange)] {
        var ranges: [(left: NSRange, right: NSRange)] = []
        var leftOffset = 0
        var rightOffset = 0
        for segment in segments {
            let len = segment.text.utf16.count
            switch segment.kind {
            case .equal:
                leftOffset += len
                rightOffset += len
            case .deletion:
                ranges.append((left: NSRange(location: leftOffset, length: len),
                                right: NSRange(location: rightOffset, length: 0)))
                leftOffset += len
            case .insertion:
                if let last = ranges.last, last.right.location + last.right.length == rightOffset,
                   last.left.location + last.left.length == leftOffset {
                    // Merge adjacent deletion+insertion into one change
                    ranges[ranges.count - 1] = (left: last.left,
                                                  right: NSRange(location: last.right.location, length: len))
                } else {
                    ranges.append((left: NSRange(location: leftOffset, length: 0),
                                    right: NSRange(location: rightOffset, length: len)))
                }
                rightOffset += len
            }
        }
        return ranges
    }

    private func updateNavButtonStates() {
        let hasChanges = !changeRanges.isEmpty
        prevChangeButton.isEnabled = hasChanges && currentChangeIndex > 0
        nextChangeButton.isEnabled = hasChanges && currentChangeIndex < changeRanges.count - 1
    }

    @objc private func prevChangeClicked() {
        guard currentChangeIndex > 0 else { return }
        currentChangeIndex -= 1
        scrollToCurrentChange()
        updateNavButtonStates()
    }

    @objc private func nextChangeClicked() {
        guard currentChangeIndex < changeRanges.count - 1 else { return }
        currentChangeIndex += 1
        scrollToCurrentChange()
        updateNavButtonStates()
    }

    private func scrollToCurrentChange() {
        guard changeRanges.indices.contains(currentChangeIndex) else { return }
        let change = changeRanges[currentChangeIndex]

        // Scroll left side to the deletion
        if change.left.length > 0 {
            leftTextView.scrollRangeToVisible(change.left)
            leftTextView.setSelectedRange(change.left)
        } else {
            leftTextView.scrollRangeToVisible(NSRange(location: change.left.location, length: 0))
        }

        // Scroll right side to the insertion
        if change.right.length > 0 {
            rightTextView.scrollRangeToVisible(change.right)
            rightTextView.setSelectedRange(change.right)
        } else {
            rightTextView.scrollRangeToVisible(NSRange(location: change.right.location, length: 0))
        }
    }

    @objc private func acceptClicked() {
        guard !isDismissed, isComplete, acceptButton.isEnabled else { return }
        if let message = validateAcceptance?() {
            statusLabel.stringValue = message
            statusLabel.toolTip = message
            return
        }
        isDismissed = true
        cancelPendingAutoDismiss()
        dismissMonitor.stop()
        requestID = UUID()
        window?.close()
        onAccept(latestCorrectedText)
    }

    @objc private func copyClicked() {
        guard !isDismissed, isComplete, copyButton.isEnabled else { return }
        // Copying is not acceptance and must not dismiss or take focus.
        cancelPendingAutoDismiss()
        onCopy(latestCorrectedText)
    }

    @objc private func regenerateClicked() {
        guard !isDismissed, regenerateButton.isEnabled else { return }
        resetForRegeneration()
        onRegenerate()
    }

    @objc private func cancelClicked() {
        dismiss(reason: .cancelled)
    }
}

// MARK: - Flipped Clip View (top-aligned scroll content)

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Line Number Ruler View (Item 29)

private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private static let rulerWidth: CGFloat = 36
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private static let textColor = NSColor.tertiaryLabelColor

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = Self.rulerWidth
        clientView = textView

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("LineNumberRulerView does not support NSCoder") }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? rect
        let textInset = textView.textContainerInset

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )

        let text = textView.string as NSString
        var lineNumber = 1

        // Count lines before visible range
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw line numbers for visible lines
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Self.textColor
        ]

        text.enumerateSubstrings(
            in: visibleCharRange,
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: substringRange.location, length: 0),
                actualCharacterRange: nil
            )
            var lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil
            )
            lineRect.origin.y += textInset.height - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: Self.rulerWidth - strSize.width - 5,
                y: lineRect.origin.y + (lineRect.height - strSize.height) / 2
            )
            numStr.draw(at: drawPoint, withAttributes: attrs)
            lineNumber += 1
        }
    }
}
