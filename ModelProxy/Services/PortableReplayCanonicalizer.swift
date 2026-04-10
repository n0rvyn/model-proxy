import Foundation

struct PortableReplayCanonicalizer {
    nonisolated init() {}

    nonisolated static func canonicalizeMessage(_ message: [String: Any]) -> [String: Any] {
        var canonical = pruneReplayUnstableFields(from: message)
        guard let content = canonical["content"] as? [Any] else {
            return canonical
        }

        canonical["content"] = content.compactMap { block in
            guard let dictionary = block as? [String: Any] else {
                return block
            }
            return canonicalizeBlock(dictionary)
        }
        return canonical
    }

    nonisolated static func canonicalizeBlock(_ block: [String: Any]) -> [String: Any] {
        let sanitized = pruneReplayUnstableFields(from: block)

        switch (sanitized["type"] as? String)?.lowercased() {
        case "tool_use":
            return canonicalizeToolUseBlock(sanitized)
        case "tool_result":
            return canonicalizeToolResultBlock(sanitized)
        default:
            return sanitized
        }
    }

    private nonisolated static func canonicalizeToolUseBlock(_ block: [String: Any]) -> [String: Any] {
        var canonical: [String: Any] = [:]

        if let type = block["type"] {
            canonical["type"] = type
        }
        if let id = block["id"] {
            canonical["id"] = id
        }
        if let name = block["name"] {
            canonical["name"] = name
        }

        // Claude Code tool payloads have been observed to be backfilled after the fact.
        // Replay identity should follow the stable tool invocation handle, not the mutable payload.
        if canonical.isEmpty {
            return block
        }
        return canonical
    }

    private nonisolated static func canonicalizeToolResultBlock(_ block: [String: Any]) -> [String: Any] {
        var canonical: [String: Any] = [:]

        if let type = block["type"] {
            canonical["type"] = type
        }
        if let toolUseID = block["tool_use_id"] {
            canonical["tool_use_id"] = toolUseID
        }
        if let isError = block["is_error"] {
            canonical["is_error"] = isError
        }
        if let content = block["content"] {
            canonical["content"] = pruneReplayUnstableValue(content)
        }

        return canonical.isEmpty ? block : canonical
    }

    private nonisolated static func pruneReplayUnstableFields(from dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { partialResult, entry in
            guard entry.key != "cache_control" else { return }
            partialResult[entry.key] = pruneReplayUnstableValue(entry.value)
        }
    }

    private nonisolated static func pruneReplayUnstableValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return pruneReplayUnstableFields(from: dictionary)
        case let array as [Any]:
            return array.map(pruneReplayUnstableValue)
        default:
            return value
        }
    }
}
