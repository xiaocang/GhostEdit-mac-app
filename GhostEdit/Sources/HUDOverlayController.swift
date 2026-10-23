import AppKit

final class HUDOverlayController {
    /// Writes the full corrected text to the pasteboard. The host can override
    /// this to coordinate its own clipboard snapshot handling.
    var onCopy: (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private let dismissMonitor = FloatingPanelDismissMonitor()
    private var panel: NSPanel?
    private var tintOverlay: NSView?
    private var spinner: NSProgressIndicator?
    private var ghostImageView: NSImageView?
    private var messageLabel: NSTextField?
    private var copyButton: NSButton?
    private var copyFeedbackWorkItem: DispatchWorkItem?
    private var dismissWorkItem: DispatchWorkItem?
    private var ghostWithSpectacles: NSImage?
    private var ghostWithoutSpectacles: NSImage?
    private var isDiffMode = false
    private var dismissOverride: TimeInterval?
    private var latestCorrectedText = ""
    /// Invalidates work scheduled for an earlier panel generation, so a stale
    /// fade completion can never hide a newer working or result panel.
    private var transitionGeneration = 0

    deinit {
        dismissMonitor.stop()
    }

    func show(state: HUDOverlayState, dismissAfter: TimeInterval? = nil) {
        transitionGeneration += 1
        cancelPendingDismissal()
        dismissOverride = dismissAfter

        let needsDiff = HUDContentSupport.isDiffState(state)
        if panel == nil || needsDiff != isDiffMode || needsDiff {
            tearDownPanel()
            if needsDiff {
                buildDiffPanel(for: state)
            } else {
                buildPanel()
            }
        }

        applyContent(for: state)

        guard let panel else { return }
        // Start 10px below and faded out, then slide up
        var frame = panel.frame
        frame.origin.y -= 10
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(HUDOverlaySupport.fadeInDuration)
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var targetFrame = panel.frame
            targetFrame.origin.y += 10
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }

        startDismissMonitorIfNeeded(for: state)
        scheduleAutoDismissIfNeeded(for: state)
    }

    func update(state: HUDOverlayState, dismissAfter: TimeInterval? = nil) {
        transitionGeneration += 1
        cancelPendingDismissal()
        dismissOverride = dismissAfter

        let needsDiff = HUDContentSupport.isDiffState(state)
        if panel == nil || needsDiff != isDiffMode || needsDiff {
            tearDownPanel()
            if needsDiff {
                buildDiffPanel(for: state)
            } else {
                buildPanel()
            }
        }

        applyContent(for: state)

        guard let panel else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        startDismissMonitorIfNeeded(for: state)
        scheduleAutoDismissIfNeeded(for: state)
    }

    func dismiss() {
        transitionGeneration += 1
        cancelPendingDismissal()
        dismissMonitor.stop()

        guard let panel else { return }

        let generation = transitionGeneration
        let fadingPanel = panel
        let fadeDuration = TimeInterval(HUDOverlaySupport.fadeOutDuration)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.allowsImplicitAnimation = true
            fadingPanel.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration + 0.05) { [weak self, weak fadingPanel] in
            guard let self, let fadingPanel,
                  self.panel === fadingPanel,
                  self.transitionGeneration == generation else { return }
            fadingPanel.orderOut(nil)
            fadingPanel.alphaValue = 1
        }
    }

    private func cancelPendingDismissal() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    private func tearDownPanel() {
        transitionGeneration += 1
        dismissMonitor.stop()
        cancelPendingDismissal()
        copyFeedbackWorkItem?.cancel()
        copyFeedbackWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        tintOverlay = nil
        spinner = nil
        ghostImageView = nil
        messageLabel = nil
        copyButton = nil
        latestCorrectedText = ""
        isDiffMode = false
    }

    private func buildPanel() {
        isDiffMode = false
        let width = HUDOverlaySupport.windowWidth
        let height = HUDOverlaySupport.windowHeight
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let centered = HUDOverlaySupport.windowOrigin(screenSize: screenFrame.size)
        let origin = CGPoint(x: screenFrame.origin.x + centered.x, y: screenFrame.origin.y + centered.y)

        let newPanel = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        newPanel.isMovableByWindowBackground = false

        let background = FloatingPanelBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let iconSize = HUDOverlaySupport.iconSize
        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let message = NSTextField(labelWithString: "")
        message.font = NSFont.systemFont(ofSize: HUDOverlaySupport.messageFontSize, weight: .medium)
        message.textColor = .labelColor
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true

        let stack = NSStackView(views: [imageView, progress, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = HUDOverlaySupport.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: background.leadingAnchor,
                constant: HUDOverlaySupport.contentInset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: background.trailingAnchor,
                constant: -HUDOverlaySupport.contentInset
            ),
        ])

        // Tint overlay for state color. The background's rounded mask clips it.
        let tint = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.clear.cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tint, positioned: .below, relativeTo: stack)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            tint.topAnchor.constraint(equalTo: background.topAnchor),
            tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        newPanel.contentView = background

        self.panel = newPanel
        self.tintOverlay = tint
        self.spinner = progress
        self.ghostImageView = imageView
        self.messageLabel = message
    }

    private func buildDiffPanel(for state: HUDOverlayState) {
        isDiffMode = true

        guard case .successWithDiff(let segments, let toolsUsed) = state else { return }

        let panelWidth = HUDOverlaySupport.diffWindowWidth
        let inset = HUDOverlaySupport.diffContentInset
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let display = HUDOverlaySupport.originalDiffDisplay(from: segments)
        let originalAttributed = attributedOriginalText(display)
        let correctedAttributed = attributedCorrectedText(from: segments)
        latestCorrectedText = StreamingPreviewSupport.correctedText(from: segments)

        // Fixed chrome around both text areas: insets, top row, headers, copy row.
        let chromeHeight: CGFloat =
            inset * 2 + HUDOverlaySupport.diffIconSize + 8 + 15 + 4 + 10 + 15 + 4 + 10 + 26
        let textMeasureWidth = panelWidth - inset * 2
        let measuredOriginal = measuredTextHeight(originalAttributed, width: textMeasureWidth)
        let measuredCorrected = measuredTextHeight(correctedAttributed, width: textMeasureWidth)
        let panelHeight = HUDOverlaySupport.diffPanelHeight(
            intrinsicContentHeight: chromeHeight + measuredOriginal + measuredCorrected,
            visibleFrameHeight: screenFrame.height
        )
        let textBudget = max(64, panelHeight - chromeHeight)
        let originalViewport = max(32, min(measuredOriginal, textBudget / 2))
        let correctedViewport = max(32, textBudget - originalViewport)

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        newPanel.isMovableByWindowBackground = false

        let ev = FloatingPanelBackgroundView(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        )

        let iconSize = HUDOverlaySupport.diffIconSize
        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Corrections applied"
        )
        imageView.contentTintColor = .systemGreen

        let message = NSTextField(labelWithString: "Done!")
        message.font = NSFont.systemFont(ofSize: HUDOverlaySupport.messageFontSize, weight: .medium)
        message.textColor = .labelColor
        message.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [imageView, message])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        if !toolsUsed.isEmpty {
            let toolsLabel = NSTextField(labelWithString: toolsUsed)
            toolsLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            if let italicDescriptor = toolsLabel.font?.fontDescriptor.withSymbolicTraits(.italic) {
                toolsLabel.font = NSFont(descriptor: italicDescriptor, size: 9)
            }
            toolsLabel.textColor = .secondaryLabelColor
            toolsLabel.translatesAutoresizingMaskIntoConstraints = false
            topRow.addArrangedSubview(toolsLabel)
        }

        let originalHeader = headerLabel("Original")
        let correctedHeader = headerLabel("Corrected")
        let (originalScroll, _) = makeDiffTextView(
            attributed: originalAttributed,
            width: textMeasureWidth,
            accessibilityLabel: "Original text with corrections marked"
        )
        let (correctedScroll, _) = makeDiffTextView(
            attributed: correctedAttributed,
            width: textMeasureWidth,
            accessibilityLabel: "Corrected text"
        )

        let copy = NSButton(
            title: "Copy corrected text",
            target: self,
            action: #selector(copyCorrectedText)
        )
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = NSFont.systemFont(ofSize: 11)
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.setAccessibilityLabel("Copy corrected text")

        ev.addSubview(topRow)
        ev.addSubview(originalHeader)
        ev.addSubview(originalScroll)
        ev.addSubview(correctedHeader)
        ev.addSubview(correctedScroll)
        ev.addSubview(copy)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: ev.topAnchor, constant: inset),
            topRow.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: inset),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: ev.trailingAnchor, constant: -inset),
            topRow.heightAnchor.constraint(equalToConstant: HUDOverlaySupport.diffIconSize),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),

            originalHeader.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 8),
            originalHeader.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: inset),
            originalHeader.trailingAnchor.constraint(lessThanOrEqualTo: ev.trailingAnchor, constant: -inset),
            originalHeader.heightAnchor.constraint(equalToConstant: 15),

            originalScroll.topAnchor.constraint(equalTo: originalHeader.bottomAnchor, constant: 4),
            originalScroll.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: inset),
            originalScroll.trailingAnchor.constraint(equalTo: ev.trailingAnchor, constant: -inset),
            originalScroll.heightAnchor.constraint(equalToConstant: originalViewport),

            correctedHeader.topAnchor.constraint(equalTo: originalScroll.bottomAnchor, constant: 10),
            correctedHeader.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: inset),
            correctedHeader.trailingAnchor.constraint(lessThanOrEqualTo: ev.trailingAnchor, constant: -inset),
            correctedHeader.heightAnchor.constraint(equalToConstant: 15),

            correctedScroll.topAnchor.constraint(equalTo: correctedHeader.bottomAnchor, constant: 4),
            correctedScroll.leadingAnchor.constraint(equalTo: ev.leadingAnchor, constant: inset),
            correctedScroll.trailingAnchor.constraint(equalTo: ev.trailingAnchor, constant: -inset),
            correctedScroll.heightAnchor.constraint(equalToConstant: correctedViewport),

            copy.topAnchor.constraint(equalTo: correctedScroll.bottomAnchor, constant: 10),
            copy.trailingAnchor.constraint(equalTo: ev.trailingAnchor, constant: -inset),
            copy.bottomAnchor.constraint(equalTo: ev.bottomAnchor, constant: -inset),
            copy.heightAnchor.constraint(equalToConstant: 26),
            copy.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        // Tint overlay behind the content; the background's rounded mask clips it.
        let tint = NSView(frame: .zero)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.06).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        ev.addSubview(tint, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: ev.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: ev.trailingAnchor),
            tint.topAnchor.constraint(equalTo: ev.topAnchor),
            tint.bottomAnchor.constraint(equalTo: ev.bottomAnchor),
        ])

        newPanel.contentView = ev

        let centered = HUDOverlaySupport.windowOrigin(
            screenSize: screenFrame.size,
            windowSize: NSSize(width: panelWidth, height: panelHeight)
        )
        newPanel.setFrameOrigin(
            CGPoint(x: screenFrame.origin.x + centered.x, y: screenFrame.origin.y + centered.y)
        )

        self.panel = newPanel
        self.tintOverlay = tint
        self.ghostImageView = imageView
        self.messageLabel = message
        self.copyButton = copy
    }

    private func headerLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeDiffTextView(
        attributed: NSAttributedString,
        width: CGFloat,
        accessibilityLabel: String
    ) -> (NSScrollView, NSTextView) {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        textView.textStorage?.setAttributedString(attributed)
        textView.sizeToFit()
        var fittedFrame = textView.frame
        fittedFrame.size.width = width
        textView.frame = fittedFrame
        textView.setAccessibilityLabel(accessibilityLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func attributedOriginalText(_ display: HUDOverlaySupport.OriginalDiffDisplay) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: HUDOverlaySupport.diffFontSize)
        let result = NSMutableAttributedString(
            string: display.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let length = (display.text as NSString).length
        for range in display.deletionRanges where NSMaxRange(range) <= length {
            result.addAttributes([
                .foregroundColor: NSColor.systemRed,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemRed,
                .backgroundColor: NSColor.systemRed.withAlphaComponent(0.08),
            ], range: range)
        }
        for range in display.insertionAnchorRanges where NSMaxRange(range) <= length {
            result.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.systemRed,
            ], range: range)
        }
        return result
    }

    private func attributedCorrectedText(from segments: [DiffSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: HUDOverlaySupport.diffFontSize)
        for segment in segments {
            switch segment.kind {
            case .equal:
                result.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
            case .insertion:
                result.append(NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.systemGreen,
                        .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.14),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemGreen,
                    ]
                ))
            case .deletion:
                break
            }
        }
        return result
    }

    private func measuredTextHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = attributed.boundingRect(
            with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height) + 12
    }

    @objc private func copyCorrectedText() {
        onCopy(latestCorrectedText)
        copyFeedbackWorkItem?.cancel()
        copyButton?.title = "Copied!"
        let workItem = DispatchWorkItem { [weak self] in
            self?.copyButton?.title = "Copy corrected text"
        }
        copyFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func applyContent(for state: HUDOverlayState) {
        // Diff mode content is set up during buildDiffPanel.
        if HUDContentSupport.isDiffState(state) { return }

        let message = HUDOverlaySupport.content(for: state).message
        messageLabel?.stringValue = message
        messageLabel?.toolTip = message

        if case .success = state {
            let symbol = NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: "No changes needed"
            )
            ghostImageView?.image = symbol
            ghostImageView?.contentTintColor = .systemGreen
            ghostImageView?.setAccessibilityLabel("No changes needed")
        } else {
            ghostImageView?.image = renderGhostImage(
                size: HUDOverlaySupport.iconSize,
                spectacles: HUDOverlaySupport.showsSpectacles(for: state)
            )
            ghostImageView?.contentTintColor = nil
            ghostImageView?.setAccessibilityLabel("GhostEdit")
        }

        if HUDContentSupport.showsSpinner(for: state) {
            spinner?.isHidden = false
            spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
        }

        tintOverlay?.layer?.backgroundColor = tintColor(for: state).withAlphaComponent(0.06).cgColor
    }

    private func tintColor(for state: HUDOverlayState) -> NSColor {
        switch HUDContentSupport.tintColorName(for: state) {
        case "systemBlue":
            return .systemBlue
        case "systemOrange":
            return .systemOrange
        case "systemRed":
            return .systemRed
        default:
            return .systemGreen
        }
    }

    /// Only ready corrections and failures dismiss on outside interaction. Working
    /// and brief confirmation states must never install the monitor.
    private func startDismissMonitorIfNeeded(for state: HUDOverlayState) {
        dismissMonitor.stop()
        guard isStickyResultState(state), let panel else { return }
        dismissMonitor.start(for: panel) { [weak self] in
            self?.dismiss()
        }
    }

    private func isStickyResultState(_ state: HUDOverlayState) -> Bool {
        switch state {
        case .successWithDiff, .error:
            return true
        case .working, .success, .successWithCount, .fallback:
            return false
        }
    }

    private func scheduleAutoDismissIfNeeded(for state: HUDOverlayState) {
        // Working, correction, and failure states are timerless; an obsolete
        // diff/error override cannot schedule a dismiss for them.
        guard let defaultDelay = HUDOverlaySupport.autoDismissDelay(for: state) else { return }
        let delay = dismissOverride ?? defaultDelay

        let generation = transitionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func renderGhostImage(size: CGFloat, spectacles: Bool) -> NSImage {
        if spectacles, let cached = ghostWithSpectacles { return cached }
        if !spectacles, let cached = ghostWithoutSpectacles { return cached }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let vbX = HUDOverlaySupport.ghostViewBoxOriginX
            let vbY = HUDOverlaySupport.ghostViewBoxOriginY
            let vbSize = HUDOverlaySupport.ghostViewBoxSize
            let scale = size / vbSize

            ctx.translateBy(x: -vbX * scale, y: -vbY * scale)
            ctx.scaleBy(x: scale, y: scale)

            let darkFill = CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1)

            // Ghost body
            if let bodyPath = CGPath.from(svgPath: HUDOverlaySupport.ghostBodyPath) {
                ctx.addPath(bodyPath)
                ctx.setFillColor(.white)
                ctx.fillPath()
            }

            // Eyes (rotated ellipses)
            for eye in [HUDOverlaySupport.ghostLeftEye, HUDOverlaySupport.ghostRightEye] {
                ctx.saveGState()
                ctx.translateBy(x: eye.cx, y: eye.cy)
                ctx.rotate(by: eye.rotation * .pi / 180)
                let eyeRect = CGRect(x: -eye.rx, y: -eye.ry, width: eye.rx * 2, height: eye.ry * 2)
                ctx.addEllipse(in: eyeRect)
                ctx.setFillColor(darkFill)
                ctx.fillPath()
                ctx.restoreGState()

                // Highlight
                let hlRect = CGRect(
                    x: eye.highlightCX - eye.highlightR,
                    y: eye.highlightCY - eye.highlightR,
                    width: eye.highlightR * 2,
                    height: eye.highlightR * 2
                )
                ctx.addEllipse(in: hlRect)
                ctx.setFillColor(.white)
                ctx.fillPath()

                // Spectacle lens (only for working state)
                if spectacles {
                    let lensRect = CGRect(
                        x: eye.cx - eye.lensR,
                        y: eye.cy - eye.lensR,
                        width: eye.lensR * 2,
                        height: eye.lensR * 2
                    )
                    ctx.addEllipse(in: lensRect)
                    ctx.setStrokeColor(darkFill)
                    ctx.setLineWidth(HUDOverlaySupport.ghostStrokeWidth)
                    ctx.strokePath()
                }
            }

            // Mouth
            if let mouthPath = CGPath.from(svgPath: HUDOverlaySupport.ghostMouthPath) {
                ctx.addPath(mouthPath)
                ctx.setFillColor(darkFill)
                ctx.fillPath()
            }

            // Spectacle bridge and arms (only for working state)
            if spectacles {
                let sw = HUDOverlaySupport.ghostStrokeWidth
                for pathStr in [HUDOverlaySupport.ghostBridgePath,
                                HUDOverlaySupport.ghostLeftArmPath,
                                HUDOverlaySupport.ghostRightArmPath] {
                    if let p = CGPath.from(svgPath: pathStr) {
                        ctx.addPath(p)
                        ctx.setStrokeColor(darkFill)
                        ctx.setLineWidth(sw)
                        ctx.setLineCap(.round)
                        ctx.strokePath()
                    }
                }
            }

            return true
        }

        if spectacles {
            ghostWithSpectacles = image
        } else {
            ghostWithoutSpectacles = image
        }
        return image
    }
}

private extension CGPath {
    static func from(svgPath: String) -> CGPath? {
        let path = CGMutablePath()
        let scanner = Scanner(string: svgPath)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))

        var currentCommand: Character = "M"

        while !scanner.isAtEnd {
            if let cmd = scanner.scanCharacter(), "MmLlCcQqZz".contains(cmd) {
                currentCommand = cmd
            }

            switch currentCommand {
            case "M":
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { break }
                path.move(to: CGPoint(x: x, y: y))
                currentCommand = "L"
            case "L":
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { break }
                path.addLine(to: CGPoint(x: x, y: y))
            case "C":
                guard let x1 = scanner.scanDouble(), let y1 = scanner.scanDouble(),
                      let x2 = scanner.scanDouble(), let y2 = scanner.scanDouble(),
                      let x = scanner.scanDouble(), let y = scanner.scanDouble() else { break }
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x2, y: y2)
                )
            case "Q":
                guard let cx = scanner.scanDouble(), let cy = scanner.scanDouble(),
                      let x = scanner.scanDouble(), let y = scanner.scanDouble() else { break }
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case "Z", "z":
                path.closeSubpath()
            default:
                _ = scanner.scanDouble()
            }
        }

        return path.isEmpty ? nil : path
    }
}
