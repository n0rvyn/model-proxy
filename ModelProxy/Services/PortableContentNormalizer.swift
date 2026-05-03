import Foundation
import NIOCore
import NIOFoundationCompat

struct NormalizedResponseBody: Sendable {
    let bodyData: Data
    let assistantTurn: PortableAssistantTurn?
}

struct SSEToolCallGuardSummary: Equatable {
    let repairedCount: Int
    let droppedCount: Int
    let reasons: [String]

    var changed: Bool {
        repairedCount > 0 || droppedCount > 0
    }
}

protocol PortableContentNormalizing: Sendable {
    nonisolated func normalizeJSONBody(_ data: Data) throws -> NormalizedResponseBody
    nonisolated func makeSSEStreamNormalizer(
        portableMode: Bool,
        toolCallGuard: ToolCallInputGuard?
    ) -> PortableSSEStreamNormalizer
}

extension PortableContentNormalizing {
    nonisolated func makeSSEStreamNormalizer() -> PortableSSEStreamNormalizer {
        makeSSEStreamNormalizer(portableMode: true, toolCallGuard: nil)
    }
}

struct PortableContentNormalizer: PortableContentNormalizing {
    private let reducer: any BranchMergeReducing

    nonisolated init(reducer: any BranchMergeReducing = BranchMergeReducer()) {
        self.reducer = reducer
    }

    nonisolated func normalizeJSONBody(_ data: Data) throws -> NormalizedResponseBody {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NormalizedResponseBody(bodyData: data, assistantTurn: nil)
        }
        guard let content = json["content"] as? [Any] else {
            return NormalizedResponseBody(bodyData: data, assistantTurn: nil)
        }

        let message: [String: Any] = [
            "role": (json["role"] as? String) ?? "assistant",
            "content": content
        ]
        let assistantTurn = try reducer.reduceAssistantMessage(message)

        if let portableMessage = try JSONSerialization.jsonObject(with: assistantTurn.portableMessageData) as? [String: Any] {
            json["content"] = portableMessage["content"]
            if let role = portableMessage["role"] {
                json["role"] = role
            }
        }
        let normalizedData = try TranscriptProjector.encodeJSONObject(json)
        return NormalizedResponseBody(bodyData: normalizedData, assistantTurn: assistantTurn)
    }

    nonisolated func makeSSEStreamNormalizer(
        portableMode: Bool = true,
        toolCallGuard: ToolCallInputGuard? = nil
    ) -> PortableSSEStreamNormalizer {
        PortableSSEStreamNormalizer(
            reducer: reducer,
            portableMode: portableMode,
            toolCallGuard: toolCallGuard
        )
    }
}

final class PortableSSEStreamNormalizer {
    private let reducer: any BranchMergeReducing
    private let portableMode: Bool
    private let toolCallGuard: ToolCallInputGuard?
    private var bufferedData = Data()
    private var activeBlocks: [Int: SSEContentBlockBuilder] = [:]
    private var visibleIndexMap: [Int: Int] = [:]
    private var delayedToolUseIndexes: Set<Int> = []
    private var nextVisibleIndex = 0
    private var fullBlocksByIndex: [Int: [String: Any]] = [:]
    private var guardRepairedCount = 0
    private var guardDroppedCount = 0
    private var guardReasons: [String] = []

    nonisolated init(
        reducer: any BranchMergeReducing,
        portableMode: Bool = true,
        toolCallGuard: ToolCallInputGuard? = nil
    ) {
        self.reducer = reducer
        self.portableMode = portableMode
        self.toolCallGuard = toolCallGuard
    }

    func push(chunk: ByteBuffer) throws -> [Data] {
        guard let data = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) else {
            return []
        }
        bufferedData.append(data)

        var normalizedEvents: [Data] = []
        while let range = bufferedData.range(of: Data("\n\n".utf8)) {
            let eventData = bufferedData.subdata(in: bufferedData.startIndex..<range.upperBound)
            bufferedData.removeSubrange(bufferedData.startIndex..<range.upperBound)
            if let normalized = try normalizeEvent(eventData) {
                normalizedEvents.append(normalized)
            }
        }
        return normalizedEvents
    }

    func finish() throws -> PortableAssistantTurn? {
        defer { resetState() }
        if !bufferedData.isEmpty, let normalized = try normalizeEvent(bufferedData) {
            bufferedData = Data()
            if normalized.isEmpty {
                return nil
            }
        }

        finalizeRemainingActiveBlocks()

        let fullBlocks = orderedBlocks(from: fullBlocksByIndex)
        guard !fullBlocks.isEmpty else {
            return nil
        }

        let message: [String: Any] = [
            "role": "assistant",
            "content": fullBlocks
        ]
        return try reducer.reduceAssistantMessage(message)
    }

    func toolCallGuardSummary() -> SSEToolCallGuardSummary {
        SSEToolCallGuardSummary(
            repairedCount: guardRepairedCount,
            droppedCount: guardDroppedCount,
            reasons: guardReasons
        )
    }

    private func normalizeEvent(_ eventData: Data) throws -> Data? {
        guard let text = String(data: eventData, encoding: .utf8) else {
            return eventData
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let eventName = lines.first(where: { $0.hasPrefix("event:") })?.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let dataLines = lines.filter { $0.hasPrefix("data:") }.map {
            String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        guard !dataLines.isEmpty else {
            return eventData
        }

        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return eventData
        }

        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              var json = object as? [String: Any] else {
            return eventData
        }

        switch json["type"] as? String {
        case "content_block_start":
            return try normalizeBlockStart(json: &json, eventName: eventName)
        case "content_block_delta":
            return try normalizeBlockDelta(json: &json, eventName: eventName)
        case "content_block_stop":
            return try normalizeBlockStop(json: &json, eventName: eventName)
        default:
            return try encodeEvent(name: eventName, json: json)
        }
    }

    private func normalizeBlockStart(json: inout [String: Any], eventName: String?) throws -> Data? {
        guard let originalIndex = json["index"] as? Int,
              let block = json["content_block"] as? [String: Any] else {
            return try encodeEvent(name: eventName, json: json)
        }

        let normalizedBlock = ToolUseIDNormalizer.normalizeMessage([
            "role": "assistant",
            "content": [block]
        ])["content"] as? [[String: Any]]
        let visibleBlock = normalizedBlock?.first ?? block
        let isToolUse = (visibleBlock["type"] as? String)?.lowercased() == "tool_use"

        activeBlocks[originalIndex] = SSEContentBlockBuilder(block: visibleBlock)
        if portableMode, TranscriptProjector.isNonPortableBlock(visibleBlock) {
            return nil
        }

        let visibleIndex: Int
        if portableMode {
            visibleIndex = nextVisibleIndex
            nextVisibleIndex += 1
        } else {
            visibleIndex = originalIndex
        }
        visibleIndexMap[originalIndex] = visibleIndex

        if toolCallGuard != nil, isToolUse {
            delayedToolUseIndexes.insert(originalIndex)
            return nil
        }

        json["index"] = visibleIndex
        json["content_block"] = visibleBlock
        return try encodeEvent(name: eventName, json: json)
    }

    private func normalizeBlockDelta(json: inout [String: Any], eventName: String?) throws -> Data? {
        guard let originalIndex = json["index"] as? Int,
              let delta = json["delta"] as? [String: Any] else {
            return try encodeEvent(name: eventName, json: json)
        }

        activeBlocks[originalIndex]?.apply(delta: delta)

        if delayedToolUseIndexes.contains(originalIndex) {
            return nil
        }

        guard let visibleIndex = visibleIndexMap[originalIndex] else {
            return nil
        }

        if let deltaType = (delta["type"] as? String)?.lowercased(),
           portableMode,
           deltaType == "signature_delta" || deltaType.contains("thinking") || deltaType.contains("reasoning") {
            return nil
        }

        json["index"] = visibleIndex
        return try encodeEvent(name: eventName, json: json)
    }

    private func normalizeBlockStop(json: inout [String: Any], eventName: String?) throws -> Data? {
        guard let originalIndex = json["index"] as? Int else {
            return try encodeEvent(name: eventName, json: json)
        }

        if let builder = activeBlocks.removeValue(forKey: originalIndex) {
            let finalized = builder.finalize()
            if delayedToolUseIndexes.remove(originalIndex) != nil {
                let guardedBlock = guardedToolUseBlock(from: finalized)
                if let guardedBlock {
                    fullBlocksByIndex[originalIndex] = guardedBlock
                }
                if let visibleIndex = visibleIndexMap[originalIndex] {
                    visibleIndexMap.removeValue(forKey: originalIndex)
                    guard let guardedBlock else { return nil }
                    return try encodeGuardedBlockEvents(index: visibleIndex, block: guardedBlock)
                }
                return nil
            }

            fullBlocksByIndex[originalIndex] = finalized
            if let visibleIndex = visibleIndexMap[originalIndex] {
                json["index"] = visibleIndex
                visibleIndexMap.removeValue(forKey: originalIndex)
                return try encodeEvent(name: eventName, json: json)
            }
        }
        return nil
    }

    private func finalizeRemainingActiveBlocks() {
        for originalIndex in activeBlocks.keys.sorted() {
            guard let builder = activeBlocks.removeValue(forKey: originalIndex) else { continue }
            let finalized = builder.finalize()
            if delayedToolUseIndexes.remove(originalIndex) != nil {
                if let guardedBlock = guardedToolUseBlock(from: finalized) {
                    fullBlocksByIndex[originalIndex] = guardedBlock
                }
            } else {
                fullBlocksByIndex[originalIndex] = finalized
            }
            visibleIndexMap.removeValue(forKey: originalIndex)
        }
    }

    private func orderedBlocks(from indexedBlocks: [Int: [String: Any]]) -> [[String: Any]] {
        indexedBlocks.keys.sorted().compactMap { indexedBlocks[$0] }
    }

    private func resetState() {
        bufferedData = Data()
        activeBlocks.removeAll(keepingCapacity: false)
        visibleIndexMap.removeAll(keepingCapacity: false)
        delayedToolUseIndexes.removeAll(keepingCapacity: false)
        fullBlocksByIndex.removeAll(keepingCapacity: false)
        nextVisibleIndex = 0
        guardRepairedCount = 0
        guardDroppedCount = 0
        guardReasons.removeAll(keepingCapacity: false)
    }

    private func encodeGuardedBlockEvents(index: Int, block: [String: Any]) throws -> Data? {
        let blockType = (block["type"] as? String)?.lowercased()
        switch blockType {
        case "tool_use":
            return try encodeToolUseEvents(index: index, block: block)
        case "text":
            return try encodeTextEvents(index: index, text: block["text"] as? String ?? "")
        default:
            break
        }

        var data = Data()
        data.append(try encodeEvent(name: "content_block_start", json: [
            "type": "content_block_start",
            "index": index,
            "content_block": block
        ]))
        data.append(try encodeEvent(name: "content_block_stop", json: [
            "type": "content_block_stop",
            "index": index
        ]))
        return data
    }

    private func guardedToolUseBlock(from block: [String: Any]) -> [String: Any]? {
        guard let toolCallGuard else {
            return block
        }
        let transformed = toolCallGuard.transformContentBlocks([block])
        recordGuardTransform(transformed)
        return transformed.blocks.first as? [String: Any]
    }

    private func recordGuardTransform(_ transformed: ToolCallInputGuard.TransformResult) {
        guardRepairedCount += transformed.repairedCount
        guardDroppedCount += transformed.droppedCount
        for reason in transformed.reasons where !guardReasons.contains(reason) {
            guardReasons.append(reason)
        }
    }

    private func encodeToolUseEvents(index: Int, block: [String: Any]) throws -> Data {
        let input = block["input"] ?? [:]
        let inputData = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data("{}".utf8)
        let inputText = String(data: inputData, encoding: .utf8) ?? "{}"
        var data = Data()
        data.append(try encodeEvent(name: "content_block_start", json: [
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "tool_use",
                "id": block["id"] as? String ?? "",
                "name": block["name"] as? String ?? "",
                "input": [:]
            ]
        ]))
        data.append(try encodeEvent(name: "content_block_delta", json: [
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "input_json_delta",
                "partial_json": inputText
            ]
        ]))
        data.append(try encodeEvent(name: "content_block_stop", json: [
            "type": "content_block_stop",
            "index": index
        ]))
        return data
    }

    private func encodeTextEvents(index: Int, text: String) throws -> Data {
        var data = Data()
        data.append(try encodeEvent(name: "content_block_start", json: [
            "type": "content_block_start",
            "index": index,
            "content_block": [
                "type": "text",
                "text": ""
            ]
        ]))
        data.append(try encodeEvent(name: "content_block_delta", json: [
            "type": "content_block_delta",
            "index": index,
            "delta": [
                "type": "text_delta",
                "text": text
            ]
        ]))
        data.append(try encodeEvent(name: "content_block_stop", json: [
            "type": "content_block_stop",
            "index": index
        ]))
        return data
    }

    private func encodeEvent(name: String?, json: [String: Any]) throws -> Data {
        var event = ""
        if let name, !name.isEmpty {
            event += "event: \(name)\n"
        }
        let data = try TranscriptProjector.encodeJSONObject(json)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        event += "data: \(text)\n\n"
        return Data(event.utf8)
    }
}

private struct SSEContentBlockBuilder {
    private var block: [String: Any]
    private var inputJSONBuffer: String = ""

    init(block: [String: Any]) {
        self.block = block
        if let input = block["input"] {
            if let dictionary = input as? [String: Any], dictionary.isEmpty {
                return
            }
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                inputJSONBuffer = text
            }
        }
    }

    mutating func apply(delta: [String: Any]) {
        guard let deltaType = (delta["type"] as? String)?.lowercased() else { return }
        switch deltaType {
        case "text_delta":
            let current = (block["text"] as? String) ?? ""
            block["text"] = current + ((delta["text"] as? String) ?? "")
        case "thinking_delta":
            let current = (block["thinking"] as? String) ?? ""
            block["thinking"] = current + ((delta["thinking"] as? String) ?? "")
        case "signature_delta":
            block["signature"] = delta["signature"]
        case "input_json_delta":
            inputJSONBuffer += (delta["partial_json"] as? String) ?? ""
        default:
            break
        }
    }

    func finalize() -> [String: Any] {
        var finalized = block
        if !inputJSONBuffer.isEmpty,
           let data = inputJSONBuffer.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            finalized["input"] = json
        }
        return finalized
    }
}
