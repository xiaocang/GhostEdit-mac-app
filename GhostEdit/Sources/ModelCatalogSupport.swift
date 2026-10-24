import Foundation

enum ModelCatalogSupport {
    static func cacheKey(provider: String, endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider : "\(provider)|\(trimmed)"
    }

    static func endpoint(provider: String, ollamaBaseURL: String, magpieBaseURL: String) -> String {
        switch provider {
        case CLIProvider.ollama.rawValue:
            return ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        case CLIProvider.magpie.rawValue:
            return magpieBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return ""
        }
    }

    static func models(in catalog: [String: [String]], key: String) -> [String] {
        catalog[key] ?? []
    }

    static func updating(_ catalog: [String: [String]], key: String, models: [String]) -> [String: [String]] {
        var copy = catalog
        copy[key] = models
        return copy
    }

    static func parseGrokModels(_ text: String) -> [String] {
        uniqueModels(in: text) { line in
            if line.hasPrefix("*") || line.hasPrefix("-") || line.hasPrefix("+") {
                return line.drop(while: { $0 == "*" || $0 == "-" || $0 == "+" || $0.isWhitespace })
                    .split(separator: " ").first.map(String.init) ?? ""
            }
            guard let range = line.range(of: "Default model:", options: .caseInsensitive) else { return "" }
            return String(line[range.upperBound])
        }
    }

    static func parseMagpieModels(_ text: String) -> [String] {
        uniqueModels(in: text) { line in
            guard let token = line.split(separator: " ").first else { return "" }
            let name = String(token)
            return name.contains("/") ? name : ""
        }
    }

    static func parseCLIModels(_ text: String) -> [String] {
        uniqueModels(in: text) { line in
            guard !line.hasSuffix(":") else { return "" }
            let stripped = line.drop(while: { $0 == "*" || $0 == "-" || $0 == "+" || $0.isWhitespace })
            guard let token = stripped.split(separator: " ").first else { return "" }
            let name = String(token)
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil else {
                return ""
            }
            return name
        }
    }

    static func decode(_ data: Data) -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    static func encode(_ catalog: [String: [String]]) throws -> Data {
        try JSONEncoder().encode(catalog)
    }

    static func load(from url: URL) -> [String: [String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return decode(data)
    }

    static func save(_ catalog: [String: [String]], to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(catalog).write(to: url, options: .atomic)
    }

    private static func uniqueModels(in text: String, nameAt line: (String) -> String) -> [String] {
        var models: [String] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let candidate = line(raw.trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
            models.append(candidate)
        }
        return models
    }
}
