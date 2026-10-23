import AppKit

/// Keeps the visual-effect backdrop and its contents inside the same rounded silhouette.
final class FloatingPanelBackgroundView: NSVisualEffectView {
    private static let radius: CGFloat = 18
    private static let roundedMask: NSImage = {
        let radius = FloatingPanelBackgroundView.radius
        let size = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        state = .active
        blendingMode = .behindWindow
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        // Layer clipping alone does not reliably clip the separate backdrop surface.
        maskImage = Self.roundedMask
        updateBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FloatingPanelBackgroundView does not support NSCoder") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        }
    }
}

/// Dismisses ready results on deliberate outside interaction, never on mouse movement.
final class FloatingPanelDismissMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var generation: UInt = 0

    func start(for window: NSWindow, onOutsideInteraction: @escaping () -> Void) {
        stop()
        guard window.isVisible else { return }
        let currentGeneration = generation
        let handleOutside = { [weak self] in
            guard self?.generation == currentGeneration else { return }
            onOutsideInteraction()
        }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .keyDown, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak window] event in
            if let window, event.window !== window {
                handleOutside()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { _ in
            handleOutside()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                handleOutside()
            }
        }
    }

    func stop() {
        generation &+= 1
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        localMonitor = nil
        globalMonitor = nil
        activationObserver = nil
    }

    deinit { stop() }
}
