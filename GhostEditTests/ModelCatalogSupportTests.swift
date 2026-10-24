import XCTest
@testable import GhostEditCore

final class ModelCatalogSupportTests: XCTestCase {
    func testCacheKeyOmitsEmptyEndpointAndKeepsServer() {
        XCTAssertEqual(ModelCatalogSupport.cacheKey(provider: "grok", endpoint: "  "), "grok")
        XCTAssertEqual(
            ModelCatalogSupport.cacheKey(provider: "ollama", endpoint: " http://127.0.0.1:11434 "),
            "ollama|http://127.0.0.1:11434"
        )
    }

    func testEndpointSelectsTheServerForHTTPProvidersOnly() {
        XCTAssertEqual(
            ModelCatalogSupport.endpoint(provider: "ollama", ollamaBaseURL: " http://a ", magpieBaseURL: "http://b"),
            "http://a"
        )
        XCTAssertEqual(
            ModelCatalogSupport.endpoint(provider: "magpie", ollamaBaseURL: "http://a", magpieBaseURL: " http://b "),
            "http://b"
        )
        XCTAssertEqual(
            ModelCatalogSupport.endpoint(provider: "grok", ollamaBaseURL: "http://a", magpieBaseURL: "http://b"),
            ""
        )
    }

    func testCatalogLookupAndUpdate() {
        XCTAssertEqual(ModelCatalogSupport.models(in: [:], key: "missing"), [])
        let updated = ModelCatalogSupport.updating([:], key: "grok", models: ["grok-4.7"])
        XCTAssertEqual(ModelCatalogSupport.models(in: updated, key: "grok"), ["grok-4.7"])
    }

    func testParsesGrokModelListWithoutHardcodedNames() {
        let text = """
        You are not authenticated.

        Default model: grok-4.7

        Available models:
          * grok-4.7 (default)
          - grok-4.7-build-fast
          + grok-4.6
          - grok-4.5
        """
        XCTAssertEqual(
            ModelCatalogSupport.parseGrokModels(text),
            ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"]
        )
        XCTAssertEqual(ModelCatalogSupport.parseGrokModels("no models here"), [])
        XCTAssertEqual(ModelCatalogSupport.parseGrokModels("*\n-"), [])
    }

    func testParsesMagpieModelIds() {
        let text = """
          Routing groups
          group/auto-grok-4-7                Grok 4.7
          Claude Code
          claude/claude-haiku-4-5            Claude Haiku 4.5
          claude/claude-haiku-4-5            duplicate
        """
        XCTAssertEqual(
            ModelCatalogSupport.parseMagpieModels(text),
            ["group/auto-grok-4-7", "claude/claude-haiku-4-5"]
        )
        XCTAssertEqual(ModelCatalogSupport.parseMagpieModels("\n"), [])
        XCTAssertEqual(ModelCatalogSupport.parseMagpieModels("   "), [])
    }

    func testParsesGenericCLIModelLines() {
        let text = """
        Available models:
        haiku
        * sonnet extra
        - opus
        !!!
        """
        XCTAssertEqual(ModelCatalogSupport.parseCLIModels(text), ["haiku", "sonnet", "opus"])
        XCTAssertEqual(ModelCatalogSupport.parseCLIModels(""), [])
        XCTAssertEqual(ModelCatalogSupport.parseCLIModels("*"), [])
    }

    func testCacheRoundTripAndInvalidPayload() throws {
        XCTAssertEqual(ModelCatalogSupport.decode(Data("nope".utf8)), [:])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostedit-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("model-cache.json")
        XCTAssertEqual(ModelCatalogSupport.load(from: url), [:])
        let catalog = ["grok": ["grok-4.7"]]
        try ModelCatalogSupport.save(catalog, to: url)
        XCTAssertEqual(ModelCatalogSupport.load(from: url), catalog)
        XCTAssertEqual(ModelCatalogSupport.decode(try ModelCatalogSupport.encode(catalog)), catalog)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
