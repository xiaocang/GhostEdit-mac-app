import Foundation

enum MagpieClientError: LocalizedError {
    case invalidURL
    case transport(String)
    case timedOut(Int)
    case server(Int, String)
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Magpie server URL. Set an http:// or https:// server address in Settings."
        case let .transport(details):
            return "Cannot reach Magpie: \(details). Start Magpie and check the server URL in Settings."
        case let .timedOut(seconds):
            return "Magpie timed out after \(seconds) seconds."
        case let .server(status, details):
            return "Magpie returned \(status): \(details)."
        case .invalidResponse:
            return "Magpie returned an invalid response. Check that the server URL points to the Magpie gateway."
        case .emptyResponse:
            return "Magpie returned no corrected text. Refresh Models and try another model."
        }
    }
}

final class MagpieClient {
    private let baseURL: String
    private let timeoutSeconds: Int
    private let configuration: URLSessionConfiguration

    init(baseURL: String, timeoutSeconds: Int, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.configuration = sessionConfiguration
    }

    func correctText(
        systemPrompt: String,
        selectedText: String,
        model: String,
        onChunk: ((String) -> Void)? = nil
    ) throws -> String {
        var request = try makeRequest(path: "v1/chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer magpie", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": selectedText]
            ],
            "temperature": 0,
            "stream": false
        ])
        let data = try perform(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MagpieClientError.emptyResponse
        }
        if let onChunk {
            if Thread.isMainThread {
                onChunk(text)
            } else {
                DispatchQueue.main.sync { onChunk(text) }
            }
        }
        return text
    }

    private func makeRequest(path: String) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.query == nil, url.fragment == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MagpieClientError.invalidURL
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/" + path
        guard let requestURL = components.url else { throw MagpieClientError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        return request
    }

    private func perform(_ request: URLRequest) throws -> Data {
        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            finished.signal()
        }.resume()
        guard finished.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            throw MagpieClientError.timedOut(timeoutSeconds)
        }
        if let error = box.error {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw MagpieClientError.timedOut(timeoutSeconds)
            }
            throw MagpieClientError.transport(error.localizedDescription)
        }
        guard let response = box.response as? HTTPURLResponse else {
            throw MagpieClientError.invalidResponse
        }
        let data = box.data ?? Data()
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let details = object?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw MagpieClientError.server(response.statusCode, String(details.prefix(1000)))
        }
        guard !data.isEmpty else { throw MagpieClientError.invalidResponse }
        return data
    }
}

private final class ResultBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}
