import XCTest
@testable import TandemCore

final class AIModelCatalogTests: XCTestCase {
    private func claude(_ id: String) -> ModelCapabilities {
        ModelCatalog.anthropicCapabilities(for: id)
    }

    func testFableAndMythosAlwaysThinkWithFallbacks() {
        for id in ["claude-fable-5-1", "claude-fable-5", "claude-mythos-5-1", "claude-mythos-5", "anthropic.claude-fable-5-1"] {
            let caps = claude(id)
            XCTAssertFalse(caps.sendsThinkingParam, id)
            XCTAssertTrue(caps.supportsThinkingDisplay, id)
            XCTAssertEqual(caps.supportedEfforts, ReasoningEffort.allCases, id)
            XCTAssertTrue(caps.supportsFallbacks, id)
        }
    }

    func testFrontierModelsSendAdaptiveThinkingAndFallbacks() {
        for id in ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-opus-5-20260301", "us.anthropic.claude-opus-5-5", "claude-opus-5-5[1m]"] {
            let caps = claude(id)
            XCTAssertTrue(caps.sendsThinkingParam, id)
            XCTAssertTrue(caps.supportsThinkingDisplay, id)
            XCTAssertEqual(caps.supportedEfforts, ReasoningEffort.allCases, id)
            XCTAssertTrue(caps.supportsFallbacks, id)
        }
    }

    func testAdaptiveModelsHaveNoFallbacks() {
        for id in ["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5", "anthropic.claude-opus-4-8-v1:0", "claude-opus-4-8@20260101"] {
            let caps = claude(id)
            XCTAssertTrue(caps.sendsThinkingParam, id)
            XCTAssertTrue(caps.supportsThinkingDisplay, id)
            XCTAssertEqual(caps.supportedEfforts, ReasoningEffort.allCases, id)
            XCTAssertFalse(caps.supportsFallbacks, id)
        }
    }

    func testClaude46HasNoXHighOrDisplay() {
        for id in ["claude-opus-4-6", "claude-sonnet-4-6"] {
            let caps = claude(id)
            XCTAssertTrue(caps.sendsThinkingParam, id)
            XCTAssertFalse(caps.supportsThinkingDisplay, id)
            XCTAssertEqual(caps.supportedEfforts, [.low, .medium, .high, .max], id)
            XCTAssertFalse(caps.supportsFallbacks, id)
            XCTAssertEqual(caps.resolvedEffort(.xhigh), .high, id)
            XCTAssertEqual(caps.resolvedEffort(.max), .max, id)
        }
    }

    func testHaikuAndOlderTakeNoThinkingOrEffort() {
        let legacy = [
            "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929", "claude-opus-4-1",
            "claude-opus-4-20250514", "claude-3-5-haiku-20241022", "claude-3-7-sonnet-20250219", "claude-instant-1.2"
        ]
        for id in legacy {
            let caps = claude(id)
            XCTAssertFalse(caps.sendsThinkingParam, id)
            XCTAssertFalse(caps.supportsThinkingDisplay, id)
            XCTAssertEqual(caps.supportedEfforts, [], id)
            XCTAssertFalse(caps.supportsFallbacks, id)
            XCTAssertNil(caps.resolvedEffort(.high), id)
        }
    }

    func testUnknownClaudeIDsGetTheOpus48Profile() {
        let opus48 = claude("claude-opus-4-8")
        for id in ["claude-nova-1", "claude-haiku-5", "some-proxy-alias"] {
            XCTAssertEqual(claude(id), opus48, id)
        }
        // A newer member of a known family keeps that family's newest profile.
        XCTAssertEqual(claude("claude-opus-6"), claude("claude-opus-5-5"))
    }

    func testResolvedEffort() {
        let all = claude("claude-opus-5-5")
        XCTAssertNil(all.resolvedEffort(nil))
        for effort in ReasoningEffort.allCases { XCTAssertEqual(all.resolvedEffort(effort), effort) }

        let openAIGPT5 = ModelCatalog.openAICapabilities(for: "gpt-5")
        XCTAssertEqual(openAIGPT5.resolvedEffort(.xhigh), .high)
        XCTAssertEqual(openAIGPT5.resolvedEffort(.max), .high)
        XCTAssertEqual(openAIGPT5.resolvedEffort(.low), .low)
    }

    func testOpenAICapabilities() {
        XCTAssertEqual(ModelCatalog.openAICapabilities(for: "gpt-6-astra").supportedEfforts, ReasoningEffort.allCases)
        XCTAssertEqual(ModelCatalog.openAICapabilities(for: "o3").supportedEfforts, [.low, .medium, .high])
        let gpt4 = ModelCatalog.openAICapabilities(for: "gpt-4o")
        XCTAssertEqual(gpt4.supportedEfforts, [])
        XCTAssertFalse(gpt4.supportsThinkingDisplay)
        XCTAssertFalse(ModelCatalog.openAICapabilities(for: "gpt-6-astra").supportsFallbacks)
    }

    func testCapabilitiesDispatchByProvider() {
        XCTAssertEqual(ModelCatalog.capabilities(for: "claude-opus-5-5", provider: .anthropic), claude("claude-opus-5-5"))
        XCTAssertEqual(ModelCatalog.capabilities(for: "gpt-5", provider: .openAI), ModelCatalog.openAICapabilities(for: "gpt-5"))
        XCTAssertEqual(ModelCatalog.capabilities(for: "anything", provider: .openAICompatible), ModelCatalog.openAICompatibleCapabilities)
    }

    func testPresetsAndDefaults() {
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .anthropic), "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.defaultModelID(for: .openAI), "gpt-6-astra")
        XCTAssertNil(ModelCatalog.defaultModelID(for: .openAICompatible))
        XCTAssertTrue(ModelCatalog.presets(for: .anthropic).allSatisfy { $0.provider == .anthropic })
        XCTAssertTrue(ModelCatalog.presets(for: .openAI).allSatisfy { $0.provider == .openAI })
    }
}
