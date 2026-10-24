import AppKit

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    struct ModelOption {
        let title: String
        let value: String?
    }

    private enum Tab: String, CaseIterable {
        case general
        case hotkey
        case behavior
        case advanced

        var label: String {
            switch self {
            case .general: return "General"
            case .hotkey: return "Hotkey"
            case .behavior: return "Behavior"
            case .advanced: return "Advanced"
            }
        }

        var sfSymbolName: String {
            switch self {
            case .general: return "globe"
            case .hotkey: return "keyboard"
            case .behavior: return "slider.horizontal.3"
            case .advanced: return "wrench.and.screwdriver"
            }
        }

        var toolbarItemID: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier(rawValue)
        }
    }

    private let configManager: ConfigManager
    private let onConfigSaved: (AppConfig) -> Void

    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customModelField = NSTextField(string: "")
    private let customModelContainer = NSStackView()
    private let ollamaURLField = NSTextField(string: "")
    private let magpieURLField = NSTextField(string: "")
    private let serverURLContainer = NSStackView()
    private let refreshModelsButton = NSButton(title: "Refresh Models", target: nil, action: nil)
    private var cachedModels: [String] = []
    private let hotkeyKeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commandModifierCheckbox = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let optionModifierCheckbox = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let controlModifierCheckbox = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let shiftModifierCheckbox = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let hotkeyPreviewLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Start GhostEdit automatically when you log in",
        target: nil,
        action: nil
    )
    private let launchAtLoginSwitch = NSSwitch()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let historyLimitField = NSTextField(string: "")
    private let timeoutField = NSTextField(string: "")
    private let soundFeedbackCheckbox = NSButton(
        checkboxWithTitle: "Play sound feedback on errors and corrections",
        target: nil,
        action: nil
    )
    private let notifyOnSuccessCheckbox = NSButton(
        checkboxWithTitle: "Show notification on successful correction",
        target: nil,
        action: nil
    )
    private let liveFeedbackCheckbox = NSButton(
        checkboxWithTitle: "Enable live spell-check feedback while typing",
        target: nil,
        action: nil
    )
    private let tonePresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let developerModeCheckbox = NSButton(
        checkboxWithTitle: "Enable Developer Mode (show behind-the-scenes log)",
        target: nil,
        action: nil
    )
    private let floaterTransparencySlider = NSSlider()
    private let floaterTransparencyValue = NSTextField(labelWithString: "58%")
    private let floaterTransparencySwatch = FloaterTransparencySwatch()
    private let hintLabel = NSTextField(labelWithString: "")
    private let hotkeyBadgeView = NSView()
    private let hotkeyBadgeLabel = NSTextField(labelWithString: "")

    private var tabViews: [Tab: NSView] = [:]
    private var currentTab: Tab = .general

    private let providerOptions = CLIProvider.allCases
    private let hotkeyKeyOptions = HotkeySupport.keyOptions
    private var modelOptions: [ModelOption] = []

    init(configManager: ConfigManager, onConfigSaved: @escaping (AppConfig) -> Void) {
        self.configManager = configManager
        self.onConfigSaved = onConfigSaved

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayoutSupport.windowWidth,
                height: SettingsLayoutSupport.minWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GhostEditSettings")
        if !window.setFrameUsingName("GhostEditSettings") { window.center() }

        super.init(window: window)
        setupToolbar()
        buildAllTabs()
        loadCurrentValues()

        fitSettingsWindowHeight()

        switchToTab(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Tab.general.toolbarItemID
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemID)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemID)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemID)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.label
        item.target = self
        item.action = #selector(toolbarTabClicked(_:))
        if let img = NSImage(systemSymbolName: tab.sfSymbolName, accessibilityDescription: tab.label) {
            item.image = img
        }
        return item
    }

    @objc private func toolbarTabClicked(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue) else { return }
        switchToTab(tab)
    }

    private func switchToTab(_ tab: Tab) {
        guard let window, let contentView = window.contentView else { return }
        let previousTab = currentTab
        currentTab = tab
        window.toolbar?.selectedItemIdentifier = tab.toolbarItemID
        window.title = tab.label

        guard let newView = tabViews[tab] else { return }

        newView.translatesAutoresizingMaskIntoConstraints = false
        newView.alphaValue = 0
        contentView.addSubview(newView)

        NSLayoutConstraint.activate([
            newView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            newView.topAnchor.constraint(equalTo: contentView.topAnchor),
            newView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            newView.animator().alphaValue = 1
            if previousTab != tab, let oldView = self.tabViews[previousTab] {
                oldView.animator().alphaValue = 0
            }
        }, completionHandler: {
            for (t, view) in self.tabViews where t != tab {
                view.removeFromSuperview()
                view.alphaValue = 1
            }
        })
    }

    // MARK: - Build Tabs

    private func buildAllTabs() {
        tabViews[.general] = buildGeneralTab()
        tabViews[.hotkey] = buildHotkeyTab()
        tabViews[.behavior] = buildBehaviorTab()
        tabViews[.advanced] = buildAdvancedTab()
    }

    private func buildCorrectionModesSection() -> NSView {
        let note = makeDescription("The correction hotkey shows a nearby diff and a Copy button. It does not replace the selected text.")
        note.maximumNumberOfLines = 3
        return makeSection(title: "Correction", views: [note])
    }

    private func buildGeneralTab() -> NSView {
        providerPopup.removeAllItems()
        providerOptions.forEach { providerPopup.addItem(withTitle: $0.displayName) }
        providerPopup.target = self
        providerPopup.action = #selector(providerPopupChanged)
        modelPopup.target = self
        modelPopup.action = #selector(modelPopupChanged)

        customModelField.placeholderString = "Enter custom model name"
        customModelContainer.orientation = .horizontal
        customModelContainer.spacing = 8
        customModelContainer.alignment = .firstBaseline
        customModelContainer.addArrangedSubview(makeFieldLabel("Custom"))
        customModelContainer.addArrangedSubview(customModelField)

        configureServerURLField(ollamaURLField)
        configureServerURLField(magpieURLField)
        ollamaURLField.placeholderString = AppConfig.default.ollamaBaseURL
        magpieURLField.placeholderString = AppConfig.default.magpieBaseURL
        ollamaURLField.toolTip = "Ollama server URL. Localhost keeps corrections on this Mac."
        magpieURLField.toolTip = "Magpie gateway URL. The local gateway must be running."
        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(refreshModelsClicked)
        refreshModelsButton.lineBreakMode = .byClipping
        refreshModelsButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshModelsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        serverURLContainer.orientation = .vertical
        serverURLContainer.alignment = .leading
        serverURLContainer.spacing = 8
        serverURLContainer.addArrangedSubview(makeRow(label: makeFieldLabel("Server URL"), field: ollamaURLField))
        serverURLContainer.addArrangedSubview(makeRow(label: makeFieldLabel("Server URL"), field: magpieURLField))

        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.alignment = .firstBaseline
        modelRow.spacing = 8
        modelRow.addArrangedSubview(makeFieldLabel("Model"))
        modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelRow.addArrangedSubview(modelPopup)
        modelRow.addArrangedSubview(refreshModelsButton)

        languagePopup.removeAllItems()
        AppConfig.supportedLanguages.forEach { languagePopup.addItem(withTitle: $0.displayName) }
        tonePresetPopup.removeAllItems()
        AppConfig.supportedPresets.forEach { tonePresetPopup.addItem(withTitle: $0.capitalized) }

        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.maximumNumberOfLines = 3
        hintLabel.lineBreakMode = .byWordWrapping

        let providerDesc = makeDescription("The AI provider used for grammar corrections")
        let modelDesc = makeDescription(modelDescriptionText())
        modelDesc.identifier = NSUserInterfaceItemIdentifier("modelDescriptionLabel")

        let languageDesc = makeDescription("Auto-detect keeps the input language. A chosen language translates into it when needed.")
        let toneDesc = makeDescription("Adjusts formality and style of corrections")

        let stack = makeTabStack(sections: [
            buildCorrectionModesSection(),
            makeSection(title: "Provider & Model", views: [
                makeRow(label: makeFieldLabel("Provider"), field: providerPopup),
                providerDesc,
                serverURLContainer,
                modelRow,
                modelDesc,
                customModelContainer,
                hintLabel,
            ]),
            makeSection(title: "Language & Tone", views: [
                makeRow(label: makeFieldLabel("Language"), field: languagePopup),
                languageDesc,
                makeRow(label: makeFieldLabel("Tone"), field: tonePresetPopup),
                toneDesc,
            ]),
            makeButtonRow(),
        ])
        return stack
    }

    private func modelDescriptionText() -> String {
        guard let selected = modelPopup.selectedItem?.title else { return "" }
        let descriptions: [String: String] = [
            "Sonnet": "Balanced speed and quality",
            "Opus": "Highest quality, slower",
            "Haiku": "Fastest, lightweight corrections",
            "GPT-4o": "OpenAI flagship model",
            "GPT-4o mini": "Fast and cost-effective",
            "o3-mini": "OpenAI reasoning model",
            "Gemini 2.0 Flash": "Fast multimodal model",
            "Gemini 2.5 Pro": "Most capable Gemini model",
            "Custom...": "Specify any model identifier",
        ]
        return descriptions[selected] ?? ""
    }

    private func refreshModelDescription() {
        guard let tabView = tabViews[.general] else { return }
        func findLabel(in view: NSView) -> NSTextField? {
            if let label = view as? NSTextField,
               label.identifier?.rawValue == "modelDescriptionLabel" {
                return label
            }
            for sub in view.subviews {
                if let found = findLabel(in: sub) { return found }
            }
            return nil
        }
        if let label = findLabel(in: tabView) {
            label.stringValue = modelDescriptionText()
        }
    }

    private func buildHotkeyTab() -> NSView {
        // Correction hotkey controls
        hotkeyKeyPopup.removeAllItems()
        hotkeyKeyOptions.forEach { hotkeyKeyPopup.addItem(withTitle: $0.title) }
        hotkeyKeyPopup.target = self
        hotkeyKeyPopup.action = #selector(hotkeyInputChanged)

        commandModifierCheckbox.target = self
        commandModifierCheckbox.action = #selector(hotkeyInputChanged)
        optionModifierCheckbox.target = self
        optionModifierCheckbox.action = #selector(hotkeyInputChanged)
        controlModifierCheckbox.target = self
        controlModifierCheckbox.action = #selector(hotkeyInputChanged)
        shiftModifierCheckbox.target = self
        shiftModifierCheckbox.action = #selector(hotkeyInputChanged)

        let modStack = NSStackView()
        modStack.orientation = .horizontal
        modStack.spacing = 6
        modStack.addArrangedSubview(commandModifierCheckbox)
        modStack.addArrangedSubview(optionModifierCheckbox)
        modStack.addArrangedSubview(controlModifierCheckbox)
        modStack.addArrangedSubview(shiftModifierCheckbox)

        hotkeyPreviewLabel.textColor = .secondaryLabelColor
        hotkeyPreviewLabel.font = .systemFont(ofSize: 12, weight: .medium)

        hotkeyBadgeView.wantsLayer = true
        hotkeyBadgeView.layer?.cornerRadius = 6
        hotkeyBadgeView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        hotkeyBadgeView.layer?.borderWidth = 1
        hotkeyBadgeView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        hotkeyBadgeView.translatesAutoresizingMaskIntoConstraints = false

        hotkeyBadgeLabel.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        hotkeyBadgeLabel.textColor = .controlAccentColor
        hotkeyBadgeLabel.alignment = .center
        hotkeyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        hotkeyBadgeView.addSubview(hotkeyBadgeLabel)

        NSLayoutConstraint.activate([
            hotkeyBadgeLabel.topAnchor.constraint(equalTo: hotkeyBadgeView.topAnchor, constant: 8),
            hotkeyBadgeLabel.bottomAnchor.constraint(equalTo: hotkeyBadgeView.bottomAnchor, constant: -8),
            hotkeyBadgeLabel.leadingAnchor.constraint(equalTo: hotkeyBadgeView.leadingAnchor, constant: 16),
            hotkeyBadgeLabel.trailingAnchor.constraint(equalTo: hotkeyBadgeView.trailingAnchor, constant: -16),
        ])

        let badgeRow = NSStackView()
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 8
        badgeRow.alignment = .centerY
        badgeRow.addArrangedSubview(makeFieldLabel("Current"))
        badgeRow.addArrangedSubview(hotkeyBadgeView)

        let stack = makeTabStack(sections: [
            makeSection(title: "Correction Hotkey", views: [
                badgeRow,
                makeRow(label: makeFieldLabel("Key"), field: hotkeyKeyPopup),
                makeRow(label: makeFieldLabel("Modifiers"), field: modStack),
                hotkeyPreviewLabel,
            ]),
            makeButtonRow(),
        ])
        return stack
    }

    private func buildBehaviorTab() -> NSView {
        soundFeedbackCheckbox.setContentHuggingPriority(.required, for: .vertical)
        notifyOnSuccessCheckbox.setContentHuggingPriority(.required, for: .vertical)
        liveFeedbackCheckbox.setContentHuggingPriority(.required, for: .vertical)
        launchAtLoginCheckbox.setContentHuggingPriority(.required, for: .vertical)

        let stack = makeTabStack(sections: [
            makeSection(title: "Correction box", views: [
                makeTransparencyRow(),
                makeDescription("How see-through the correction box is. The text stays solid."),
            ]),
            makeSection(title: "Live Feedback", views: [
                makeCheckboxWithDescription(
                    checkbox: liveFeedbackCheckbox,
                    description: "Monitors the active text field and highlights spelling issues in real time using macOS spell checker"
                ),
            ]),
            makeSection(title: "Feedback", views: [
                makeCheckboxWithDescription(
                    checkbox: soundFeedbackCheckbox,
                    description: "Plays a system sound when a correction finishes"
                ),
                makeCheckboxWithDescription(
                    checkbox: notifyOnSuccessCheckbox,
                    description: "Shows a macOS notification banner on success"
                ),
            ]),
            makeSection(title: "System", views: [
                makeSwitchRow(
                    label: "Launch at Login",
                    toggle: launchAtLoginSwitch,
                    description: "Start GhostEdit automatically when you log in"
                ),
            ]),
            makeButtonRow(),
        ])
        return stack
    }

    private func buildAdvancedTab() -> NSView {
        historyLimitField.placeholderString = "50"
        historyLimitField.alignment = .left
        timeoutField.placeholderString = "60"
        timeoutField.alignment = .left
        developerModeCheckbox.setContentHuggingPriority(.required, for: .vertical)

        let historyDesc = makeDescription("Maximum number of corrections to keep in history")
        let timeoutDesc = makeDescription("Seconds to wait before cancelling a correction request")

        let stack = makeTabStack(sections: [
            makeSection(title: "Limits", views: [
                makeRow(label: makeFieldLabel("History limit"), field: historyLimitField),
                historyDesc,
                makeRow(label: makeFieldLabel("Timeout (s)"), field: timeoutField),
                timeoutDesc,
            ]),
            makeSection(title: "Debug", views: [
                makeCheckboxWithDescription(
                    checkbox: developerModeCheckbox,
                    description: "Shows a console log with CLI commands and raw responses"
                ),
            ]),
            makeButtonRow(),
        ])
        return stack
    }

    // MARK: - Layout Helpers

    private func makeTabStack(sections: [NSView]) -> NSView {
        // Separate the button row (last item) from content sections
        let contentSections: [NSView]
        let buttonRow: NSView?
        if let last = sections.last, last is NSStackView,
           (last as? NSStackView)?.arrangedSubviews.contains(where: { ($0 as? NSButton)?.title == "Save" }) == true {
            contentSections = Array(sections.dropLast())
            buttonRow = last
        } else {
            contentSections = sections
            buttonRow = nil
        }

        let contentStack = NSStackView(views: contentSections)
        contentStack.orientation = .vertical
        contentStack.spacing = SettingsLayoutSupport.sectionSpacing
        contentStack.alignment = .leading
        contentStack.edgeInsets = NSEdgeInsets(
            top: SettingsLayoutSupport.verticalInset,
            left: 32,
            bottom: SettingsLayoutSupport.verticalInset,
            right: 32
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for section in contentSections {
            section.translatesAutoresizingMaskIntoConstraints = false
            section.widthAnchor.constraint(
                equalToConstant: SettingsLayoutSupport.windowWidth - 64
            ).isActive = true
        }

        guard let buttonRow = buttonRow else { return contentStack }

        // Container: content pinned to top, button row pinned to bottom
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentStack)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsLayoutSupport.verticalInset),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: SettingsLayoutSupport.sectionSpacing),
        ])

        return container
    }

    private func makeSection(title: String, views: [NSView]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = SettingsLayoutSupport.groupCornerRadius
        card.fillColor = .controlBackgroundColor
        card.borderColor = .separatorColor
        card.borderWidth = 0.5
        card.contentViewMargins = .zero
        card.titlePosition = .noTitle
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = SettingsLayoutSupport.rowSpacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let cardContent = card.contentView {
            cardContent.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: cardContent.topAnchor, constant: 14),
                stack.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -16),
                stack.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor, constant: -14),
            ])
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeButtonRow() -> NSView {
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(buttonSpacer)
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.addArrangedSubview(saveButton)
        return buttonRow
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: SettingsLayoutSupport.labelWidth).isActive = true
        return label
    }

    private func makeRow(label: NSTextField, field: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return row
    }

    private func makeDescription(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeSwitchRow(label: String, toggle: NSSwitch, description: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        row.addArrangedSubview(labelField)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(toggle)

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 2
        container.alignment = .leading
        container.addArrangedSubview(row)

        let desc = makeDescription(description)
        container.addArrangedSubview(desc)

        return container
    }

    private func makeCheckboxWithDescription(checkbox: NSButton, description: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.addArrangedSubview(checkbox)
        let desc = makeDescription(description)
        desc.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(desc)
        // Indent description to align with checkbox label
        desc.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        return stack
    }

    // MARK: - Load / Save

    private func loadCurrentValues() {
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        let providerIndex = providerOptions.firstIndex(of: provider) ?? 0
        providerPopup.selectItem(at: providerIndex)
        ollamaURLField.stringValue = config.ollamaBaseURL
        magpieURLField.stringValue = config.magpieBaseURL
        launchAtLoginCheckbox.state = config.launchAtLogin ? .on : .off
        launchAtLoginSwitch.state = config.launchAtLogin ? .on : .off
        soundFeedbackCheckbox.state = config.soundFeedbackEnabled ? .on : .off
        notifyOnSuccessCheckbox.state = config.notifyOnSuccess ? .on : .off
        liveFeedbackCheckbox.state = config.liveFeedbackEnabled ? .on : .off
        if let toneIndex = AppConfig.supportedPresets.firstIndex(of: config.tonePreset) {
            tonePresetPopup.selectItem(at: toneIndex)
        } else {
            tonePresetPopup.selectItem(at: 0)
        }
        developerModeCheckbox.state = config.developerMode ? .on : .off
        if let langIndex = AppConfig.supportedLanguages.firstIndex(where: { $0.code == config.resolvedLanguage }) {
            languagePopup.selectItem(at: langIndex)
        } else {
            languagePopup.selectItem(at: 0) // auto
        }
        historyLimitField.stringValue = "\(config.historyLimit)"
        applyFloaterTransparency(config.floaterOpacity)
        timeoutField.stringValue = "\(config.timeoutSeconds)"
        loadHotkeyValues(from: config)

        let rawModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = rawModel.isEmpty ? AppConfig.defaultModel(for: provider) : rawModel
        applyCachedModels(for: provider, selectedModel: selectedModel)
    }

    @objc private func providerPopupChanged() {
        let provider = selectedProvider()
        applyCachedModels(for: provider, selectedModel: AppConfig.defaultModel(for: provider))
    }

    @objc private func modelPopupChanged() {
        refreshCustomFieldVisibility()
        refreshModelDescription()
    }

    @objc private func hotkeyInputChanged() {
        updateHotkeyPreview()
    }

    private func reloadModelOptions(for provider: CLIProvider, selectedModel: String) {
        modelOptions = modelOptionsForProvider(provider)
        modelPopup.removeAllItems()
        modelOptions.forEach { modelPopup.addItem(withTitle: $0.title) }

        if let index = modelOptions.firstIndex(where: { $0.value == selectedModel }) {
            modelPopup.selectItem(at: index)
            customModelField.stringValue = ""
        } else {
            modelPopup.selectItem(at: modelOptions.count - 1)
            customModelField.stringValue = selectedModel
        }

        refreshCustomFieldVisibility()
        updateHint(for: provider)
        refreshModelDescription()
    }

    private func catalogURL() -> URL {
        configManager.baseDirectoryURL.appendingPathComponent("model-cache.json")
    }

    private func currentEndpoint(for provider: CLIProvider) -> String {
        ModelCatalogSupport.endpoint(
            provider: provider.rawValue,
            ollamaBaseURL: ollamaURLField.stringValue,
            magpieBaseURL: magpieURLField.stringValue
        )
    }

    private func applyCachedModels(for provider: CLIProvider, selectedModel: String) {
        let key = ModelCatalogSupport.cacheKey(provider: provider.rawValue, endpoint: currentEndpoint(for: provider))
        cachedModels = ModelCatalogSupport.models(in: ModelCatalogSupport.load(from: catalogURL()), key: key)
        reloadModelOptions(for: provider, selectedModel: selectedModel)
    }

    private func modelOptionsForProvider(_ provider: CLIProvider) -> [ModelOption] {
        let predefined = cachedModels.map { modelName in
            ModelOption(title: modelName, value: modelName)
        }
        return predefined + [ModelOption(title: "Custom", value: nil)]
    }

    private func updateHint(for provider: CLIProvider) {
        let showOllama = provider == .ollama
        let showMagpie = provider == .magpie
        ollamaURLField.superview?.isHidden = !showOllama
        magpieURLField.superview?.isHidden = !showMagpie
        serverURLContainer.isHidden = !(showOllama || showMagpie)
        if provider.usesHTTP {
            hintLabel.stringValue = "Refresh Models to list what \(provider.displayName) can use. Use Custom for a name that is not listed."
            return
        }
        let fallback = provider.defaultModel.isEmpty ? "the CLI default" : provider.defaultModel
        hintLabel.stringValue = "Refresh Models to list \(provider.displayName) models. A blank model uses \(fallback)."
    }

    @objc private func refreshModelsClicked() {
        let provider = selectedProvider()
        let endpoint = currentEndpoint(for: provider)
        let executablePath = configManager.loadConfig().resolvedPath(for: provider)
        refreshModelsButton.isEnabled = false
        hintLabel.stringValue = "Fetching \(provider.displayName) models…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ModelListing.fetch(provider: provider, endpoint: endpoint, executablePath: executablePath)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshModelsButton.isEnabled = true
                guard self.selectedProvider() == provider,
                      self.currentEndpoint(for: provider) == endpoint else { return }
                switch result {
                case let .success(models):
                    let key = ModelCatalogSupport.cacheKey(provider: provider.rawValue, endpoint: endpoint)
                    var catalog = ModelCatalogSupport.load(from: self.catalogURL())
                    catalog = ModelCatalogSupport.updating(catalog, key: key, models: models)
                    try? ModelCatalogSupport.save(catalog, to: self.catalogURL())
                    let selectedModel = self.selectedModel()
                    self.cachedModels = models
                    self.reloadModelOptions(for: provider, selectedModel: selectedModel)
                    self.hintLabel.stringValue = models.isEmpty
                        ? "No models returned. Check \(provider.displayName), then click Refresh Models."
                        : "\(models.count) models. Select one and Save Changes."
                case let .failure(error):
                    self.hintLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func loadHotkeyValues(from config: AppConfig) {
        if let index = hotkeyKeyOptions.firstIndex(where: { $0.keyCode == config.hotkeyKeyCode }) {
            hotkeyKeyPopup.selectItem(at: index)
        } else if let defaultIndex = hotkeyKeyOptions.firstIndex(where: { $0.keyCode == HotkeySupport.defaultKeyCode }) {
            hotkeyKeyPopup.selectItem(at: defaultIndex)
        } else {
            hotkeyKeyPopup.selectItem(at: 0)
        }

        let split = HotkeySupport.splitModifiers(config.hotkeyModifiers)
        commandModifierCheckbox.state = split.command ? .on : .off
        optionModifierCheckbox.state = split.option ? .on : .off
        controlModifierCheckbox.state = split.control ? .on : .off
        shiftModifierCheckbox.state = split.shift ? .on : .off

        updateHotkeyPreview()
    }

    private func selectedHotkeyKeyCode() -> UInt32? {
        let index = hotkeyKeyPopup.indexOfSelectedItem
        guard hotkeyKeyOptions.indices.contains(index) else {
            return nil
        }
        return hotkeyKeyOptions[index].keyCode
    }

    private func selectedHotkeyModifiers() -> UInt32 {
        HotkeySupport.makeModifiers(
            command: commandModifierCheckbox.state == .on,
            option: optionModifierCheckbox.state == .on,
            control: controlModifierCheckbox.state == .on,
            shift: shiftModifierCheckbox.state == .on
        )
    }

    private func updateHotkeyPreview() {
        guard let keyCode = selectedHotkeyKeyCode() else {
            hotkeyPreviewLabel.stringValue = "Correction hotkey: unavailable"
            hotkeyBadgeLabel.stringValue = "-"
            return
        }

        let modifiers = selectedHotkeyModifiers()
        let display = HotkeySupport.displayString(keyCode: keyCode, modifiers: modifiers)
        hotkeyPreviewLabel.stringValue = "Correction hotkey: \(display)"
        hotkeyBadgeLabel.stringValue = display
    }

    private func refreshCustomFieldVisibility() {
        let isCustom = selectedOptionValue() == nil
        customModelContainer.isHidden = !isCustom
        if isCustom {
            customModelField.becomeFirstResponder()
        }
    }

    private func selectedOptionValue() -> String? {
        let index = modelPopup.indexOfSelectedItem
        guard modelOptions.indices.contains(index) else {
            return modelOptions.first?.value
        }

        return modelOptions[index].value
    }

    private func selectedProvider() -> CLIProvider {
        let index = providerPopup.indexOfSelectedItem
        guard providerOptions.indices.contains(index) else {
            return .default
        }
        return providerOptions[index]
    }

    private func selectedModel() -> String {
        if let fixedValue = selectedOptionValue() {
            return fixedValue
        }

        return customModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func saveClicked() {
        let provider = selectedProvider()
        let model = selectedModel()
        let historyLimitText = historyLimitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutText = timeoutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hotkeyKeyCode = selectedHotkeyKeyCode() else {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hotkey key is required"
            alert.informativeText = "Choose a hotkey key before saving."
            alert.runModal()
            return
        }
        let hotkeyModifiers = selectedHotkeyModifiers()
        if selectedOptionValue() == nil, model.isEmpty {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Model is required"
            alert.informativeText = "Choose a model or enter a custom model name."
            alert.runModal()
            return
        }
        if hotkeyModifiers == 0 {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hotkey modifiers are required"
            alert.informativeText = "Select at least one modifier key (Command, Option, Control, or Shift)."
            alert.runModal()
            return
        }
        guard let historyLimit = Int(historyLimitText), historyLimit > 0 else {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "History size is invalid"
            alert.informativeText = "Enter a whole number greater than 0 for History N."
            alert.runModal()
            return
        }
        guard let timeoutSeconds = Int(timeoutText), timeoutSeconds >= 5 else {
            NSSound.beep()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Timeout is invalid"
            alert.informativeText = "Enter a whole number of at least 5 for Timeout (seconds)."
            alert.runModal()
            return
        }

        let ollamaBaseURL = ollamaURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let magpieBaseURL = magpieURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.usesHTTP {
            let serverURL = provider == .magpie ? magpieBaseURL : ollamaBaseURL
            guard let url = URL(string: serverURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(provider.displayName) server URL is invalid"
                alert.informativeText = "Enter an HTTP or HTTPS server URL without a query or fragment."
                alert.runModal()
                return
            }
        }

        var config = configManager.loadConfig()
        config.provider = provider.rawValue
        config.model = model
        config.ollamaBaseURL = ollamaBaseURL
        config.magpieBaseURL = magpieBaseURL
        config.hotkeyKeyCode = hotkeyKeyCode
        config.hotkeyModifiers = hotkeyModifiers
        config.launchAtLogin = (launchAtLoginSwitch.state == .on)
        config.soundFeedbackEnabled = (soundFeedbackCheckbox.state == .on)
        config.notifyOnSuccess = (notifyOnSuccessCheckbox.state == .on)
        config.liveFeedbackEnabled = (liveFeedbackCheckbox.state == .on)
        let toneIndex = tonePresetPopup.indexOfSelectedItem
        config.tonePreset = AppConfig.supportedPresets.indices.contains(toneIndex)
            ? AppConfig.supportedPresets[toneIndex]
            : "default"
        config.developerMode = (developerModeCheckbox.state == .on)
        let langIndex = languagePopup.indexOfSelectedItem
        config.language = AppConfig.supportedLanguages.indices.contains(langIndex)
            ? AppConfig.supportedLanguages[langIndex].code
            : "auto"
        config.historyLimit = historyLimit
        config.timeoutSeconds = timeoutSeconds
        config.floaterOpacity = AppConfig.clampedFloaterOpacity(1 - floaterTransparencySlider.doubleValue / 100)

        do {
            try configManager.saveConfig(config)
            do {
                try LaunchAtLoginManager.setEnabled(config.launchAtLogin)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not update Launch at Login"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            onConfigSaved(config)
            showSaveConfirmation()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to Save Settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func closeClicked() {
        close()
    }

    private func showSaveConfirmation() {
        guard let window else {
            close()
            return
        }

        // Show a brief "Settings Saved" overlay before closing
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        overlay.layer?.cornerRadius = 8
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let checkmark = NSTextField(labelWithString: "\u{2713} Settings Saved")
        checkmark.font = .systemFont(ofSize: 14, weight: .semibold)
        checkmark.textColor = .white
        checkmark.alignment = .center
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(checkmark)

        guard let contentView = window.contentView else {
            close()
            return
        }
        contentView.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkmark.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
            checkmark.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -12),
            checkmark.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            checkmark.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
        ])

        overlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            overlay.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                overlay.removeFromSuperview()
                self?.close()
            })
        }
    }

    private func configureServerURLField(_ field: NSTextField) {
        let fieldWidth = SettingsLayoutSupport.windowWidth - 64 - 32 - SettingsLayoutSupport.labelWidth - 8
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
    }

    private func fitSettingsWindowHeight() {
        guard let window else { return }
        tabViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let maxTabHeight = tabViews.values.map(\.fittingSize.height).max() ?? SettingsLayoutSupport.minWindowHeight
        let needed = max(ceil(maxTabHeight), SettingsLayoutSupport.minWindowHeight)
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? needed
        let height = min(needed, max(SettingsLayoutSupport.minWindowHeight, screenHeight - 40))
        var frame = window.frame
        guard abs(frame.height - height) >= 1 else { return }
        frame.origin.y -= height - frame.height
        frame.size.height = height
        window.setFrame(frame, display: window.isVisible)
    }

    private func makeTransparencyRow() -> NSView {
        floaterTransparencySlider.minValue = 0
        floaterTransparencySlider.maxValue = (1 - AppConfig.minimumFloaterOpacity) * 100
        floaterTransparencySlider.isContinuous = true
        floaterTransparencySlider.target = self
        floaterTransparencySlider.action = #selector(floaterTransparencyChanged)
        floaterTransparencySlider.toolTip = "Drag right to make the correction box more transparent."
        floaterTransparencySlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        floaterTransparencyValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        floaterTransparencyValue.alignment = .right
        floaterTransparencyValue.setContentHuggingPriority(.required, for: .horizontal)
        floaterTransparencyValue.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let row = NSStackView(views: [
            makeFieldLabel("Transparency"),
            floaterTransparencySlider,
            floaterTransparencyValue,
            floaterTransparencySwatch,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func applyFloaterTransparency(_ opacity: Double) {
        let clamped = AppConfig.clampedFloaterOpacity(opacity)
        floaterTransparencySlider.doubleValue = (1 - clamped) * 100
        refreshFloaterTransparencyPreview()
    }

    @objc private func floaterTransparencyChanged() {
        refreshFloaterTransparencyPreview()
    }

    private func refreshFloaterTransparencyPreview() {
        let percent = Int(floaterTransparencySlider.doubleValue.rounded())
        floaterTransparencyValue.stringValue = "\(percent)%"
        floaterTransparencySwatch.opacity = CGFloat(
            AppConfig.clampedFloaterOpacity(1 - floaterTransparencySlider.doubleValue / 100)
        )
    }
}

private final class FloaterTransparencySwatch: NSView {
    var opacity: CGFloat = CGFloat(AppConfig.defaultFloaterOpacity) {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloaterTransparencySwatch does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        let light = NSColor.controlBackgroundColor
        let dark = NSColor.separatorColor
        let square: CGFloat = 4
        var y: CGFloat = 0
        var row = 0
        while y < bounds.height {
            var x: CGFloat = 0
            var column = 0
            while x < bounds.width {
                ((row + column).isMultiple(of: 2) ? light : dark).setFill()
                NSRect(x: x, y: y, width: square, height: square).fill()
                x += square
                column += 1
            }
            y += square
            row += 1
        }

        let plate = bounds.insetBy(dx: 6, dy: 4)
        let path = NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5)
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let sample = "Aa" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = sample.size(withAttributes: attributes)
        sample.draw(
            at: NSPoint(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

