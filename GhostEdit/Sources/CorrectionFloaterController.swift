import AppKit

/// Small non-activating panel that sits beside the selection.
/// Each state has its own ghost. The edit box is translucent, with that ghost at the start.
final class CorrectionFloaterController: NSObject {
    var onCopy: ((String) -> Void)?
    var onCopyAndPaste: ((String) -> Void)?
    var onUserDismiss: (() -> Void)?

    private var panel: NSPanel?
    private let dismissMonitor = FloatingPanelDismissMonitor()
    private var autoDismiss: DispatchWorkItem?
    private var copyButton: NSButton?
    private var correctedText: String?
    var editBoxOpacity: CGFloat = CGFloat(AppConfig.defaultFloaterOpacity)

    func showLoading(near anchor: CGRect?) {
        let card = makeCard(width: 28, height: 28)
        let ghost = imageView(ghostImage(.loading, pointSize: 20), size: 20)
        pin(ghost, in: card, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        present(card, near: anchor, clickOutsideDismisses: true, autoDismissAfter: nil)
    }

    func showUnchanged(near anchor: CGRect?) {
        let card = makeCard(width: 40, height: 26)
        let ghost = imageView(ghostImage(.unchanged, pointSize: 16), size: 16)
        let check = imageView(symbol("checkmark", pointSize: 11, color: .systemGreen), size: 11)
        let row = NSStackView(views: [ghost, check])
        row.orientation = .horizontal
        row.spacing = 2
        row.alignment = .centerY
        pin(row, in: card, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        present(card, near: anchor, clickOutsideDismisses: true, autoDismissAfter: 1.2)
    }

    func showCorrection(original: String, corrected: String, near anchor: CGRect?) {
        let text = attributedPreview(DiffSupport.charDiff(old: original, new: corrected))
        let visible = visibleFrame(near: anchor)
        let margin: CGFloat = 16
        let buttonSize: CGFloat = 18
        let actionsWidth = buttonSize * 2 + 4
        let ghostSize: CGFloat = 16
        let padX: CGFloat = 6
        let padY: CGFloat = 4
        let ghostGap: CGFloat = 4
        let wrapWidth: CGFloat = 320
        let textLeading = padX + ghostSize + ghostGap
        let availableWidth = visible.width - margin * 2 - actionsWidth - textLeading - padX - 2
        let maxTextWidth = max(48, min(wrapWidth, availableWidth))
        let maxTextHeight = max(18, visible.height - margin * 2 - padY * 2)
        let measured = text.boundingRect(
            with: NSSize(width: maxTextWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textWidth = min(maxTextWidth, max(24, ceil(measured.width)))
        let contentHeight = max(ghostSize, ceil(measured.height) + 2)
        let textHeight = min(maxTextHeight, contentHeight)
        let width = textLeading + textWidth + 2 + actionsWidth + padX
        let height = padY + textHeight + padY

        let card = makeEditCard(width: width, height: height)
        let ghost = imageView(ghostImage(.edited, pointSize: ghostSize), size: ghostSize)
        let button = NSButton()
        button.isBordered = false
        button.image = symbol("doc.on.doc", pointSize: 11, color: .secondaryLabelColor)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(copyClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Copy"
        button.setAccessibilityLabel("Copy correction")

        let pasteButton = NSButton()
        pasteButton.isBordered = false
        pasteButton.image = symbol("arrow.left.arrow.right", pointSize: 11, color: .secondaryLabelColor)
        pasteButton.imageScaling = .scaleProportionallyDown
        pasteButton.imagePosition = .imageOnly
        pasteButton.target = self
        pasteButton.action = #selector(copyAndPasteClicked)
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.toolTip = "Replace selected text and copy result"
        pasteButton.setAccessibilityLabel("Replace selected text and copy result")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: contentHeight))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: textWidth, height: contentHeight)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(text)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentHeight > textHeight + 1
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(ghost)
        card.addSubview(button)
        card.addSubview(pasteButton)
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            ghost.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padX),
            ghost.topAnchor.constraint(equalTo: card.topAnchor, constant: padY),
            pasteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padX),
            pasteButton.topAnchor.constraint(equalTo: card.topAnchor, constant: padY),
            pasteButton.widthAnchor.constraint(equalToConstant: buttonSize),
            pasteButton.heightAnchor.constraint(equalToConstant: buttonSize),
            button.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -4),
            button.topAnchor.constraint(equalTo: card.topAnchor, constant: padY),
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: padY),
            scroll.leadingAnchor.constraint(equalTo: ghost.trailingAnchor, constant: ghostGap),
            scroll.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padY),
        ])
        present(card, near: anchor, clickOutsideDismisses: true, autoDismissAfter: nil, shadowed: true)
        correctedText = corrected
        copyButton = button
    }

    func showError(_ message: String, near anchor: CGRect?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = NSTextField(wrappingLabelWithString: trimmed.isEmpty ? "Failed" : trimmed)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 150
        let ghost = imageView(ghostImage(.failed, pointSize: 14), size: 14)
        let row = NSStackView(views: [ghost, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        let card = makeCard(width: 180, height: 36)
        pin(row, in: card, insets: NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 6))
        present(card, near: anchor, clickOutsideDismisses: true, autoDismissAfter: 2.5)
    }

    func dismiss() {
        autoDismiss?.cancel()
        autoDismiss = nil
        dismissMonitor.stop()
        panel?.orderOut(nil)
        panel = nil
        copyButton = nil
        correctedText = nil
    }


    @objc private func copyClicked() {
        guard let correctedText else { return }
        onCopy?(correctedText)
        copyButton?.image = symbol("checkmark", pointSize: 8, color: .systemGreen)
    }

    @objc private func copyAndPasteClicked() {
        guard let correctedText else { return }
        onCopyAndPaste?(correctedText)
    }

    private func present(
        _ card: NSView,
        near anchor: CGRect?,
        clickOutsideDismisses: Bool,
        autoDismissAfter delay: TimeInterval?,
        shadowed: Bool = false
    ) {
        dismiss()
        let size = card.frame.size
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = shadowed
        window.alphaValue = 1
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.contentView = card
        panel = window

        let mouse = NSEvent.mouseLocation
        let resolved = anchor ?? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let visible = visibleFrame(near: anchor)
        let origin = WidgetPositioningSupport.floaterOrigin(
            anchor: resolved,
            panelSize: size,
            visibleFrame: visible
        )
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()

        if clickOutsideDismisses {
            dismissMonitor.start(for: window) { [weak self] in
                self?.dismiss()
                self?.onUserDismiss?()
            }
        }
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            autoDismiss = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func makeCard(width: CGFloat, height: CGFloat) -> NSView {
        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 4
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        return card
    }

    private func makeEditCard(width: CGFloat, height: CGFloat) -> NSView {
        FloaterEditChromeView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            backgroundAlpha: editBoxOpacity
        )
    }

    private func pin(_ view: NSView, in card: NSView, insets: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -insets.bottom),
        ])
    }

    private func imageView(_ image: NSImage, size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    private func ghostImage(_ mood: FloaterMood, pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            FloaterGhostArt.draw(mood, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
            ?? NSImage()
        image.isTemplate = false
        return tinted(image, color: color)
    }

    private func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }

    private func visibleFrame(near anchor: CGRect?) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let resolved = anchor ?? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let screen = NSScreen.screens.first { $0.frame.intersects(resolved) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func previewFont() -> NSFont {
        let size: CGFloat = 14
        let system = NSFont.systemFont(ofSize: size)
        guard let cjk = NSFont(name: "PingFang SC", size: size) else { return system }
        let descriptor = system.fontDescriptor.addingAttributes([
            .cascadeList: [cjk.fontDescriptor],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? system
    }

    private func attributedPreview(_ segments: [DiffSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = previewFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        for segment in segments {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
            ]
            switch segment.kind {
            case .equal:
                attributes[.foregroundColor] = NSColor.labelColor
            case .deletion:
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .insertion:
                attributes[.foregroundColor] = NSColor.systemGreen
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }
}

private enum FloaterMood {
    case loading
    case unchanged
    case edited
    case failed
}

/// Translucent plate for the correction edit box. Text sits above it at full opacity.
private final class FloaterEditChromeView: NSView {
    private let backgroundAlpha: CGFloat

    init(frame frameRect: NSRect, backgroundAlpha: CGFloat) {
        self.backgroundAlpha = backgroundAlpha
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloaterEditChromeView does not support NSCoder")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(backgroundAlpha).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }
}

private enum FloaterGhostArt {
    static func draw(_ mood: FloaterMood, in rect: NSRect) {
        let body = bodyPath(in: rect)
        let fill = bodyColor(mood)
        fill.setFill()
        body.fill()

        let hole = NSColor.windowBackgroundColor
        let left = point(0.34, 0.40, in: rect)
        let right = point(0.66, 0.40, in: rect)
        let eyeW = rect.width * (mood == .failed ? 0.12 : 0.09)
        let eyeH = rect.height * (mood == .failed ? 0.16 : 0.14)
        drawEye(at: left, rx: eyeW, ry: eyeH, hole: hole, highlight: fill)
        drawEye(at: right, rx: eyeW, ry: eyeH, hole: hole, highlight: fill)

        switch mood {
        case .loading:
            drawGlasses(left: left, right: right, radius: rect.width * 0.125, color: hole)
            drawMouth(.small, in: rect, color: hole)
        case .unchanged:
            drawMouth(.smile, in: rect, color: hole)
        case .edited:
            drawMouth(.smile, in: rect, color: hole)
            drawPencil(in: rect, color: .labelColor)
        case .failed:
            drawMouth(.frown, in: rect, color: hole)
        }
    }

    private static func bodyColor(_ mood: FloaterMood) -> NSColor {
        switch mood {
        case .loading, .unchanged:
            return .labelColor
        case .edited:
            return .controlAccentColor
        case .failed:
            return .systemRed
        }
    }

    private static func bodyPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(0.50, 0.06, in: rect))
        path.curve(
            to: point(0.90, 0.40, in: rect),
            controlPoint1: point(0.78, 0.06, in: rect),
            controlPoint2: point(0.90, 0.18, in: rect)
        )
        path.line(to: point(0.90, 0.70, in: rect))
        path.curve(
            to: point(0.74, 0.94, in: rect),
            controlPoint1: point(0.90, 0.86, in: rect),
            controlPoint2: point(0.84, 0.94, in: rect)
        )
        path.curve(
            to: point(0.62, 0.76, in: rect),
            controlPoint1: point(0.66, 0.94, in: rect),
            controlPoint2: point(0.64, 0.76, in: rect)
        )
        path.curve(
            to: point(0.50, 0.94, in: rect),
            controlPoint1: point(0.58, 0.76, in: rect),
            controlPoint2: point(0.56, 0.94, in: rect)
        )
        path.curve(
            to: point(0.38, 0.76, in: rect),
            controlPoint1: point(0.44, 0.94, in: rect),
            controlPoint2: point(0.42, 0.76, in: rect)
        )
        path.curve(
            to: point(0.26, 0.94, in: rect),
            controlPoint1: point(0.34, 0.76, in: rect),
            controlPoint2: point(0.32, 0.94, in: rect)
        )
        path.curve(
            to: point(0.10, 0.70, in: rect),
            controlPoint1: point(0.16, 0.94, in: rect),
            controlPoint2: point(0.10, 0.86, in: rect)
        )
        path.line(to: point(0.10, 0.40, in: rect))
        path.curve(
            to: point(0.50, 0.06, in: rect),
            controlPoint1: point(0.10, 0.18, in: rect),
            controlPoint2: point(0.22, 0.06, in: rect)
        )
        path.close()
        return path
    }

    private static func drawEye(at center: NSPoint, rx: CGFloat, ry: CGFloat, hole: NSColor, highlight: NSColor) {
        let eye = NSBezierPath(ovalIn: NSRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
        hole.setFill()
        eye.fill()
        let dot = max(0.8, rx * 0.32)
        let shine = NSBezierPath(ovalIn: NSRect(
            x: center.x - rx * 0.05,
            y: center.y + ry * 0.12,
            width: dot,
            height: dot
        ))
        highlight.setFill()
        shine.fill()
    }

    private static func drawGlasses(left: NSPoint, right: NSPoint, radius: CGFloat, color: NSColor) {
        color.setStroke()
        let width = max(1, radius * 0.28)
        for center in [left, right] {
            let lens = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            lens.lineWidth = width
            lens.stroke()
        }
        let bridge = NSBezierPath()
        bridge.move(to: NSPoint(x: left.x + radius * 0.85, y: left.y))
        bridge.line(to: NSPoint(x: right.x - radius * 0.85, y: right.y))
        bridge.lineWidth = width
        bridge.stroke()
    }

    private enum Mouth {
        case smile
        case small
        case frown
    }

    private static func drawMouth(_ mouth: Mouth, in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        switch mouth {
        case .smile:
            path.move(to: point(0.40, 0.56, in: rect))
            path.curve(
                to: point(0.60, 0.56, in: rect),
                controlPoint1: point(0.46, 0.70, in: rect),
                controlPoint2: point(0.54, 0.70, in: rect)
            )
        case .small:
            path.appendOval(in: NSRect(
                x: rect.midX - rect.width * 0.045,
                y: rect.maxY - rect.height * 0.64,
                width: rect.width * 0.09,
                height: rect.height * 0.07
            ))
        case .frown:
            path.move(to: point(0.40, 0.66, in: rect))
            path.curve(
                to: point(0.60, 0.66, in: rect),
                controlPoint1: point(0.46, 0.54, in: rect),
                controlPoint2: point(0.54, 0.54, in: rect)
            )
        }
        path.lineWidth = max(1, rect.width * 0.07)
        path.lineCapStyle = .round
        color.setStroke()
        if mouth == .small {
            color.setFill()
            path.fill()
        } else {
            path.stroke()
        }
    }

    private static func drawPencil(in rect: NSRect, color: NSColor) {
        let tip = point(0.93, 0.68, in: rect)
        let end = point(0.74, 0.90, in: rect)
        let shaft = NSBezierPath()
        shaft.move(to: tip)
        shaft.line(to: end)
        shaft.lineWidth = max(1.4, rect.width * 0.09)
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()
        let nib = NSBezierPath()
        nib.move(to: tip)
        nib.line(to: NSPoint(x: tip.x + rect.width * 0.06, y: tip.y + rect.height * 0.02))
        nib.lineWidth = max(1.2, rect.width * 0.07)
        nib.lineCapStyle = .round
        NSColor.systemOrange.setStroke()
        nib.stroke()
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height)
    }
}
