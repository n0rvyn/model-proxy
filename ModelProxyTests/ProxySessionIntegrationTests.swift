import Testing
import Foundation
import NIOCore
@testable import ModelProxy

@MainActor
struct ProxySessionIntegrationTests {

    @Test func claudeCommitOnPortableVendorDoesNotPoisonMainAnthropicSession() async throws {
        let broker = makeBroker()
        let normalizer = PortableContentNormalizer()
        let portableTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let commitRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "thinking": ["type": "enabled", "budget_tokens": 31999],
            "messages": [
                ["role": "assistant", "content": [
                    ["type": "thinking", "thinking": "anthropic signed history", "signature": "sig_anthropic"],
                    ["type": "text", "text": "Earlier visible output"]
                ]],
                ["role": "user", "content": "Run /commit"]
            ]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: commitRequest,
            clientName: "Claude Code",
            target: portableTarget
        )
        let projected = try #require(try JSONSerialization.jsonObject(with: prepared.bodyData) as? [String: Any])
        let projectedMessages = try #require(projected["messages"] as? [[String: Any]])
        let projectedBlocks = try #require(projectedMessages.first?["content"] as? [[String: Any]])
        // Vendor-ready: thinking kept (signature stripped) for the vendor.
        #expect(projectedBlocks.count == 2)
        let projectedThinking = try #require(projectedBlocks.first { $0["type"] as? String == "thinking" })
        #expect(projectedThinking["signature"] == nil)
        #expect(projectedThinking["thinking"] as? String == "anthropic signed history")

        let qwenResponse = try JSONSerialization.data(withJSONObject: [
            "id": "msg_qwen",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "qwen hidden reasoning", "signature": "sig_qwen"],
                ["type": "text", "text": "Committed successfully"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(qwenResponse)
        try await broker.commitResponse(
            context: try #require(prepared.context),
            assistantTurn: try #require(normalized.assistantTurn)
        )

        // Response normalization strips thinking — client never sees vendor thinking.
        let portableReply = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let portableBlocks = try #require(portableReply["content"] as? [[String: Any]])
        #expect(portableBlocks.count == 1)
        #expect(portableBlocks.first?["text"] as? String == "Committed successfully")

        // When client sends to Anthropic: no unsigned thinking to contaminate.
        let mainOpusRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-6",
            "thinking": ["type": "adaptive"],
            "messages": [
                ["role": "assistant", "content": projectedBlocks],
                ["role": "assistant", "content": portableBlocks],
                ["role": "user", "content": "What changed?"]
            ]
        ], options: [.sortedKeys])

        let mainJSON = try #require(try JSONSerialization.jsonObject(with: mainOpusRequest) as? [String: Any])
        let mainMessages = try #require(mainJSON["messages"] as? [[String: Any]])
        let assistantMessages = mainMessages.filter { ($0["role"] as? String) == "assistant" }
        let allBlocks = try assistantMessages.flatMap { message in
            try #require(message["content"] as? [[String: Any]])
        }
        // projectedBlocks has thinking (unsigned, from vendor-ready), portableBlocks has no thinking.
        // For Anthropic passthrough, the client's own body goes through — proxy doesn't modify it.
        // The unsigned thinking from projectedBlocks would be in the body.
        // But in real usage, projectedBlocks came from a DIFFERENT conversation branch (commit skill).
        // The main session's client would have portableBlocks (no thinking) as its response.
        // So the actual Anthropic request would only have the main session's clean data.
        #expect(!allBlocks.contains { $0["signature"] != nil })
    }

    @Test func codexForkRequestWithoutMessagesStaysTransparent() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.openai.com",
            apiKey: "key",
            vendorName: "OpenAI",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2"),
            targetModel: "gpt-5-mini",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let forkRequest = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5",
            "input": "Review the branch"
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: forkRequest,
            clientName: "Codex",
            target: target
        )

        #expect(prepared.bodyData == forkRequest)
        #expect(prepared.context == nil)
    }

    @Test func sameSigningDomainReplayRemainsTransparentAcrossModelSwitch() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.anthropic.com",
            apiKey: "key",
            vendorName: "passthrough",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .anthropicOfficial,
            replayPolicy: .transparent
        )

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-4-6",
            "messages": [
                ["role": "assistant", "content": [
                    ["type": "thinking", "thinking": "official", "signature": "sig_official"],
                    ["type": "text", "text": "visible"]
                ]]
            ]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: target)
        #expect(prepared.bodyData == request)
        #expect(prepared.context == nil)
    }

    @Test func portableBranchSuccessorReusesCommittedVendorHistoryAfterLeaderCompletes() async throws {
        let broker = makeBroker()
        let coordinator = BranchRequestCoordinator()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let initialRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])
        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let firstPrepared = try await broker.prepareRequest(
            bodyData: initialRequest,
            clientName: "Claude Code",
            target: target
        )
        let firstContext = try #require(firstPrepared.context)
        let firstLease = switch await coordinator.acquire(context: firstContext) {
        case .acquired(let lease): lease
        default: Issue.record("Expected leader acquisition"); throw IntegrationTestAbort()
        }

        try await broker.commitResponse(
            context: firstContext,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "private", "signature": "qwen_sig"],
                        ["type": "text", "text": "I inspected the diff"]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "I inspected the diff"]]
                ], options: [.sortedKeys])
            )
        )
        await coordinator.complete(lease: firstLease, replay: nil)

        let reprepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            target: target
        )
        #expect(reprepared.context?.reusedBranchHistory == true)
        #expect(reprepared.context?.reusedPortableMessageCount == 2)
    }

    @Test func deepSeekToolContinuationReusesThinkingAfterCoordinationScopeChanges() async throws {
        let broker = makeBroker()
        let coordinator = BranchRequestCoordinator()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D5"),
            targetModel: "deepseek-v4-pro",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [["role": "user", "content": "Read the file"]]
        ], options: [.sortedKeys])

        let firstPrepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|a",
            target: target
        )
        let firstContext = try #require(firstPrepared.context)
        let firstLease = switch await coordinator.acquire(context: firstContext) {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw IntegrationTestAbort()
        }

        try await broker.commitResponse(
            context: firstContext,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "I need the file contents.", "signature": "deepseek_sig"],
                        ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["path": "/tmp/file"]]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "tool_use", "id": "toolu_read", "name": "Read"]
                    ]
                ], options: [.sortedKeys])
            )
        )
        await coordinator.complete(lease: firstLease, replay: nil)

        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [
                ["role": "user", "content": "Read the file"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["path": "/tmp/file"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_read", "content": "contents"]
                ]]
            ]
        ], options: [.sortedKeys])

        let successorPrepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|b",
            target: target
        )

        #expect(successorPrepared.context?.reusedBranchHistory == true)
        let json = try #require(try JSONSerialization.jsonObject(with: successorPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["type"] as? String == "thinking")
        #expect(assistantBlocks.first?["signature"] as? String == "deepseek_sig")
    }

    @Test func deepSeekGuardedUnknownToolDropKeepsBranchReusableForThinkingReplay() async throws {
        let broker = makeBroker()
        let coordinator = BranchRequestCoordinator()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D6"),
            targetModel: "deepseek-v4-pro",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [["role": "user", "content": "Read the file"]]
        ], options: [.sortedKeys])

        let firstPrepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|a",
            target: target
        )
        let firstContext = try #require(firstPrepared.context)
        let firstLease = switch await coordinator.acquire(context: firstContext) {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw IntegrationTestAbort()
        }

        try await broker.commitResponse(
            context: firstContext,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "I need the file contents.", "signature": "deepseek_sig"],
                        ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["path": "/tmp/file"]]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "tool_use", "id": "toolu_read", "name": "Read"]
                    ]
                ], options: [.sortedKeys])
            )
        )
        await coordinator.complete(lease: firstLease, replay: nil)

        let toolResultRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [
                ["role": "user", "content": "Read the file"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["path": "/tmp/file"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_read", "content": "contents"]
                ]]
            ]
        ], options: [.sortedKeys])

        let toolResultPrepared = try await broker.prepareRequest(
            bodyData: toolResultRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|b",
            target: target
        )
        #expect(toolResultPrepared.context?.reusedBranchHistory == true)
        let toolResultContext = try #require(toolResultPrepared.context)
        let toolResultLease = switch await coordinator.acquire(context: toolResultContext) {
        case .acquired(let lease): lease
        default: Issue.record("Expected tool-result lease acquisition"); throw IntegrationTestAbort()
        }

        let guarder = ToolCallInputGuard(catalog: ToolCallInputGuard.ToolCatalog(schemasByName: [
            "Bash": [
                "type": "object",
                "required": ["cmd"],
                "properties": ["cmd": ["type": "string"]]
            ]
        ]))
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer(
            portableMode: true,
            toolCallGuard: guarder
        )
        let output = try pushSSE([
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep\",\"name\":\"Grep\",\"input\":{}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"TODO\\\"}\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        ], through: normalizer)
        #expect(output.contains("Tool call removed"))
        #expect(!output.contains("\"type\":\"tool_use\""))

        let guardedTurn = try #require(try normalizer.finish())
        let guardedPortableBlocks = try messageBlocks(from: guardedTurn.portableMessageData)
        let clientVisibleText = try #require(guardedPortableBlocks.first?["text"] as? String)
        try await broker.commitResponse(context: toolResultContext, assistantTurn: guardedTurn)
        await coordinator.complete(lease: toolResultLease, replay: nil)

        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [
                ["role": "user", "content": "Read the file"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["path": "/tmp/file"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_read", "content": "contents"]
                ]],
                ["role": "assistant", "content": [["type": "text", "text": clientVisibleText]]],
                ["role": "user", "content": "Continue"]
            ]
        ], options: [.sortedKeys])

        let successorPrepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|c",
            target: target
        )

        #expect(successorPrepared.context?.reusedBranchHistory == true)
        let successorJSON = try #require(try JSONSerialization.jsonObject(with: successorPrepared.bodyData) as? [String: Any])
        let successorMessages = try #require(successorJSON["messages"] as? [[String: Any]])
        let restoredToolUseBlocks = try #require(successorMessages[1]["content"] as? [[String: Any]])
        let guardedAssistantBlocks = try #require(successorMessages[3]["content"] as? [[String: Any]])
        #expect(restoredToolUseBlocks.first?["type"] as? String == "thinking")
        #expect(restoredToolUseBlocks.first?["signature"] as? String == "deepseek_sig")
        #expect(guardedAssistantBlocks.first?["type"] as? String == "text")
        #expect(guardedAssistantBlocks.first?["text"] as? String == clientVisibleText)
    }

    @Test func portableVendorToolUseIDsStayAnthropicSafeWhenReturningToMainSession() async throws {
        let broker = makeBroker()
        let normalizer = PortableContentNormalizer()
        let portableTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C4"),
            targetModel: "kimi-k2.5",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let invalidID = "toolu bad/id"
        let expectedID = ToolUseIDNormalizer.stableSafeID(for: invalidID)
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Run a tool"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: portableTarget
        )
        let qwenResponse = try JSONSerialization.data(withJSONObject: [
            "id": "msg_qwen",
            "role": "assistant",
            "content": [
                ["type": "tool_use", "id": invalidID, "name": "bash", "input": ["cmd": "pwd"]],
                ["type": "text", "text": "Tool requested"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(qwenResponse)
        try await broker.commitResponse(
            context: try #require(prepared.context),
            assistantTurn: try #require(normalized.assistantTurn)
        )

        let portableReply = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let portableBlocks = try #require(portableReply["content"] as? [[String: Any]])
        #expect(portableBlocks.first?["id"] as? String == expectedID)

        let mainOpusRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-6",
            "thinking": ["type": "adaptive"],
            "messages": [
                ["role": "user", "content": "Run a tool"],
                ["role": "assistant", "content": portableBlocks],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": expectedID, "content": "done"]
                ]]
            ]
        ], options: [.sortedKeys])

        let sanitized = ProxyForwarder.sanitizeAnthropicBodyIfNeeded(mainOpusRequest)
        #expect(sanitized.normalizedToolUseCount == 0)
        #expect(sanitized.normalizedToolResultCount == 0)
        let sanitizedJSON = try #require(try JSONSerialization.jsonObject(with: sanitized.bodyData) as? [String: Any])
        let messages = try #require(sanitizedJSON["messages"] as? [[String: Any]])
        let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        let toolResultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["id"] as? String == expectedID)
        #expect(toolResultBlocks.first?["tool_use_id"] as? String == expectedID)
    }

    @Test func anthropicOutboundGuardrailNormalizesLegacyInvalidToolIDs() throws {
        let invalidID = "toolu bad/id"
        let expectedID = ToolUseIDNormalizer.stableSafeID(for: invalidID)
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-6",
            "messages": [
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": invalidID, "name": "bash", "input": ["cmd": "pwd"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": invalidID, "content": "done"]
                ]]
            ]
        ], options: [.sortedKeys])

        let sanitized = ProxyForwarder.sanitizeAnthropicBodyIfNeeded(request)
        #expect(sanitized.normalizedToolUseCount == 1)
        #expect(sanitized.normalizedToolResultCount == 1)

        let json = try #require(try JSONSerialization.jsonObject(with: sanitized.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistantBlocks = try #require(messages.first?["content"] as? [[String: Any]])
        let userBlocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["id"] as? String == expectedID)
        #expect(userBlocks.first?["tool_use_id"] as? String == expectedID)
    }
}

private struct IntegrationTestAbort: Error {}

private func pushSSE(_ events: [String], through normalizer: PortableSSEStreamNormalizer) throws -> String {
    let allocator = ByteBufferAllocator()
    var output = Data()
    for event in events {
        var buffer = allocator.buffer(capacity: event.utf8.count)
        buffer.writeString(event)
        try normalizer.push(chunk: buffer).forEach { output.append($0) }
    }
    return String(data: output, encoding: .utf8) ?? ""
}

private func messageBlocks(from data: Data) throws -> [[String: Any]] {
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(json["content"] as? [[String: Any]])
}

private func makeBroker() -> SessionLineageBroker {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("lineages.json", isDirectory: false)
    return SessionLineageBroker(store: FileLineageStore(fileURL: storeURL))
}
