import Testing
import Foundation
import NIOCore
@testable import ModelProxy

@Suite(.serialized)
struct BranchMergeReducerTests {

    @Test func reducerRemovesThinkingAndSignatureFromPortableTurn() throws {
        let reducer = BranchMergeReducer()
        let turn = try reducer.reduceAssistantMessage([
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "private", "signature": "sig_1"],
                ["type": "tool_use", "id": "tool_1", "name": "git_status", "input": [:]],
                ["type": "text", "text": "Done"]
            ]
        ])

        let portable = try #require(try JSONSerialization.jsonObject(with: turn.portableMessageData) as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks.contains { $0["type"] as? String == "tool_use" })
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(!blocks.contains { $0["type"] as? String == "thinking" })
    }

    @Test func projectorNormalizesInvalidToolUseIDsAcrossMessages() throws {
        let invalidID = "toolu bad/id"
        let expectedID = ToolUseIDNormalizer.stableSafeID(for: invalidID)
        let portableMessages = TranscriptProjector.makePortableMessages(from: [
            [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "id": invalidID, "name": "bash", "input": ["cmd": "pwd"]]
                ]
            ],
            [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": invalidID, "content": "ok"]
                ]
            ]
        ])

        let assistantBlocks = try #require(portableMessages.first?["content"] as? [[String: Any]])
        let userBlocks = try #require(portableMessages.last?["content"] as? [[String: Any]])
        #expect(assistantBlocks.first?["id"] as? String == expectedID)
        #expect(userBlocks.first?["tool_use_id"] as? String == expectedID)
        #expect(ToolUseIDNormalizer.isValidToolID(expectedID))
    }

    @Test func jsonNormalizerNormalizesInvalidToolUseIdentifiers() throws {
        let invalidID = "toolu bad/id"
        let expectedID = ToolUseIDNormalizer.stableSafeID(for: invalidID)
        let normalizer = PortableContentNormalizer()
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "msg_1",
            "role": "assistant",
            "content": [
                ["type": "tool_use", "id": invalidID, "name": "bash", "input": ["cmd": "git status"]],
                ["type": "text", "text": "Running command"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(response)
        let json = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let blocks = try #require(json["content"] as? [[String: Any]])
        #expect(blocks.first?["id"] as? String == expectedID)

        let assistantTurn = try #require(normalized.assistantTurn)
        let portableJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let portableBlocks = try #require(portable["content"] as? [[String: Any]])
        #expect(portableBlocks.first?["id"] as? String == expectedID)
    }

    @Test func jsonNormalizerStripsReplaySensitiveBlocksFromResponse() throws {
        let normalizer = PortableContentNormalizer()
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "msg_1",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_qwen"],
                ["type": "text", "text": "Commit created"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(response)
        let json = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let blocks = try #require(json["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "Commit created")
        #expect(normalized.assistantTurn != nil)
    }

    @Test func sseNormalizerSuppressesThinkingEventsButKeepsFullTurnInternally() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig_qwen\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"secret\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Visible output\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n"
        ]

        var output = Data()
        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            let normalizedEvents = try normalizer.push(chunk: buffer)
            normalizedEvents.forEach { output.append($0) }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(!text.contains("\"thinking\""))
        #expect(text.contains("Visible output"))

        let finishedTurn = try normalizer.finish()
        let assistantTurn = try #require(finishedTurn)
        let fullJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.fullMessageData)
        let full = try #require(fullJSONObject as? [String: Any])
        let fullBlocks = try #require(full["content"] as? [[String: Any]])
        #expect(fullBlocks.count == 2)
        #expect(fullBlocks.first?["type"] as? String == "thinking")
    }

    @Test func sseNormalizerFinalizesActiveBlocksWhenStreamEndsWithoutBlockStop() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Committed successfully\"}}\n\n"
        ]

        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            _ = try normalizer.push(chunk: buffer)
        }

        let completedTurn = try normalizer.finish()
        let finishedTurn = try #require(completedTurn)
        let portableJSONObject = try JSONSerialization.jsonObject(with: finishedTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "Committed successfully")
    }

    @Test func sseNormalizerPassesMalformedJSONEventThroughWithoutThrowing() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let malformedEvent = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":\n\n"
        var malformedBuffer = allocator.buffer(capacity: malformedEvent.utf8.count)
        malformedBuffer.writeString(malformedEvent)
        let malformedOutput = try normalizer.push(chunk: malformedBuffer)
        let malformedText = String(data: malformedOutput.first ?? Data(), encoding: .utf8) ?? ""
        #expect(malformedOutput.count == 1)
        #expect(malformedText.contains("\"type\":\"content_block_delta\""))
    }

    @Test func sseNormalizerBuffersPartialEventUntilTerminatorArrives() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()
        let partialStart = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
        var firstBuffer = allocator.buffer(capacity: partialStart.utf8.count)
        firstBuffer.writeString(partialStart)

        let firstOutput = try normalizer.push(chunk: firstBuffer)
        #expect(firstOutput.isEmpty)

        var secondBuffer = allocator.buffer(capacity: 2)
        secondBuffer.writeString("\n\n")
        let secondOutput = try normalizer.push(chunk: secondBuffer)
        #expect(secondOutput.count == 1)

        let deltaEvent = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Buffered\"}}\n\n"
        var deltaBuffer = allocator.buffer(capacity: deltaEvent.utf8.count)
        deltaBuffer.writeString(deltaEvent)
        _ = try normalizer.push(chunk: deltaBuffer)

        let completedBufferedTurn = try normalizer.finish()
        let assistantTurn = try #require(completedBufferedTurn)
        let portableJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.first?["text"] as? String == "Buffered")
    }

    @Test func sseNormalizerNormalizesInvalidToolUseIdentifiersInStreamAndPortableTurn() throws {
        let invalidID = "toolu bad/id"
        let expectedID = ToolUseIDNormalizer.stableSafeID(for: invalidID)
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()
        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"\(invalidID)\",\"name\":\"bash\",\"input\":{}}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        ]

        var output = Data()
        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            let normalizedEvents = try normalizer.push(chunk: buffer)
            normalizedEvents.forEach { output.append($0) }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(text.contains(expectedID))
        #expect(!text.contains(invalidID))

        let assistantTurn = try #require(try normalizer.finish())
        let portableJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.first?["id"] as? String == expectedID)
    }

    @Test func sseNormalizerFinishIsConsumptiveAndSecondFinishReturnsNil() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()
        let event = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Once\"}}\n\n"
        var buffer = allocator.buffer(capacity: event.utf8.count)
        buffer.writeString(event)

        _ = try normalizer.push(chunk: buffer)

        let firstTurn = try #require(try normalizer.finish())
        let portableJSONObject = try JSONSerialization.jsonObject(with: firstTurn.portableMessageData)
        let portable = try #require(portableJSONObject as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.first?["text"] as? String == "Once")

        let secondTurn = try normalizer.finish()
        #expect(secondTurn == nil)
    }

    @Test func vendorReadyMessagesKeepThinkingButStripSignatureAndRedactedThinking() throws {
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "vendor thought", "signature": "sig_vendor"],
                    ["type": "redacted_thinking", "data": "opaque"],
                    ["type": "text", "text": "visible"]
                ]
            ]
        ]

        let vendorReady = TranscriptProjector.makeVendorReadyMessages(from: messages)
        let blocks = try #require(vendorReady.first?["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        let thinkingBlock = try #require(blocks.first { $0["type"] as? String == "thinking" })
        #expect(thinkingBlock["signature"] == nil)
        #expect(thinkingBlock["thinking"] as? String == "vendor thought")
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(!blocks.contains { $0["type"] as? String == "redacted_thinking" })
    }
}
