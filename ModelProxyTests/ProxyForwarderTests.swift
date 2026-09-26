import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
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

    @Test func headProbeIsAnsweredLocally() {
        let probe = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/api/hello")
        let messages = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages?beta=true")

        #expect(ProxyForwarder.isLocalProbe(probe))
        #expect(!ProxyForwarder.isLocalProbe(messages))
    }

    @Test func sendResponseWithEmptyBodyWritesZeroContentLengthAndNoBodyPart() async throws {
        let channel = EmbeddedChannel()

        await ProxyForwarder.sendResponse(channel: channel, status: .ok, contentType: nil, body: Data())

        let headPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let head) = headPart else {
            Issue.record("Expected response head"); return
        }
        #expect(head.status == .ok)
        #expect(head.headers["content-length"] == ["0"])
        #expect(!head.headers.contains(name: "content-type"))
        let endPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .end = endPart else {
            Issue.record("Expected response end directly after head"); return
        }
    }

    @Test func sendErrorWritesHeadBodyAndEndWithoutWaitingForAFlush() async throws {
        let channel = EmbeddedChannel()

        await ProxyForwarder.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable")

        let headPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .head(let head) = headPart else {
            Issue.record("Expected response head"); return
        }
        #expect(head.status == .badGateway)
        #expect(head.headers["content-length"] == ["20"])
        let bodyPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .body(.byteBuffer(let buffer)) = bodyPart else {
            Issue.record("Expected response body"); return
        }
        #expect(buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) == "Upstream unreachable")
        let endPart = try #require(try channel.readOutbound(as: HTTPServerResponsePart.self))
        guard case .end = endPart else {
            Issue.record("Expected response end"); return
        }
    }

    @Test func claudeCodeHeadersGiveSessionAndAgentCoordinationScope() {
        let main: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1"]
        let subagent: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1", "x-claude-code-agent-id": "agent-7"]
        let body = Data(#"{"model":"claude-sonnet-5","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let shape = ProxyForwarder.requestShapeFingerprint(body)

        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: main, bodyData: body, clientName: "Claude Code")
            == "Claude Code|cc-session|sess-1|shape|\(shape)")
        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: subagent, bodyData: body, clientName: "Claude Code")
            == "Claude Code|cc-session|sess-1|agent|agent-7|shape|\(shape)")
        #expect(ProxyForwarder.claudeCodeCoordinationScopeKey(headers: [:], bodyData: body, clientName: "Claude Code") == nil)
    }

    @Test func claudeCodeScopeSeparatesConcurrentRequestsThatOnlyShareMessages() {
        let headers: HTTPHeaders = ["X-Claude-Code-Session-Id": "sess-1"]
        func scope(_ json: String) -> String? {
            ProxyForwarder.claudeCodeCoordinationScopeKey(headers: headers, bodyData: Data(json.utf8), clientName: "Claude Code")
        }
        let apple = #"{"model":"claude-sonnet-5","system":"Answer APPLE","messages":[{"role":"user","content":"word?"}]}"#
        let banana = #"{"model":"claude-sonnet-5","system":"Answer BANANA","messages":[{"role":"user","content":"word?"}]}"#
        let otherModel = #"{"model":"claude-haiku-4-5","system":"Answer APPLE","messages":[{"role":"user","content":"word?"}]}"#
        let appleLaterTurn = #"{"system":"Answer APPLE","model":"claude-sonnet-5","messages":[{"role":"user","content":"word?"},{"role":"assistant","content":"APPLE"},{"role":"user","content":"again"}]}"#

        // Same messages but a different system prompt or model must not share in-flight coordination.
        #expect(scope(apple) != scope(banana))
        #expect(scope(apple) != scope(otherModel))
        // A retry or a later turn of the same request shape stays in one scope, regardless of key order.
        #expect(scope(apple) == scope(apple))
        #expect(scope(apple) == scope(appleLaterTurn))
    }

    @Test func claudeCodeRequestClassComesFromHintHeaderOrAgentID() {
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-request-class": "compaction"]) == .compaction)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-agent-id": "agent-7"]) == .subagent)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: ["x-claude-code-request-class": "unknown-class"]) == nil)
        #expect(ProxyForwarder.claudeCodeRequestClass(from: [:]) == nil)
    }

    @Test func mappedVendorsDoNotReceiveClaudeCodeHeadersOrClientCredentials() {
        let request: HTTPHeaders = [
            "x-api-key": "client-key",
            "anthropic-version": "2023-06-01",
            "X-Claude-Code-Session-Id": "sess-1",
            "x-claude-code-agent-id": "agent-7",
            "Host": "localhost:8080"
        ]
        let mapped = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let passthrough = countTokensTarget(supportsCountTokens: true, isPassthrough: true)

        let vendorHeaders = ProxyForwarder.upstreamHeaders(from: request, target: mapped)
        #expect(!vendorHeaders.contains(name: "x-claude-code-session-id"))
        #expect(!vendorHeaders.contains(name: "x-claude-code-agent-id"))
        #expect(vendorHeaders["x-api-key"] == ["vendor-key"])
        #expect(vendorHeaders["anthropic-version"] == ["2023-06-01"])
        #expect(vendorHeaders["host"] == ["api.deepseek.com"])

        let passthroughHeaders = ProxyForwarder.upstreamHeaders(from: request, target: passthrough)
        #expect(passthroughHeaders["x-claude-code-session-id"] == ["sess-1"])
        #expect(passthroughHeaders["x-api-key"] == ["client-key"])
    }

    @Test func stripClaudeOnlyRequestFieldsRemovesBodyAndToolFieldsOnly() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-5-5",
            "max_tokens": 1024,
            "thinking": ["type": "adaptive"],
            "context_management": ["edits": [["type": "clear_tool_uses_20250919"]]],
            "output_config": ["effort": "xhigh"],
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "name": "Bash",
                "input_schema": ["type": "object"],
                "strict": true,
                "eager_input_streaming": true,
                "cache_control": ["type": "ephemeral"]
            ]]
        ])

        let result = ProxyForwarder.stripClaudeOnlyRequestFields(in: body)

        #expect(result.removedFields == ["context_management", "output_config", "tools[].eager_input_streaming", "tools[].strict"])
        let json = try #require(try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any])
        #expect(json["context_management"] == nil)
        #expect(json["output_config"] == nil)
        #expect(json["thinking"] != nil)
        #expect(json["max_tokens"] as? Int == 1024)
        let tool = try #require((json["tools"] as? [[String: Any]])?.first)
        #expect(tool["strict"] == nil)
        #expect(tool["eager_input_streaming"] == nil)
        #expect(tool["cache_control"] != nil)
        #expect(tool["input_schema"] != nil)
    }

    @Test func stripClaudeOnlyRequestFieldsLeavesBytesUntouchedWhenNothingToRemove() throws {
        let body = Data(#"{"model":"claude-opus-5-5","messages":[{"role":"user","content":"hi"}]}"#.utf8)

        let result = ProxyForwarder.stripClaudeOnlyRequestFields(in: body)

        #expect(result.bodyData == body)
        #expect(result.removedFields.isEmpty)
    }

    @Test func anthropicBetaHeaderIsDroppedOnlyForStrippingVendors() {
        let request: HTTPHeaders = ["anthropic-beta": "context-management-2025-06-27", "anthropic-version": "2023-06-01"]
        let base = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let stripping = RoutingSnapshot.RouteTarget(
            baseURL: base.baseURL,
            apiKey: base.apiKey,
            vendorName: base.vendorName,
            vendorID: base.vendorID,
            targetModel: base.targetModel,
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            stripsClaudeOnlyRequestFields: true
        )

        #expect(ProxyForwarder.upstreamHeaders(from: request, target: base)["anthropic-beta"] == ["context-management-2025-06-27"])
        #expect(!ProxyForwarder.upstreamHeaders(from: request, target: stripping).contains(name: "anthropic-beta"))
        #expect(ProxyForwarder.upstreamHeaders(from: request, target: stripping)["anthropic-version"] == ["2023-06-01"])
    }

    @Test func restoredThinkingBlockCountMeasuresOnlyBlocksTheClientDidNotSend() throws {
        func body(thinkingBlocks: Int) throws -> Data {
            let thinking = Array(repeating: ["type": "thinking", "thinking": "t"], count: thinkingBlocks)
            return try JSONSerialization.data(withJSONObject: [
                "model": "m",
                "messages": [
                    ["role": "user", "content": "q"],
                    ["role": "assistant", "content": thinking + [["type": "text", "text": "a"]]]
                ]
            ])
        }

        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 0), preparedBody: try body(thinkingBlocks: 2)) == 2)
        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 2), preparedBody: try body(thinkingBlocks: 2)) == 0)
        #expect(ProxyForwarder.restoredThinkingBlockCount(originalBody: try body(thinkingBlocks: 2), preparedBody: try body(thinkingBlocks: 0)) == 0)
    }

    @Test func countTokensIsAnsweredLocallyWhenVendorLacksEndpoint() {
        let vendor = countTokensTarget(supportsCountTokens: false, isPassthrough: false)

        #expect(ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: vendor))
        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .generation, target: vendor))
    }

    @Test func countTokensIsForwardedWhenVendorSupportsEndpointOrRouteIsPassthrough() {
        let supporting = countTokensTarget(supportsCountTokens: true, isPassthrough: false)
        let passthrough = countTokensTarget(supportsCountTokens: false, isPassthrough: true)

        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: supporting))
        #expect(!ProxyForwarder.answersCountTokensLocally(requestKind: .countTokens, target: passthrough))
    }

    @Test func countTokensUnsupportedBodyIsAnthropicNotFoundError() throws {
        let data = ProxyForwarder.countTokensUnsupportedBody(vendorName: "DeepSeek")
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])

        #expect(json["type"] as? String == "error")
        #expect(error["type"] as? String == "not_found_error")
        #expect((error["message"] as? String)?.contains("DeepSeek") == true)
    }

    private func countTokensTarget(supportsCountTokens: Bool, isPassthrough: Bool) -> RoutingSnapshot.RouteTarget {
        RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "vendor-key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1"),
            targetModel: "deepseek-v4-pro[1m]",
            isPassthrough: isPassthrough,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: supportsCountTokens,
            repairsAnthropicToolCalls: true
        )
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
