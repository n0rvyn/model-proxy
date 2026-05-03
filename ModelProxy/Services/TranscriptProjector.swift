import Foundation

protocol TranscriptProjecting: Sendable {
    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        coordinationScopeKey: String?,
        target: RoutingSnapshot.RouteTarget,
        existingBranches: [BranchTranscript],
        fingerprint: any ConversationFingerprinting
    ) throws -> PreparedRequest
}

extension TranscriptProjecting {
    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget,
        existingBranches: [BranchTranscript],
        fingerprint: any ConversationFingerprinting
    ) throws -> PreparedRequest {
        try prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            sessionScopeKey: nil,
            coordinationScopeKey: nil,
            target: target,
            existingBranches: existingBranches,
            fingerprint: fingerprint
        )
    }

    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        target: RoutingSnapshot.RouteTarget,
        existingBranches: [BranchTranscript],
        fingerprint: any ConversationFingerprinting
    ) throws -> PreparedRequest {
        try prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            sessionScopeKey: sessionScopeKey,
            coordinationScopeKey: sessionScopeKey,
            target: target,
            existingBranches: existingBranches,
            fingerprint: fingerprint
        )
    }
}

enum TranscriptProjectorError: Error {
    case invalidJSON
}

struct TranscriptProjector: TranscriptProjecting {
    nonisolated init() {}

    nonisolated func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        coordinationScopeKey: String?,
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

        let vendorReadyMessages = Self.makeVendorReadyMessages(
            from: originalMessages,
            supportsThinkingBlocks: target.supportsThinkingBlocks
        )

        let vendorKey = Self.vendorKey(for: target)
        let matchedBranch = Self.bestMatchingBranch(
            for: portableMessageHashes,
            sessionScopeKey: sessionScopeKey,
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
            let suffix = Array(vendorReadyMessages.dropFirst(matchedBranch.portableMessageHashes.count))
            let branchMessagesForTarget = target.supportsThinkingBlocks
                ? branchFullMessages
                : Self.makeVendorReadyMessages(
                    from: branchFullMessages,
                    supportsThinkingBlocks: false
                )
            fullMessages = branchMessagesForTarget + suffix
            lineageKey = matchedBranch.lineageKey
            branchKey = matchedBranch.branchKey
            reusedBranchHistory = true
            reusedPortableMessageCount = matchedBranch.portableMessageHashes.count
        } else {
            fullMessages = vendorReadyMessages
            let lineageSeed = Self.lineageSeed(
                portableMessagesData: portableMessagesData,
                sessionScopeKey: sessionScopeKey
            )
            lineageKey = fingerprint.sha256Hex(lineageSeed)
            branchKey = fingerprint.sha256Hex(
                Self.branchSeed(
                    lineageKey: lineageKey,
                    vendorKey: vendorKey,
                    sessionScopeKey: sessionScopeKey,
                    coordinationScopeKey: coordinationScopeKey
                )
            )
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
            sessionScopeKey: sessionScopeKey,
            coordinationScopeKey: coordinationScopeKey,
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
        sessionScopeKey: String?,
        vendorKey: String,
        branches: [BranchTranscript]
    ) -> BranchTranscript? {
        branches
            .filter { branch in
                Self.isSessionScopeCompatible(branch.sessionScopeKey, request: sessionScopeKey)
                && branch.vendorKey == vendorKey
                && branch.portableMessageHashes.count <= portableMessageHashes.count
                && Array(portableMessageHashes.prefix(branch.portableMessageHashes.count)) == branch.portableMessageHashes
            }
            .max { lhs, rhs in lhs.portableMessageHashes.count < rhs.portableMessageHashes.count }
    }

    nonisolated static func isSessionScopeCompatible(
        _ branchSessionScopeKey: String?,
        request sessionScopeKey: String?
    ) -> Bool {
        if let sessionScopeKey {
            return branchSessionScopeKey == sessionScopeKey
        }
        guard let branchSessionScopeKey else { return true }
        return branchSessionScopeKey.contains("|channel|")
    }

    nonisolated static func makePortableMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        return normalized.messages.compactMap(makePortableMessage(from:))
    }

    nonisolated static func makePortableMessage(from message: [String: Any]) -> [String: Any]? {
        let normalizedMessage = ToolUseIDNormalizer.normalizeMessage(message)
        guard let content = normalizedMessage["content"] else {
            return PortableReplayCanonicalizer.canonicalizeMessage(normalizedMessage)
        }
        guard let blocks = content as? [Any] else {
            return PortableReplayCanonicalizer.canonicalizeMessage(normalizedMessage)
        }

        var portableMessage = PortableReplayCanonicalizer.canonicalizeMessage(normalizedMessage)
        let portableBlocks = makePortableBlocks(from: blocks)

        if let role = normalizedMessage["role"] as? String, role == "assistant", portableBlocks.isEmpty {
            portableMessage["content"] = [["type": "text", "text": ""]]
        } else {
            portableMessage["content"] = portableBlocks
        }
        return portableMessage
    }

    nonisolated static func makeVendorReadyMessages(
        from messages: [[String: Any]],
        supportsThinkingBlocks: Bool = true
    ) -> [[String: Any]] {
        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        return normalized.messages.compactMap { message in
            makeVendorReadyMessage(
                from: message,
                supportsThinkingBlocks: supportsThinkingBlocks
            )
        }
    }

    nonisolated static func makeVendorReadyMessage(
        from message: [String: Any],
        supportsThinkingBlocks: Bool = true
    ) -> [String: Any]? {
        let normalizedMessage = ToolUseIDNormalizer.normalizeMessage(message)
        guard let content = normalizedMessage["content"] else {
            return normalizedMessage
        }
        guard let blocks = content as? [Any] else {
            return normalizedMessage
        }

        var vendorMessage = normalizedMessage
        let vendorBlocks = makeVendorReadyBlocks(
            from: blocks,
            supportsThinkingBlocks: supportsThinkingBlocks
        )

        if let role = normalizedMessage["role"] as? String,
           (role == "assistant" || role == "user"),
           vendorBlocks.isEmpty {
            vendorMessage["content"] = [["type": "text", "text": ""]]
        } else {
            vendorMessage["content"] = vendorBlocks
        }
        return vendorMessage
    }

    /// Content block types that third-party vendors support via the Anthropic Messages API.
    /// Blocks with types outside this set are Anthropic-internal (e.g. advisor_tool_result)
    /// and are silently dropped to avoid 400 errors from vendors.
    private static let vendorSafeBlockTypes: Set<String> = [
        "text", "image", "document", "tool_use", "tool_result", "thinking"
    ]

    nonisolated static func makeVendorReadyBlocks(
        from blocks: [Any],
        supportsThinkingBlocks: Bool = true
    ) -> [Any] {
        blocks.compactMap { block in
            guard let dictionary = block as? [String: Any] else {
                return block
            }
            if isThinkingLikeBlock(dictionary), !supportsThinkingBlocks {
                return nil
            }
            guard let type = (dictionary["type"] as? String)?.lowercased(),
                  vendorSafeBlockTypes.contains(type) else {
                return nil
            }

            var sanitized = dictionary
            sanitized.removeValue(forKey: "signature")
            return sanitized
        }
    }

    nonisolated static func isThinkingLikeBlock(_ block: [String: Any]) -> Bool {
        if block["thinking"] != nil || block["redacted_thinking"] != nil { return true }
        guard let type = (block["type"] as? String)?.lowercased() else { return false }
        return type == "thinking" || type == "redacted_thinking" || type.contains("reasoning")
    }

    nonisolated static func makePortableBlocks(from blocks: [Any]) -> [Any] {
        blocks.compactMap { block in
            guard let dictionary = block as? [String: Any] else {
                return block
            }
            guard !isNonPortableBlock(dictionary) else {
                return nil
            }
            return PortableReplayCanonicalizer.canonicalizeBlock(dictionary)
        }
    }

    nonisolated static func isNonPortableBlock(_ block: [String: Any]) -> Bool {
        if block["signature"] != nil { return true }
        if block["thinking"] != nil || block["redacted_thinking"] != nil { return true }
        if let type = (block["type"] as? String)?.lowercased(),
           type == "thinking" || type == "redacted_thinking" || type.contains("reasoning") {
            return true
        }
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

    private nonisolated static func lineageSeed(
        portableMessagesData: Data,
        sessionScopeKey: String?
    ) -> Data {
        guard let sessionScopeKey else {
            return portableMessagesData
        }
        var seed = Data(sessionScopeKey.utf8)
        seed.append(0)
        seed.append(portableMessagesData)
        return seed
    }

    private nonisolated static func branchSeed(
        lineageKey: String,
        vendorKey: String,
        sessionScopeKey: String?,
        coordinationScopeKey: String?
    ) -> Data {
        guard sessionScopeKey == nil, let coordinationScopeKey else {
            return Data("\(lineageKey)|\(vendorKey)".utf8)
        }
        return Data("\(lineageKey)|\(vendorKey)|\(coordinationScopeKey)".utf8)
    }
}
