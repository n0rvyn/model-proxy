import Foundation

protocol TranscriptProjecting: Sendable {
    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget,
        existingBranches: [BranchTranscript],
        fingerprint: any ConversationFingerprinting
    ) throws -> PreparedRequest
}

enum TranscriptProjectorError: Error {
    case invalidJSON
}

struct TranscriptProjector: TranscriptProjecting {
    nonisolated init() {}

    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget,
        existingBranches: [BranchTranscript],
        fingerprint: any ConversationFingerprinting
    ) throws -> PreparedRequest {
        guard target.replayPolicy == .portableOnly else {
            return PreparedRequest(bodyData: bodyData, context: nil, projectedPortableMessagesData: nil)
        }

        guard var json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw TranscriptProjectorError.invalidJSON
        }
        guard let originalMessages = json["messages"] as? [[String: Any]] else {
            return PreparedRequest(bodyData: bodyData, context: nil, projectedPortableMessagesData: nil)
        }

        let portableMessages = Self.makePortableMessages(from: originalMessages)
        let portableMessagesData = try Self.encodeMessages(portableMessages)
        let portableMessageHashes = portableMessages.map { message in
            fingerprint.sha256Hex((try? Self.encodeJSONObject(message)) ?? Data())
        }

        let vendorKey = Self.vendorKey(for: target)
        let matchedBranch = Self.bestMatchingBranch(
            for: portableMessageHashes,
            vendorKey: vendorKey,
            branches: existingBranches
        )

        let fullMessages: [[String: Any]]
        let lineageKey: String
        let branchKey: String
        let reusedBranchHistory: Bool
        let reusedPortableMessageCount: Int

        if let matchedBranch,
           let branchFullMessages = try? Self.decodeMessagesData(matchedBranch.fullMessagesData) {
            let suffix = Array(portableMessages.dropFirst(matchedBranch.portableMessageHashes.count))
            fullMessages = branchFullMessages + suffix
            lineageKey = matchedBranch.lineageKey
            branchKey = matchedBranch.branchKey
            reusedBranchHistory = true
            reusedPortableMessageCount = matchedBranch.portableMessageHashes.count
        } else {
            fullMessages = portableMessages
            lineageKey = fingerprint.sha256Hex(portableMessagesData)
            branchKey = fingerprint.sha256Hex(Data("\(lineageKey)|\(vendorKey)".utf8))
            reusedBranchHistory = false
            reusedPortableMessageCount = 0
        }

        let fullMessagesData = try Self.encodeMessages(fullMessages)
        json["messages"] = fullMessages
        let projectedBodyData = try Self.encodeJSONObject(json)

        let context = PreparedBranchContext(
            lineageKey: lineageKey,
            branchKey: branchKey,
            clientName: clientName,
            vendorKey: vendorKey,
            signingDomain: target.signingDomain,
            replayPolicy: target.replayPolicy,
            preparedFullMessagesData: fullMessagesData,
            preparedPortableMessagesData: portableMessagesData,
            preparedPortableMessageHashes: portableMessageHashes,
            reusedBranchHistory: reusedBranchHistory,
            reusedPortableMessageCount: reusedPortableMessageCount
        )

        return PreparedRequest(
            bodyData: projectedBodyData,
            context: context,
            projectedPortableMessagesData: portableMessagesData
        )
    }

    nonisolated static func vendorKey(for target: RoutingSnapshot.RouteTarget) -> String {
        target.vendorID?.uuidString ?? target.baseURL
    }

    nonisolated static func bestMatchingBranch(
        for portableMessageHashes: [String],
        vendorKey: String,
        branches: [BranchTranscript]
    ) -> BranchTranscript? {
        branches
            .filter { branch in
                branch.vendorKey == vendorKey
                && branch.portableMessageHashes.count <= portableMessageHashes.count
                && Array(portableMessageHashes.prefix(branch.portableMessageHashes.count)) == branch.portableMessageHashes
            }
            .max { lhs, rhs in lhs.portableMessageHashes.count < rhs.portableMessageHashes.count }
    }

    nonisolated static func makePortableMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        return normalized.messages.compactMap(makePortableMessage(from:))
    }

    nonisolated static func makePortableMessage(from message: [String: Any]) -> [String: Any]? {
        let normalizedMessage = ToolUseIDNormalizer.normalizeMessage(message)
        guard let content = normalizedMessage["content"] else {
            return normalizedMessage
        }
        guard let blocks = content as? [Any] else {
            return normalizedMessage
        }

        var portableMessage = normalizedMessage
        let portableBlocks = makePortableBlocks(from: blocks)

        if let role = normalizedMessage["role"] as? String, role == "assistant", portableBlocks.isEmpty {
            portableMessage["content"] = [["type": "text", "text": ""]]
        } else {
            portableMessage["content"] = portableBlocks
        }
        return portableMessage
    }

    nonisolated static func makePortableBlocks(from blocks: [Any]) -> [Any] {
        blocks.compactMap { block in
            guard let dictionary = block as? [String: Any] else {
                return block
            }
            guard !isNonPortableBlock(dictionary) else {
                return nil
            }

            var sanitized = dictionary
            sanitized.removeValue(forKey: "signature")
            return sanitized
        }
    }

    nonisolated static func isNonPortableBlock(_ block: [String: Any]) -> Bool {
        if let type = (block["type"] as? String)?.lowercased(),
           type == "redacted_thinking" {
            return true
        }
        if block["redacted_thinking"] != nil { return true }
        return false
    }

    nonisolated static func encodeJSONObject(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    nonisolated static func encodeMessages(_ messages: [[String: Any]]) throws -> Data {
        try encodeJSONObject(messages)
    }

    nonisolated static func decodeMessagesData(_ data: Data) throws -> [[String: Any]] {
        guard let messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TranscriptProjectorError.invalidJSON
        }
        return messages
    }

    nonisolated static func appendMessage(_ messageData: Data, to messagesData: Data) throws -> Data {
        var messages = try decodeMessagesData(messagesData)
        guard let message = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            throw TranscriptProjectorError.invalidJSON
        }
        messages.append(message)
        return try encodeMessages(messages)
    }
}
