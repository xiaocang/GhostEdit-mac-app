import AppKit
import ApplicationServices
import UserNotifications
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hotkeyManager = HotkeyManager()
    private let clipboardManager = ClipboardManager()
    private let configManager = ConfigManager()
    private lazy var historyStore = CorrectionHistoryStore(fileURL: configManager.historyURL)
    private lazy var shellRunner = ShellRunner(configManager: configManager)
    private var settingsWindowController: SettingsWindowController?
    private var historyWindowController: HistoryWindowController?
    private var developerConsoleController: DeveloperConsoleController?
    private var liveFeedbackController: LiveFeedbackController?
    private let correctionFloater = CorrectionFloaterController()
    private var pendingFloaterAnchor: CGRect?

    private var statusMenu: NSMenu?
    private var statusMenuItem: NSMenuItem?
    private var statusDetailMenuItem: NSMenuItem?
    private var runNowMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var writingCoachMenuItem: NSMenuItem?
    private var developerModeMenuItem: NSMenuItem?
    private var toneMenuItem: NSMenuItem?
    private var advancedSubmenuItem: NSMenuItem?
    private var checkUpdatesMenuItem: NSMenuItem?
    private var liveFeedbackMenuItem: NSMenuItem?

    private var isProcessing = false
    private var correctionGeneration = 0
    private var isShowingAccessibilityAlert = false
    private var didShowAccessibilityGuidance = false
    private var clipboardSnapshot: ClipboardManager.Snapshot?
    private var pendingClipboardRestore: DispatchWorkItem?
    private var targetAppAtTrigger: NSRunningApplication?
    private var lastExternalActiveApp: NSRunningApplication?

    private let idleMenuBarIcon = MenuBarIconSupport.descriptor(for: .idle)
    private let workingMenuBarIcon = MenuBarIconSupport.descriptor(for: .processing)
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - App Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningUnitTests {
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupEditMenu()
        configureStatusItem()

        correctionFloater.onCopy = { [weak self] text in
            self?.copyFloaterResult(text)
        }
        correctionFloater.onUserDismiss = { [weak self] in
            self?.cancelInFlightCorrection()
        }
        do {
            try configManager.bootstrapIfNeeded()
            try historyStore.bootstrapIfNeeded()
        } catch {
            showFatalAlert(
                title: "GhostEdit Setup Failed",
                message: "Could not create ~/.ghostedit files.\n\n\(error.localizedDescription)"
            )
            return
        }

        startObservingActiveApplication()
        _ = ensureAccessibilityPermission(promptSystemDialog: false, showGuidanceAlert: false)
        syncLaunchAtLoginPreferenceSilently()
        registerHotkey()
        if configManager.loadConfig().liveFeedbackEnabled {
            startLiveFeedback()
        }
        setStatus("Idle")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        stopLiveFeedback()
        shellRunner.killPersistentSession()
        stopProcessingIndicator()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Menu Bar Setup

    private func configureStatusItem() {
        if let button = statusItem.button {
            setMenuBarIcon(idleMenuBarIcon)
            button.toolTip = "GhostEdit"
        }

        let menu = NSMenu()

        // ── Status line ──
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        let model = config.resolvedModel(for: provider)
        let modelDisplay = model.isEmpty ? provider.defaultModel : model

        let status = NSMenuItem(
            title: "\(provider.displayName) · \(modelDisplay)",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let detail = NSMenuItem(
            title: "Ready",
            action: nil,
            keyEquivalent: ""
        )
        detail.isEnabled = false
        if let img = sfSymbol("circle.fill", size: 8) {
            img.isTemplate = false
            let tinted = tintedImage(img, color: .systemGreen)
            detail.image = tinted
        }
        menu.addItem(detail)
        statusDetailMenuItem = detail

        menu.addItem(.separator())

        // ── CORRECTION section ──
        menu.addItem(sectionHeader("CORRECTION"))

        let runNow = NSMenuItem(
            title: "Correct Selection",
            action: #selector(runNowAction),
            keyEquivalent: ""
        )
        runNow.target = self
        runNow.image = sfSymbol("pencil.and.outline", size: 15)
        let hotkeyDisplay = HotkeySupport.displayString(
            keyCode: config.hotkeyKeyCode,
            modifiers: config.hotkeyModifiers
        )
        runNow.toolTip = "Shows a nearby diff. Does not replace the text. Hotkey: \(hotkeyDisplay)"
        menu.addItem(runNow)
        runNowMenuItem = runNow

        menu.addItem(.separator())

        // ── TOOLS section ──
        menu.addItem(sectionHeader("TOOLS"))

        let settings = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = sfSymbol("gearshape", size: 15)
        menu.addItem(settings)

        let history = NSMenuItem(
            title: "History...",
            action: #selector(openHistoryAction),
            keyEquivalent: ""
        )
        history.target = self
        history.image = sfSymbol("clock", size: 15)
        menu.addItem(history)
        historyMenuItem = history

        let writingCoach = NSMenuItem(
            title: "Sharpen My Writing Style",
            action: #selector(openWritingCoachAction),
            keyEquivalent: ""
        )
        writingCoach.target = self
        writingCoach.image = sfSymbol("text.magnifyingglass", size: 15)
        menu.addItem(writingCoach)
        writingCoachMenuItem = writingCoach

        let liveFeedback = NSMenuItem(
            title: "Live Feedback",
            action: #selector(toggleLiveFeedbackAction),
            keyEquivalent: ""
        )
        liveFeedback.target = self
        liveFeedback.image = sfSymbol("waveform.badge.magnifyingglass", size: 15)
        let feedbackConfig = configManager.loadConfig()
        liveFeedback.state = feedbackConfig.liveFeedbackEnabled ? .on : .off
        menu.addItem(liveFeedback)
        liveFeedbackMenuItem = liveFeedback

        let toneItem = NSMenuItem(title: "Tone", action: nil, keyEquivalent: "")
        toneItem.image = sfSymbol("speaker.wave.2", size: 15)
        let toneSubmenu = NSMenu()
        let toneIcons: [String: String] = [
            "default": "circle", "casual": "cup.and.saucer", "professional": "briefcase",
            "academic": "graduationcap", "slack": "bubble.left"
        ]
        for preset in AppConfig.supportedPresets {
            let item = NSMenuItem(
                title: preset.capitalized,
                action: #selector(tonePresetSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            if let iconName = toneIcons[preset] {
                item.image = sfSymbol(iconName, size: 13)
            }
            toneSubmenu.addItem(item)
        }
        toneItem.submenu = toneSubmenu
        menu.addItem(toneItem)
        toneMenuItem = toneItem
        refreshToneMenuState()

        let statistics = NSMenuItem(
            title: "Statistics...",
            action: #selector(openStatisticsAction),
            keyEquivalent: ""
        )
        statistics.target = self
        statistics.image = sfSymbol("chart.bar", size: 15)
        menu.addItem(statistics)

        menu.addItem(.separator())

        // ── ADVANCED submenu ──
        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.image = sfSymbol("wrench.and.screwdriver", size: 15)
        let advancedSubmenu = NSMenu()

        let openPrompt = NSMenuItem(
            title: "Open Prompt File",
            action: #selector(openPromptFileAction),
            keyEquivalent: ""
        )
        openPrompt.target = self
        openPrompt.image = sfSymbol("doc.text", size: 15)
        advancedSubmenu.addItem(openPrompt)

        let openConfig = NSMenuItem(
            title: "Open Config File",
            action: #selector(openConfigFileAction),
            keyEquivalent: ""
        )
        openConfig.target = self
        openConfig.image = sfSymbol("doc.badge.gearshape", size: 15)
        advancedSubmenu.addItem(openConfig)

        advancedSubmenu.addItem(.separator())

        let exportSettings = NSMenuItem(
            title: "Export Settings...",
            action: #selector(exportSettingsAction),
            keyEquivalent: ""
        )
        exportSettings.target = self
        exportSettings.image = sfSymbol("square.and.arrow.up", size: 15)
        advancedSubmenu.addItem(exportSettings)

        let importSettings = NSMenuItem(
            title: "Import Settings...",
            action: #selector(importSettingsAction),
            keyEquivalent: ""
        )
        importSettings.target = self
        importSettings.image = sfSymbol("square.and.arrow.down", size: 15)
        advancedSubmenu.addItem(importSettings)

        advancedSubmenu.addItem(.separator())

        let checkAccessibility = NSMenuItem(
            title: "Check Accessibility Permission",
            action: #selector(checkAccessibilityAction),
            keyEquivalent: ""
        )
        checkAccessibility.target = self
        checkAccessibility.image = sfSymbol("lock.shield", size: 15)
        advancedSubmenu.addItem(checkAccessibility)

        advancedSubmenu.addItem(.separator())

        let developerMode = NSMenuItem(
            title: "Developer Mode",
            action: #selector(toggleDeveloperModeAction),
            keyEquivalent: ""
        )
        developerMode.target = self
        developerMode.image = sfSymbol("terminal", size: 15)
        advancedSubmenu.addItem(developerMode)
        developerModeMenuItem = developerMode
        refreshDeveloperModeMenuState()

        advancedItem.submenu = advancedSubmenu
        menu.addItem(advancedItem)
        advancedSubmenuItem = advancedItem

        menu.addItem(.separator())

        // ── ABOUT section ──
        let version = NSMenuItem(title: appVersionText(), action: nil, keyEquivalent: "")
        version.isEnabled = false
        version.image = sfSymbol("ghost", size: 15) ?? sfSymbol("sparkles", size: 15)
        menu.addItem(version)

        let checkUpdates = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        checkUpdates.image = sfSymbol("arrow.triangle.2.circlepath", size: 15)
        menu.addItem(checkUpdates)
        checkUpdatesMenuItem = checkUpdates

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit GhostEdit",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quit.image = sfSymbol("power", size: 15)
        quit.target = self
        menu.addItem(quit)

        statusMenu = menu
        statusItem.menu = menu
    }

    private func sfSymbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        return item
    }

    // MARK: - Menu Actions

    private func startObservingActiveApplication() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if let current = NSWorkspace.shared.frontmostApplication {
            cacheExternalAppIfNeeded(current)
        }
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return
        }

        cacheExternalAppIfNeeded(app)
    }

    private func cacheExternalAppIfNeeded(_ app: NSRunningApplication) {
        if app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalActiveApp = app
        }
    }

    private func startLiveFeedback() {
        guard liveFeedbackController == nil else { return }
        liveFeedbackController = LiveFeedbackController(configManager: configManager)
        liveFeedbackController?.onAXWriteBlocked = { [weak self] original, fixed in
            self?.writeBackViaClipboard(fixedText: fixed, original: original)
        }
        liveFeedbackController?.start()
    }

    private func stopLiveFeedback() {
        liveFeedbackController?.stop()
        liveFeedbackController = nil
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Hotkey Registration

    private func registerHotkey() {
        let config = configManager.loadConfig()
        hotkeyManager.register(
            keyCode: config.hotkeyKeyCode,
            modifiers: config.hotkeyModifiers
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleHotkeyTrigger()
            }
        }
    }

    @objc private func runNowAction() {
        statusMenu?.cancelTracking()
        handleHotkeyTrigger()
    }

    @objc private func openPromptFileAction() {
        NSWorkspace.shared.open(configManager.promptURL)
    }

    @objc private func openSettingsAction() {
        statusMenu?.cancelTracking()
        showSettingsWindow()
    }

    @objc private func openHistoryAction() {
        statusMenu?.cancelTracking()
        showHistoryWindow()
    }

    @objc private func openWritingCoachAction() {
        statusMenu?.cancelTracking()
        runWritingCoach()
    }

    @objc private func toggleLiveFeedbackAction() {
        var config = configManager.loadConfig()
        config.liveFeedbackEnabled.toggle()
        try? configManager.saveConfig(config)
        liveFeedbackMenuItem?.state = config.liveFeedbackEnabled ? .on : .off
        if config.liveFeedbackEnabled {
            startLiveFeedback()
        } else {
            stopLiveFeedback()
        }
    }

    @objc private func openConfigFileAction() {
        NSWorkspace.shared.open(configManager.configURL)
    }

    @objc private func checkAccessibilityAction() {
        statusMenu?.cancelTracking()
        didShowAccessibilityGuidance = false
        _ = ensureAccessibilityPermission(promptSystemDialog: true, showGuidanceAlert: true)
    }

    @objc private func checkForUpdatesAction() {
        statusMenu?.cancelTracking()
        performUpdateCheck()
    }

    @objc private func openStatisticsAction() {
        statusMenu?.cancelTracking()
        showStatisticsWindow()
    }

    @objc private func exportSettingsAction() {
        statusMenu?.cancelTracking()
        performExportSettings()
    }

    @objc private func importSettingsAction() {
        statusMenu?.cancelTracking()
        performImportSettings()
    }

    @objc private func tonePresetSelected(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        var config = configManager.loadConfig()
        config.tonePreset = preset
        try? configManager.saveConfig(config)
        refreshToneMenuState()
    }

    private func refreshToneMenuState() {
        let config = configManager.loadConfig()
        guard let submenu = toneMenuItem?.submenu else { return }
        for item in submenu.items {
            if let preset = item.representedObject as? String {
                item.state = (preset == config.tonePreset) ? .on : .off
            }
        }
    }

    @objc private func toggleDeveloperModeAction() {
        statusMenu?.cancelTracking()
        var config = configManager.loadConfig()
        config.developerMode = !config.developerMode
        try? configManager.saveConfig(config)
        refreshDeveloperModeMenuState()

        if config.developerMode {
            shellRunner.developerModeLogger = self
            showDeveloperConsole()
            devLog(.textCapture, "Developer mode enabled")
        } else {
            devLog(.textCapture, "Developer mode disabled")
            shellRunner.developerModeLogger = nil
        }
    }

    private func refreshDeveloperModeMenuState() {
        let config = configManager.loadConfig()
        developerModeMenuItem?.state = config.developerMode ? .on : .off

        if config.developerMode {
            shellRunner.developerModeLogger = self
        }
    }

    private func showDeveloperConsole() {
        if developerConsoleController == nil {
            developerConsoleController = DeveloperConsoleController()
        }
        developerConsoleController?.showWindow(nil)
        developerConsoleController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isDeveloperModeEnabled() -> Bool {
        configManager.loadConfig().developerMode
    }

    private func devLog(_ phase: DeveloperModeLogEntry.Phase, _ message: String) {
        guard isDeveloperModeEnabled() else { return }
        let entry = DeveloperModeLogEntry(phase: phase, message: message)
        developerConsoleController?.appendEntry(entry)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    /// Extract the line containing the cursor position.
    /// Returns the line text (trimmed of trailing newline for correction) and its range in the full text.
    private func extractLineAtCursor(text: String, cursorLocation: Int) -> (lineText: String, lineRange: NSRange)? {
        LocalFixSupport.extractLineAtCursor(text: text, cursorLocation: cursorLocation)
    }

    /// Clipboard fallback when text was read & fixed but AX write failed (web/Electron apps).
    /// Pastes via Cmd+A (select all) then Cmd+V (paste) in the target app.
    private func writeBackViaClipboard(fixedText: String, original: String) {
        guard let targetApp = NSWorkspace.shared.frontmostApplication,
              targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            if let cached = lastExternalActiveApp, !cached.isTerminated {
                writeBackViaClipboardToApp(cached, fixedText: fixedText, original: original)
            }
            return
        }
        writeBackViaClipboardToApp(targetApp, fixedText: fixedText, original: original)
    }

    private func writeBackViaClipboardToApp(
        _ targetApp: NSRunningApplication,
        fixedText: String,
        original _: String
    ) {
        let snap = clipboardManager.snapshot()
        clipboardManager.writePlainText(fixedText)

        targetApp.activate(options: [.activateAllWindows])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }

            // Select all text in the field, then paste the corrected text
            self.clipboardManager.simulateSelectAllShortcut(using: .annotatedSession)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = self.clipboardManager.simulatePasteShortcut(using: .annotatedSession)
                    || self.clipboardManager.simulatePasteShortcut(using: .hidSystem)

                // Restore clipboard after a short delay (cancellable)
                self.pendingClipboardRestore?.cancel()
                let restoreItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingClipboardRestore = nil
                    self.clipboardManager.restore(snap)
                }
                self.pendingClipboardRestore = restoreItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: restoreItem)
            }
        }
    }

    // MARK: - Correction Pipeline

    private func handleHotkeyTrigger() {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil

        guard ensureAccessibilityPermission(promptSystemDialog: false, showGuidanceAlert: true) else {
            playErrorSound()
            setStatus("Accessibility permission required")
            return
        }

        guard !isProcessing else {
            playErrorSound()
            setStatus("Already processing")
            return
        }

        guard let targetApp = resolveTargetApplication() else {
            playErrorSound()
            setStatus("Could not determine target app; focus text app and retry")
            return
        }

        isProcessing = true
        correctionGeneration += 1
        let generation = correctionGeneration
        startProcessingIndicator()
        pendingFloaterAnchor = focusedSelectionRect(pid: targetApp.processIdentifier)
        correctionFloater.showLoading(near: pendingFloaterAnchor)
        targetAppAtTrigger = targetApp
        devLog(.textCapture, "Target app: \(targetApp.localizedName ?? targetApp.bundleIdentifier ?? "unknown") (PID \(targetApp.processIdentifier))")

        // Try accessibility-based reading first (no clipboard round-trip needed).
        // Skip if text contains U+FFFC (Object Replacement Character) - this means
        // the source app rendered inline images (e.g. Slack custom emojis) that the
        // AX API cannot represent as text. Fall through to clipboard which has HTML.
        if let selectedText = AccessibilityTextSupport.readSelectedText(
            appPID: targetApp.processIdentifier
        ), !selectedText.contains(TokenPreservationSupport.objectReplacementCharacter) {
            devLog(.textCapture, "Read via Accessibility (\(selectedText.count) chars): \(DeveloperModeSupport.truncate(selectedText))")
            processSelectedText(selectedText, generation: generation)
            return
        }

        // Nothing selected - try extracting the current line at the cursor
        let pid = targetApp.processIdentifier
        if let fullText = AccessibilityTextSupport.readFullText(appPID: pid),
           !fullText.contains(TokenPreservationSupport.objectReplacementCharacter),
           let cursorPos = AccessibilityTextSupport.readCursorPosition(appPID: pid),
           let lineInfo = extractLineAtCursor(text: fullText, cursorLocation: cursorPos) {
            devLog(.textCapture, "No selection - extracted line at cursor (\(lineInfo.lineText.count) chars)")
            processSelectedText(lineInfo.lineText, generation: generation)
            return
        }

        devLog(.textCapture, "Accessibility read failed or contained U+FFFC, falling back to clipboard")

        // Fall back to clipboard-based copy.
        clipboardSnapshot = clipboardManager.snapshot()

        let sentinel = "__GHOSTEDIT_SENTINEL_\(UUID().uuidString)__"
        clipboardManager.writePlainText(sentinel)

        let strategies: [ClipboardManager.ShortcutPosting] = [.annotatedSession, .hidSystem]
        attemptCopySelection(sentinel: sentinel, strategies: strategies, index: 0, generation: generation)
    }

    private func resolveTargetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost
        }

        if let cached = lastExternalActiveApp, !cached.isTerminated {
            return cached
        }

        return nil
    }

    private func attemptCopySelection(
        sentinel: String,
        strategies: [ClipboardManager.ShortcutPosting],
        index: Int,
        generation: Int
    ) {
        guard generation == correctionGeneration else { return }
        guard index < strategies.count else {
            playErrorSound()
            restoreClipboardSnapshot(after: 0)
            setStatus("No text selected")
            correctionFloater.showError("No text selected. Focus a text field and try again.", near: pendingFloaterAnchor)
            finishProcessing()
            return
        }

        let strategy = strategies[index]
        setStatus("Copying selected text... (\(strategy.displayName))")

        // Give the triggering key chord enough time to release.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, generation == self.correctionGeneration else { return }
            self.targetAppAtTrigger?.activate(options: [.activateAllWindows])

            guard self.clipboardManager.simulateCopyShortcut(using: strategy) else {
                self.attemptCopySelection(sentinel: sentinel, strategies: strategies, index: index + 1, generation: generation)
                return
            }

            self.waitForCopiedText(sentinel: sentinel, timeoutSeconds: 1.4) { [weak self] selectedText in
                guard let self else { return }
                if let selectedText {
                    self.processSelectedText(selectedText, generation: generation)
                    return
                }

                self.attemptCopySelection(sentinel: sentinel, strategies: strategies, index: index + 1, generation: generation)
            }
        }
    }

    private func waitForCopiedText(
        sentinel: String,
        timeoutSeconds: TimeInterval,
        completion: @escaping (String?) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let startTime = Date()

        func poll() {
            if let candidate = clipboardManager.readBestText() {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != sentinel {
                    // Recover Slack emoji codes from HTML clipboard if the plain text
                    // contains U+FFFC (Object Replacement Characters from inline images).
                    let recovered = TokenPreservationSupport.recoverObjectReplacements(
                        in: trimmed,
                        fromHTML: clipboardManager.readHTMLString()
                    )
                    completion(recovered)
                    return
                }
            }

            if Date() >= deadline {
                completion(nil)
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let interval: TimeInterval = elapsed < 0.2 ? 0.02 : 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: poll)
        }

        poll()
    }

    private func processSelectedText(_ selectedText: String, generation: Int) {
        guard generation == correctionGeneration else { return }
        let prompt: String
        let baseConfig = configManager.loadConfig()

        // Apply per-app profile overrides if a matching profile exists.
        let profiles = loadAppProfiles()
        let targetBundleID = targetAppAtTrigger?.bundleIdentifier
        let config = AppProfileSupport.resolvedConfig(
            base: baseConfig,
            profiles: profiles,
            bundleIdentifier: targetBundleID
        )

        let provider = config.resolvedProvider
        let model = config.resolvedModel(for: provider)
        let startedAt = Date()

        if !profiles.isEmpty, let bundleID = targetBundleID {
            devLog(.textCapture, "Per-app profile check for \(bundleID): \(profiles.contains(where: { $0.bundleIdentifier == bundleID }) ? "matched" : "no match")")
        }

        // If a tone preset is active, use its prompt instead of the file prompt.
        if let presetPrompt = AppConfig.promptForPreset(config.tonePreset) {
            prompt = presetPrompt
        } else {
            do {
                prompt = try configManager.loadPrompt()
            } catch {
                let message = "Could not read prompt file.\n\n\(error.localizedDescription)"
                restoreClipboardSnapshot(after: 0)
                correctionFloater.showError(message, near: pendingFloaterAnchor)
                notifyFailure(body: "Correction Failed. \(message)")
                showFailureAlert(title: "Correction Failed", message: message)
                setStatus("Failed to read prompt file")
                finishProcessing()
                return
            }
        }

        let modelDisplay = model.isEmpty ? "provider default" : model
        devLog(.cliExecution, "Processing with \(provider.executableName) (\(modelDisplay))")
        setStatus("Processing with \(provider.executableName) (\(modelDisplay))...")


        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let correctedText = try self.shellRunner.correctTextPreservingTokens(
                    systemPrompt: prompt,
                    selectedText: selectedText
                )
                self.recordHistoryEntry(
                    originalText: selectedText,
                    generatedText: correctedText,
                    provider: provider,
                    model: model,
                    startedAt: startedAt,
                    succeeded: true
                )

                DispatchQueue.main.async {
                    guard generation == self.correctionGeneration else { return }
                    self.updateTooltip(
                        original: selectedText,
                        corrected: correctedText,
                        provider: provider.displayName,
                        model: model
                    )
                    self.presentCorrection(original: selectedText, corrected: correctedText)
                }
            } catch {
                // Try the next cached model if the error is retriable.
                let catalog = ModelCatalogSupport.load(
                    from: configManager.baseDirectoryURL.appendingPathComponent("model-cache.json")
                )
                let endpoint = ModelCatalogSupport.endpoint(
                    provider: provider.rawValue,
                    ollamaBaseURL: config.ollamaBaseURL,
                    magpieBaseURL: config.magpieBaseURL
                )
                let models = ModelCatalogSupport.models(
                    in: catalog,
                    key: ModelCatalogSupport.cacheKey(provider: provider.rawValue, endpoint: endpoint)
                )
                if FallbackSupport.isRetriable(error),
                   let fallbackModel = FallbackSupport.nextFallbackModel(currentModel: model, models: models) {
                    DispatchQueue.main.async {
                        guard generation == self.correctionGeneration else { return }
                        self.devLog(.cliExecution, "Retrying with fallback model: \(fallbackModel)")
                        self.setStatus("Retrying with \(fallbackModel)...")
                    }
                    do {
                        let stored = self.configManager.loadConfig()
                        var retryConfig = stored
                        retryConfig.model = fallbackModel
                        try self.configManager.saveConfig(retryConfig)
                        defer { try? self.configManager.saveConfig(stored) }
                        let correctedText = try self.shellRunner.correctTextPreservingTokens(
                            systemPrompt: prompt,
                            selectedText: selectedText
                        )
                        self.recordHistoryEntry(
                            originalText: selectedText,
                            generatedText: correctedText,
                            provider: provider,
                            model: fallbackModel,
                            startedAt: startedAt,
                            succeeded: true
                        )
                        DispatchQueue.main.async {
                            guard generation == self.correctionGeneration else { return }
                            self.updateTooltip(
                                original: selectedText,
                                corrected: correctedText,
                                provider: provider.displayName,
                                model: fallbackModel
                            )
                            self.presentCorrection(original: selectedText, corrected: correctedText)
                        }
                        return
                    } catch {
                        // Fallback also failed - fall through to normal error handling.
                    }
                }

                DispatchQueue.main.async {
                    guard generation == self.correctionGeneration else { return }
                    self.restoreClipboardSnapshot(after: 0)
                    self.recordHistoryEntry(
                        originalText: selectedText,
                        generatedText: "",
                        provider: provider,
                        model: model,
                        startedAt: startedAt,
                        succeeded: false
                    )
                    self.correctionFloater.showError(error.localizedDescription, near: self.pendingFloaterAnchor)
                    self.handleProcessingError(error)
                    self.finishProcessing()
                }
            }
        }
    }

    private func presentCorrection(original: String, corrected: String) {
        restoreClipboardSnapshot(after: 0)
        let anchor = pendingFloaterAnchor
        if corrected == original {
            correctionFloater.showUnchanged(near: anchor)
            setStatus("No changes needed")
        } else {
            correctionFloater.editBoxOpacity = CGFloat(configManager.loadConfig().floaterOpacity)
            correctionFloater.showCorrection(original: original, corrected: corrected, near: anchor)
            setStatus("Correction ready to copy")
            playSuccessSound()
            notifySuccessIfEnabled()
        }
        finishProcessing()
    }

    private func focusedSelectionRect(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement
        var selectedRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success,
              let selectedRange,
              CFGetTypeID(selectedRange) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selectedRange as! AXValue, .cfRange, &range), range.location >= 0 else {
            return nil
        }
        // The union box of a long selection sits at the field's left edge. The last
        // character is the point next to the selected text.
        var tail = range.length > 1
            ? CFRange(location: range.location + range.length - 1, length: 1)
            : range
        guard let tailValue = AXValueCreate(.cfRange, &tail) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            tailValue,
            &boundsValue
        ) == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.height > 0 else {
            return nil
        }
        if rect.width < 1 { rect.size.width = 1 }
        return Self.cocoaRect(fromTopLeftScreenRect: rect)
    }

    private static func cocoaRect(fromTopLeftScreenRect rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGRect(
            x: rect.origin.x,
            y: height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func handleProcessingError(_ error: Error) {
        if case let ShellRunnerError.cliNotFound(provider) = error {
            setStatus("\(provider.executableName) CLI not found; update config.json")
            notifyFailure(body: "Correction Failed. \(provider.displayName) CLI not found.")
            showCLIPathAlert(provider: provider)
            return
        }

        if case let ShellRunnerError.authenticationRequired(provider) = error {
            setStatus("\(provider.executableName) authentication required")
            notifyFailure(body: "Correction Failed. \(provider.displayName) authentication expired. Run `\(provider.authCommand)` in Terminal.")
            showCLIAuthAlert(provider: provider)
            return
        }

        let shouldSuggestModelSwitch: Bool
        if let shellError = error as? ShellRunnerError {
            switch shellError {
            case .processFailed, .timedOut, .emptyResponse:
                shouldSuggestModelSwitch = true
            default:
                shouldSuggestModelSwitch = false
            }
        } else {
            shouldSuggestModelSwitch = false
        }

        let message: String
        if shouldSuggestModelSwitch {
            message = "\(error.localizedDescription)\nTry switching model in Settings if the selected model is busy or unavailable."
        } else {
            message = error.localizedDescription
        }
        setStatus("Correction failed")
        notifyFailure(body: "Correction Failed. \(message)")
        showFailureAlert(title: "Correction Failed", message: message)
    }

    private func startProcessingIndicator() {
        runNowMenuItem?.isEnabled = false
        writingCoachMenuItem?.isEnabled = false
        statusMenu?.cancelTracking()
        statusItem.menu = nil
        setMenuBarIcon(workingMenuBarIcon)
    }

    private func stopProcessingIndicator() {
        runNowMenuItem?.isEnabled = true
        writingCoachMenuItem?.isEnabled = true
        statusItem.menu = statusMenu
        setMenuBarIcon(idleMenuBarIcon)
    }

    // MARK: - Processing State

    private func finishProcessing() {
        isProcessing = false
        targetAppAtTrigger = nil
        stopProcessingIndicator()
    }

    @discardableResult
    // MARK: - Accessibility & Alerts

    private func ensureAccessibilityPermission(
        promptSystemDialog: Bool,
        showGuidanceAlert: Bool
    ) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: promptSystemDialog] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted, showGuidanceAlert, !didShowAccessibilityGuidance {
            didShowAccessibilityGuidance = true
            showAccessibilityAlert()
        }

        return trusted
    }

    private func showAccessibilityAlert() {
        guard !isShowingAccessibilityAlert else {
            return
        }

        isShowingAccessibilityAlert = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = AccessibilitySupport.guidanceText(appName: "GhostEdit")
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Later")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }

            self.isShowingAccessibilityAlert = false
        }
    }

    private func showCLIPathAlert(provider: CLIProvider) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(provider.displayName) CLI Not Found"
            alert.informativeText = "Set an absolute path in ~/.ghostedit/config.json (\(provider.configPathKey)), or switch provider/model in Settings."
            alert.addButton(withTitle: "Open Config")
            alert.addButton(withTitle: "OK")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(self.configManager.configURL)
            }
        }
    }

    private func showCLIAuthAlert(provider: CLIProvider) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(provider.displayName) Authentication Required"
            alert.informativeText = "Your \(provider.displayName) CLI session is expired.\n\nRun this command in Terminal:\n\(provider.authCommand)\n\nThen retry GhostEdit."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Sound & Notifications

    private func playErrorSound() {
        guard configManager.loadConfig().soundFeedbackEnabled else { return }
        NSSound.beep()
    }

    private func playSuccessSound() {
        guard configManager.loadConfig().soundFeedbackEnabled else { return }
        NSSound(named: "Glass")?.play()
    }

    private func notifySuccessIfEnabled() {
        guard configManager.loadConfig().notifyOnSuccess else { return }
        let content = UNMutableNotificationContent()
        content.title = "GhostEdit"
        content.body = "Correction ready to copy."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func notifyFailure(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "GhostEdit"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Status Bar

    private func setStatus(_ text: String) {
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        let model = config.resolvedModel(for: provider)
        let modelDisplay = model.isEmpty ? provider.defaultModel : model
        statusMenuItem?.title = "\(provider.displayName) · \(modelDisplay)"
        statusDetailMenuItem?.title = text

        // Update status dot color on detail item
        let dotColor: NSColor
        switch StatusDisplaySupport.statusColor(for: text) {
        case .green:  dotColor = .systemGreen
        case .orange: dotColor = .systemOrange
        case .red:    dotColor = .systemRed
        }
        if let img = sfSymbol("circle.fill", size: 8) {
            img.isTemplate = false
            statusDetailMenuItem?.image = tintedImage(img, color: dotColor)
        }

        statusItem.button?.toolTip = "GhostEdit\n\(provider.displayName) · \(modelDisplay)\n\(text)"
    }

    private func setMenuBarIcon(_ descriptor: MenuBarIconDescriptor) {
        guard let button = statusItem.button else {
            return
        }

        if let iconImage = MenuBarIconSupport.resolveImage(
            named: NSImage.Name(descriptor.assetName)
        ) {
            iconImage.isTemplate = false
            button.image = iconImage
            button.imagePosition = .imageOnly
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular)
        ]
        button.image = nil
        button.title = descriptor.fallbackGlyph
        button.attributedTitle = NSAttributedString(string: descriptor.fallbackGlyph, attributes: attrs)
    }

    private func appVersionText() -> String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "Version \(shortVersion)"
    }

    // MARK: - Window Presentation

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                configManager: configManager
            ) { [weak self] config in
                guard let self else {
                    return
                }
                let provider = config.resolvedProvider
                let model = config.resolvedModel(for: provider)
                let modelDisplay = model.isEmpty ? "provider default" : model
                let hotkeyDisplay = HotkeySupport.displayString(
                    keyCode: config.hotkeyKeyCode,
                    modifiers: config.hotkeyModifiers
                )
                try? self.historyStore.trim(limit: config.historyLimit)
                self.refreshHistoryWindowIfVisible()
                self.registerHotkey()
                self.liveFeedbackMenuItem?.state = config.liveFeedbackEnabled ? .on : .off
                if config.liveFeedbackEnabled {
                    self.startLiveFeedback()
                } else {
                    self.stopLiveFeedback()
                }
                self.setStatus("Settings saved (\(provider.executableName), model: \(modelDisplay), hotkey: \(hotkeyDisplay))")
            }
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistoryWindow() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        refreshHistoryWindowIfVisible()
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStatisticsWindow() {
        let entries = historyStore.load()
        let stats = CorrectionStatisticsSupport.compute(from: entries)
        let tokenEstimate = TokenEstimationSupport.estimateCumulativeTokens(entries: entries)
        var summary = CorrectionStatisticsSupport.formattedSummary(stats)
        summary += "\n\nEstimated tokens used:"
        summary += "\n  Input: \(TokenEstimationSupport.formatTokenCount(tokenEstimate.inputTokens))"
        summary += "\n  Output: \(TokenEstimationSupport.formatTokenCount(tokenEstimate.outputTokens))"
        summary += "\n  Total: \(TokenEstimationSupport.formatTokenCount(tokenEstimate.totalTokens))"

        let alert = NSAlert()
        alert.messageText = "Correction Statistics"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
        }
    }

    // MARK: - Settings Import/Export

    private func performExportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SettingsExportSupport.defaultFileName(appVersion: appVersionText())
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let config = configManager.loadConfig()
            let prompt = (try? configManager.loadPrompt()) ?? ""
            let data = try SettingsExportSupport.exportSettings(
                config: config,
                prompt: prompt,
                appVersion: appVersionText()
            )
            try data.write(to: url, options: .atomic)
            setStatus("Settings exported")
        } catch {
            showFailureAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func performImportSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        do {
            let data = try Data(contentsOf: url)
            let imported = try SettingsExportSupport.importSettings(from: data)
            try configManager.saveConfig(imported.config)
            if !imported.prompt.isEmpty {
                try imported.prompt.write(to: configManager.promptURL, atomically: true, encoding: .utf8)
            }
            configManager.invalidateCache()
            refreshToneMenuState()
            refreshDeveloperModeMenuState()
            setStatus("Settings imported")
        } catch {
            showFailureAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    private func updateTooltip(original: String, corrected: String, provider: String, model: String) {
        let tooltip = TooltipSupport.tooltip(
            lastOriginal: original,
            lastCorrected: corrected,
            lastTime: Date(),
            provider: provider,
            model: model
        )
        statusItem.button?.toolTip = tooltip
    }

    // MARK: - Update Check

    private func performUpdateCheck() {
        setStatus("Checking for updates...")

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let latestVersion = self.fetchLatestGitHubVersion()

            DispatchQueue.main.async {
                guard let latest = latestVersion else {
                    self.setStatus("Idle")
                    let alert = NSAlert()
                    alert.messageText = "Update Check"
                    alert.informativeText = "Could not reach GitHub to check for updates. Please check your internet connection."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                let info = UpdateCheckSupport.checkVersion(current: currentVersion, latest: latest)
                self.setStatus("Idle")

                let alert = NSAlert()
                alert.messageText = "Update Check"
                if info.isUpdateAvailable {
                    self.checkUpdatesMenuItem?.title = "Update Available (v\(info.latest))"
                    if let badge = self.sfSymbol("exclamationmark.circle.fill", size: 15) {
                        badge.isTemplate = false
                        self.checkUpdatesMenuItem?.image = self.tintedImage(badge, color: .systemOrange)
                    }
                    alert.informativeText = "A new version is available!\n\nCurrent: \(info.current)\nLatest: \(info.latest)"
                    alert.addButton(withTitle: "Open Downloads")
                    alert.addButton(withTitle: "Later")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn, let url = URL(string: UpdateCheckSupport.defaultReleaseURL) {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    alert.informativeText = "You're up to date!\n\nCurrent version: \(info.current)"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func fetchLatestGitHubVersion() -> String? {
        let apiURL = URL(string: "https://api.github.com/repos/nareshnavinash/GhostEdit/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else { return }
            // Strip leading "v" from tag like "v4.3.0"
            result = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private func loadAppProfiles() -> [AppProfile] {
        AppProfileSupport.loadProfiles(from: configManager.profilesURL)
    }

    // MARK: - Writing Coach

    private func runWritingCoach() {
        guard !isProcessing else {
            playErrorSound()
            setStatus("Already processing")
            return
        }

        let originalSamples = historyOriginalSamples()
        guard !originalSamples.isEmpty else {
            playErrorSound()
            setStatus("No history available for writing coach")
            showNoHistoryForWritingCoachAlert()
            return
        }

        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        let model = config.resolvedModel(for: provider)
        let modelDisplay = model.isEmpty ? "provider default" : model
        let writingInput = WritingCoachSupport.buildInput(from: originalSamples)

        isProcessing = true
        startProcessingIndicator()
        setStatus("Analyzing writing style with \(provider.executableName) (\(modelDisplay))...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let response = try self.shellRunner.correctText(
                    systemPrompt: WritingCoachSupport.systemPrompt,
                    selectedText: writingInput,
                    includeLanguageContract: false
                )
                let insights = WritingCoachSupport.parseInsights(from: response)

                DispatchQueue.main.async {
                    if let insights {
                        self.showWritingCoachInsights(insights, sampleCount: originalSamples.count)
                    } else {
                        self.showWritingCoachFallback(rawResponse: response, sampleCount: originalSamples.count)
                    }

                    let time = self.timeFormatter.string(from: Date())
                    self.setStatus("Writing coach ready at \(time)")
                    self.finishProcessing()
                }
            } catch {
                DispatchQueue.main.async {
                    self.handleWritingCoachError(error)
                    self.finishProcessing()
                }
            }
        }
    }

    private func historyOriginalSamples() -> [String] {
        historyStore.load().compactMap { entry in
            let trimmed = entry.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func showNoHistoryForWritingCoachAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Sharpen My Writing Style"
        alert.informativeText = "No history samples found yet. Run a few corrections, then try again."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showWritingCoachInsights(_ insights: WritingCoachInsights, sampleCount: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Sharpen My Writing Style"
        alert.informativeText = WritingCoachLayoutSupport.reviewedText(sampleCount: sampleCount)
        alert.accessoryView = buildWritingCoachAccessoryView(insights)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func buildWritingCoachAccessoryView(_ insights: WritingCoachInsights) -> NSView {
        let width = WritingCoachLayoutSupport.accessoryWidth
        let contentWidth = WritingCoachLayoutSupport.panelContentWidth()

        let strengthItems = WritingCoachLayoutSupport.cappedItems(insights.positives)
        let improvementItems = WritingCoachLayoutSupport.cappedItems(insights.improvements)

        let strengthPanel = buildCoachPanel(
            title: "Strengths",
            items: strengthItems,
            prefix: WritingCoachLayoutSupport.strengthPrefix,
            accentColor: .systemGreen,
            contentWidth: contentWidth,
            emptyFallback: WritingCoachLayoutSupport.emptyStrengthsFallback
        )

        let improvementPanel = buildCoachPanel(
            title: "Areas to Improve",
            items: improvementItems,
            prefix: WritingCoachLayoutSupport.improvementPrefix,
            accentColor: .systemPink,
            contentWidth: contentWidth,
            emptyFallback: WritingCoachLayoutSupport.emptyImprovementsFallback
        )

        let stack = NSStackView(views: [strengthPanel, improvementPanel])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = WritingCoachLayoutSupport.panelSpacing

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true

        let fittingSize = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: width, height: fittingSize.height)

        return stack
    }

    private func buildCoachPanel(
        title: String,
        items: [String],
        prefix: String,
        accentColor: NSColor,
        contentWidth: CGFloat,
        emptyFallback: String
    ) -> NSView {
        let inset = WritingCoachLayoutSupport.panelInset

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = WritingCoachLayoutSupport.cornerRadius
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = accentColor.withAlphaComponent(WritingCoachLayoutSupport.borderAlpha).cgColor
        panel.layer?.backgroundColor = accentColor.withAlphaComponent(WritingCoachLayoutSupport.backgroundAlpha).cgColor

        let headerField = NSTextField(labelWithString: title)
        headerField.font = NSFont.systemFont(ofSize: WritingCoachLayoutSupport.headerFontSize, weight: .semibold)
        headerField.textColor = accentColor

        let displayItems = items.isEmpty ? [emptyFallback] : items
        let itemFields: [NSTextField] = displayItems.map { text in
            let attributed = NSMutableAttributedString()
            let prefixAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: accentColor,
                .font: NSFont.systemFont(ofSize: WritingCoachLayoutSupport.itemFontSize)
            ]
            let textAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: WritingCoachLayoutSupport.itemFontSize)
            ]
            attributed.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
            attributed.append(NSAttributedString(string: text, attributes: textAttrs))

            let field = NSTextField(wrappingLabelWithString: "")
            field.attributedStringValue = attributed
            field.preferredMaxLayoutWidth = contentWidth
            return field
        }

        var views: [NSView] = [headerField]
        views.append(contentsOf: itemFields)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -inset),
        ])

        return panel
    }

    private func showWritingCoachFallback(rawResponse: String, sampleCount: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Sharpen My Writing Style"
        alert.informativeText = """
        Reviewed \(sampleCount) writing sample(s).

        \(rawResponse)
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handleWritingCoachError(_ error: Error) {
        if case let ShellRunnerError.cliNotFound(provider) = error {
            setStatus("\(provider.executableName) CLI not found; update config.json")
            notifyFailure(body: "Writing Coach Failed. \(provider.displayName) CLI not found.")
            showCLIPathAlert(provider: provider)
            return
        }

        if case let ShellRunnerError.authenticationRequired(provider) = error {
            setStatus("\(provider.executableName) authentication required")
            notifyFailure(body: "Writing Coach Failed. \(provider.displayName) authentication expired. Run `\(provider.authCommand)` in Terminal.")
            showCLIAuthAlert(provider: provider)
            return
        }

        let shouldSuggestModelSwitch: Bool
        if let shellError = error as? ShellRunnerError {
            switch shellError {
            case .processFailed, .timedOut, .emptyResponse:
                shouldSuggestModelSwitch = true
            default:
                shouldSuggestModelSwitch = false
            }
        } else {
            shouldSuggestModelSwitch = false
        }

        let message: String
        if shouldSuggestModelSwitch {
            message = "\(error.localizedDescription)\nTry switching model in Settings if the selected model is busy or unavailable."
        } else {
            message = error.localizedDescription
        }
        setStatus("Writing coach failed")
        notifyFailure(body: "Writing Coach Failed. \(message)")
        showFailureAlert(title: "Writing Coach Failed", message: message)
    }

    private func showFailureAlert(title: String, message: String) {
        let present: () -> Void = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    // MARK: - History

    private func refreshHistoryWindowIfVisible() {
        let entries = historyStore.load().reversed()
        let snapshot = Array(entries)
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.update(entries: snapshot)
        }
    }

    // MARK: - Clipboard

    private func restoreClipboardSnapshot(after delay: TimeInterval) {
        guard let snapshot = clipboardSnapshot else {
            return
        }

        clipboardSnapshot = nil
        pendingClipboardRestore?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClipboardRestore = nil
            self.clipboardManager.restore(snapshot)
        }
        pendingClipboardRestore = workItem

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            workItem.perform()
        }
    }

    private func copyFloaterResult(_ text: String) {
        pendingClipboardRestore?.cancel()
        pendingClipboardRestore = nil
        clipboardSnapshot = nil
        clipboardManager.writePlainText(text)
        setStatus("Correction copied")
    }

    private func cancelInFlightCorrection() {
        correctionGeneration += 1
        restoreClipboardSnapshot(after: 0)
        guard isProcessing else { return }
        finishProcessing()
        setStatus("Idle")
    }

    // MARK: - Developer Mode

    private func syncLaunchAtLoginPreferenceSilently() {
        let config = configManager.loadConfig()
        let launchAtLogin = config.launchAtLogin
        try? historyStore.trim(limit: config.historyLimit)
        try? LaunchAtLoginManager.setEnabled(launchAtLogin)
    }

    private func recordHistoryEntry(
        originalText: String,
        generatedText: String,
        provider: CLIProvider,
        model: String,
        startedAt: Date,
        succeeded: Bool
    ) {
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = normalizedModel.isEmpty ? AppConfig.defaultModel(for: provider) : normalizedModel
        let historyLimit = configManager.loadConfig().historyLimit

        let entry = CorrectionHistoryEntry(
            id: UUID(),
            timestamp: Date(),
            originalText: originalText,
            generatedText: generatedText,
            provider: provider.displayName,
            model: modelName,
            durationMilliseconds: max(0, elapsed),
            succeeded: succeeded
        )

        try? historyStore.append(entry, limit: historyLimit)
        refreshHistoryWindowIfVisible()
    }

    private func showFatalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: DeveloperModeLogger {
    func log(_ entry: DeveloperModeLogEntry) {
        let append: () -> Void = { [weak self] in
            self?.developerConsoleController?.appendEntry(entry)
        }
        if Thread.isMainThread {
            append()
        } else {
            DispatchQueue.main.async(execute: append)
        }
    }
}
