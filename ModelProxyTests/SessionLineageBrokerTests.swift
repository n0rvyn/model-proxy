import Testing
import Foundation
import NIOCore
@testable import ModelProxy

@MainActor
struct SessionLineageBrokerTests {

    @Test func brokerStoresVendorLocalAssistantTurnForNextBranchRequest() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            target: target
        )
        let context = try #require(prepared.context)
        let assistantTurn = PortableAssistantTurn(
            fullMessageData: try JSONSerialization.data(withJSONObject: [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "private branch reasoning", "signature": "qwen_sig"],
                    ["type": "text", "text": "I inspected the diff"]
                ]
            ], options: [.sortedKeys]),
            portableMessageData: try JSONSerialization.data(withJSONObject: [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "I inspected the diff"]
                ]
            ], options: [.sortedKeys])
        )

        try await broker.commitResponse(context: context, assistantTurn: assistantTurn)

        let secondRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let secondPrepared = try await broker.prepareRequest(
            bodyData: secondRequest,
            clientName: "Claude Code",
            target: target
        )

        let json = try #require(try JSONSerialization.jsonObject(with: secondPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredBlocks.count == 2)
        #expect(restoredBlocks.first?["signature"] as? String == "qwen_sig")
    }

    @Test func brokerScopesBranchCacheByClientName() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Task"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: target)
        let context = try #require(prepared.context)
        try await broker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys])
            )
        )

        #expect(await broker.branches(for: "Claude Code").count == 1)
        #expect(await broker.branches(for: "Claude Code", sessionScopeKey: nil).count == 1)
        #expect(await broker.branches(for: "Codex").isEmpty)
    }

    @Test func brokerScopesBranchReuseBySessionScopeKey() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Task"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            sessionScopeKey: "session-a",
            target: target
        )
        let context = try #require(prepared.context)
        try await broker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys])
            )
        )

        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Task"],
                ["role": "assistant", "content": [["type": "text", "text": "done"]]],
                ["role": "user", "content": "Next"]
            ]
        ], options: [.sortedKeys])

        let sameSessionPrepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            sessionScopeKey: "session-a",
            target: target
        )
        let otherSessionPrepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            sessionScopeKey: "session-b",
            target: target
        )

        #expect(await broker.branches(for: "Claude Code", sessionScopeKey: "session-a").count == 1)
        #expect(await broker.branches(for: "Claude Code", sessionScopeKey: "session-b").isEmpty)
        #expect(sameSessionPrepared.context?.reusedBranchHistory == true)
        #expect(otherSessionPrepared.context?.reusedBranchHistory == false)
    }

    @Test func brokerReusesNoExplicitBranchAcrossCoordinationScopes() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3"),
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
            "messages": [["role": "user", "content": "Run a tool"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|a",
            target: target
        )
        let context = try #require(prepared.context)
        try await broker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "tool reasoning", "signature": "deepseek_sig"],
                        ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["path": "/tmp/file"]]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "tool_use", "id": "toolu_1", "name": "Read"]
                    ]
                ], options: [.sortedKeys])
            )
        )

        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "messages": [
                ["role": "user", "content": "Run a tool"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "toolu_1", "name": "Read", "input": ["path": "/tmp/file"]]
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": "contents"]
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

        let successorContext = try #require(successorPrepared.context)
        #expect(successorContext.sessionScopeKey == nil)
        #expect(successorContext.coordinationScopeKey == "Claude Code|channel|b")
        #expect(successorContext.reusedBranchHistory == true)
        let json = try #require(try JSONSerialization.jsonObject(with: successorPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredBlocks.first?["type"] as? String == "thinking")
        #expect(restoredBlocks.first?["signature"] as? String == "deepseek_sig")
    }

    @Test func brokerCanReuseLegacyChannelScopedBranchForNoExplicitSession() async throws {
        let broker = makeBroker()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.deepseek.com/anthropic",
            apiKey: "key",
            vendorName: "DeepSeek",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D4"),
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
            "messages": [["role": "user", "content": "Inspect"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            sessionScopeKey: "Claude Code|channel|legacy",
            coordinationScopeKey: "Claude Code|channel|legacy",
            target: target
        )
        let context = try #require(prepared.context)
        try await broker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "legacy reasoning", "signature": "legacy_sig"],
                        ["type": "text", "text": "done"]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]]
                ], options: [.sortedKeys])
            )
        )

        let successorRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-7",
            "messages": [
                ["role": "user", "content": "Inspect"],
                ["role": "assistant", "content": [["type": "text", "text": "done"]]],
                ["role": "user", "content": "Continue"]
            ]
        ], options: [.sortedKeys])

        let successorPrepared = try await broker.prepareRequest(
            bodyData: successorRequest,
            clientName: "Claude Code",
            sessionScopeKey: nil,
            coordinationScopeKey: "Claude Code|channel|new",
            target: target
        )

        #expect(successorPrepared.context?.reusedBranchHistory == true)
        let json = try #require(try JSONSerialization.jsonObject(with: successorPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredBlocks.first?["signature"] as? String == "legacy_sig")
    }

    @Test func brokerReusesBranchAfterSSECommitWithoutContentBlockStop() async throws {
        let broker = makeBroker()
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            target: target
        )
        let context = try #require(prepared.context)

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I inspected the diff\"}}\n\n"
        ]

        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            _ = try normalizer.push(chunk: buffer)
        }

        let finishedTurn = try normalizer.finish()
        let assistantTurn = try #require(finishedTurn)
        try await broker.commitResponse(context: context, assistantTurn: assistantTurn)

        let secondRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let secondPrepared = try await broker.prepareRequest(
            bodyData: secondRequest,
            clientName: "Claude Code",
            target: target
        )

        #expect(secondPrepared.context?.reusedBranchHistory == true)
        #expect(secondPrepared.context?.reusedPortableMessageCount == 2)
    }

    @Test func brokerTrimsLineagesToMostRecentTwentyFourPerClient() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("lineages.json", isDirectory: false)
        let broker = SessionLineageBroker(store: FileLineageStore(fileURL: storeURL))
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B4"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        for index in 0..<25 {
            let request = try JSONSerialization.data(withJSONObject: [
                "model": "claude-haiku-4-5-20251001",
                "messages": [["role": "user", "content": "Task \(index)"]]
            ], options: [.sortedKeys])

            let prepared = try await broker.prepareRequest(
                bodyData: request,
                clientName: "Claude Code",
                target: target
            )
            let context = try #require(prepared.context)
            try await broker.commitResponse(
                context: context,
                assistantTurn: PortableAssistantTurn(
                    fullMessageData: try JSONSerialization.data(withJSONObject: [
                        "role": "assistant",
                        "content": [["type": "text", "text": "done \(index)"]]
                    ], options: [.sortedKeys]),
                    portableMessageData: try JSONSerialization.data(withJSONObject: [
                        "role": "assistant",
                        "content": [["type": "text", "text": "done \(index)"]]
                    ], options: [.sortedKeys])
                )
            )
        }

        let branches = await broker.branches(for: "Claude Code")
        #expect(branches.count == 24)
        let portableTexts = try branches.map { branch in
            let messages = try TranscriptProjector.decodeMessagesData(branch.portableMessagesData)
            let assistant = try #require(messages.last)
            let blocks = try #require(assistant["content"] as? [[String: Any]])
            return blocks.first?["text"] as? String
        }
        #expect(!portableTexts.contains("done 0"))
        #expect(portableTexts.contains("done 24"))

        let persisted = try FileLineageStore(fileURL: storeURL).loadLineages()
        let persistedBranches = persisted.values
            .filter { $0.clientName == "Claude Code" }
            .flatMap(\.branches.values)
        #expect(persistedBranches.count == 24)
    }

    @Test func brokerReloadsCommittedBranchHistoryFromPersistentStore() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("lineages.json", isDirectory: false)
        let store = FileLineageStore(fileURL: storeURL)
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B5"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsThinkingBlocks: true
        )

        let initialBroker = SessionLineageBroker(store: store)
        let firstRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await initialBroker.prepareRequest(
            bodyData: firstRequest,
            clientName: "Claude Code",
            target: target
        )
        let context = try #require(prepared.context)
        try await initialBroker.commitResponse(
            context: context,
            assistantTurn: PortableAssistantTurn(
                fullMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "private branch reasoning", "signature": "persisted_sig"],
                        ["type": "text", "text": "I inspected the diff"]
                    ]
                ], options: [.sortedKeys]),
                portableMessageData: try JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": [["type": "text", "text": "I inspected the diff"]]
                ], options: [.sortedKeys])
            )
        )

        let restartedBroker = SessionLineageBroker(store: store)
        let secondRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [
                ["role": "user", "content": "Inspect the diff"],
                ["role": "assistant", "content": [["type": "text", "text": "I inspected the diff"]]],
                ["role": "user", "content": "Write the commit message"]
            ]
        ], options: [.sortedKeys])

        let secondPrepared = try await restartedBroker.prepareRequest(
            bodyData: secondRequest,
            clientName: "Claude Code",
            target: target
        )

        #expect(secondPrepared.context?.reusedBranchHistory == true)
        #expect(secondPrepared.context?.reusedPortableMessageCount == 2)

        let json = try #require(try JSONSerialization.jsonObject(with: secondPrepared.bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let restoredBlocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(restoredBlocks.first?["signature"] as? String == "persisted_sig")
    }

    @Test func brokerDoesNotMutateInMemoryStateWhenPersistenceFails() async throws {
        let store = SaveFailingLineageStore()
        let broker = SessionLineageBroker(store: store)
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B6"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])
        let prepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: target)
        let context = try #require(prepared.context)

        await #expect(throws: SaveFailingLineageStore.Error.failed) {
            try await broker.commitResponse(
                context: context,
                assistantTurn: PortableAssistantTurn(
                    fullMessageData: try JSONSerialization.data(withJSONObject: [
                        "role": "assistant",
                        "content": [["type": "text", "text": "done"]]
                    ], options: [.sortedKeys]),
                    portableMessageData: try JSONSerialization.data(withJSONObject: [
                        "role": "assistant",
                        "content": [["type": "text", "text": "done"]]
                    ], options: [.sortedKeys])
                )
            )
        }

        #expect(await broker.branches(for: "Claude Code").isEmpty)
        #expect(store.saveAttempts == 1)
    }

    @Test func brokerStartsColdWhenPersistedLineageFileIsMalformed() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("lineages.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{broken".utf8).write(to: storeURL, options: [.atomic])

        let broker = SessionLineageBroker(store: FileLineageStore(fileURL: storeURL))
        #expect(await broker.branches(for: "Claude Code").isEmpty)

        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B7"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let prepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: target)
        #expect(prepared.context != nil)
    }

    @Test func concurrentCommitsToSameLineagePersistBothBranches() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("lineages.json", isDirectory: false)
        let store = FileLineageStore(fileURL: storeURL)
        let broker = SessionLineageBroker(store: store)
        let primaryTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen-A",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B8"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )
        let secondaryTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen-B",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B9"),
            targetModel: "qwen3.5-max",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": "Inspect the diff"]]
        ], options: [.sortedKeys])

        let firstPrepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: primaryTarget)
        let secondPrepared = try await broker.prepareRequest(bodyData: request, clientName: "Claude Code", target: secondaryTarget)
        let firstContext = try #require(firstPrepared.context)
        let secondContext = try #require(secondPrepared.context)
        #expect(firstContext.lineageKey == secondContext.lineageKey)
        #expect(firstContext.branchKey != secondContext.branchKey)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await broker.commitResponse(
                    context: firstContext,
                    assistantTurn: PortableAssistantTurn(
                        fullMessageData: try JSONSerialization.data(withJSONObject: [
                            "role": "assistant",
                            "content": [["type": "text", "text": "done A"]]
                        ], options: [.sortedKeys]),
                        portableMessageData: try JSONSerialization.data(withJSONObject: [
                            "role": "assistant",
                            "content": [["type": "text", "text": "done A"]]
                        ], options: [.sortedKeys])
                    )
                )
            }
            group.addTask {
                try await broker.commitResponse(
                    context: secondContext,
                    assistantTurn: PortableAssistantTurn(
                        fullMessageData: try JSONSerialization.data(withJSONObject: [
                            "role": "assistant",
                            "content": [["type": "text", "text": "done B"]]
                        ], options: [.sortedKeys]),
                        portableMessageData: try JSONSerialization.data(withJSONObject: [
                            "role": "assistant",
                            "content": [["type": "text", "text": "done B"]]
                        ], options: [.sortedKeys])
                    )
                )
            }
            try await group.waitForAll()
        }

        let persisted = try store.loadLineages()
        let lineage = try #require(persisted[firstContext.lineageKey])
        #expect(lineage.branches.count == 2)
        #expect(lineage.branches[firstContext.branchKey] != nil)
        #expect(lineage.branches[secondContext.branchKey] != nil)
    }
}

private func makeBroker() -> SessionLineageBroker {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("lineages.json", isDirectory: false)
    return SessionLineageBroker(store: FileLineageStore(fileURL: storeURL))
}

private final class SaveFailingLineageStore: LineageStoring, @unchecked Sendable {
    enum Error: Swift.Error {
        case failed
    }

    private(set) var saveAttempts = 0

    func loadLineages() throws -> [String: ConversationLineage] {
        [:]
    }

    func saveLineages(_ lineages: [String : ConversationLineage]) throws {
        saveAttempts += 1
        throw Error.failed
    }
}
