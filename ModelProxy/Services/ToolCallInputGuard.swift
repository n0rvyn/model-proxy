import Foundation

struct ToolCallInputGuard {
    struct ToolCatalog {
        let schemasByName: [String: [String: Any]]

        var isEmpty: Bool {
            schemasByName.isEmpty
        }

        static func fromRequestBody(_ data: Data) -> ToolCatalog {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tools = json["tools"] as? [[String: Any]] else {
                return ToolCatalog(schemasByName: [:])
            }

            var schemas: [String: [String: Any]] = [:]
            for tool in tools {
                guard let name = tool["name"] as? String, !name.isEmpty,
                      let schema = tool["input_schema"] as? [String: Any] else {
                    continue
                }
                schemas[name] = schema
            }
            return ToolCatalog(schemasByName: schemas)
        }
    }

    enum Action: Equatable {
        case unchanged
        case repaired(String)
        case dropped(String)
    }

    struct BlockResult {
        let block: [String: Any]?
        let action: Action
    }

    struct TransformResult {
        let blocks: [Any]
        let repairedCount: Int
        let droppedCount: Int
        let reasons: [String]

        var changed: Bool {
            repairedCount > 0 || droppedCount > 0
        }
    }

    struct JSONTransformResult {
        let data: Data
        let repairedCount: Int
        let droppedCount: Int
        let reasons: [String]
        let parseFailed: Bool

        var changed: Bool {
            repairedCount > 0 || droppedCount > 0
        }
    }

    let catalog: ToolCatalog

    init(catalog: ToolCatalog) {
        self.catalog = catalog
    }

    func transformJSONResponseBody(_ data: Data) -> JSONTransformResult {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JSONTransformResult(
                data: data,
                repairedCount: 0,
                droppedCount: 0,
                reasons: ["response_json_parse_failed"],
                parseFailed: true
            )
        }

        guard let content = json["content"] as? [Any] else {
            return JSONTransformResult(
                data: data,
                repairedCount: 0,
                droppedCount: 0,
                reasons: [],
                parseFailed: false
            )
        }

        let transformed = transformContentBlocks(content)
        guard transformed.changed else {
            return JSONTransformResult(
                data: data,
                repairedCount: 0,
                droppedCount: 0,
                reasons: [],
                parseFailed: false
            )
        }

        json["content"] = transformed.blocks
        let remainingToolUseCount = transformed.blocks.filter {
            (($0 as? [String: Any])?["type"] as? String)?.lowercased() == "tool_use"
        }.count
        if let stopReason = Self.stopReasonAfterGuard(
            json["stop_reason"] as? String,
            remainingToolUseCount: remainingToolUseCount,
            droppedCount: transformed.droppedCount
        ) {
            json["stop_reason"] = stopReason
        }
        let encoded = (try? TranscriptProjector.encodeJSONObject(json)) ?? data
        return JSONTransformResult(
            data: encoded,
            repairedCount: transformed.repairedCount,
            droppedCount: transformed.droppedCount,
            reasons: transformed.reasons,
            parseFailed: false
        )
    }

    func transformContentBlocks(_ blocks: [Any]) -> TransformResult {
        var transformedBlocks: [Any] = []
        var repairedCount = 0
        var droppedCount = 0
        var reasons: [String] = []

        for block in blocks {
            guard let dictionary = block as? [String: Any],
                  (dictionary["type"] as? String)?.lowercased() == "tool_use" else {
                transformedBlocks.append(block)
                continue
            }

            let result = repairToolUseBlock(dictionary)
            switch result.action {
            case .unchanged:
                transformedBlocks.append(result.block ?? dictionary)
            case .repaired(let reason):
                repairedCount += 1
                reasons.append(reason)
                transformedBlocks.append(result.block ?? dictionary)
            case .dropped(let reason):
                droppedCount += 1
                reasons.append(reason)
                transformedBlocks.append(Self.invalidToolTextBlock(
                    toolName: dictionary["name"] as? String,
                    reason: reason
                ))
            }
        }

        return TransformResult(
            blocks: transformedBlocks,
            repairedCount: repairedCount,
            droppedCount: droppedCount,
            reasons: reasons
        )
    }

    /// Repairs only the *shape* of a returned `tool_use` block so it stays a valid Anthropic block in
    /// Claude Code's history. Argument *content* (required fields, types, extra keys, unknown tools) is
    /// left for Claude Code to validate: it answers with an error `tool_result` the model can retry on,
    /// which is better than removing the call. A block is dropped only when it has no tool name.
    func repairToolUseBlock(_ block: [String: Any]) -> BlockResult {
        guard let name = block["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BlockResult(block: nil, action: .dropped("missing_tool_name"))
        }
        var repairedBlock = block
        var repairReasons: [String] = []

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != name {
            repairReasons.append("name_whitespace_trimmed")
        }
        var resolvedName = trimmedName
        if catalog.schemasByName[trimmedName] == nil {
            let lower = trimmedName.lowercased()
            let matches = catalog.schemasByName.keys.filter { $0.lowercased() == lower }
            if matches.count == 1, let matchName = matches.first {
                resolvedName = matchName
                repairReasons.append("name_case_normalized")
            }
        }
        repairedBlock["name"] = resolvedName

        if (block["id"] as? String)?.isEmpty ?? true {
            repairedBlock["id"] = "toolu_mp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            repairReasons.append("missing_id_inserted")
        }

        switch block["input"] {
        case is [String: Any]:
            break
        case let text as String:
            if let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                repairedBlock["input"] = parsed
                repairReasons.append("input_string_parsed")
            } else {
                repairedBlock["input"] = [String: Any]()
                repairReasons.append("input_not_object_replaced")
            }
        case nil:
            repairedBlock["input"] = [String: Any]()
            repairReasons.append("empty_input_inserted")
        default:
            repairedBlock["input"] = [String: Any]()
            repairReasons.append("input_not_object_replaced")
        }

        guard !repairReasons.isEmpty else {
            return BlockResult(block: block, action: .unchanged)
        }
        return BlockResult(block: repairedBlock, action: .repaired(repairReasons.joined(separator: "+")))
    }

    /// When every tool call in a turn was dropped, a `tool_use` stop reason would leave Claude Code
    /// waiting on tool calls that no longer exist.
    static func stopReasonAfterGuard(_ stopReason: String?, remainingToolUseCount: Int, droppedCount: Int) -> String? {
        guard stopReason == "tool_use", droppedCount > 0, remainingToolUseCount == 0 else {
            return stopReason
        }
        return "end_turn"
    }

    static func invalidToolTextBlock(toolName: String?, reason: String) -> [String: Any] {
        let name: String
        if let toolName, !toolName.isEmpty {
            name = toolName
        } else {
            name = "unknown"
        }
        return [
            "type": "text",
            "text": "Tool call removed: \(name) could not be relayed (\(reason))."
        ]
    }
}
