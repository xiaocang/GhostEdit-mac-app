import Foundation

enum OllamaClientError: LocalizedError {
    case invalidURL
    case transport(String)
    case timedOut(Int)
    case server(Int, String)
    case invalidResponse
    case truncatedStream
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama server URL. Set an http:// or https:// server address in Settings."
        case let .transport(details):
            return "Cannot reach Ollama: \(details). Start Ollama and check the server URL in Settings."
        case let .timedOut(seconds):
            return "Ollama timed out after \(seconds) seconds. Check the server or choose a smaller installed model."
        case let .server(status, details):
            return "Ollama returned \(status): \(details). Check the selected model; install it with `ollama pull <model>` if missing."
        case .invalidResponse:
            return "Ollama returned an invalid response. Check that the server URL points to an Ollama server."
        case .truncatedStream:
            return "Ollama stopped before completing its response. Check the server and try again."
        case .emptyResponse:
            return "Ollama returned no corrected text. Try another installed model in Settings."
        }
    }
}

/// Synchronous API for the correction worker queue; streaming delivery is always on main.
final class OllamaClient {
    static let defaultCloudCatalogURL = "https://ollama.com"

    private let baseURL: String
    private let timeoutSeconds: Int
    private let configuration: URLSessionConfiguration
    private let cloudCatalogURL: String

    init(
        baseURL: String,
        timeoutSeconds: Int,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        cloudCatalogURL: String = OllamaClient.defaultCloudCatalogURL
    ) {
        self.baseURL = baseURL
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.configuration = sessionConfiguration
        self.cloudCatalogURL = cloudCatalogURL
    }

    func correctText(
        systemPrompt: String,
        selectedText: String,
        model: String,
        onChunk: ((String) -> Void)? = nil
    ) throws -> String {
        var request = try makeRequest(path: "api/chat")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": selectedText]
            ],
            "stream": onChunk != nil,
            "think": false,
            "options": ["temperature": 0, "seed": 0]
        ])
        let exchange = OllamaExchange(streaming: onChunk != nil, onChunk: onChunk)
        try perform(request, exchange: exchange)
        // Preserve punctuation, indentation, and internal spacing exactly as generated.
        let text = exchange.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OllamaClientError.emptyResponse
        }
        return text
    }

    func listModels() throws -> [String] {
        let local = try fetchModelNames(baseURL: baseURL)
        // Cloud catalog failure must not hide models already installed locally.
        let catalog = (try? fetchModelNames(baseURL: cloudCatalogURL)) ?? []
        return Self.mergingCloudModels(local: local, catalog: catalog)
    }

    /// Local daemon names for ollama.com catalog entries.
    /// Untagged names become `kimi-k3:cloud`. Tagged names become `gpt-oss:120b-cloud`,
    /// because `gpt-oss:cloud` does not resolve when several sizes exist.
    static func cloudModelName(for catalogName: String) -> String {
        let trimmed = catalogName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasSuffix(":cloud") || trimmed.hasSuffix("-cloud") { return trimmed }
        if trimmed.contains(":") { return trimmed + "-cloud" }
        return trimmed + ":cloud"
    }

    static func mergingCloudModels(local: [String], catalog: [String]) -> [String] {
        var seen = Set(local)
        var merged = local
        for name in catalog {
            let cloudName = cloudModelName(for: name)
            guard !cloudName.isEmpty, seen.insert(cloudName).inserted else { continue }
            merged.append(cloudName)
        }
        return merged
    }

    private func fetchModelNames(baseURL: String) throws -> [String] {
        let exchange = OllamaExchange(streaming: false, listingModels: true)
        try perform(makeRequest(baseURL: baseURL, path: "api/tags"), exchange: exchange)
        return exchange.models
    }

    private func makeRequest(path: String) throws -> URLRequest {
        try makeRequest(baseURL: baseURL, path: path)
    }

    private func makeRequest(baseURL: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.query == nil, url.fragment == nil else {
            throw OllamaClientError.invalidURL
        }
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        return request
    }

    private func perform(_ request: URLRequest, exchange: OllamaExchange) throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard exchange.finished.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            throw OllamaClientError.timedOut(timeoutSeconds)
        }
        if let error = exchange.error {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw OllamaClientError.timedOut(timeoutSeconds)
            }
            if let error = error as? OllamaClientError { throw error }
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }
}

private final class OllamaExchange: NSObject, URLSessionDataDelegate {
    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool?
        let error: String?
    }

    let finished = DispatchSemaphore(value: 0)
    private(set) var error: Error?
    private(set) var text = ""
    private(set) var models: [String] = []
    private let streaming: Bool
    private let listingModels: Bool
    private let onChunk: ((String) -> Void)?
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var done = false

    init(streaming: Bool, listingModels: Bool = false, onChunk: ((String) -> Void)? = nil) {
        self.streaming = streaming
        self.listingModels = listingModels
        self.onChunk = onChunk
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard error == nil else { return }
        buffer.append(data)
        guard streaming, let response, (200..<300).contains(response.statusCode) else { return }
        do {
            // Frame bytes before decoding UTF-8: a network chunk may split any scalar.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if !line.isEmpty && line != Data([0x0D]) { try consume(line) }
            }
        } catch {
            self.error = error
            dataTask.cancel()
        }
    }

    private func consume(_ data: Data) throws {
        guard !done else { throw OllamaClientError.invalidResponse }
        let value: ChatResponse
        do { value = try JSONDecoder().decode(ChatResponse.self, from: data) }
        catch { throw OllamaClientError.invalidResponse }
        if let message = value.error { throw OllamaClientError.server(response?.statusCode ?? 200, message) }
        guard let complete = value.done, value.message != nil || complete else {
            throw OllamaClientError.invalidResponse
        }
        if let content = value.message?.content, !content.isEmpty {
            text += content
            let accumulated = text
            if let onChunk { DispatchQueue.main.async { onChunk(accumulated) } }
        }
        done = complete
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError transportError: Error?) {
        defer { finished.signal() }
        guard error == nil else { return }
        if let transportError { error = transportError; return }
        guard let response else { error = OllamaClientError.invalidResponse; return }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any]
            let details = object?["error"] as? String ?? String(data: buffer, encoding: .utf8) ?? "Unknown server error"
            error = OllamaClientError.server(response.statusCode, String(details.prefix(1000)))
            return
        }
        do {
            if listingModels {
                struct ModelList: Decodable {
                    struct Model: Decodable {
                        let name: String

                        init(from decoder: Decoder) throws {
                            let container = try decoder.container(keyedBy: CodingKeys.self)
                            let name = try container.decodeIfPresent(String.self, forKey: .name)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let model = try container.decodeIfPresent(String.self, forKey: .model)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let resolved = name.isEmpty ? model : name
                            guard !resolved.isEmpty else {
                                throw DecodingError.dataCorruptedError(
                                    forKey: .name,
                                    in: container,
                                    debugDescription: "missing model name"
                                )
                            }
                            self.name = resolved
                        }

                        private enum CodingKeys: String, CodingKey {
                            case name
                            case model
                        }
                    }
                    let models: [Model]
                }
                do { models = try JSONDecoder().decode(ModelList.self, from: buffer).models.map(\.name) }
                catch { throw OllamaClientError.invalidResponse }
            } else {
                if !buffer.isEmpty { try consume(buffer) }
                guard done else { throw OllamaClientError.truncatedStream }
            }
        } catch { self.error = error }
    }
}
