import Foundation
import Testing
@testable import ModelProxy

struct ProxyForwarderTests {

    @Test func branchWaitBudgetStopsAfterConfiguredLimit() {
        var budget = ProxyForwarder.BranchWaitBudget(maxAttempts: 3)

        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == true)
        #expect(budget.recordWait() == false)
        #expect(budget.attempts == 4)
    }

    @Test func countTokensBypassesMappedVendorWhenUnsupported() {
        let vendorTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "vendor-key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1"),
            targetModel: "deepseek-v4-pro[1m]",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: false,
            repairsAnthropicToolCalls: true
        )
        let passthroughTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.anthropic.com",
            apiKey: "original-key",
            vendorName: "passthrough",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .anthropicOfficial,
            replayPolicy: .transparent,
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: false
        )

        let decision = ProxyForwarder.effectiveTarget(
            for: .countTokens,
            resolvedTarget: vendorTarget,
            passthroughTarget: passthroughTarget
        )

        #expect(decision.didBypass == true)
        #expect(decision.bypassedVendorName == "DeepSeek")
        #expect(decision.target.isPassthrough == true)
        #expect(decision.target.baseURL == "https://api.anthropic.com")
        #expect(decision.target.apiKey == "original-key")
    }

    @Test func countTokensStaysMappedWhenVendorSupportsEndpoint() {
        let vendorTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://supports.example.com/anthropic",
            apiKey: "vendor-key",
            vendorName: "Supports",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1"),
            targetModel: "target-model",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: false
        )
        let passthroughTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.anthropic.com",
            apiKey: "original-key",
            vendorName: "passthrough",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .anthropicOfficial,
            replayPolicy: .transparent,
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: false
        )

        let decision = ProxyForwarder.effectiveTarget(
            for: .countTokens,
            resolvedTarget: vendorTarget,
            passthroughTarget: passthroughTarget
        )

        #expect(decision.didBypass == false)
        #expect(decision.target.vendorName == "Supports")
        #expect(decision.target.isPassthrough == false)
    }

    @Test func sanitizeToolsRemovesToolsWithEmptyName() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "", "input_schema": ["type": "object"]],
                ["name": "bash", "input_schema": ["type": "object", "properties": [:]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "bash")
    }

    @Test func sanitizeToolsRemovesToolsWithMissingInputSchema() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "advisor", "type": "custom"],
                ["name": "bash", "input_schema": ["type": "object"]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "bash")
    }

    @Test func sanitizeToolsRemovesServerSideToolsByType() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
                ["type": "computer_20241022", "name": "computer", "display_width_px": 1024],
                ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "Read")
    }

    @Test func sanitizeToolsRemovesToolChoiceWhenAllToolsFiltered() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
            ],
            "tool_choice": ["type": "auto"]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect(json["tools"] == nil)
        #expect(json["tool_choice"] == nil)
    }

    @Test func sanitizeToolsPassesThroughValidToolsUnchanged() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                ["name": "bash", "input_schema": ["type": "object"]],
                ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
            ]
        ])
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
    }
}
