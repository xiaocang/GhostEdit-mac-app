import XCTest
@testable import GhostEditCore

final class ShellRunnerTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for root in tempRoots {
            try? fileManager.removeItem(at: root)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testOllamaPreservingPipelinesUseHTTPDespiteReadyClaudeSession() throws {
        let testEnv = try makeRunnerEnvironment()
        let (url, configuration) = OllamaURLProtocol.stub { stub in
            let payload = try stub.requestJSON()
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertTrue(messages[0]["content"]?.contains("Translate the user text into French") == true)
            XCTAssertTrue(messages[0]["content"]?.contains("<<<TEXT>>>") == true)
            XCTAssertTrue(messages[0]["content"]?.contains("GHOSTEDIT_KEEP") == true)
            XCTAssertTrue(messages[1]["content"]?.contains("__GHOSTEDIT_KEEP_0__") == true)
            XCTAssertEqual(payload["model"] as? String, "qwen3:0.6b")
            let text = "Bonjour — __GHOSTEDIT_KEEP_0__.\n\n    Bienvenue."
            let data = try JSONSerialization.data(withJSONObject: [
                "message": ["content": text], "done": true
            ])
            stub.respond(chunks: [data])
        }
        var config = AppConfig.default.withProvider(.ollama, executablePath: "", model: "qwen3:0.6b")
        config.ollamaBaseURL = url
        config.language = "fr"
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: configuration)
        let stale = MockPersistentCLISession()
        stale.mockIsReady = true
        stale.mockSendResult = PersistentCLISession.StreamResult(text: "wrong Claude output")
        stale.mockStreamResult = PersistentCLISession.StreamResult(text: "wrong Claude output")
        runner.setPersistentSessionForTesting(stale)
        let expected = "Bonjour — @Chema.\n\n    Bienvenue."
        XCTAssertEqual(try runner.correctTextPreservingTokens(systemPrompt: "Fix", selectedText: "hello @Chema"), expected)
        let delivered = expectation(description: "restored streaming callback")
        XCTAssertEqual(try runner.correctTextStreamingPreservingTokens(
            systemPrompt: "Fix", selectedText: "hello @Chema", onChunk: { text in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(text, expected)
                delivered.fulfill()
            }), expected)
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(stale.sendCallCount, 0)
        XCTAssertEqual(stale.streamCallCount, 0)
    }

    func testMagpieCorrectionsUseTheLocalGateway() throws {
        let testEnv = try makeRunnerEnvironment()
        let (url, configuration) = OllamaURLProtocol.stub { stub in
            XCTAssertEqual(stub.request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(stub.request.value(forHTTPHeaderField: "Authorization"), "Bearer magpie")
            let payload = try stub.requestJSON()
            XCTAssertEqual(payload["model"] as? String, "claude/claude-haiku-4-5")
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "corrected"]]]
            ])
            stub.respond(chunks: [data])
        }
        var config = AppConfig.default.withProvider(.magpie, executablePath: "", model: "claude/claude-haiku-4-5")
        config.magpieBaseURL = url
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: configuration)
        XCTAssertEqual(try runner.correctText(systemPrompt: "Fix", selectedText: "text"), "corrected")
    }

    func testOllamaStripsTheFencedCorrectionAndLeavesUnfencedTextAlone() throws {
        let fenced = OllamaURLProtocol.stub { stub in
            stub.respond(chunks: [Data(#"{"message":{"content":"notes\n<<<TEXT>>>\nHello — there\n<<<END>>>\nbye"},"done":true}"#.utf8)])
        }
        let testEnv = try makeRunnerEnvironment()
        var config = AppConfig.default.withProvider(.ollama, executablePath: "", model: "qwen3:0.6b")
        config.ollamaBaseURL = fenced.0
        config.language = "en"
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: fenced.1)
        XCTAssertEqual(try runner.correctText(systemPrompt: "Fix", selectedText: "原文"), "Hello — there")

        let raw = OllamaURLProtocol.stub { stub in
            stub.respond(chunks: [Data(#"{"message":{"content":"Bonjour — kept"},"done":true}"#.utf8)])
        }
        config.ollamaBaseURL = raw.0
        try testEnv.manager.saveConfig(config)
        let rawRunner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                    ollamaSessionConfiguration: raw.1)
        XCTAssertEqual(
            try rawRunner.correctText(systemPrompt: "Return JSON", selectedText: "samples", includeLanguageContract: false),
            "Bonjour — kept"
        )
    }

    func testOllamaSendsTheSelectedTextAndDemandsEnglishInTheSystemPrompt() throws {
        let source = "大家如果有需要其他组同事周末在线的，share一下 名字"
        let stub = OllamaURLProtocol.stub { stub in
            let payload = try stub.requestJSON()
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            let system = try XCTUnwrap(messages[0]["content"])
            XCTAssertTrue(system.contains("Target language: English. Translate the user text into English. If it is already English, correct the grammar. Do not return the original language."))
            XCTAssertTrue(system.contains("<<<TEXT>>>"))
            XCTAssertEqual(messages[1]["content"], "<selected>\n\(source)\n</selected>")
            stub.respond(chunks: [Data(#"{"message":{"content":"If anyone needs colleagues online this weekend, share the name."},"done":true}"#.utf8)])
        }
        let testEnv = try makeRunnerEnvironment()
        var config = AppConfig.default.withProvider(.ollama, executablePath: "", model: "qwen3:1.7b")
        config.ollamaBaseURL = stub.0
        config.language = "en"
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: stub.1)
        XCTAssertEqual(
            try runner.correctText(systemPrompt: "Fix", selectedText: source),
            "If anyone needs colleagues online this weekend, share the name."
        )
    }
    func testOllamaSendsAModelSwitchInsideTheSelectedTag() throws {
        let source = "历史里改正结果同一行末尾还挂着 /no_think。整行过滤抓不到，我把它从正文里剥掉。"
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "<selected>\nIn history, the line still says /no_think.\n</selected> /no_think"),
            "In history, the line still says /no_think."
        )
        let stub = OllamaURLProtocol.stub { stub in
            let payload = try stub.requestJSON()
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], "<selected>\n\(source)\n</selected>")
            XCTAssertFalse(messages[1]["content"]?.contains("NO_THINK") == true)
            stub.respond(chunks: [Data(#"{"message":{"content":"<selected>\nIn history, the line still says /no_think.\n</selected>"},"done":true}"#.utf8)])
        }
        let testEnv = try makeRunnerEnvironment()
        var config = AppConfig.default.withProvider(.ollama, executablePath: "", model: "qwen3:1.7b")
        config.ollamaBaseURL = stub.0
        config.language = "en"
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: stub.1)
        XCTAssertEqual(
            try runner.correctText(systemPrompt: "Fix", selectedText: source),
            "In history, the line still says /no_think."
        )
    }


    func testOllamaRejectsAnEmptyFencedCorrection() throws {
        let stub = OllamaURLProtocol.stub { stub in
            stub.respond(chunks: [Data(#"{"message":{"content":"notes\n<<<TEXT>>>\n\n<<<END>>>\nbye"},"done":true}"#.utf8)])
        }
        let testEnv = try makeRunnerEnvironment()
        var config = AppConfig.default.withProvider(.ollama, executablePath: "", model: "qwen3:0.6b")
        config.ollamaBaseURL = stub.0
        try testEnv.manager.saveConfig(config)
        let runner = ShellRunner(configManager: testEnv.manager, environment: [:],
                                 ollamaSessionConfiguration: stub.1)
        XCTAssertThrowsError(try runner.correctText(systemPrompt: "Fix", selectedText: "原文")) { error in
            guard case ShellRunnerError.emptyResponse = error else {
                XCTFail("Expected emptyResponse, got \(error)")
                return
            }
        }
    }

    func testNonClaudeProvidersNeverUseReadyClaudeSession() throws {
        for provider in [CLIProvider.gemini, .codex] {
            let testEnv = try makeRunnerEnvironment()
            let executable = try makeExecutableScript(
                named: "non-claude.sh", contents: "#!/bin/zsh\nprint -r -- 'non-Claude response'",
                homeURL: testEnv.homeURL)
            try testEnv.manager.saveConfig(
                AppConfig.default.withProvider(provider, executablePath: executable.path))
            let stale = MockPersistentCLISession()
            stale.mockIsReady = true
            stale.mockSendResult = PersistentCLISession.StreamResult(text: "wrong provider")
            stale.mockStreamResult = PersistentCLISession.StreamResult(text: "wrong provider")
            testEnv.runner.setPersistentSessionForTesting(stale)
            XCTAssertEqual(try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "text"), "non-Claude response")
            XCTAssertEqual(try testEnv.runner.correctTextStreaming(
                systemPrompt: "Fix", selectedText: "text", onChunk: { _ in }), "non-Claude response")
            XCTAssertEqual(stale.sendCallCount, 0)
            XCTAssertEqual(stale.streamCallCount, 0)
        }
    }

    func testCorrectTextStripsClaudeCodeEnvironmentVariables() throws {
        let testEnv = try makeRunnerEnvironment()
        let envLog = testEnv.homeURL.appendingPathComponent("env.log")

        let script = """
        #!/bin/zsh
        env > '\(envLog.path)'
        print -r -- "ok"
        """

        let executable = try makeExecutableScript(named: "claude-env-check.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        // Create a new runner with CLAUDECODE and CLAUDE_CODE set in the environment.
        let injectedEnv = [
            "CLAUDECODE": "1",
            "CLAUDE_CODE": "1",
            "HOME": testEnv.homeURL.path,
        ]
        let runner = ShellRunner(
            configManager: testEnv.manager,
            environment: injectedEnv,
            homeDirectoryPath: testEnv.homeURL.path
        )

        let output = try runner.correctText(systemPrompt: "p", selectedText: "x")
        XCTAssertEqual(output, "ok")

        let envOutput = try String(contentsOf: envLog, encoding: .utf8)
        XCTAssertFalse(envOutput.contains("CLAUDECODE="), "CLAUDECODE should be stripped from the child process environment")
        XCTAssertFalse(envOutput.contains("CLAUDE_CODE="), "CLAUDE_CODE should be stripped from the child process environment")
    }

    func testCorrectTextPassesExpectedArgumentsAndWorkingDirectoryForClaude() throws {
        let testEnv = try makeRunnerEnvironment()
        let argsLog = testEnv.homeURL.appendingPathComponent("args.log")
        let pwdLog = testEnv.homeURL.appendingPathComponent("pwd.log")

        let script = """
        #!/bin/zsh
        pwd > '\(pwdLog.path)'
        printf '%s\\0' "$@" > '\(argsLog.path)'
        print -r -- "   corrected text   "
        """

        let executable = try makeExecutableScript(named: "claude-ok.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctText(
            systemPrompt: "Fix grammar",
            selectedText: "this are wrong"
        )

        XCTAssertEqual(output, "corrected text")

        let argsData = try Data(contentsOf: argsLog)
        let args = decodeNullSeparatedArguments(from: argsData)
        XCTAssertEqual(args[0], "-p")
        XCTAssertTrue(args[1].hasPrefix("Fix grammar"))
        XCTAssertTrue(args[1].hasSuffix("\n\n<selected>\nthis are wrong\n</selected>"))
        XCTAssertEqual(args[2], "--setting-sources")
        XCTAssertEqual(args[3], "user")
        XCTAssertEqual(args[4], "--tools")
        XCTAssertEqual(args[5], "")
        XCTAssertEqual(args[6], "--model")
        XCTAssertEqual(args[7], "haiku")

        let workingDirectory = try String(contentsOf: pwdLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path,
            testEnv.manager.baseDirectoryURL.resolvingSymlinksInPath().path
        )
    }

    func testCorrectTextPassesExpectedArgumentsForCodex() throws {
        let testEnv = try makeRunnerEnvironment()
        let argsLog = testEnv.homeURL.appendingPathComponent("codex-args.log")

        let script = """
        #!/bin/zsh
        printf '%s\\0' "$@" > '\(argsLog.path)'
        print -r -- "codex corrected"
        """

        let executable = try makeExecutableScript(named: "codex-ok.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.codex, executablePath: executable.path, model: "gpt-5-codex")
        )

        let output = try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        XCTAssertEqual(output, "codex corrected")

        let argsData = try Data(contentsOf: argsLog)
        let args = decodeNullSeparatedArguments(from: argsData)
        XCTAssertEqual(args[0], "exec")
        XCTAssertEqual(args[1], "--skip-git-repo-check")
        XCTAssertEqual(args[2], "--sandbox")
        XCTAssertEqual(args[3], "read-only")
        XCTAssertEqual(args[4], "-c")
        XCTAssertEqual(args[5], "model_reasoning_effort='low'")
        XCTAssertEqual(args[6], "--model")
        XCTAssertEqual(args[7], "gpt-5-codex")
        XCTAssertTrue(args[8].hasPrefix("p"))
        XCTAssertTrue(args[8].hasSuffix("\n\n<selected>\nx\n</selected>"))
    }

    func testCorrectTextPassesExpectedArgumentsForGemini() throws {
        let testEnv = try makeRunnerEnvironment()
        let argsLog = testEnv.homeURL.appendingPathComponent("gemini-args.log")

        let script = """
        #!/bin/zsh
        printf '%s\\0' "$@" > '\(argsLog.path)'
        print -r -- "gemini corrected"
        """

        let executable = try makeExecutableScript(named: "gemini-ok.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.gemini, executablePath: executable.path, model: "gemini-2.5-flash")
        )

        let output = try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        XCTAssertEqual(output, "gemini corrected")

        let argsData = try Data(contentsOf: argsLog)
        let args = decodeNullSeparatedArguments(from: argsData)
        XCTAssertEqual(args[0], "--prompt")
        XCTAssertTrue(args[1].hasPrefix("p"))
        XCTAssertTrue(args[1].hasSuffix("\n\n<selected>\nx\n</selected>"))
        XCTAssertEqual(args[2], "--output-format")
        XCTAssertEqual(args[3], "text")
        XCTAssertEqual(args[4], "--model")
        XCTAssertEqual(args[5], "gemini-2.5-flash")
    }

    func testCorrectTextPreservingTokensFallsBackToNormalFlowWhenNoProtectedTokens() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "plain corrected text"
        """
        let executable = try makeExecutableScript(named: "plain-correct.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "this are plain text"
        )
        XCTAssertEqual(output, "plain corrected text")
    }

    func testCorrectTextPreservingTokensRestoresMentionsAndEmoji() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Please check with __GHOSTEDIT_KEEP_0__ and then add __GHOSTEDIT_KEEP_1__."
        """
        let executable = try makeExecutableScript(named: "preserve-tokens.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "pls check with @<U123ABC> and add :hat:"
        )
        XCTAssertEqual(output, "Please check with @<U123ABC> and then add :hat:.")
    }

    func testCorrectTextPreservingTokensRestoresAtNameAndFilePath() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Please ask __GHOSTEDIT_KEEP_0__ to review __GHOSTEDIT_KEEP_1__."
        """
        let executable = try makeExecutableScript(named: "preserve-static.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "pls ask @naresh to review /tmp/report.txt"
        )
        XCTAssertEqual(output, "Please ask @naresh to review /tmp/report.txt.")
    }

    func testCorrectTextPreservingTokensRetriesOnceWhenPlaceholderMissing() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("token-retry.log")
        let script = """
        #!/bin/zsh
        count=0
        if [[ -f '\(callsLog.path)' ]]; then
          count=$(cat '\(callsLog.path)')
        fi
        count=$((count + 1))
        print -r -- "$count" > '\(callsLog.path)'

        if [[ "$count" -eq 1 ]]; then
          print -r -- "First pass forgot placeholder."
        else
          print -r -- "Second pass keeps __GHOSTEDIT_KEEP_0__."
        fi
        """
        let executable = try makeExecutableScript(named: "preserve-retry.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello @<U99>"
        )
        XCTAssertEqual(output, "Second pass keeps @<U99>.")
        let attempts = try String(contentsOf: callsLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(attempts, "2")
    }

    func testCorrectTextPreservingTokensRetryPreservesEmojisWithOriginalText() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("token-aware.log")
        // With maxValidationRetries: 0:
        //   Call 1: placeholder attempt - AI strips placeholders.
        //   Call 2: token-aware retry with original text - AI preserves emojis.
        let script = """
        #!/bin/zsh
        count=0
        if [[ -f '\(callsLog.path)' ]]; then
          count=$(cat '\(callsLog.path)')
        fi
        count=$((count + 1))
        print -r -- "$count" > '\(callsLog.path)'

        if [[ "$count" -le 1 ]]; then
          print -r -- "Placeholders stripped by AI."
        else
          print -r -- "Hello :sad: and :mad: about the delay."
        fi
        """
        let executable = try makeExecutableScript(named: "token-aware.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello :sad: and :mad: about the delay",
            maxValidationRetries: 0
        )
        XCTAssertEqual(result, "Hello :sad: and :mad: about the delay.")
    }

    func testCorrectTextPreservingTokensRetryPreservesAllTokenTypes() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("token-types.log")
        let script = """
        #!/bin/zsh
        count=0
        if [[ -f '\(callsLog.path)' ]]; then
          count=$(cat '\(callsLog.path)')
        fi
        count=$((count + 1))
        print -r -- "$count" > '\(callsLog.path)'

        if [[ "$count" -le 1 ]]; then
          print -r -- "Stripped all placeholders."
        else
          print -r -- "Please ask @naresh about :hat: at /tmp/report.txt."
        fi
        """
        let executable = try makeExecutableScript(named: "token-types.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "pls ask @naresh about :hat: at /tmp/report.txt",
            maxValidationRetries: 0
        )
        XCTAssertEqual(result, "Please ask @naresh about :hat: at /tmp/report.txt.")
    }

    func testCorrectTextPreservingTokensFallsBackToBestEffortWhenRetryAlsoFails() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("both-fail.log")
        // Both placeholder and token-aware retry return text without tokens.
        let script = """
        #!/bin/zsh
        count=0
        if [[ -f '\(callsLog.path)' ]]; then
          count=$(cat '\(callsLog.path)')
        fi
        count=$((count + 1))
        print -r -- "$count" > '\(callsLog.path)'

        if [[ "$count" -le 1 ]]; then
          print -r -- "Completely rewritten text."
        else
          print -r -- "Totally different output."
        fi
        """
        let executable = try makeExecutableScript(named: "both-fail.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        // When the token-aware retry also loses tokens, falls back to best-effort.
        let result = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello :wave: world",
            maxValidationRetries: 0
        )
        // bestEffortRestore on "Completely rewritten text." - no placeholders survive.
        XCTAssertEqual(result, "Completely rewritten text.")
    }

    func testCorrectTextPreservingTokensRestoresPartialSurvivors() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("partial.log")
        // Call 1: AI keeps placeholder 0 but strips placeholder 1.
        // Call 2: token-aware retry - only one of two tokens survives.
        let script = """
        #!/bin/zsh
        count=0
        if [[ -f '\(callsLog.path)' ]]; then
          count=$(cat '\(callsLog.path)')
        fi
        count=$((count + 1))
        print -r -- "$count" > '\(callsLog.path)'

        if [[ "$count" -le 1 ]]; then
          print -r -- "Hello __GHOSTEDIT_KEEP_0__ world."
        else
          print -r -- "Hello @<U1> world without emoji."
        fi
        """
        let executable = try makeExecutableScript(named: "preserve-partial.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello @<U1> :sad:",
            maxValidationRetries: 0
        )
        // Token-aware retry has @<U1> but not :sad: → allSatisfy fails.
        // Falls back to best-effort on placeholder attempt: @<U1> restored, :sad: lost.
        XCTAssertEqual(result, "Hello @<U1> world.")
    }

    // MARK: - correctTextStreamingPreservingTokens

    func testCorrectTextStreamingPreservingTokensPassthroughWhenNoTokens() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Plain corrected text."
        """
        let executable = try makeExecutableScript(named: "stream-plain.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextStreamingPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "plain text no tokens",
            onChunk: { _ in }
        )
        XCTAssertEqual(result, "Plain corrected text.")
    }

    func testCorrectTextStreamingPreservingTokensRestoresPlaceholders() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Hello __GHOSTEDIT_KEEP_0__ and __GHOSTEDIT_KEEP_1__."
        """
        let executable = try makeExecutableScript(named: "stream-tokens.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        var chunkSnapshots: [String] = []
        let result = try testEnv.runner.correctTextStreamingPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello @<U123> and :wave:",
            onChunk: { snapshot in
                chunkSnapshots.append(snapshot)
            }
        )
        XCTAssertEqual(result, "Hello @<U123> and :wave:.")
    }

    func testCorrectTextStreamingPreservingTokensBestEffortOnPartialLoss() throws {
        let testEnv = try makeRunnerEnvironment()
        // AI keeps placeholder 0 but removes placeholder 1
        let script = """
        #!/bin/zsh
        print -r -- "Hello __GHOSTEDIT_KEEP_0__ world."
        """
        let executable = try makeExecutableScript(named: "stream-partial.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextStreamingPreservingTokens(
            systemPrompt: "Fix grammar",
            selectedText: "hello @<U1> :sad:",
            onChunk: { _ in }
        )
        // bestEffortRestore: @<U1> restored, :sad: placeholder missing → lost
        XCTAssertEqual(result, "Hello @<U1> world.")
    }

    func testCorrectTextClassifiesAuthenticationErrorFromStdout() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- 'Failed to authenticate. API Error: 401 {"error":{"message":"OAuth token has expired"}}'
        exit 1
        """

        let executable = try makeExecutableScript(named: "cli-auth-stdout.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path)
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.authenticationRequired(provider) = error else {
                return XCTFail("Expected authenticationRequired, got: \(error)")
            }
            XCTAssertEqual(provider, .claude)
        }
    }

    func testCorrectTextClassifiesAuthenticationErrorFromStderr() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- 'please run codex login' >&2
        exit 1
        """

        let executable = try makeExecutableScript(named: "cli-auth-stderr.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.codex, executablePath: executable.path)
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.authenticationRequired(provider) = error else {
                return XCTFail("Expected authenticationRequired, got: \(error)")
            }
            XCTAssertEqual(provider, .codex)
        }
    }

    func testCorrectTextFallsBackWithoutModelWhenModelFails() throws {
        let testEnv = try makeRunnerEnvironment()
        let callsLog = testEnv.homeURL.appendingPathComponent("calls.log")

        let script = """
        #!/bin/zsh
        print -r -- "CALL" >> '\(callsLog.path)'
        for arg in "$@"; do
          print -r -- "$arg" >> '\(callsLog.path)'
        done
        print -r -- "---" >> '\(callsLog.path)'

        if [[ " $* " == *" --model "* ]]; then
          print -r -- "unsupported model" >&2
          exit 7
        fi

        print -r -- "fallback ok"
        """

        let executable = try makeExecutableScript(named: "cli-fallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "custom-model")
        )

        let output = try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        XCTAssertEqual(output, "fallback ok")

        let calls = try String(contentsOf: callsLog, encoding: .utf8)
        let callCount = calls.components(separatedBy: "CALL").count - 1
        XCTAssertEqual(callCount, 2)
        XCTAssertTrue(calls.contains("--model"))
    }

    func testCorrectTextUsesStdoutDetailsWhenStderrIsEmpty() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- 'detailed failure message'
        exit 2
        """

        let executable = try makeExecutableScript(named: "cli-failure-stdout.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.gemini, executablePath: executable.path)
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.processFailed(exitCode, stderr) = error else {
                return XCTFail("Expected processFailed, got: \(error)")
            }
            XCTAssertEqual(exitCode, 2)
            XCTAssertTrue(stderr.contains("detailed failure message"))
        }
    }

    func testCorrectTextThrowsEmptyResponseWhenCLIReturnsWhitespace() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- '   '
        exit 0
        """

        let executable = try makeExecutableScript(named: "cli-empty.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.codex, executablePath: executable.path, model: "")
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case ShellRunnerError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got: \(error)")
            }
        }
    }

    func testResolveCLIPathSearchesAndCachesDiscoveredPath() throws {
        let (homeURL, manager, _) = try makeRunnerEnvironment()
        let discoveredPath = "\(homeURL.path)/.local/bin/codex"
        let fileManager = StubExecutableFileManager(executablePaths: [discoveredPath])
        let runner = ShellRunner(
            configManager: manager,
            fileManager: fileManager,
            environment: ["PATH": "/custom/bin"],
            homeDirectoryPath: homeURL.path
        )

        let first = try runner.resolveCLIPath(provider: .codex, preferredPath: "/definitely/missing/codex")
        XCTAssertEqual(first, discoveredPath)
        let firstCallCount = fileManager.callCount

        let second = try runner.resolveCLIPath(provider: .codex, preferredPath: nil)
        XCTAssertEqual(second, discoveredPath)
        XCTAssertEqual(fileManager.callCount, firstCallCount + 1)
        XCTAssertEqual(fileManager.queriedPaths.last, discoveredPath)
    }

    func testResolveClaudePathWrapperUsesClaudeProvider() throws {
        let (homeURL, manager, _) = try makeRunnerEnvironment()
        let discoveredPath = "\(homeURL.path)/.local/bin/claude"
        let fileManager = StubExecutableFileManager(executablePaths: [discoveredPath])
        let runner = ShellRunner(
            configManager: manager,
            fileManager: fileManager,
            environment: [:],
            homeDirectoryPath: homeURL.path
        )

        XCTAssertEqual(try runner.resolveClaudePath(preferredPath: nil), discoveredPath)
    }

    func testResolveCLIPathThrowsNotFoundWhenNoExecutableExists() throws {
        let (homeURL, manager, _) = try makeRunnerEnvironment()
        let fileManager = StubExecutableFileManager(executablePaths: [])
        let runner = ShellRunner(
            configManager: manager,
            fileManager: fileManager,
            environment: [:],
            homeDirectoryPath: homeURL.path
        )

        XCTAssertThrowsError(
            try runner.resolveCLIPath(provider: .gemini, preferredPath: nil)
        ) { error in
            guard case let ShellRunnerError.cliNotFound(provider) = error else {
                return XCTFail("Expected cliNotFound, got: \(error)")
            }
            XCTAssertEqual(provider, .gemini)
        }
    }

    func testPrewarmAttemptsBackgroundPathResolution() throws {
        let (homeURL, manager, _) = try makeRunnerEnvironment()
        let discoveredPath = "\(homeURL.path)/.local/bin/gemini"
        let fileManager = StubExecutableFileManager(executablePaths: [discoveredPath])
        let runner = ShellRunner(
            configManager: manager,
            fileManager: fileManager,
            environment: [:],
            homeDirectoryPath: homeURL.path
        )

        try manager.saveConfig(
            AppConfig.default.withProvider(.gemini, executablePath: discoveredPath, model: "")
        )

        runner.prewarm()

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline && fileManager.callCount == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertGreaterThan(fileManager.callCount, 0)
        XCTAssertTrue(fileManager.queriedPaths.contains(discoveredPath))
    }

    func testCorrectTextThrowsLaunchFailedWhenExecutableCannotStart() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/no/such/interpreter
        print -r -- "won't run"
        """

        let executable = try makeExecutableScript(named: "cli-launch-fail.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path)
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.launchFailed(message) = error else {
                return XCTFail("Expected launchFailed, got: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testCorrectTextThrowsTimedOutWhenCLIHangs() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        sleep 6
        print -r -- "too late"
        """

        let executable = try makeExecutableScript(named: "cli-timeout.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(
                .gemini,
                executablePath: executable.path,
                model: "gemini-2.5-flash",
                timeoutSeconds: 1
            )
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.timedOut(seconds) = error else {
                return XCTFail("Expected timedOut, got: \(error)")
            }
            XCTAssertEqual(seconds, 5)
        }
    }

    func testCorrectTextHandlesInvalidUTF8OutputStreams() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        printf '\\377'
        printf '\\377' >&2
        exit 2
        """

        let executable = try makeExecutableScript(named: "cli-invalid-utf8.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.codex, executablePath: executable.path, model: "")
        )

        XCTAssertThrowsError(
            try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        ) { error in
            guard case let ShellRunnerError.processFailed(exitCode, stderr) = error else {
                return XCTFail("Expected processFailed, got: \(error)")
            }
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(stderr, "")
        }
    }

    func testShellRunnerErrorDescriptions() {
        XCTAssertEqual(
            ShellRunnerError.cliNotFound(provider: .claude).errorDescription,
            "The claude CLI could not be found. Set an absolute path in ~/.ghostedit/config.json or switch provider in Settings."
        )
        XCTAssertEqual(
            ShellRunnerError.authenticationRequired(provider: .codex).errorDescription,
            "Codex authentication has expired. Run `codex login` in Terminal, then try again."
        )
        XCTAssertEqual(
            ShellRunnerError.launchFailed("boom").errorDescription,
            "Failed to start CLI process: boom"
        )
        XCTAssertEqual(
            ShellRunnerError.processFailed(exitCode: 17, stderr: "details here").errorDescription,
            "CLI exited with code 17: details here\nTry switching the model in Settings if this model is busy or unavailable."
        )
        XCTAssertEqual(
            ShellRunnerError.processFailed(exitCode: 17, stderr: "   \n  ").errorDescription,
            "CLI exited with code 17. Try switching the model in Settings if the selected model is busy."
        )
        XCTAssertEqual(
            ShellRunnerError.timedOut(seconds: 8).errorDescription,
            "CLI timed out after 8 seconds. Try switching the model in Settings if the selected model is busy."
        )
        XCTAssertEqual(
            ShellRunnerError.emptyResponse.errorDescription,
            "CLI returned an empty response. Try switching the model in Settings."
        )
        XCTAssertEqual(
            ShellRunnerError.protectedTokensModified.errorDescription,
            "The AI response changed protected static tokens. Retried once, but placeholders were not preserved."
        )
    }

    private func makeRunnerEnvironment() throws -> (homeURL: URL, manager: ConfigManager, runner: ShellRunner) {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostedit-shellrunner-tests-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(homeURL)

        let manager = ConfigManager(fileManager: .default, homeDirectoryURL: homeURL)
        try manager.bootstrapIfNeeded()
        let runner = ShellRunner(configManager: manager)
        return (homeURL, manager, runner)
    }

    private func makeExecutableScript(named name: String, contents: String, homeURL: URL) throws -> URL {
        let scriptURL = homeURL.appendingPathComponent(name)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: - trimPreservingInternalNewlines

    func testTrimPreservingInternalNewlinesKeepsBlankLines() {
        let input = "Hello\n\nWorld\n\nGoodbye"
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "Hello\n\nWorld\n\nGoodbye")
    }

    func testTrimPreservingInternalNewlinesStripsLeadingTrailingBlanks() {
        let input = "\n\n  Hello\n\nWorld  \n\n"
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "Hello\n\nWorld")
    }

    func testTrimPreservingInternalNewlinesReturnsEmptyForBlankInput() {
        XCTAssertEqual(ShellRunner.trimPreservingInternalNewlines(""), "")
        XCTAssertEqual(ShellRunner.trimPreservingInternalNewlines("\n\n\n"), "")
        XCTAssertEqual(ShellRunner.trimPreservingInternalNewlines("   \n   "), "")
    }

    func testTrimPreservingInternalNewlinesMultipleBlankLines() {
        let input = "\nLine1\n\n\n\nLine2\n"
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "Line1\n\n\n\nLine2")
    }

    func testTrimPreservingInternalNewlinesSingleLine() {
        let input = "  just text  "
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "just text")
    }

    func testTrimPreservingInternalNewlinesStripsEmDash() {
        let input = "This is a sentence \u{2014} with an em dash."
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "This is a sentence with an em dash.")
    }

    func testDelimitedCorrectionRequiresBothMarkersInOrder() {
        XCTAssertNil(ShellRunner.delimitedCorrection(in: "plain text"))
        XCTAssertNil(ShellRunner.delimitedCorrection(in: "<<<TEXT>>> missing end"))
        XCTAssertNil(ShellRunner.delimitedCorrection(in: "<<<END>>> before <<<TEXT>>>"))
        XCTAssertEqual(
            ShellRunner.delimitedCorrection(in: "pre\n<<<TEXT>>>\nHi\n\nThere\n<<<END>>>\npost"),
            "\nHi\n\nThere\n"
        )
    }

    func testCorrectionOnlyDropsWrappersAndKeepsTheResult() {
        XCTAssertEqual(ShellRunner.correctionOnly(in: "任意前言\n<<<TEXT>>>\nHi\n<<<END>>>\n任意后记"), "Hi")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "ignore\n<<<TEXT>>>\nHi there"), "Hi there")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "Hi there\n<<<END>>>\npost"), "")
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "Target language: English. Translate the user text into English. If it is already English, correct the grammar. Do not return the original language.\nIf anyone needs colleagues online, share the name."),
            "If anyone needs colleagues online, share the name."
        )
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "get a green mark for this sentence /no_think"),
            "get a green mark for this sentence"
        )
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "Put that short line in /no_think"),
            "Put that short line in"
        )
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "<think>should translate</think>get a green mark for this sentence /no_think"),
            "get a green mark for this sentence"
        )
        XCTAssertEqual(ShellRunner.correctionOnly(in: "<think>a</think><think>b</think>Hi"), "Hi")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "Hi<think>secret"), "Hi")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "Hi</think>"), "Hi")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "fixed /think"), "fixed")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "see path/think"), "see path/think")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "keep /no_think please"), "keep /no_think please")
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "notes\n<<<TEXT>>>\nHi /no_think\n<<<END>>>\nbye"),
            "Hi"
        )
        XCTAssertEqual(ShellRunner.correctionOnly(in: "Hello\n\nThere"), "Hello\n\nThere")
        XCTAssertEqual(ShellRunner.correctionOnly(in: ""), "")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "\n\n"), "")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "Correction:"), "Correction:")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "**Corrected text:**\n\nHello"), "Hello")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "```text\nHello\n```"), "Hello")
        XCTAssertEqual(ShellRunner.correctionOnly(in: "改正如下：你好"), "你好")
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "Hello\n\nNote: keep this paragraph"),
            "Hello\n\nNote: keep this paragraph"
        )
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "I corrected text yesterday.\nLeave this."),
            "I corrected text yesterday.\nLeave this."
        )
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "以下是修正后的会议纪要。\n第二段。"),
            "以下是修正后的会议纪要。\n第二段。"
        )
        let echoed = """
        If the input is already in English, correct it and keep it in English. If the input is not in English, translate it into English. Do not leave any sentence in another language.

        Output language: English.
        This overrides any instruction to preserve the original language.

        <<<TEXT>>>
        If the input is already in English, correct it and keep it in English. If the input is not in English, translate it into English. Do not leave any sentence in another language.
        """
        XCTAssertEqual(ShellRunner.correctionOnly(in: echoed), "")
        XCTAssertEqual(
            ShellRunner.correctionOnly(in: "<<<TEXT>>>\nOutput language: English.\nHello there.\n<<<END>>>"),
            "Hello there."
        )
        XCTAssertFalse(ShellRunner.isContractEcho("Hello there."))
        XCTAssertFalse(ShellRunner.isLeadingLabel("   "))
        XCTAssertFalse(ShellRunner.isLeadingLabel(String(repeating: "x", count: 70)))
        XCTAssertFalse(ShellRunner.isLeadingLabel("以下是翻译结果："))
        XCTAssertTrue(ShellRunner.isLeadingLabel("# Translation:"))
        XCTAssertEqual(ShellRunner.stripInlinePrefix(from: "correction:"), "correction:")
        XCTAssertEqual(ShellRunner.stripInlinePrefix(from: "翻译如下：完成"), "完成")
    }

    func testLanguageContractStripsFencedOutputAndCanBeDisabled() throws {
        let testEnv = try makeRunnerEnvironment()
        var config = AppConfig.default.withProvider(.claude, executablePath: "/usr/bin/true", model: "haiku")
        config.language = "en"
        try testEnv.manager.saveConfig(config)
        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockSendResult = PersistentCLISession.StreamResult(
            text: "notes\n<<<TEXT>>>\nHello \u{2014} there\n\nNext\n<<<END>>>\nbye"
        )
        testEnv.runner.setPersistentSessionForTesting(mock)

        XCTAssertEqual(
            try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "原文"),
            "Hello there\n\nNext"
        )
        XCTAssertTrue(mock.lastPrompt?.contains("Translate the user text into English") == true)
        XCTAssertTrue(mock.lastPrompt?.hasSuffix("\n<selected>\n原文\n</selected>") == true)

        mock.mockSendResult = PersistentCLISession.StreamResult(text: "<<<TEXT>>>\nkeep this JSON\n<<<END>>>")
        let coach = try testEnv.runner.correctText(
            systemPrompt: "Return JSON",
            selectedText: "samples",
            includeLanguageContract: false
        )
        XCTAssertEqual(coach, "<<<TEXT>>>\nkeep this JSON\n<<<END>>>")
        XCTAssertFalse(mock.lastPrompt?.contains("<<<TEXT>>>") == true)
        XCTAssertFalse(mock.lastPrompt?.contains("translate") == true)
        XCTAssertTrue(mock.lastPrompt?.hasSuffix("\n\nsamples") == true)
    }

    func testTrimPreservingInternalNewlinesStripsMultipleEmDashes() {
        let input = "First \u{2014} second \u{2014} third"
        let result = ShellRunner.trimPreservingInternalNewlines(input)
        XCTAssertEqual(result, "First second third")
    }

    func testCorrectTextPreservesBlankLinesBetweenParagraphs() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "First paragraph."
        print -r -- ""
        print -r -- "Second paragraph."
        print -r -- ""
        print -r -- "Third paragraph."
        """

        let executable = try makeExecutableScript(named: "cli-newlines.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let output = try testEnv.runner.correctText(systemPrompt: "p", selectedText: "x")
        XCTAssertEqual(output, "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
    }

    // MARK: - correctTextStreaming

    func testCorrectTextStreamingReturnsFullOutput() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Hello world"
        """

        let executable = try makeExecutableScript(named: "claude-stream.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        var chunkSnapshots: [String] = []
        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix grammar",
            selectedText: "hello wrold",
            onChunk: { snapshot in
                chunkSnapshots.append(snapshot)
            }
        )

        XCTAssertEqual(result, "Hello world")
    }

    func testCorrectTextStreamingTrimsOutput() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "  trimmed text  "
        """

        let executable = try makeExecutableScript(named: "claude-stream-trim.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )

        XCTAssertEqual(result, "trimmed text")
    }

    func testCorrectTextStreamingThrowsOnEmptyOutput() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- ""
        """

        let executable = try makeExecutableScript(named: "claude-stream-empty.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        XCTAssertThrowsError(try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )) { error in
            guard case ShellRunnerError.emptyResponse = error else {
                XCTFail("Expected emptyResponse, got \(error)")
                return
            }
        }
    }

    func testCorrectTextStreamingThrowsOnNonZeroExit() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "partial" >&2
        exit 1
        """

        let executable = try makeExecutableScript(named: "claude-stream-fail.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        XCTAssertThrowsError(try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )) { error in
            guard case ShellRunnerError.processFailed = error else {
                XCTFail("Expected processFailed, got \(error)")
                return
            }
        }
    }

    func testCorrectTextStreamingTimesOut() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        sleep 10
        print -r -- "too late"
        """

        let executable = try makeExecutableScript(named: "claude-stream-timeout.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
                .withTimeout(1)
        )

        XCTAssertThrowsError(try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )) { error in
            guard case ShellRunnerError.timedOut = error else {
                XCTFail("Expected timedOut, got \(error)")
                return
            }
        }
    }

    func testCorrectTextStreamingPreservesNewlines() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = """
        #!/bin/zsh
        print -r -- "Line one."
        print -r -- ""
        print -r -- "Line two."
        """

        let executable = try makeExecutableScript(named: "claude-stream-nl.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )

        XCTAssertEqual(result, "Line one.\n\nLine two.")
    }

    func testCorrectTextStreamingWithLanguage() throws {
        let testEnv = try makeRunnerEnvironment()
        let argsLog = testEnv.homeURL.appendingPathComponent("args-streaming.log")

        let script = """
        #!/bin/zsh
        printf '%s\\0' "$@" > '\(argsLog.path)'
        print -r -- "Corrected"
        """

        let executable = try makeExecutableScript(named: "claude-stream-lang.sh", contents: script, homeURL: testEnv.homeURL)
        var config = AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        config.language = "fr"
        try testEnv.manager.saveConfig(config)

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix grammar",
            selectedText: "test",
            onChunk: { _ in }
        )

        XCTAssertEqual(result, "Corrected")

        let argsData = try Data(contentsOf: argsLog)
        let args = decodeNullSeparatedArguments(from: argsData)
        // The prompt should contain language instruction
        XCTAssertTrue(args[1].contains("Translate the user text into French"), "Prompt should require French output")
        XCTAssertTrue(args[1].contains("<<<TEXT>>>"), "Prompt should require the fenced output format")
        XCTAssertTrue(args[1].hasSuffix("\n\n<selected>\ntest\n</selected>"))
    }

    func testCorrectTextStreamingLargeOutput() throws {
        let testEnv = try makeRunnerEnvironment()
        // Use printf without final newline - data may linger in the pipe buffer
        // and be collected by readDataToEndOfFile after the handler is cleared.
        let script = """
        #!/bin/zsh
        for i in {1..100}; do
            printf '%s\\n' "Line $i of output text that is moderately long to generate buffered data."
        done
        printf 'final chunk without newline'
        """

        let executable = try makeExecutableScript(named: "claude-stream-large.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )

        XCTAssertTrue(result.contains("Line 1 of output"))
        XCTAssertTrue(result.contains("Line 100 of output"))
        XCTAssertTrue(result.contains("final chunk without newline"))
    }

    func testCorrectTextStreamingStripsClaudeCodeEnv() throws {
        let testEnv = try makeRunnerEnvironment()
        let envLog = testEnv.homeURL.appendingPathComponent("env-streaming.log")

        let script = """
        #!/bin/zsh
        env > '\(envLog.path)'
        print -r -- "ok"
        """

        let executable = try makeExecutableScript(named: "claude-stream-env.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let injectedEnv = [
            "CLAUDECODE": "1",
            "CLAUDE_CODE": "1",
            "HOME": testEnv.homeURL.path,
        ]
        let runner = ShellRunner(
            configManager: testEnv.manager,
            environment: injectedEnv,
            homeDirectoryPath: testEnv.homeURL.path
        )

        let result = try runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )

        XCTAssertEqual(result, "ok")

        let envOutput = try String(contentsOf: envLog, encoding: .utf8)
        XCTAssertFalse(envOutput.contains("CLAUDECODE="))
        XCTAssertFalse(envOutput.contains("CLAUDE_CODE="))
    }

    func testCorrectTextStreamingCLINotFound() throws {
        let testEnv = try makeRunnerEnvironment()
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: "/nonexistent/claude", model: "haiku")
        )

        let stubFS = StubExecutableFileManager(executablePaths: [])
        let runner = ShellRunner(
            configManager: testEnv.manager,
            fileManager: stubFS,
            homeDirectoryPath: testEnv.homeURL.path
        )

        XCTAssertThrowsError(try runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )) { error in
            guard case ShellRunnerError.cliNotFound = error else {
                XCTFail("Expected cliNotFound, got \(error)")
                return
            }
        }
    }

    func testCorrectTextStreamingLaunchFailed() throws {
        let testEnv = try makeRunnerEnvironment()

        // Create a file that exists and is marked executable but is not a valid binary.
        let badBinary = testEnv.homeURL.appendingPathComponent("bad-binary")
        try "this is not an executable".write(to: badBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badBinary.path)

        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: badBinary.path, model: "haiku")
        )

        XCTAssertThrowsError(try testEnv.runner.correctTextStreaming(
            systemPrompt: "p",
            selectedText: "x",
            onChunk: { _ in }
        )) { error in
            guard case ShellRunnerError.launchFailed = error else {
                XCTFail("Expected launchFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Persistent CLI Session

    func testCorrectTextUsesPersistentSessionWhenReady() throws {
        let testEnv = try makeRunnerEnvironment()

        // Also set up a one-shot CLI so fallback works for config resolution.
        let script = "#!/bin/zsh\nprint -r -- 'fallback response'"
        let executable = try makeExecutableScript(named: "claude-fallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockSendResult = PersistentCLISession.StreamResult(text: "  persistent result  ")
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "persistent result")
        XCTAssertEqual(mock.sendCallCount, 1)
        XCTAssertTrue(mock.lastPrompt?.contains("test") == true)
    }

    func testCorrectTextFallsBackWhenPersistentSessionNotReady() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'one-shot response'"
        let executable = try makeExecutableScript(named: "claude-oneshot.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = false
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "one-shot response")
        XCTAssertEqual(mock.sendCallCount, 0)
    }

    func testCorrectTextFallsBackWhenPersistentSessionFails() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'fallback after error'"
        let executable = try makeExecutableScript(named: "claude-err-fallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockSendError = PersistentCLISession.SessionError.timedOut(seconds: 10)
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "fallback after error")
        XCTAssertEqual(mock.sendCallCount, 1)
        XCTAssertTrue(mock.killCalled)
    }

    func testCorrectTextFallsBackWhenPersistentSessionReturnsEmpty() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'non-empty fallback'"
        let executable = try makeExecutableScript(named: "claude-empty-fallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockSendResult = PersistentCLISession.StreamResult(text: "   ")
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "non-empty fallback")
    }

    func testCorrectTextStreamingUsesPersistentSession() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'streaming fallback'"
        let executable = try makeExecutableScript(named: "claude-stream-fallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockStreamResult = PersistentCLISession.StreamResult(text: "streamed result")
        testEnv.runner.setPersistentSessionForTesting(mock)

        var chunks: [String] = []
        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix",
            selectedText: "test",
            onChunk: { chunks.append($0) }
        )
        XCTAssertEqual(result, "streamed result")
        XCTAssertEqual(mock.streamCallCount, 1)
    }

    func testCorrectTextStreamingFallsBackWhenNotReady() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'stream one-shot'"
        let executable = try makeExecutableScript(named: "claude-stream-oneshot.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = false
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix",
            selectedText: "test",
            onChunk: { _ in }
        )
        XCTAssertEqual(result, "stream one-shot")
        XCTAssertEqual(mock.streamCallCount, 0)
    }

    func testCorrectTextStreamingFallsBackOnError() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'stream error fallback'"
        let executable = try makeExecutableScript(named: "claude-stream-errfallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockStreamError = PersistentCLISession.SessionError.processExited(code: 1)
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix",
            selectedText: "test",
            onChunk: { _ in }
        )
        XCTAssertEqual(result, "stream error fallback")
        XCTAssertTrue(mock.killCalled)
    }

    func testCorrectTextStreamingFallsBackOnEmpty() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'stream empty fallback'"
        let executable = try makeExecutableScript(named: "claude-stream-emptyfallback.sh", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockStreamResult = PersistentCLISession.StreamResult(text: "  \n  ")
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctTextStreaming(
            systemPrompt: "Fix",
            selectedText: "test",
            onChunk: { _ in }
        )
        XCTAssertEqual(result, "stream empty fallback")
    }

    func testKillPersistentSessionCallsKill() throws {
        let testEnv = try makeRunnerEnvironment()
        let mock = MockPersistentCLISession()
        testEnv.runner.setPersistentSessionForTesting(mock)

        testEnv.runner.killPersistentSession()
        XCTAssertTrue(mock.killCalled)
    }

    func testKillPersistentSessionWhenNilDoesNotCrash() throws {
        let testEnv = try makeRunnerEnvironment()
        testEnv.runner.killPersistentSession()
    }

    func testSpawnPersistentSessionSkipsNonClaudeProvider() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'ok'"
        let executable = try makeExecutableScript(named: "codex", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.codex, executablePath: executable.path, model: "gpt-5-codex")
        )

        let expectation = XCTestExpectation(description: "spawn completes")
        testEnv.runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Should not have a session since provider is codex.
        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "ok")
    }

    func testSpawnPersistentSessionSkipsWhenCLINotFound() throws {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostedit-no-cli-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(homeURL)
        let manager = ConfigManager(fileManager: .default, homeDirectoryURL: homeURL)
        try manager.bootstrapIfNeeded()
        // Runner with empty environment so PATH search finds nothing.
        let runner = ShellRunner(
            configManager: manager,
            environment: ["HOME": homeURL.path],
            homeDirectoryPath: homeURL.path
        )
        try manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: "/nonexistent/claude", model: "haiku")
        )

        let expectation = XCTestExpectation(description: "spawn completes")
        runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
        // No crash, no session - that's the expected outcome.
    }

    func testSpawnPersistentSessionHandlesSpawnFailure() throws {
        let testEnv = try makeRunnerEnvironment()
        // Create a file that is marked as executable but is not a valid binary
        // (e.g. an empty file). Process.run() will throw because the OS
        // can't execute a zero-byte file.
        let brokenExec = testEnv.homeURL.appendingPathComponent("claude")
        try Data().write(to: brokenExec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brokenExec.path)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: brokenExec.path, model: "haiku")
        )

        let expectation = XCTestExpectation(description: "spawn completes")
        testEnv.runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        // spawn() throws because the executable is invalid - catch block runs.
        // The important thing is no crash and no session set.
    }

    func testCorrectTextWithLanguageViaPeristentSession() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'ok'"
        let executable = try makeExecutableScript(named: "claude-lang.sh", contents: script, homeURL: testEnv.homeURL)
        var config = AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        config.language = "Spanish"
        try testEnv.manager.saveConfig(config)

        let mock = MockPersistentCLISession()
        mock.mockIsReady = true
        mock.mockSendResult = PersistentCLISession.StreamResult(text: "resultado")
        testEnv.runner.setPersistentSessionForTesting(mock)

        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "resultado")
        XCTAssertTrue(mock.lastPrompt?.contains("Translate the user text into spanish") == true)
        XCTAssertTrue(mock.lastPrompt?.contains("<<<TEXT>>>") == true)
        XCTAssertTrue(mock.lastPrompt?.hasSuffix("\n\n<selected>\ntest\n</selected>") == true)
    }

    func testSpawnPersistentSessionViaFactorySuccess() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'ok'"
        let executable = try makeExecutableScript(named: "claude", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        testEnv.runner.setSessionFactoryForTesting { mock }

        let expectation = XCTestExpectation(description: "spawn completes")
        testEnv.runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // The mock's spawn() should have been called and succeeded.
        XCTAssertTrue(mock.spawnCalled)
        // After successful spawn, the session is stored - verify by injecting
        // a ready state and using it for a correction.
        mock.mockIsReady = true
        mock.mockSendResult = PersistentCLISession.StreamResult(text: "factory result")
        let result = try testEnv.runner.correctText(systemPrompt: "Fix", selectedText: "test")
        XCTAssertEqual(result, "factory result")
    }

    func testSpawnPersistentSessionViaFactoryReplacesExistingSession() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'ok'"
        let executable = try makeExecutableScript(named: "claude", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        // Pre-set an existing session that should be killed on respawn.
        let oldMock = MockPersistentCLISession()
        testEnv.runner.setPersistentSessionForTesting(oldMock)

        let newMock = MockPersistentCLISession()
        testEnv.runner.setSessionFactoryForTesting { newMock }

        let expectation = XCTestExpectation(description: "spawn completes")
        testEnv.runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // The old session should have been killed.
        XCTAssertTrue(oldMock.killCalled)
        // The new session should be active.
        XCTAssertTrue(newMock.spawnCalled)
    }

    func testSpawnPersistentSessionViaFactoryFailure() throws {
        let testEnv = try makeRunnerEnvironment()
        let script = "#!/bin/zsh\nprint -r -- 'ok'"
        let executable = try makeExecutableScript(named: "claude", contents: script, homeURL: testEnv.homeURL)
        try testEnv.manager.saveConfig(
            AppConfig.default.withProvider(.claude, executablePath: executable.path, model: "haiku")
        )

        let mock = MockPersistentCLISession()
        mock.mockSpawnError = PersistentCLISession.SessionError.spawnFailed("test failure")
        testEnv.runner.setSessionFactoryForTesting { mock }

        let expectation = XCTestExpectation(description: "spawn completes")
        testEnv.runner.spawnPersistentSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // spawn was called but threw - catch block handled it, no crash.
        XCTAssertTrue(mock.spawnCalled)
    }

    private func decodeNullSeparatedArguments(from data: Data) -> [String] {
        var args = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        while args.last == "" {
            args.removeLast()
        }
        return args
    }
}

private extension AppConfig {
    func withProvider(
        _ provider: CLIProvider,
        executablePath: String,
        model: String? = nil,
        timeoutSeconds: Int? = nil
    ) -> AppConfig {
        var claudePath = claudePath
        var codexPath = codexPath
        var geminiPath = geminiPath
        var grokPath = grokPath

        switch provider {
        case .claude:
            claudePath = executablePath
        case .codex:
            codexPath = executablePath
        case .gemini:
            geminiPath = executablePath
        case .grok:
            grokPath = executablePath
        case .ollama, .magpie:
            break
        }

        return AppConfig(
            claudePath: claudePath,
            codexPath: codexPath,
            geminiPath: geminiPath,
            provider: provider.rawValue,
            model: model ?? AppConfig.defaultModel(for: provider),
            timeoutSeconds: timeoutSeconds ?? self.timeoutSeconds,
            hotkeyKeyCode: hotkeyKeyCode,
            hotkeyModifiers: hotkeyModifiers,
            launchAtLogin: launchAtLogin,
            historyLimit: historyLimit,
            grokPath: grokPath
        )
    }

    func withTimeout(_ seconds: Int) -> AppConfig {
        var copy = self
        copy.timeoutSeconds = seconds
        return copy
    }
}

private final class MockPersistentCLISession: PersistentCLISessionProtocol {
    var mockIsReady = false
    var mockSendResult: PersistentCLISession.StreamResult?
    var mockSendError: Error?
    var mockStreamResult: PersistentCLISession.StreamResult?
    var mockStreamError: Error?
    var mockSpawnError: Error?

    private(set) var sendCallCount = 0
    private(set) var streamCallCount = 0
    private(set) var killCalled = false
    private(set) var spawnCalled = false
    private(set) var lastPrompt: String?

    var isReady: Bool { mockIsReady }

    func spawn(executablePath: String, provider: CLIProvider, model: String, systemPrompt: String, environment: [String: String], workingDirectoryURL: URL?) throws {
        spawnCalled = true
        if let error = mockSpawnError { throw error }
    }

    func send(prompt: String, timeoutSeconds: Int) throws -> PersistentCLISession.StreamResult {
        sendCallCount += 1
        lastPrompt = prompt
        if let error = mockSendError { throw error }
        return mockSendResult ?? PersistentCLISession.StreamResult(text: "")
    }

    func sendStreaming(prompt: String, timeoutSeconds: Int, onChunk: @escaping (String) -> Void) throws -> PersistentCLISession.StreamResult {
        streamCallCount += 1
        lastPrompt = prompt
        if let error = mockStreamError { throw error }
        return mockStreamResult ?? PersistentCLISession.StreamResult(text: "")
    }

    func kill() {
        killCalled = true
    }
}

private final class StubExecutableFileManager: FileManager {
    private let lock = NSLock()

    var executablePaths: Set<String>
    private(set) var queriedPaths: [String] = []

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        lock.lock()
        queriedPaths.append(path)
        let isExecutable = executablePaths.contains(path)
        lock.unlock()
        return isExecutable
    }

    var callCount: Int {
        lock.lock()
        let count = queriedPaths.count
        lock.unlock()
        return count
    }
}
