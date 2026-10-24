import Foundation

enum ModelListingError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(details):
            return details
        }
    }
}

enum ModelListing {
    static func fetch(provider: CLIProvider, endpoint: String, executablePath: String?) throws -> [String] {
        switch provider {
        case .ollama:
            return try OllamaClient(baseURL: endpoint, timeoutSeconds: 5).listModels()
        case .magpie:
            return ModelCatalogSupport.parseMagpieModels(try commandOutput(executablePath, name: "magpie", arguments: ["models"]))
        case .grok:
            return ModelCatalogSupport.parseGrokModels(try commandOutput(executablePath, name: "grok", arguments: ["models"]))
        case .claude, .codex, .gemini:
            return ModelCatalogSupport.parseCLIModels(try commandOutput(executablePath, name: provider.rawValue, arguments: ["models"]))
        }
    }

    private static func commandOutput(_ executablePath: String?, name: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let preferred = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preferred.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [name] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: preferred)
            process.arguments = arguments
        }
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ModelListingError.failed("Cannot run \(name): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if process.terminationStatus != 0, ModelCatalogSupport.parseGrokModels(combined).isEmpty,
           ModelCatalogSupport.parseMagpieModels(combined).isEmpty,
           ModelCatalogSupport.parseCLIModels(combined).isEmpty {
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = details.isEmpty ? fallback : details
            throw ModelListingError.failed(message.isEmpty ? "\(name) models failed" : message)
        }
        return combined
    }
}
