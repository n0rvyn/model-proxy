import Foundation
import NIOCore
import NIOFoundationCompat

struct NormalizedResponseBody: Sendable {
    let bodyData: Data
    let assistantTurn: PortableAssistantTurn?
}

protocol PortableContentNormalizing: Sendable {
    nonisolated func normalizeJSONBody(_ data: Data) throws -> NormalizedResponseBody
    nonisolated func makeSSEStreamNormalizer() -> PortableSSEStreamNormalizer
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

    nonisolated func makeSSEStreamNormalizer() -> PortableSSEStreamNormalizer {
        PortableSSEStreamNormalizer(reducer: reducer)
    }
}

final class PortableSSEStreamNormalizer {
    private let reducer: any BranchMergeReducing
    private var bufferedData = Data()
    private var activeBlocks: [Int: SSEContentBlockBuilder] = [:]
    private var visibleIndexMap: [Int: Int] = [:]
    private var nextVisibleIndex = 0
    private var fullBlocksByIndex: [Int: [String: Any]] = [:]

    nonisolated init(reducer: any BranchMergeReducing) {
        self.reducer = reducer
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

        activeBlocks[originalIndex] = SSEContentBlockBuilder(block: visibleBlock)
        if TranscriptProjector.isNonPortableBlock(visibleBlock) {
            return nil
        }

        let visibleIndex = nextVisibleIndex
        nextVisibleIndex += 1
        visibleIndexMap[originalIndex] = visibleIndex
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

        guard let visibleIndex = visibleIndexMap[originalIndex] else {
            return nil
        }

        if let deltaType = (delta["type"] as? String)?.lowercased(),
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
            fullBlocksByIndex[originalIndex] = finalized
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
        fullBlocksByIndex.removeAll(keepingCapacity: false)
        nextVisibleIndex = 0
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
