import Testing
import Foundation
@testable import ModelProxy

struct TranscriptProjectorTests {

    @Test func vendorReadyRequestKeepsThinkingStripsSignatureButPortableHashesStripThinking() throws {
        let projector = TranscriptProjector()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_1"],
                ["type": "text", "text": "Visible text"]
            ]],
            ["role": "user", "content": "Do the commit"]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        // Request body should have thinking (signature stripped) — vendor needs it.
        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let thinkingConfig = try #require(json["thinking"] as? [String: Any])
        #expect(thinkingConfig["type"] as? String == "enabled")

        let assistantBlocks = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(assistantBlocks.count == 2)
        let thinkingBlock = try #require(assistantBlocks.first { $0["type"] as? String == "thinking" })
        #expect(thinkingBlock["signature"] == nil)
        #expect(thinkingBlock["thinking"] as? String == "secret")
        #expect(assistantBlocks.contains { $0["type"] as? String == "text" })

        // Portable messages should have thinking stripped — for hash consistency.
        let portableData = try #require(prepared.projectedPortableMessagesData)
        let portableMessages = try #require(try JSONSerialization.jsonObject(with: portableData) as? [[String: Any]])
        let portableAssistant = try #require(portableMessages.first?["content"] as? [[String: Any]])
        #expect(portableAssistant.count == 1)
        #expect(portableAssistant.first?["type"] as? String == "text")

        #expect(prepared.context != nil)
    }

    @Test func vendorReadyRequestStripsThinkingWhenVendorDoesNotSupportThinkingBlocks() throws {
        let projector = TranscriptProjector()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.example.com/anthropic",
            apiKey: "key",
            vendorName: "StrictVendor",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1"),
            targetModel: "strict-model",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: false
        )

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_1"],
                ["type": "redacted_thinking", "data": "opaque"],
                ["type": "reasoning", "reasoning": "private"],
                ["type": "text", "text": "Visible text"]
            ]],
            ["role": "user", "content": "Continue"]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistantBlocks = try #require(messages.first?["content"] as? [[String: Any]])
        let blockTypes = Set(assistantBlocks.compactMap { $0["type"] as? String })
        #expect(blockTypes == ["text"])
        #expect(!assistantBlocks.contains { $0["thinking"] != nil || $0["redacted_thinking"] != nil })
    }

    @Test func portableRequestRehydratesVendorLocalBranchHistory() throws {
        let projector = TranscriptProjector()
        let fingerprint = ConversationFingerprint()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let fullMessages: [[String: Any]] = [
            ["role": "user", "content": "Summarize the diff"],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "internal", "signature": "qwen_sig"],
                ["type": "text", "text": "I checked the diff."]
            ]]
        ]
        let portableMessages = TranscriptProjector.makePortableMessages(from: fullMessages)
        let portableHashes = try portableMessages.map { message in
            fingerprint.sha256Hex(try TranscriptProjector.encodeJSONObject(message))
        }
        let branch = BranchTranscript(
            lineageKey: "lineage-1",
            branchKey: "branch-1",
            clientName: "Claude Code",
            vendorKey: TranscriptProjector.vendorKey(for: target),
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            fullMessagesData: try TranscriptProjector.encodeMessages(fullMessages),
            portableMessagesData: try TranscriptProjector.encodeMessages(portableMessages),
            portableMessageHashes: portableHashes,
            lastUpdatedAt: .now
        )

        let nextRequest = try makeAnthropicRequestJSON(messages: portableMessages + [
            ["role": "user", "content": "Write the commit message"]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: nextRequest,
            clientName: "Claude Code",
            target: target,
            existingBranches: [branch],
            fingerprint: fingerprint
        )

        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredAssistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredAssistantBlocks.count == 2)
        #expect(restoredAssistantBlocks.first?["type"] as? String == "thinking")
        #expect(prepared.context?.branchKey == "branch-1")
        #expect(prepared.context?.reusedBranchHistory == true)
        #expect(prepared.context?.reusedPortableMessageCount == 2)
    }

    @Test func portableRequestDoesNotRehydrateThinkingForVendorWithoutThinkingBlocks() throws {
        let projector = TranscriptProjector()
        let fingerprint = ConversationFingerprint()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.example.com/anthropic",
            apiKey: "key",
            vendorName: "StrictVendor",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2"),
            targetModel: "strict-model",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: false
        )

        let fullMessages: [[String: Any]] = [
            ["role": "user", "content": "Run tool"],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "internal", "signature": "vendor_sig"],
                ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["path": "/tmp/file"]]
            ]]
        ]
        let portableMessages = TranscriptProjector.makePortableMessages(from: fullMessages)
        let portableHashes = try portableMessages.map { message in
            fingerprint.sha256Hex(try TranscriptProjector.encodeJSONObject(message))
        }
        let branch = BranchTranscript(
            lineageKey: "lineage-1",
            branchKey: "branch-1",
            clientName: "Claude Code",
            vendorKey: TranscriptProjector.vendorKey(for: target),
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            fullMessagesData: try TranscriptProjector.encodeMessages(fullMessages),
            portableMessagesData: try TranscriptProjector.encodeMessages(portableMessages),
            portableMessageHashes: portableHashes,
            lastUpdatedAt: .now
        )

        let nextRequest = try makeAnthropicRequestJSON(messages: portableMessages + [
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "file contents"]
            ]]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: nextRequest,
            clientName: "Claude Code",
            target: target,
            existingBranches: [branch],
            fingerprint: fingerprint
        )

        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredAssistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredAssistantBlocks.count == 1)
        #expect(restoredAssistantBlocks.first?["type"] as? String == "tool_use")
        #expect(!restoredAssistantBlocks.contains { $0["type"] as? String == "thinking" })
        #expect(prepared.context?.reusedBranchHistory == true)
    }

    @Test func transparentRequestIsLeftUntouched() throws {
        let projector = TranscriptProjector()
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

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_1"]
            ]]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        #expect(prepared.bodyData == request)
        #expect(prepared.context == nil)
    }

    @Test func portableCanonicalizationIgnoresCacheControlAndToolInputBackfill() throws {
        let firstMessages: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_write", "name": "Write", "input": [:]],
                ["type": "text", "text": "Done"]
            ]],
            ["role": "user", "content": [[
                "type": "tool_result",
                "tool_use_id": "toolu_write",
                "cache_control": ["type": "ephemeral"],
                "content": "ok"
            ]]]
        ]
        let secondMessages: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_write", "name": "Write", "input": ["content": "long backfilled payload"]],
                ["type": "text", "text": "Done"]
            ]],
            ["role": "user", "content": [[
                "type": "tool_result",
                "tool_use_id": "toolu_write",
                "content": "ok"
            ]]]
        ]

        let firstPortable = TranscriptProjector.makePortableMessages(from: firstMessages)
        let secondPortable = TranscriptProjector.makePortableMessages(from: secondMessages)
        let firstPortableData = try TranscriptProjector.encodeMessages(firstPortable)
        let secondPortableData = try TranscriptProjector.encodeMessages(secondPortable)

        #expect(firstPortable.count == secondPortable.count)
        #expect(firstPortableData == secondPortableData)
    }

    @Test func sessionScopedMatchingDoesNotReuseBranchFromOtherSession() throws {
        let projector = TranscriptProjector()
        let fingerprint = ConversationFingerprint()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let fullMessages: [[String: Any]] = [
            ["role": "user", "content": "Summarize the diff"],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "internal", "signature": "qwen_sig"],
                ["type": "text", "text": "I checked the diff."]
            ]]
        ]
        let portableMessages = TranscriptProjector.makePortableMessages(from: fullMessages)
        let portableHashes = try portableMessages.map { message in
            fingerprint.sha256Hex(try TranscriptProjector.encodeJSONObject(message))
        }
        let branch = BranchTranscript(
            lineageKey: "lineage-1",
            branchKey: "branch-1",
            clientName: "Claude Code",
            sessionScopeKey: "session-a",
            vendorKey: TranscriptProjector.vendorKey(for: target),
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            fullMessagesData: try TranscriptProjector.encodeMessages(fullMessages),
            portableMessagesData: try TranscriptProjector.encodeMessages(portableMessages),
            portableMessageHashes: portableHashes,
            lastUpdatedAt: .now
        )

        let nextRequest = try makeAnthropicRequestJSON(messages: portableMessages + [
            ["role": "user", "content": "Write the commit message"]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: nextRequest,
            clientName: "Claude Code",
            sessionScopeKey: "session-b",
            target: target,
            existingBranches: [branch],
            fingerprint: fingerprint
        )

        #expect(prepared.context?.reusedBranchHistory == false)
        #expect(prepared.context?.branchKey != "branch-1")
    }

    @Test func vendorReadyRequestStripsNonStandardContentTypes() throws {
        let projector = TranscriptProjector()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.minimax.chat/v1",
            apiKey: "key",
            vendorName: "MiniMax",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"),
            targetModel: "minimax-2.7-highspeed",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "assistant", "content": [
                ["type": "text", "text": "Let me check with the advisor."],
                ["type": "advisor_tool_use", "id": "adv_001", "name": "advisor", "input": [:]],
            ]],
            ["role": "user", "content": [
                ["type": "advisor_tool_result", "tool_use_id": "adv_001", "content": "advisor says yes"],
                ["type": "tool_result", "tool_use_id": "toolu_002", "content": "file contents"],
            ]],
            ["role": "assistant", "content": [
                ["type": "text", "text": "Based on the analysis..."],
                ["type": "server_tool_use", "id": "srv_001", "name": "server_tool", "input": [:]],
                ["type": "tool_use", "id": "toolu_003", "name": "Read", "input": ["path": "/tmp"]],
            ]],
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])

        // First assistant message: advisor_tool_use stripped, only text remains
        let msg0Blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(msg0Blocks.count == 1)
        #expect(msg0Blocks[0]["type"] as? String == "text")

        // User message: advisor_tool_result stripped, only tool_result remains
        let msg1Blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(msg1Blocks.count == 1)
        #expect(msg1Blocks[0]["type"] as? String == "tool_result")

        // Second assistant message: server_tool_use stripped, text + tool_use remain
        let msg2Blocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(msg2Blocks.count == 2)
        let msg2Types = Set(msg2Blocks.compactMap { $0["type"] as? String })
        #expect(msg2Types == ["text", "tool_use"])

        // Portable hashes should still include all blocks (non-standard types are part of identity)
        let portableData = try #require(prepared.projectedPortableMessagesData)
        let portableMessages = try #require(
            try JSONSerialization.jsonObject(with: portableData) as? [[String: Any]]
        )
        let portableMsg0Blocks = try #require(portableMessages[0]["content"] as? [[String: Any]])
        let portableMsg0Types = Set(portableMsg0Blocks.compactMap { $0["type"] as? String })
        #expect(portableMsg0Types.contains("advisor_tool_use"))
    }

    @Test func vendorReadyRequestFallsBackForUserMessageWithOnlyNonStandardBlocks() throws {
        let projector = TranscriptProjector()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.minimax.chat/v1",
            apiKey: "key",
            vendorName: "MiniMax",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2"),
            targetModel: "minimax-2.7-highspeed",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "user", "content": [
                ["type": "advisor_tool_result", "tool_use_id": "adv_001", "content": "advisor response"],
            ]],
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let userBlocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(userBlocks.count == 1)
        #expect(userBlocks[0]["type"] as? String == "text")
        #expect(userBlocks[0]["text"] as? String == "")
    }
}

private func makeAnthropicRequestJSON(messages: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "model": "claude-haiku-4-5-20251001",
        "thinking": ["type": "enabled", "budget_tokens": 32000],
        "messages": messages
    ], options: [.sortedKeys])
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
