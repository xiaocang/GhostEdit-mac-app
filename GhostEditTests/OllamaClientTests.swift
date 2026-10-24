import XCTest
@testable import GhostEditCore

/// Each stub has a unique host, so unrelated tests cannot replace its transport.
final class OllamaURLProtocol: URLProtocol {
    typealias Handler = (OllamaURLProtocol) throws -> Void
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func stub(_ handler: @escaping Handler) -> (String, URLSessionConfiguration) {
        let host = UUID().uuidString.lowercased() + ".test"
        lock.lock()
        handlers[host] = handler
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        return ("http://\(host):11434", configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host!]
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            try handler(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    func requestJSON() throws -> [String: Any] {
        // URLSession may expose request bodies as a stream to URLProtocol.
        var body = request.httpBody ?? Data()
        if request.httpBody == nil {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func respond(status: Int = 200, chunks: [Data], finish: Bool = true, contentType: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

final class OllamaClientTests: XCTestCase {
    private func client(_ handler: @escaping OllamaURLProtocol.Handler) -> OllamaClient {
        let (url, configuration) = OllamaURLProtocol.stub(handler)
        return OllamaClient(baseURL: url, timeoutSeconds: 2, sessionConfiguration: configuration)
    }

    private func correction(_ client: OllamaClient, streaming: Bool = false) throws -> String {
        try client.correctText(systemPrompt: "Correct grammar", selectedText: "原文", model: "qwen3:1.7b",
                               onChunk: streaming ? { _ in } : nil)
    }

    func testNonstreamRequestAndFormatting() throws {
        let backend = client { stub in
            XCTAssertEqual(stub.request.url?.path, "/api/chat")
            XCTAssertEqual(stub.request.httpMethod, "POST")
            let payload = try stub.requestJSON()
            XCTAssertEqual(payload["model"] as? String, "qwen3:1.7b")
            XCTAssertEqual(payload["think"] as? Bool, false)
            XCTAssertEqual(payload["stream"] as? Bool, false)
            let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "system", "content": "Correct grammar"],
                                      ["role": "user", "content": "原文"]])
            let data = try JSONSerialization.data(withJSONObject: [
                "message": ["content": "  修正 — text\n\n    indented  line\n"], "done": true
            ])
            stub.respond(chunks: [data])
        }
        XCTAssertEqual(try correction(backend), "  修正 — text\n\n    indented  line\n")
    }

    func testStreamingFramesUnicodeAndThinkingAndDeliversAccumulatedMainQueueText() throws {
        let backend = client { stub in
            let stream = "{\"message\":{\"thinking\":\"private\",\"content\":\"\"},\"done\":false}\r\n"
                + "{\"message\":{\"content\":\"你好\"},\"done\":false}\n"
                + "{\"message\":{\"content\":\" — world\"},\"done\":false}\n"
                + "{\"done\":true}"
            // Every byte is a separate callback, including bytes within Chinese scalars.
            stub.respond(chunks: Data(stream.utf8).map { Data([$0]) })
        }
        let delivered = expectation(description: "content callbacks")
        delivered.expectedFulfillmentCount = 2
        var snapshots: [String] = []
        let text = try backend.correctText(systemPrompt: "p", selectedText: "x", model: "qwen3") { text in
            XCTAssertTrue(Thread.isMainThread)
            snapshots.append(text)
            delivered.fulfill()
        }
        XCTAssertEqual(text, "你好 — world")
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(snapshots, ["你好", "你好 — world"])
    }

    func testStreamingDeliversContentBeforeHTTPCompletion() {
        let receivedContent = DispatchSemaphore(value: 0)
        let backend = client { stub in
            stub.respond(chunks: [Data("{\"message\":{\"content\":\"live\"},\"done\":false}\n".utf8)],
                         finish: false, contentType: "application/x-ndjson")
            DispatchQueue.global().async {
                guard receivedContent.wait(timeout: .now() + 2) == .success else {
                    stub.client?.urlProtocol(stub, didFailWithError: URLError(.timedOut))
                    return
                }
                stub.client?.urlProtocol(stub, didLoad: Data("{\"done\":true}\n".utf8))
                stub.client?.urlProtocolDidFinishLoading(stub)
            }
        }
        let completed = expectation(description: "stream completed")
        DispatchQueue.global().async {
            do {
                let text = try backend.correctText(systemPrompt: "p", selectedText: "x", model: "qwen3") { text in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(text, "live")
                    receivedContent.signal()
                }
                XCTAssertEqual(text, "live")
            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 4)
    }

    func testRejectsMalformedTruncatedAndEmptyResponses() throws {
        let cases: [(String, String)] = [
            ("not json\n", "invalid response"),
            ("{\"message\":{\"content\":\"partial\"},\"done\":false}\n", "before completing"),
            ("{\"done\":true}\n{\"done\":true}\n", "invalid response"),
            ("{\"message\":{\"content\":\"  \\n\"},\"done\":true}\n", "no corrected text"),
            ("{\"message\":{\"thinking\":\"only reasoning\"},\"done\":true}\n", "no corrected text")
        ]
        for (response, description) in cases {
            for streaming in [false, true] {
                let backend = client { $0.respond(chunks: [Data(response.utf8)]) }
                XCTAssertThrowsError(try correction(backend, streaming: streaming)) {
                    XCTAssertTrue($0.localizedDescription.contains(description), $0.localizedDescription)
                }
            }
        }
    }

    func testServerModelMissingAndMidstreamErrorsAreActionable() throws {
        for status in [404, 503] {
            let backend = client { $0.respond(status: status, chunks: [Data("{\"error\":\"model missing\"}".utf8)]) }
            XCTAssertThrowsError(try correction(backend)) {
                XCTAssertTrue($0.localizedDescription.contains("model missing"))
                XCTAssertTrue($0.localizedDescription.contains("ollama pull"))
            }
        }
        let backend = client { $0.respond(chunks: [Data("{\"error\":\"model unloaded\"}\n".utf8)]) }
        XCTAssertThrowsError(try correction(backend, streaming: true)) {
            XCTAssertTrue($0.localizedDescription.contains("model unloaded"))
        }
    }

    func testConnectionAndTimeoutErrorsAreActionable() {
        for (code, expected) in [(URLError.cannotConnectToHost, "Start Ollama"), (.timedOut, "timed out")] {
            let backend = client { _ in throw URLError(code) }
            XCTAssertThrowsError(try correction(backend)) {
                XCTAssertTrue($0.localizedDescription.contains(expected), $0.localizedDescription)
            }
        }
    }

    func testOverallDeadlineEvenWhenServerNeverFinishes() {
        let (url, configuration) = OllamaURLProtocol.stub { _ in }
        let backend = OllamaClient(baseURL: url, timeoutSeconds: 1, sessionConfiguration: configuration)
        XCTAssertThrowsError(try correction(backend)) {
            XCTAssertTrue($0.localizedDescription.contains("timed out after 1 seconds"))
        }
    }

    func testInvalidBaseURLDoesNotReachTransport() {
        for url in ["not a url", "file:///tmp/test", "http://localhost:11434?bad=1"] {
            let backend = OllamaClient(baseURL: url, timeoutSeconds: 1)
            XCTAssertThrowsError(try correction(backend)) {
                XCTAssertTrue($0.localizedDescription.contains("Invalid Ollama server URL"))
            }
        }
    }

    func testListsInstalledModelsAndRejectsInvalidListing() throws {
        let backend = client { stub in
            XCTAssertEqual(stub.request.url?.path, "/api/tags")
            stub.respond(chunks: [Data("{\"models\":[{\"name\":\"qwen3:1.7b\"},{\"name\":\"qwen3:0.6b\"}]}".utf8)])
        }
        XCTAssertEqual(try backend.listModels(), ["qwen3:1.7b", "qwen3:0.6b"])
        let namedByModel = client { stub in
            stub.respond(chunks: [Data("{\"models\":[{\"model\":\"llama3:latest\"},{\"name\":\"  \",\"model\":\"qwen3:1.7b\"}]}".utf8)])
        }
        XCTAssertEqual(try namedByModel.listModels(), ["llama3:latest", "qwen3:1.7b"])
        let invalid = client { $0.respond(chunks: [Data("{}".utf8)]) }
        XCTAssertThrowsError(try invalid.listModels())
    }

    func testListsCloudModelsBesideInstalledModels() throws {
        let (localURL, configuration) = OllamaURLProtocol.stub { stub in
            XCTAssertEqual(stub.request.url?.path, "/api/tags")
            stub.respond(chunks: [Data(#"{"models":[{"name":"qwen3:1.7b"},{"name":"gemma4:31b-cloud"}]}"#.utf8)])
        }
        let (cloudURL, _) = OllamaURLProtocol.stub { stub in
            XCTAssertTrue(stub.request.url?.host?.hasSuffix(".test") == true)
            stub.respond(chunks: [Data(#"{"models":[{"name":"gemma4:31b"},{"name":"kimi-k3"},{"name":"gpt-oss:120b"},{"name":"gemma4:31b-cloud"}]}"#.utf8)])
        }
        let backend = OllamaClient(
            baseURL: localURL,
            timeoutSeconds: 2,
            sessionConfiguration: configuration,
            cloudCatalogURL: cloudURL
        )
        XCTAssertEqual(
            try backend.listModels(),
            ["qwen3:1.7b", "gemma4:31b-cloud", "kimi-k3:cloud", "gpt-oss:120b-cloud"]
        )
    }

    func testCloudCatalogFailureKeepsInstalledModels() throws {
        let (localURL, configuration) = OllamaURLProtocol.stub { stub in
            stub.respond(chunks: [Data(#"{"models":[{"name":"qwen3:0.6b"}]}"#.utf8)])
        }
        let backend = OllamaClient(
            baseURL: localURL,
            timeoutSeconds: 2,
            sessionConfiguration: configuration,
            cloudCatalogURL: "http://missing.cloud.test"
        )
        XCTAssertEqual(try backend.listModels(), ["qwen3:0.6b"])
    }

    func testCloudModelNameUsesTagSuffixWhenTheCatalogNameIsTagged() {
        XCTAssertEqual(OllamaClient.cloudModelName(for: "kimi-k3"), "kimi-k3:cloud")
        XCTAssertEqual(OllamaClient.cloudModelName(for: " gpt-oss:120b "), "gpt-oss:120b-cloud")
        XCTAssertEqual(OllamaClient.cloudModelName(for: "gemma4:31b-cloud"), "gemma4:31b-cloud")
        XCTAssertEqual(OllamaClient.cloudModelName(for: "already:cloud"), "already:cloud")
        XCTAssertEqual(OllamaClient.cloudModelName(for: "   "), "")
        XCTAssertEqual(
            OllamaClient.mergingCloudModels(local: ["local:latest"], catalog: ["", "local:latest", "kimi-k3"]),
            ["local:latest", "local:latest-cloud", "kimi-k3:cloud"]
        )
    }
}
