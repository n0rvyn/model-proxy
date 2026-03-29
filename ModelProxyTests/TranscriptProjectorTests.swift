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
            replayPolicy: .portableOnly
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
