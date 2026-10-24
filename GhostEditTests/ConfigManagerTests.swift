import XCTest
@testable import GhostEditCore

final class ConfigManagerTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for root in tempRoots {
            try? fileManager.removeItem(at: root)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testBootstrapCreatesDefaultFiles() throws {
        let (manager, _) = makeManager()

        try manager.bootstrapIfNeeded()

        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.baseDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.promptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.historyURL.path))

        let prompt = try String(contentsOf: manager.promptURL, encoding: .utf8)
        XCTAssertEqual(prompt, manager.defaultPrompt)

        let config = manager.loadConfig()
        XCTAssertEqual(config.provider, CLIProvider.default.rawValue)
        XCTAssertEqual(config.model, AppConfig.default.model)
        XCTAssertEqual(config.timeoutSeconds, AppConfig.default.timeoutSeconds)
        XCTAssertEqual(config.hotkeyKeyCode, AppConfig.default.hotkeyKeyCode)
        XCTAssertEqual(config.hotkeyModifiers, AppConfig.default.hotkeyModifiers)
        XCTAssertEqual(config.claudePath, AppConfig.default.claudePath)
        XCTAssertEqual(config.codexPath, AppConfig.default.codexPath)
        XCTAssertEqual(config.geminiPath, AppConfig.default.geminiPath)
        XCTAssertEqual(config.launchAtLogin, AppConfig.default.launchAtLogin)
        XCTAssertEqual(config.historyLimit, AppConfig.default.historyLimit)
        XCTAssertEqual(config.developerMode, AppConfig.default.developerMode)
    }

    func testBootstrapMigratesLegacyDirectory() throws {
        let (manager, homeURL) = makeManager()
        let fileManager = FileManager.default

        let legacyDirectory = homeURL.appendingPathComponent(".grammarfixer", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try "legacy prompt".write(
            to: legacyDirectory.appendingPathComponent("prompt.txt"),
            atomically: true,
            encoding: .utf8
        )

        let legacyConfig = AppConfig(
            claudePath: "/tmp/claude",
            codexPath: "/tmp/codex",
            geminiPath: "/tmp/gemini",
            provider: "gemini",
            model: "gemini-2.5-flash",
            timeoutSeconds: 42,
            hotkeyKeyCode: 11,
            hotkeyModifiers: 256,
            launchAtLogin: true,
            historyLimit: 15
        )
        let legacyData = try JSONEncoder().encode(legacyConfig)
        try legacyData.write(to: legacyDirectory.appendingPathComponent("config.json"), options: .atomic)

        try manager.bootstrapIfNeeded()

        XCTAssertFalse(fileManager.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: manager.baseDirectoryURL.path))

        let migratedPrompt = try String(contentsOf: manager.promptURL, encoding: .utf8)
        XCTAssertEqual(migratedPrompt, "legacy prompt")

        let migratedConfig = manager.loadConfig()
        XCTAssertEqual(migratedConfig.claudePath, legacyConfig.claudePath)
        XCTAssertEqual(migratedConfig.codexPath, legacyConfig.codexPath)
        XCTAssertEqual(migratedConfig.geminiPath, legacyConfig.geminiPath)
        XCTAssertEqual(migratedConfig.provider, legacyConfig.provider)
        XCTAssertEqual(migratedConfig.model, legacyConfig.model)
        XCTAssertEqual(migratedConfig.timeoutSeconds, legacyConfig.timeoutSeconds)
        XCTAssertEqual(migratedConfig.hotkeyKeyCode, legacyConfig.hotkeyKeyCode)
        XCTAssertEqual(migratedConfig.hotkeyModifiers, legacyConfig.hotkeyModifiers)
        XCTAssertEqual(migratedConfig.launchAtLogin, legacyConfig.launchAtLogin)
        XCTAssertEqual(migratedConfig.historyLimit, legacyConfig.historyLimit)
        XCTAssertEqual(migratedConfig.developerMode, legacyConfig.developerMode)
    }

    func testBootstrapPreservesExistingFiles() throws {
        let (manager, _) = makeManager()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: manager.baseDirectoryURL, withIntermediateDirectories: true)

        try "custom prompt".write(to: manager.promptURL, atomically: true, encoding: .utf8)
        let customConfig = AppConfig(
            claudePath: "/bin/claude",
            codexPath: "/bin/codex",
            geminiPath: "/bin/gemini",
            provider: "codex",
            model: "",
            timeoutSeconds: 60,
            hotkeyKeyCode: 7,
            hotkeyModifiers: 512,
            launchAtLogin: true,
            historyLimit: 50
        )
        try JSONEncoder().encode(customConfig).write(to: manager.configURL, options: .atomic)

        try manager.bootstrapIfNeeded()

        let prompt = try String(contentsOf: manager.promptURL, encoding: .utf8)
        XCTAssertEqual(prompt, "custom prompt")

        let loaded = manager.loadConfig()
        XCTAssertEqual(loaded.claudePath, customConfig.claudePath)
        XCTAssertEqual(loaded.codexPath, customConfig.codexPath)
        XCTAssertEqual(loaded.geminiPath, customConfig.geminiPath)
        XCTAssertEqual(loaded.provider, customConfig.provider)
        XCTAssertEqual(loaded.model, AppConfig.defaultModel(for: .codex))
        XCTAssertEqual(loaded.timeoutSeconds, customConfig.timeoutSeconds)
        XCTAssertEqual(loaded.hotkeyKeyCode, customConfig.hotkeyKeyCode)
        XCTAssertEqual(loaded.hotkeyModifiers, customConfig.hotkeyModifiers)
        XCTAssertEqual(loaded.launchAtLogin, customConfig.launchAtLogin)
        XCTAssertEqual(loaded.historyLimit, customConfig.historyLimit)
        XCTAssertEqual(loaded.developerMode, customConfig.developerMode)
    }

    func testBootstrapMigratesLegacyDefaultPromptToCurrentDefault() throws {
        let (manager, _) = makeManager()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: manager.baseDirectoryURL, withIntermediateDirectories: true)

        let legacyPrompt = "Fix the grammar, spelling, and punctuation of the following text. Improve clarity and flow, but keep the tone authentic. Return ONLY the fixed text. Do not add introductory conversational filler."
        try legacyPrompt.write(to: manager.promptURL, atomically: true, encoding: .utf8)

        try manager.bootstrapIfNeeded()

        let prompt = try String(contentsOf: manager.promptURL, encoding: .utf8)
        XCTAssertEqual(prompt, manager.defaultPrompt)
    }

    func testBootstrapMigratesV11DefaultPromptToCurrentDefault() throws {
        let (manager, _) = makeManager()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: manager.baseDirectoryURL, withIntermediateDirectories: true)

        let v11Prompt = "Edit the following text for grammar, spelling, and punctuation. Improve clarity and flow while preserving the original meaning, message sequence, and authentic tone. Keep the final writing absolutely professional, concise, and direct. Where natural, reflect these behaviors in tone: think big, deliver user value fast, own it, raise the bar, dive deep, learn and grow, and support each other. Return ONLY the revised text with no introductory or conversational filler."
        try v11Prompt.write(to: manager.promptURL, atomically: true, encoding: .utf8)

        try manager.bootstrapIfNeeded()

        let prompt = try String(contentsOf: manager.promptURL, encoding: .utf8)
        XCTAssertEqual(prompt, manager.defaultPrompt)
    }

    func testLoadPromptFallsBackWhenPromptIsWhitespace() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        try "\n  \t\n".write(to: manager.promptURL, atomically: true, encoding: .utf8)

        let prompt = try manager.loadPrompt()
        XCTAssertEqual(prompt, manager.defaultPrompt)
    }

    func testLoadPromptReturnsTrimmedPromptWhenNonEmpty() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        try "\n  Keep this prompt.   \n".write(to: manager.promptURL, atomically: true, encoding: .utf8)

        let prompt = try manager.loadPrompt()
        XCTAssertEqual(prompt, "Keep this prompt.")
    }

    func testLoadConfigReturnsDefaultWhenConfigIsInvalid() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        try "{ this is not valid json }".write(to: manager.configURL, atomically: true, encoding: .utf8)

        let config = manager.loadConfig()
        XCTAssertEqual(config.provider, AppConfig.default.provider)
        XCTAssertEqual(config.model, AppConfig.default.model)
        XCTAssertEqual(config.timeoutSeconds, AppConfig.default.timeoutSeconds)
        XCTAssertEqual(config.hotkeyKeyCode, AppConfig.default.hotkeyKeyCode)
        XCTAssertEqual(config.hotkeyModifiers, AppConfig.default.hotkeyModifiers)
        XCTAssertEqual(config.claudePath, AppConfig.default.claudePath)
        XCTAssertEqual(config.codexPath, AppConfig.default.codexPath)
        XCTAssertEqual(config.geminiPath, AppConfig.default.geminiPath)
        XCTAssertEqual(config.launchAtLogin, AppConfig.default.launchAtLogin)
        XCTAssertEqual(config.historyLimit, AppConfig.default.historyLimit)
        XCTAssertEqual(config.developerMode, AppConfig.default.developerMode)
    }

    func testLoadConfigAppliesDecoderDefaultsForMissingFields() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        try "{\"timeoutSeconds\": 12}".write(to: manager.configURL, atomically: true, encoding: .utf8)

        let config = manager.loadConfig()
        XCTAssertEqual(config.timeoutSeconds, 12)
        XCTAssertEqual(config.provider, AppConfig.default.provider)
        XCTAssertEqual(config.model, AppConfig.default.model)
        XCTAssertEqual(config.hotkeyKeyCode, AppConfig.default.hotkeyKeyCode)
        XCTAssertEqual(config.hotkeyModifiers, AppConfig.default.hotkeyModifiers)
        XCTAssertEqual(config.claudePath, AppConfig.default.claudePath)
        XCTAssertEqual(config.codexPath, AppConfig.default.codexPath)
        XCTAssertEqual(config.geminiPath, AppConfig.default.geminiPath)
        XCTAssertEqual(config.launchAtLogin, AppConfig.default.launchAtLogin)
        XCTAssertEqual(config.historyLimit, AppConfig.default.historyLimit)
        XCTAssertEqual(config.developerMode, AppConfig.default.developerMode)
    }

    func testLoadConfigUsesDefaultTimeoutWhenTimeoutMissing() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        try "{\"model\": \"sonnet\"}".write(to: manager.configURL, atomically: true, encoding: .utf8)

        let config = manager.loadConfig()
        XCTAssertEqual(config.model, "sonnet")
        XCTAssertEqual(config.timeoutSeconds, AppConfig.default.timeoutSeconds)
    }

    func testSaveConfigNormalizesTimeoutProviderAndModel() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        let raw = AppConfig(
            claudePath: " /opt/homebrew/bin/claude ",
            codexPath: " /opt/homebrew/bin/codex ",
            geminiPath: " /opt/homebrew/bin/gemini ",
            provider: "invalid-provider",
            model: "   ",
            timeoutSeconds: 1,
            hotkeyKeyCode: 33,
            hotkeyModifiers: 512,
            launchAtLogin: true,
            historyLimit: 0
        )

        try manager.saveConfig(raw)
        let loaded = manager.loadConfig()

        XCTAssertEqual(loaded.claudePath, raw.claudePath)
        XCTAssertEqual(loaded.codexPath, raw.codexPath)
        XCTAssertEqual(loaded.geminiPath, raw.geminiPath)
        XCTAssertEqual(loaded.provider, CLIProvider.default.rawValue)
        XCTAssertEqual(loaded.model, AppConfig.defaultModel(for: .claude))
        XCTAssertEqual(loaded.timeoutSeconds, 5)
        XCTAssertEqual(loaded.hotkeyKeyCode, raw.hotkeyKeyCode)
        XCTAssertEqual(loaded.hotkeyModifiers, raw.hotkeyModifiers)
        XCTAssertEqual(loaded.launchAtLogin, true)
        XCTAssertEqual(loaded.historyLimit, 1)
    }

    func testAppConfigResolvedPropertiesForProviderPathModelAndFallbacks() {
        let config = AppConfig(
            claudePath: "  /usr/local/bin/claude  ",
            codexPath: "  /usr/local/bin/codex  ",
            geminiPath: "  /usr/local/bin/gemini  ",
            provider: " GeMiNi ",
            model: "   ",
            timeoutSeconds: 30,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 20
        )

        XCTAssertEqual(config.resolvedClaudePath, "/usr/local/bin/claude")
        XCTAssertEqual(config.resolvedCodexPath, "/usr/local/bin/codex")
        XCTAssertEqual(config.resolvedGeminiPath, "/usr/local/bin/gemini")
        XCTAssertEqual(config.resolvedProvider, .gemini)
        XCTAssertEqual(config.resolvedModel(for: .claude), "claude-haiku-4-5")
        XCTAssertEqual(config.resolvedModel(for: .codex), "gpt-5-codex")
        XCTAssertEqual(config.resolvedModel(for: .gemini), "gemini-2.5-flash-lite")
    }

    func testAppConfigResolvedModelUsesResolvedProviderWhenArgumentIsNil() {
        let codexConfig = AppConfig(
            claudePath: "",
            codexPath: "",
            geminiPath: "",
            provider: "codex",
            model: "   ",
            timeoutSeconds: 30,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 20
        )
        XCTAssertEqual(codexConfig.resolvedModel(), "gpt-5-codex")

        let fallbackConfig = AppConfig(
            claudePath: "",
            codexPath: "",
            geminiPath: "",
            provider: "unknown",
            model: "   ",
            timeoutSeconds: 30,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 20
        )
        XCTAssertEqual(fallbackConfig.resolvedModel(), "claude-haiku-4-5")
    }

    func testAppConfigResolvedProviderFallsBackToDefaultWhenInvalid() {
        let config = AppConfig(
            claudePath: "",
            codexPath: "",
            geminiPath: "",
            provider: "???",
            model: "haiku",
            timeoutSeconds: 30,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 20
        )

        XCTAssertEqual(config.resolvedProvider, .claude)
    }

    func testAppConfigResolvedClaudePathReturnsNilWhenBlank() {
        let config = AppConfig(
            claudePath: " \n\t ",
            codexPath: "",
            geminiPath: "",
            provider: "claude",
            model: "haiku",
            timeoutSeconds: 30,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 20
        )

        XCTAssertNil(config.resolvedClaudePath)
    }


    func testLoadConfigReturnsCachedValueWithoutRereadingDisk() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        let first = manager.loadConfig()
        XCTAssertEqual(first.model, AppConfig.default.model)

        // Overwrite the config file on disk with a different model.
        let altered = AppConfig(
            claudePath: "",
            codexPath: "",
            geminiPath: "",
            provider: "claude",
            model: "opus",
            timeoutSeconds: 60,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 200
        )
        try JSONEncoder().encode(altered).write(to: manager.configURL, options: .atomic)

        // Second call should return the cached value, not the disk value.
        let second = manager.loadConfig()
        XCTAssertEqual(second.model, first.model)
    }

    func testLoadPromptReturnsCachedValueWithoutRereadingDisk() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        let first = try manager.loadPrompt()
        XCTAssertEqual(first, manager.defaultPrompt)

        // Overwrite the prompt file on disk.
        try "completely different prompt".write(to: manager.promptURL, atomically: true, encoding: .utf8)

        // Second call should return the cached value.
        let second = try manager.loadPrompt()
        XCTAssertEqual(second, first)
    }

    func testSaveConfigInvalidatesBothCaches() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        // Populate both caches.
        _ = manager.loadConfig()
        _ = try manager.loadPrompt()

        // Save a new config (this should invalidate caches).
        var config = manager.loadConfig()
        config.model = "sonnet"
        try manager.saveConfig(config)

        // Overwrite prompt on disk after save.
        try "fresh prompt after save".write(to: manager.promptURL, atomically: true, encoding: .utf8)

        // loadConfig should re-read and get the saved value.
        let reloaded = manager.loadConfig()
        XCTAssertEqual(reloaded.model, "sonnet")

        // loadPrompt should re-read and get the new disk value.
        let reloadedPrompt = try manager.loadPrompt()
        XCTAssertEqual(reloadedPrompt, "fresh prompt after save")
    }

    func testInvalidateCacheClearsBothCaches() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        // Populate both caches.
        _ = manager.loadConfig()
        _ = try manager.loadPrompt()

        // Change files on disk.
        let altered = AppConfig(
            claudePath: "",
            codexPath: "",
            geminiPath: "",
            provider: "claude",
            model: "opus",
            timeoutSeconds: 60,
            hotkeyKeyCode: 14,
            hotkeyModifiers: 256,
            launchAtLogin: false,
            historyLimit: 200
        )
        try JSONEncoder().encode(altered).write(to: manager.configURL, options: .atomic)
        try "invalidated prompt".write(to: manager.promptURL, atomically: true, encoding: .utf8)

        // Invalidate caches.
        manager.invalidateCache()

        // Now reads should reflect the on-disk changes.
        let config = manager.loadConfig()
        XCTAssertEqual(config.model, "opus")

        let prompt = try manager.loadPrompt()
        XCTAssertEqual(prompt, "invalidated prompt")
    }

    func testDefaultInitializerUsesCurrentUserHomeDirectory() {
        let manager = ConfigManager()
        let expectedBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ghostedit", isDirectory: true)
            .path
        XCTAssertEqual(manager.baseDirectoryURL.path, expectedBase)
        XCTAssertEqual(
            manager.historyURL.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ghostedit", isDirectory: true)
                .appendingPathComponent("history.json")
                .path
        )
    }

    func testLanguageDefaultIsAuto() {
        XCTAssertEqual(AppConfig.default.language, "auto")
        XCTAssertEqual(AppConfig.default.resolvedLanguage, "auto")
    }

    func testResolvedLanguageNormalizesBlankToAuto() {
        var config = AppConfig.default
        config.language = "   "
        XCTAssertEqual(config.resolvedLanguage, "auto")
    }

    func testResolvedLanguageLowercases() {
        var config = AppConfig.default
        config.language = " FR "
        XCTAssertEqual(config.resolvedLanguage, "fr")
    }

    func testLanguageInstructionForAuto() {
        let instruction = AppConfig.languageInstruction(for: "auto")
        XCTAssertEqual(instruction, "Keep the input language. Do not translate.")
    }

    func testLanguageInstructionForEmpty() {
        let instruction = AppConfig.languageInstruction(for: "")
        XCTAssertEqual(instruction, "Keep the input language. Do not translate.")
        XCTAssertEqual(AppConfig.languageInstruction(for: "   "), instruction)
    }

    func testLanguageInstructionForKnownLanguage() {
        let french = AppConfig.languageInstruction(for: "fr")
        XCTAssertEqual(french, "Target language: French. Translate the user text into French. If it is already French, correct the grammar. Do not return the original language.")
        XCTAssertTrue(AppConfig.languageInstruction(for: "ja").contains("Target language: Japanese."))
        XCTAssertTrue(AppConfig.languageInstruction(for: "ta").contains("Translate the user text into Tamil."))
        XCTAssertTrue(AppConfig.languageInstruction(for: " FR ").contains("Target language: French."))
    }

    func testLanguageInstructionForUnknownLanguageUsesRawValue() {
        XCTAssertEqual(
            AppConfig.languageInstruction(for: "klingon"),
            "Target language: klingon. Translate the user text into klingon. If it is already klingon, correct the grammar. Do not return the original language."
        )
    }


    func testCorrectionSystemPromptOmitsContractWhenDisabled() {
        XCTAssertEqual(
            AppConfig.correctionSystemPrompt(systemPrompt: "Fix", language: "en", includeLanguageContract: false),
            "Fix"
        )
        let prompt = AppConfig.correctionSystemPrompt(systemPrompt: "Fix", language: "en", includeLanguageContract: true)
        XCTAssertTrue(prompt.hasPrefix("Fix\n\n"))
        XCTAssertTrue(prompt.contains("Target language: English."))
        XCTAssertTrue(prompt.contains("Translate the user text into English."))
        XCTAssertTrue(prompt.contains(AppConfig.outputFormatInstruction))
        XCTAssertTrue(prompt.contains("<<<TEXT>>>"))
        XCTAssertTrue(prompt.contains("<<<END>>>"))
    }

    func testLanguageRoundTripsViaConfigManager() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        var config = manager.loadConfig()
        XCTAssertEqual(config.resolvedLanguage, "auto")

        config.language = "es"
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().resolvedLanguage, "es")
    }

    func testLanguageDecodesFromJSON() throws {
        let json = """
        {"language": "de", "provider": "claude"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.resolvedLanguage, "de")
    }

    func testLanguageDefaultsWhenMissingFromJSON() throws {
        let json = """
        {"provider": "claude"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.resolvedLanguage, "auto")
    }

    func testSupportedLanguagesContainsAutoAndEnglish() {
        let codes = AppConfig.supportedLanguages.map { $0.code }
        XCTAssertTrue(codes.contains("auto"))
        XCTAssertTrue(codes.contains("en"))
        XCTAssertGreaterThan(codes.count, 10)
    }

    // MARK: - Sound Feedback Toggle Tests

    func testSoundFeedbackEnabledDefaultIsTrue() {
        XCTAssertTrue(AppConfig.default.soundFeedbackEnabled)
    }

    func testSoundFeedbackEnabledBackwardCompatJSON() throws {
        let json = """
        {"provider": "claude"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.soundFeedbackEnabled)
    }

    func testSoundFeedbackEnabledRoundTrip() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        var config = manager.loadConfig()
        XCTAssertTrue(config.soundFeedbackEnabled)

        config.soundFeedbackEnabled = false
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertFalse(manager.loadConfig().soundFeedbackEnabled)
    }

    // MARK: - Notification Center Integration Tests

    func testNotifyOnSuccessDefaultIsFalse() {
        XCTAssertFalse(AppConfig.default.notifyOnSuccess)
    }

    func testNotifyOnSuccessBackwardCompatJSON() throws {
        let json = """
        {"provider": "claude"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.notifyOnSuccess)
    }

    func testNotifyOnSuccessRoundTrip() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        var config = manager.loadConfig()
        XCTAssertFalse(config.notifyOnSuccess)

        config.notifyOnSuccess = true
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertTrue(manager.loadConfig().notifyOnSuccess)
    }

    // MARK: - Tone/Style Presets Tests

    func testTonePresetDefaultIsDefault() {
        XCTAssertEqual(AppConfig.default.tonePreset, "default")
    }

    func testTonePresetBackwardCompatJSON() throws {
        let json = """
        {"provider": "claude"}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.tonePreset, "default")
    }

    func testTonePresetRoundTrip() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        var config = manager.loadConfig()
        XCTAssertEqual(config.tonePreset, "default")

        config.tonePreset = "professional"
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().tonePreset, "professional")
    }

    func testSupportedPresetsContainsExpectedValues() {
        let presets = AppConfig.supportedPresets
        XCTAssertEqual(presets, ["default", "casual", "professional", "academic", "slack"])
    }

    func testPromptForPresetReturnsNilForDefault() {
        XCTAssertNil(AppConfig.promptForPreset("default"))
        XCTAssertNil(AppConfig.promptForPreset(""))
    }

    func testPromptForPresetReturnsPromptForKnownPresets() {
        XCTAssertNotNil(AppConfig.promptForPreset("casual"))
        XCTAssertNotNil(AppConfig.promptForPreset("professional"))
        XCTAssertNotNil(AppConfig.promptForPreset("academic"))
        XCTAssertNotNil(AppConfig.promptForPreset("slack"))
    }

    func testPromptForPresetReturnsNilForUnknown() {
        XCTAssertNil(AppConfig.promptForPreset("unknown-preset"))
    }

    func testPromptForPresetIsCaseInsensitive() {
        XCTAssertNotNil(AppConfig.promptForPreset("CASUAL"))
        XCTAssertNotNil(AppConfig.promptForPreset(" Professional "))
    }

    func testTonePresetNormalizesToDefaultForInvalidValue() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()

        var config = manager.loadConfig()
        config.tonePreset = "invalid-tone"
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().tonePreset, "default")
    }

    func testOllamaConfigurationSurvivesSaveReloadAndExport() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()
        var config = manager.loadConfig()
        config.provider = " OLLAMA "
        config.model = " custom-editor:latest "
        config.ollamaBaseURL = " http://localhost:11435/proxy "
        try manager.saveConfig(config)
        manager.invalidateCache()

        let loaded = manager.loadConfig()
        XCTAssertEqual(loaded.resolvedProvider, .ollama, "Saving must not silently fall back to a cloud provider")
        XCTAssertEqual(loaded.resolvedModel(), "custom-editor:latest", "Custom installed model names must survive normalization")
        XCTAssertEqual(loaded.ollamaBaseURL, "http://localhost:11435/proxy", "The selected server must survive save/reload")
        XCTAssertNil(loaded.resolvedPath(for: .ollama), "HTTP corrections must not depend on an executable path")

        let data = try SettingsExportSupport.exportSettings(config: loaded, prompt: "Correct text", appVersion: "test")
        let imported = try SettingsExportSupport.importSettings(from: data)
        XCTAssertEqual(imported.config, loaded, "Export/import must retain the complete local provider configuration")
    }

    func testExistingConfigRetainsProviderWhenOllamaSettingsAreAbsent() throws {
        let data = Data(#"{"provider":"codex","model":"custom-cloud-model"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.resolvedProvider, .codex, "Adding local support must not migrate an existing provider")
        XCTAssertEqual(decoded.resolvedModel(), "custom-cloud-model", "Existing model choice must remain intact")
        XCTAssertEqual(decoded.ollamaBaseURL, AppConfig.default.ollamaBaseURL, "Old configs must resolve a usable local server address")
    }

    func testBlankOllamaModelResolvesForSelectedBackendInsteadOfCloud() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()
        var config = manager.loadConfig()
        config.provider = "ollama"
        config.model = "  "
        try manager.saveConfig(config)
        manager.invalidateCache()

        let loaded = manager.loadConfig()
        XCTAssertEqual(loaded.resolvedProvider, .ollama, "Normalization must retain the selected HTTP backend")
        XCTAssertEqual(loaded.resolvedModel(), CLIProvider.ollama.defaultModel,
                       "A blank local model must use the local backend's default, not the global Claude model")
        XCTAssertNotEqual(loaded.resolvedModel(), AppConfig.default.model,
                          "A cloud-only alias must not be sent to the local Ollama server")
    }

    func testCLIPathGuidanceKeysCanConfigureTheirCorrespondingRuntime() throws {
        for provider in [CLIProvider.claude, .codex, .gemini, .grok] {
            let path = "/custom/tools/\(provider.rawValue)"
            let data = try JSONSerialization.data(withJSONObject: [
                "provider": provider.rawValue,
                provider.configPathKey: path
            ])
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            XCTAssertEqual(config.resolvedPath(for: provider), path,
                           "The configuration key shown in setup guidance must control that provider's executable")
            XCTAssertFalse(provider.usesHTTP)
        }
        XCTAssertTrue(CLIProvider.ollama.usesHTTP)
        XCTAssertTrue(CLIProvider.magpie.usesHTTP)
        XCTAssertNil(AppConfig.default.resolvedPath(for: .magpie))
    }

    func testGrokAndMagpieSettingsSurviveSave() throws {
        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()
        var config = manager.loadConfig()
        config.provider = "magpie"
        config.model = "claude/claude-haiku-4-5"
        config.grokPath = "/opt/homebrew/bin/grok"
        config.magpieBaseURL = " http://127.0.0.1:3425 "
        try manager.saveConfig(config)
        manager.invalidateCache()
        let loaded = manager.loadConfig()
        XCTAssertEqual(loaded.resolvedProvider, .magpie)
        XCTAssertEqual(loaded.grokPath, "/opt/homebrew/bin/grok")
        XCTAssertEqual(loaded.magpieBaseURL, "http://127.0.0.1:3425")
        XCTAssertEqual(loaded.resolvedModel(), "claude/claude-haiku-4-5")
        XCTAssertEqual(CLIProvider.grok.displayName, "Grok")
        XCTAssertEqual(CLIProvider.magpie.authCommand, "magpie")
    }

    func testFloaterOpacityDefaultsClampsAndRoundTrips() throws {
        let missing = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"provider":"claude"}"#.utf8))
        XCTAssertEqual(missing.floaterOpacity, AppConfig.defaultFloaterOpacity)

        let present = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"floaterOpacity":0.7}"#.utf8))
        XCTAssertEqual(present.floaterOpacity, 0.7, accuracy: 0.0001)

        let nullValue = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"floaterOpacity":null}"#.utf8))
        XCTAssertEqual(nullValue.floaterOpacity, AppConfig.defaultFloaterOpacity)
        XCTAssertEqual(AppConfig.clampedFloaterOpacity(.nan), AppConfig.defaultFloaterOpacity)
        XCTAssertEqual(AppConfig.clampedFloaterOpacity(.infinity), AppConfig.defaultFloaterOpacity)

        let (manager, _) = makeManager()
        try manager.bootstrapIfNeeded()
        var config = manager.loadConfig()
        config.floaterOpacity = 2
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().floaterOpacity, AppConfig.maximumFloaterOpacity)

        config = manager.loadConfig()
        config.floaterOpacity = -1
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().floaterOpacity, AppConfig.minimumFloaterOpacity)

        config = manager.loadConfig()
        config.floaterOpacity = 0.55
        try manager.saveConfig(config)
        manager.invalidateCache()
        XCTAssertEqual(manager.loadConfig().floaterOpacity, 0.55, accuracy: 0.0001)
    }

    private func makeManager() -> (ConfigManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostedit-tests-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        let manager = ConfigManager(fileManager: .default, homeDirectoryURL: root)
        return (manager, root)
    }
}
