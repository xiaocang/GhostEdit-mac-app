import Foundation

enum ShellRunnerError: LocalizedError {
    case cliNotFound(provider: CLIProvider)
    case authenticationRequired(provider: CLIProvider)
    case launchFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut(seconds: Int)
    case emptyResponse
    case protectedTokensModified

    var errorDescription: String? {
        switch self {
        case let .cliNotFound(provider):
            return "The \(provider.executableName) CLI could not be found. Set an absolute path in ~/.ghostedit/config.json or switch provider in Settings."
        case let .authenticationRequired(provider):
            return "\(provider.displayName) authentication has expired. Run `\(provider.authCommand)` in Terminal, then try again."
        case let .launchFailed(message):
            return "Failed to start CLI process: \(message)"
        case let .processFailed(exitCode, stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return details.isEmpty
                ? "CLI exited with code \(exitCode). Try switching the model in Settings if the selected model is busy."
                : "CLI exited with code \(exitCode): \(details)\nTry switching the model in Settings if this model is busy or unavailable."
        case let .timedOut(seconds):
            return "CLI timed out after \(seconds) seconds. Try switching the model in Settings if the selected model is busy."
        case .emptyResponse:
            return "CLI returned an empty response. Try switching the model in Settings."
        case .protectedTokensModified:
            return "The AI response changed protected static tokens. Retried once, but placeholders were not preserved."
        }
    }
}

final class ShellRunner {
    private let configManager: ConfigManager
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectoryPath: String
    private let ollamaSessionConfiguration: URLSessionConfiguration
    weak var developerModeLogger: DeveloperModeLogger?

    private let discoveredPathLock = NSLock()
    private var discoveredCLIPaths: [CLIProvider: String] = [:]

    private let persistentSessionLock = NSLock()
    private var persistentSession: PersistentCLISessionProtocol?
    private var sessionFactory: () -> PersistentCLISessionProtocol = { PersistentCLISession() }

    /// Test-only: inject a mock persistent session.
    func setPersistentSessionForTesting(_ session: PersistentCLISessionProtocol?) {
        persistentSessionLock.lock()
        persistentSession = session
        persistentSessionLock.unlock()
    }

    /// Test-only: override the factory used by `spawnPersistentSessionSync`.
    func setSessionFactoryForTesting(_ factory: @escaping () -> PersistentCLISessionProtocol) {
        sessionFactory = factory
    }

    init(
        configManager: ConfigManager,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String? = nil,
        ollamaSessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configManager = configManager
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectoryPath = homeDirectoryPath ?? fileManager.homeDirectoryForCurrentUser.path
        self.ollamaSessionConfiguration = ollamaSessionConfiguration
    }

    func prewarm() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let config = self.configManager.loadConfig()
            let provider = config.resolvedProvider
            guard provider != .ollama else { return }
            _ = try? self.resolveCLIPath(
                provider: provider,
                preferredPath: config.resolvedPath(for: provider)
            )

            // Spawn a persistent CLI session so the first Cmd+E is fast.
            self.spawnPersistentSession()
        }
    }

    /// Spawn (or respawn) a persistent CLI session in the background.
    /// Safe to call multiple times - kills any existing session first.
    func spawnPersistentSession() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.spawnPersistentSessionSync()
        }
    }

    private func spawnPersistentSessionSync() {
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider

        guard provider == .claude else {
            devLog(.cliResolution, "Persistent session skipped: only Claude supports stream-json")
            return
        }

        guard let executablePath = try? resolveCLIPath(
            provider: provider,
            preferredPath: config.resolvedPath(for: provider)
        ) else {
            devLog(.cliResolution, "Persistent session skipped: CLI path not found")
            return
        }

        let model = config.resolvedModel(for: provider)

        // Build a minimal system prompt for the warm session. The actual
        // per-correction prompt will be sent as the user message content.
        let systemPrompt = "You are a text correction assistant. The user will send text to fix. Return ONLY the corrected text with no explanation."

        var runtimeEnv = environment
        runtimeEnv["PATH"] = ClaudeRuntimeSupport.runtimePathValue(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )

        let session = sessionFactory()

        do {
            try session.spawn(
                executablePath: executablePath,
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                environment: runtimeEnv,
                workingDirectoryURL: configManager.baseDirectoryURL
            )

            persistentSessionLock.lock()
            persistentSession?.kill()
            persistentSession = session
            persistentSessionLock.unlock()

            devLog(.cliResolution, "Persistent CLI session spawned (model: \(model.isEmpty ? "default" : model))")
        } catch {
            devLog(.cliResolution, "Persistent session spawn failed: \(error.localizedDescription)")
        }
    }

    /// Kill the persistent session (e.g. on app quit).
    func killPersistentSession() {
        persistentSessionLock.lock()
        persistentSession?.kill()
        persistentSession = nil
        persistentSessionLock.unlock()
    }

    /// Correct text with streaming output. The `onChunk` callback fires on the main queue
    /// each time new data arrives from stdout. Returns the final complete corrected text.
    func correctTextStreaming(
        systemPrompt: String,
        selectedText: String,
        includeLanguageContract: Bool = true,
        onChunk: @escaping (String) -> Void
    ) throws -> String {
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        if provider.usesHTTP {
            return try correctTextWithHTTP(systemPrompt: systemPrompt, selectedText: selectedText,
                                            config: config, includeLanguageContract: includeLanguageContract,
                                            onChunk: onChunk)
        }

        // Try the persistent session first (Claude only, zero bootstrap overhead).
        if let result = tryPersistentSessionStreaming(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            config: config,
            includeLanguageContract: includeLanguageContract,
            onChunk: onChunk
        ) {
            return result
        }

        devLog(.cliResolution, "Resolving CLI path for provider: \(provider.displayName)")
        let executablePath = try resolveCLIPath(
            provider: provider,
            preferredPath: config.resolvedPath(for: provider)
        )
        devLog(.cliResolution, "Resolved CLI path: \(executablePath)")
        let model = config.resolvedModel(for: provider)

        let input = preparedPrompt(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            language: config.resolvedLanguage,
            includeLanguageContract: includeLanguageContract
        )

        devLog(.cliExecution, "Launching \(provider.executableName) (streaming) with model: \(model.isEmpty ? "(default)" : model)")
        let output = try runCLIStreaming(
            provider: provider,
            executablePath: executablePath,
            model: model,
            prompt: input,
            timeoutSeconds: config.timeoutSeconds,
            onChunk: onChunk
        )

        let trimmed = finishedCLIOutput(output, includeLanguageContract: includeLanguageContract)
        guard !trimmed.isEmpty else {
            devLog(.cliResponse, "CLI returned empty response")
            throw ShellRunnerError.emptyResponse
        }

        devLog(.cliResponse, "Streaming CLI response (\(trimmed.count) chars)")
        return trimmed
    }

    func correctText(systemPrompt: String, selectedText: String, includeLanguageContract: Bool = true) throws -> String {
        let config = configManager.loadConfig()
        let provider = config.resolvedProvider
        if provider.usesHTTP {
            return try correctTextWithHTTP(systemPrompt: systemPrompt, selectedText: selectedText,
                                            config: config, includeLanguageContract: includeLanguageContract)
        }

        // Try the persistent session first (Claude only, zero bootstrap overhead).
        if let result = tryPersistentSession(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            config: config,
            includeLanguageContract: includeLanguageContract
        ) {
            return result
        }

        devLog(.cliResolution, "Resolving CLI path for provider: \(provider.displayName)")
        let executablePath = try resolveCLIPath(
            provider: provider,
            preferredPath: config.resolvedPath(for: provider)
        )
        devLog(.cliResolution, "Resolved CLI path: \(executablePath)")
        let model = config.resolvedModel(for: provider)

        let input = preparedPrompt(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            language: config.resolvedLanguage,
            includeLanguageContract: includeLanguageContract
        )
        if includeLanguageContract {
            devLog(.cliExecution, "Language: \(config.resolvedLanguage)")
        }

        devLog(.cliExecution, "Launching \(provider.executableName) with model: \(model.isEmpty ? "(default)" : model), timeout: \(config.timeoutSeconds)s")
        let output = try runCLI(
            provider: provider,
            executablePath: executablePath,
            model: model,
            prompt: input,
            timeoutSeconds: config.timeoutSeconds
        )

        let trimmed = finishedCLIOutput(output, includeLanguageContract: includeLanguageContract)
        guard !trimmed.isEmpty else {
            devLog(.cliResponse, "CLI returned empty response")
            throw ShellRunnerError.emptyResponse
        }

        devLog(.cliResponse, "CLI response (\(trimmed.count) chars): \(DeveloperModeSupport.truncate(trimmed))")
        return trimmed
    }

    private func correctTextWithHTTP(
        systemPrompt: String,
        selectedText: String,
        config: AppConfig,
        includeLanguageContract: Bool,
        onChunk: ((String) -> Void)? = nil
    ) throws -> String {
        let prompt = AppConfig.correctionSystemPrompt(
            systemPrompt: systemPrompt,
            language: config.resolvedLanguage,
            includeLanguageContract: includeLanguageContract
        )
        let userText = includeLanguageContract ? Self.taggedSelectedText(selectedText) : selectedText
        devLog(.cliExecution, "GhostEdit HTTP user fence prefix=\(userText.hasPrefix("<selected>"))")
        let provider = config.resolvedProvider
        let text: String
        if provider == .magpie {
            text = try MagpieClient(baseURL: config.magpieBaseURL, timeoutSeconds: config.timeoutSeconds,
                                    sessionConfiguration: ollamaSessionConfiguration)
                .correctText(systemPrompt: prompt, selectedText: userText,
                             model: config.resolvedModel(for: .magpie), onChunk: onChunk)
        } else {
            text = try OllamaClient(baseURL: config.ollamaBaseURL, timeoutSeconds: config.timeoutSeconds,
                                    sessionConfiguration: ollamaSessionConfiguration)
                .correctText(systemPrompt: prompt, selectedText: userText,
                             model: config.resolvedModel(for: .ollama), onChunk: onChunk)
        }
        guard includeLanguageContract else { return text }
        let cleaned = Self.correctionOnly(in: text)
        guard !cleaned.isEmpty else {
            devLog(.cliResponse, "HTTP correction was empty after stripping extra text")
            throw ShellRunnerError.emptyResponse
        }
        return cleaned
    }

    func correctTextPreservingTokens(
        systemPrompt: String,
        selectedText: String,
        maxValidationRetries: Int = 1
    ) throws -> String {
        let protection = TokenPreservationSupport.protectTokens(in: selectedText)
        guard protection.hasProtectedTokens else {
            devLog(.tokenProtection, "No protected tokens found, using direct correction")
            return try correctText(systemPrompt: systemPrompt, selectedText: selectedText)
        }

        devLog(.tokenProtection, "Protected \(protection.tokens.count) token(s): \(protection.tokens.map { "\($0.placeholder)=\(DeveloperModeSupport.truncate($0.originalToken, maxLength: 40))" }.joined(separator: ", "))")
        let augmentedPrompt = TokenPreservationSupport.appendInstruction(to: systemPrompt)
        let retries = max(0, maxValidationRetries)
        var lastCandidate = ""

        for attempt in 0...retries {
            devLog(.cliExecution, "Token-preserving correction attempt \(attempt + 1)/\(retries + 1)")
            lastCandidate = try correctText(
                systemPrompt: augmentedPrompt,
                selectedText: protection.protectedText
            )

            if TokenPreservationSupport.placeholdersAreIntact(in: lastCandidate, tokens: protection.tokens) {
                devLog(.tokenRestoration, "All placeholders intact, restoring tokens")
                return TokenPreservationSupport.restoreTokens(in: lastCandidate, tokens: protection.tokens)
            }
            devLog(.tokenRestoration, "Placeholders modified by AI on attempt \(attempt + 1)")
        }

        // Placeholders were modified by the AI - retry with the original text
        // and an explicit instruction to preserve emoji codes and other tokens.
        devLog(.tokenRestoration, "Retrying with original text and token-aware instruction")
        let segments = TokenPreservationSupport.splitAroundTokens(in: selectedText)
        let tokenAwarePrompt = TokenPreservationSupport.appendTokenAwareInstruction(to: systemPrompt)

        let retryWithOriginal = try correctText(
            systemPrompt: tokenAwarePrompt,
            selectedText: selectedText
        )

        // If all original tokens survived in the retry, return it directly.
        if segments.tokens.allSatisfy({ retryWithOriginal.contains($0) }) {
            devLog(.tokenRestoration, "Token-aware retry preserved all tokens")
            return retryWithOriginal
        }

        // Last resort: best-effort restoration on the placeholder-based attempt.
        devLog(.tokenRestoration, "Falling back to best-effort token restoration")
        return TokenPreservationSupport.bestEffortRestore(in: lastCandidate, tokens: protection.tokens)
    }

    /// Correct text with streaming output, protecting @mentions, :emoji:, URLs, etc.
    /// On each chunk, restores any surviving placeholders so the streaming preview shows real tokens.
    func correctTextStreamingPreservingTokens(
        systemPrompt: String,
        selectedText: String,
        onChunk: @escaping (String) -> Void
    ) throws -> String {
        let protection = TokenPreservationSupport.protectTokens(in: selectedText)
        guard protection.hasProtectedTokens else {
            devLog(.tokenProtection, "No protected tokens found, using direct streaming correction")
            return try correctTextStreaming(systemPrompt: systemPrompt, selectedText: selectedText, onChunk: onChunk)
        }

        devLog(.tokenProtection, "Protected \(protection.tokens.count) token(s) for streaming")
        let augmentedPrompt = TokenPreservationSupport.appendInstruction(to: systemPrompt)

        let rawResult = try correctTextStreaming(
            systemPrompt: augmentedPrompt,
            selectedText: protection.protectedText,
            onChunk: { accumulated in
                let restored = TokenPreservationSupport.bestEffortRestore(in: accumulated, tokens: protection.tokens)
                onChunk(restored)
            }
        )

        if TokenPreservationSupport.placeholdersAreIntact(in: rawResult, tokens: protection.tokens) {
            devLog(.tokenRestoration, "All placeholders intact in streaming result, restoring tokens")
            return TokenPreservationSupport.restoreTokens(in: rawResult, tokens: protection.tokens)
        }
        devLog(.tokenRestoration, "Placeholders modified in streaming result, using best-effort restoration")
        return TokenPreservationSupport.bestEffortRestore(in: rawResult, tokens: protection.tokens)
    }

    // MARK: - Persistent session helpers

    /// Attempt to use the persistent session for a non-streaming correction.
    /// Returns `nil` if the session isn't available, letting the caller fall
    /// back to the one-shot path.
    private func tryPersistentSession(
        systemPrompt: String,
        selectedText: String,
        config: AppConfig,
        includeLanguageContract: Bool
    ) -> String? {
        guard config.resolvedProvider == .claude else { return nil }
        persistentSessionLock.lock()
        guard let session = persistentSession, session.isReady else {
            persistentSessionLock.unlock()
            devLog(.cliExecution, "Persistent session not ready, falling back to one-shot CLI")
            return nil
        }
        persistentSessionLock.unlock()

        let input = preparedPrompt(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            language: config.resolvedLanguage,
            includeLanguageContract: includeLanguageContract
        )

        devLog(.cliExecution, "Using persistent session (zero bootstrap overhead)")

        do {
            let result = try session.send(prompt: input, timeoutSeconds: config.timeoutSeconds)
            let trimmed = finishedCLIOutput(result.text, includeLanguageContract: includeLanguageContract)
            guard !trimmed.isEmpty else {
                devLog(.cliResponse, "Persistent session returned empty response, falling back")
                return nil
            }
            devLog(.cliResponse, "Persistent session response (\(trimmed.count) chars): \(DeveloperModeSupport.truncate(trimmed))")
            return trimmed
        } catch {
            devLog(.cliExecution, "Persistent session failed: \(error.localizedDescription), falling back to one-shot CLI")
            // Kill the broken session; a new one will be spawned after correction.
            persistentSessionLock.lock()
            persistentSession?.kill()
            persistentSession = nil
            persistentSessionLock.unlock()
            return nil
        }
    }

    /// Attempt to use the persistent session for a streaming correction.
    /// Returns `nil` if the session isn't available.
    private func tryPersistentSessionStreaming(
        systemPrompt: String,
        selectedText: String,
        config: AppConfig,
        includeLanguageContract: Bool,
        onChunk: @escaping (String) -> Void
    ) -> String? {
        guard config.resolvedProvider == .claude else { return nil }
        persistentSessionLock.lock()
        guard let session = persistentSession, session.isReady else {
            persistentSessionLock.unlock()
            devLog(.cliExecution, "Persistent session not ready, falling back to one-shot streaming CLI")
            return nil
        }
        persistentSessionLock.unlock()

        let input = preparedPrompt(
            systemPrompt: systemPrompt,
            selectedText: selectedText,
            language: config.resolvedLanguage,
            includeLanguageContract: includeLanguageContract
        )

        devLog(.cliExecution, "Using persistent session for streaming (zero bootstrap overhead)")

        do {
            let result = try session.sendStreaming(
                prompt: input,
                timeoutSeconds: config.timeoutSeconds,
                onChunk: onChunk
            )
            let trimmed = finishedCLIOutput(result.text, includeLanguageContract: includeLanguageContract)
            guard !trimmed.isEmpty else {
                devLog(.cliResponse, "Persistent session streaming returned empty, falling back")
                return nil
            }
            devLog(.cliResponse, "Persistent session streaming response (\(trimmed.count) chars)")
            return trimmed
        } catch {
            devLog(.cliExecution, "Persistent session streaming failed: \(error.localizedDescription), falling back")
            persistentSessionLock.lock()
            persistentSession?.kill()
            persistentSession = nil
            persistentSessionLock.unlock()
            return nil
        }
    }

    func resolveCLIPath(provider: CLIProvider, preferredPath: String?) throws -> String {
        if let preferredPath, isExecutable(preferredPath) {
            return preferredPath
        }

        discoveredPathLock.lock()
        if let cached = discoveredCLIPaths[provider], isExecutable(cached) {
            discoveredPathLock.unlock()
            return cached
        }
        discoveredPathLock.unlock()

        let searchPaths = ClaudeRuntimeSupport.cliSearchPaths(
            provider: provider,
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )

        for path in searchPaths where isExecutable(path) {
            cacheDiscoveredPath(path, provider: provider)
            return path
        }

        throw ShellRunnerError.cliNotFound(provider: provider)
    }

    func resolveClaudePath(preferredPath: String?) throws -> String {
        try resolveCLIPath(provider: .claude, preferredPath: preferredPath)
    }

    private func cacheDiscoveredPath(_ path: String, provider: CLIProvider) {
        discoveredPathLock.lock()
        discoveredCLIPaths[provider] = path
        discoveredPathLock.unlock()
    }

    private func isExecutable(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    private func runCLI(
        provider: CLIProvider,
        executablePath: String,
        model: String,
        prompt: String,
        timeoutSeconds: Int
    ) throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            return try runCLIDirect(
                provider: provider,
                executablePath: executablePath,
                model: trimmedModel,
                prompt: prompt,
                timeoutSeconds: timeoutSeconds
            )
        } catch let error as ShellRunnerError {
            // Some CLI versions reject aliases like "haiku". Retry once with default model.
            if case .processFailed = error, !trimmedModel.isEmpty {
                devLog(.cliExecution, "CLI failed with model '\(trimmedModel)', retrying without model flag")
                return try runCLIDirect(
                    provider: provider,
                    executablePath: executablePath,
                    model: "",
                    prompt: prompt,
                    timeoutSeconds: timeoutSeconds
                )
            }
            throw error
        }
    }

    private func runCLIDirect(
        provider: CLIProvider,
        executablePath: String,
        model: String,
        prompt: String,
        timeoutSeconds: Int
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = configManager.baseDirectoryURL
        let args = try ClaudeRuntimeSupport.cliArguments(
            provider: provider,
            prompt: prompt,
            model: model
        )
        process.arguments = args

        devLog(.cliExecution, "$ \(executablePath) \(args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")

        var runtimeEnvironment = environment
        runtimeEnvironment["PATH"] = ClaudeRuntimeSupport.runtimePathValue(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        // Remove CLAUDECODE env var to prevent "nested session" errors when
        // GhostEdit is launched from within a Claude Code terminal session.
        runtimeEnvironment.removeValue(forKey: "CLAUDE_CODE")
        runtimeEnvironment.removeValue(forKey: "CLAUDECODE")
        process.environment = runtimeEnvironment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            devLog(.cliExecution, "Failed to launch process: \(error.localizedDescription)")
            throw ShellRunnerError.launchFailed(error.localizedDescription)
        }

        if completion.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            process.terminate()
            _ = completion.wait(timeout: .now() + .seconds(2))
            devLog(.cliExecution, "Process timed out after \(timeoutSeconds)s")
            throw ShellRunnerError.timedOut(seconds: timeoutSeconds)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        devLog(.cliExecution, "Process exited with code \(process.terminationStatus)")
        if !errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            devLog(.cliExecution, "stderr: \(DeveloperModeSupport.truncate(errorText))")
        }

        guard process.terminationStatus == 0 else {
            throw ClaudeRuntimeSupport.classifyProcessFailure(
                provider: provider,
                exitCode: process.terminationStatus,
                stdout: outputText,
                stderr: errorText
            )
        }

        return outputText
    }

    private func runCLIStreaming(
        provider: CLIProvider,
        executablePath: String,
        model: String,
        prompt: String,
        timeoutSeconds: Int,
        onChunk: @escaping (String) -> Void
    ) throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = configManager.baseDirectoryURL
        let args = try ClaudeRuntimeSupport.cliArguments(
            provider: provider,
            prompt: prompt,
            model: trimmedModel
        )
        process.arguments = args

        var runtimeEnvironment = environment
        runtimeEnvironment["PATH"] = ClaudeRuntimeSupport.runtimePathValue(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        runtimeEnvironment.removeValue(forKey: "CLAUDE_CODE")
        runtimeEnvironment.removeValue(forKey: "CLAUDECODE")
        process.environment = runtimeEnvironment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var accumulatedOutput = ""
        let outputLock = NSLock()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            outputLock.lock()
            accumulatedOutput += chunk
            let snapshot = accumulatedOutput
            outputLock.unlock()
            DispatchQueue.main.async {
                onChunk(snapshot)
            }
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            devLog(.cliExecution, "Failed to launch process: \(error.localizedDescription)")
            throw ShellRunnerError.launchFailed(error.localizedDescription)
        }

        if completion.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            _ = completion.wait(timeout: .now() + .seconds(2))
            devLog(.cliExecution, "Process timed out after \(timeoutSeconds)s")
            throw ShellRunnerError.timedOut(seconds: timeoutSeconds)
        }

        // Drain any data that arrived between the handler being cleared and now.
        let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let remaining = String(decoding: remainingData, as: UTF8.self)
        outputLock.lock()
        accumulatedOutput += remaining
        outputLock.unlock()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ClaudeRuntimeSupport.classifyProcessFailure(
                provider: provider,
                exitCode: process.terminationStatus,
                stdout: accumulatedOutput,
                stderr: errorText
            )
        }

        return accumulatedOutput
    }

    private func preparedPrompt(
        systemPrompt: String,
        selectedText: String,
        language: String,
        includeLanguageContract: Bool
    ) -> String {
        let system = AppConfig.correctionSystemPrompt(
            systemPrompt: systemPrompt,
            language: language,
            includeLanguageContract: includeLanguageContract
        )
        let body = includeLanguageContract ? Self.taggedSelectedText(selectedText) : selectedText
        return "\(system)\n\n\(body)"
    }

    private func finishedCLIOutput(_ text: String, includeLanguageContract: Bool) -> String {
        let source = includeLanguageContract ? Self.correctionOnly(in: text) : text
        return Self.trimPreservingInternalNewlines(source)
    }

    static func delimitedCorrection(in text: String) -> String? {
        let startMarker = "<<<TEXT>>>"
        let endMarker = "<<<END>>>"
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Keeps the corrected text and drops labels, fences, and explanations.
    static func correctionOnly(in text: String) -> String {
        let withoutThinking = stripThinkingResidue(text)
        return trimEdges(stripIrrelevant(stripThinkingResidue(extractDelimited(strippingSelectedTags(withoutThinking)))))
    }

    /// Isolates the selection so a switch inside it stays data, not an instruction.
    static func taggedSelectedText(_ text: String) -> String {
        "<selected>\n\(text)\n</selected>"
    }

    static func strippingSelectedTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<selected>", with: "")
            .replacingOccurrences(of: "</selected>", with: "")
    }

    /// qwen appends `/no_think` on the correction line and may wrap reasoning in `<think>`.
    static func stripThinkingResidue(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>", options: .caseInsensitive) {
            if let end = result.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound...)
                break
            }
        }
        result = result.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        return result.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { strippingThinkSwitch(String($0)) }
            .joined(separator: "\n")
    }

    private static func strippingThinkSwitch(_ line: String) -> String {
        var core = Substring(line)
        while let last = core.last, last == " " || last == "\t" {
            core = core.dropLast()
        }
        for suffix in ["/no_think", "/think"] {
            guard core.hasSuffix(suffix) else { continue }
            let prefix = core.dropLast(suffix.count)
            if suffix == "/think", let previous = prefix.last, previous != " " && previous != "\t" {
                continue
            }
            var kept = prefix
            while let last = kept.last, last == " " || last == "\t" {
                kept = kept.dropLast()
            }
            return String(kept)
        }
        return line
    }

    static func trimEdges(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return ""
        }
        var relevant = Array(lines[first...last])
        relevant[0] = Substring(relevant[0].drop(while: { $0 == " " || $0 == "\t" }))
        let lastIdx = relevant.count - 1
        relevant[lastIdx] = Substring(relevant[lastIdx].replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression
        ))
        return relevant.joined(separator: "\n")
    }

    static func extractDelimited(_ text: String) -> String {
        let startMarker = "<<<TEXT>>>"
        let endMarker = "<<<END>>>"
        if let start = text.range(of: startMarker) {
            let afterStart = text[start.upperBound...]
            if let end = afterStart.range(of: endMarker) {
                return String(afterStart[..<end.lowerBound])
            }
            return String(afterStart)
        }
        if text.range(of: endMarker) != nil {
            return ""
        }
        return text
    }

    static func stripIrrelevant(_ text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        lines = dropContractEcho(lines)
        lines = dropLeadingLabels(lines)
        lines = unwrapMarkdownFence(lines)
        if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines[index] = stripInlinePrefix(from: lines[index])
        }
        return lines.joined(separator: "\n")
    }

    static func dropContractEcho(_ lines: [String]) -> [String] {
        lines.filter { !isContractEcho($0) }
    }

    static func isContractEcho(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed == "<<<TEXT>>>" || trimmed == "<<<END>>>" { return true }
        let patterns = [
            #"^Output language: .+\.?$"#,
            #"^This overrides any instruction to preserve the original language\.?$"#,
            #"^Detect the language of the input and correct it in that same language\. Do not translate\.?$"#,
            #"^Output format:?$"#,
            #"^Return exactly one block and nothing else\.?$"#,
            #"^final text only$"#,
            #"^Do not add a title, label, quotes, or explanation outside the block\.?$"#,
            #"^Preserve line breaks, blank lines, and paragraph spacing inside the block\.?$"#,
            #"^If the input is already in .+, correct it and keep it in .+\.?$"#,
            #"^If the input is not in .+, translate it into .+\. Do not leave any sentence in another language\.?$"#,
            #"^If the input is already in .+, correct it and keep it in .+\. If the input is not in .+, translate it into .+\. Do not leave any sentence in another language\.?$"#,
            #"^Target language: .+\. Keep text already in .+\. Translate every other sentence into .+\.?$"#,
            #"^Target language: .+\. Translate the user text into .+\. If it is already .+, correct the grammar\. Do not return the original language\.?$"#,
            #"^Keep the input language\. Do not translate\.?$"#,
            #"^Put the result between the markers\. Do not copy these instructions\.?$"#,
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    static func dropLeadingLabels(_ lines: [String]) -> [String] {
        var lines = lines
        while true {
            guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                return lines
            }
            guard isLeadingLabel(lines[firstIndex]) else { return lines }
            let rest = Array(lines[(firstIndex + 1)...])
            guard rest.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return lines }
            lines = rest
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
    }

    static func unwrapMarkdownFence(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              first < last else {
            return lines
        }
        let open = lines[first].trimmingCharacters(in: .whitespaces)
        let close = lines[last].trimmingCharacters(in: .whitespaces)
        guard open.hasPrefix("```"), close == "```" else { return lines }
        return Array(lines[(first + 1)..<last])
    }

    static func isLeadingLabel(_ line: String) -> Bool {
        let normalized = normalizedLabel(line)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":：.。 "))
            .lowercased()
        guard !normalized.isEmpty, normalized.count <= 40 else { return false }
        return [
            "here is the corrected text", "here's the corrected text",
            "here is the correction", "here's the correction",
            "here is the translation", "here's the translation",
            "here is the result", "corrected text", "corrected version",
            "correction", "translation", "translated text", "final text", "output",
            "改正如下", "修正如下", "纠正如下", "翻译如下", "输出如下",
        ].contains(normalized)
    }

    static func normalizedLabel(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        if text.hasPrefix("#") {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func stripInlinePrefix(from line: String) -> String {
        let prefixes = [
            "here's the corrected text:", "here is the corrected text:",
            "here's the correction:", "here is the correction:",
            "here's the translation:", "here is the translation:",
            "corrected text:", "corrected version:", "correction:", "translation:",
            "改正如下：", "修正如下：", "纠正如下：", "翻译如下：", "输出如下：",
            "以下是修正后的文本：", "以下是改正后的文本：", "以下是翻译：", "以下是修正：", "以下是改正：",
        ]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for prefix in prefixes {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return String(rest) }
        }
        return line
    }

    /// Trims leading/trailing whitespace and newlines from the CLI output
    /// but preserves all internal blank lines and paragraph structure.
    /// Matches the newline pattern of the input text when possible.
    static func trimPreservingInternalNewlines(_ text: String) -> String {
        // Drop leading blank lines/spaces and trailing blank lines/spaces
        // but keep all internal newlines intact.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        // Find first and last non-blank lines
        guard let firstNonBlank = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let lastNonBlank = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return ""
        }

        var relevantLines = Array(lines[firstNonBlank...lastNonBlank])
        // Trim leading/trailing whitespace on the boundary lines only
        relevantLines[0] = Substring(relevantLines[0].drop(while: { $0 == " " || $0 == "\t" }))
        let lastIdx = relevantLines.count - 1
        let trimmedLast = relevantLines[lastIdx].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        relevantLines[lastIdx] = Substring(trimmedLast)
        var result = relevantLines.joined(separator: "\n")
        // Strip em dashes (\u{2014}) that models tend to insert
        result = result.replacingOccurrences(of: "\u{2014}", with: "")
        // Collapse any double spaces left behind after removal
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    private func devLog(_ phase: DeveloperModeLogEntry.Phase, _ message: String) {
        developerModeLogger?.log(DeveloperModeLogEntry(phase: phase, message: message))
    }
}
