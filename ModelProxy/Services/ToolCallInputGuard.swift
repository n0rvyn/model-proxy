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

    func repairToolUseBlock(_ block: [String: Any]) -> BlockResult {
        guard let name = block["name"] as? String, !name.isEmpty else {
            return BlockResult(block: nil, action: .dropped("missing_tool_name"))
        }
        guard let schema = catalog.schemasByName[name] else {
            return BlockResult(block: nil, action: .dropped("unknown_tool"))
        }

        let required = Set((schema["required"] as? [String]) ?? [])
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let objectSchema = (schema["type"] as? String)?.lowercased() == "object" || schema["type"] == nil

        guard objectSchema else {
            return BlockResult(block: block, action: .unchanged)
        }

        var repairedBlock = block
        var inputObject: [String: Any]
        var repairReasons: [String] = []

        if let input = block["input"] {
            if let dictionary = input as? [String: Any] {
                inputObject = dictionary
            } else if let text = input as? String {
                guard let data = text.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return BlockResult(block: nil, action: .dropped("input_string_parse_failed"))
                }
                inputObject = parsed
                repairReasons.append("input_string_parsed")
            } else {
                return BlockResult(block: nil, action: .dropped("input_not_object"))
            }
        } else {
            guard required.isEmpty else {
                return BlockResult(block: nil, action: .dropped("missing_required_input"))
            }
            inputObject = [:]
            repairReasons.append("empty_input_inserted")
        }

        if schema["additionalProperties"] as? Bool == false {
            let allowedKeys = Set(properties.keys)
            let filtered = inputObject.filter { allowedKeys.contains($0.key) }
            if filtered.count != inputObject.count {
                inputObject = filtered
                repairReasons.append("additional_properties_removed")
            }
        }

        for field in required where inputObject[field] == nil {
            return BlockResult(block: nil, action: .dropped("missing_required_field"))
        }

        for (field, value) in inputObject {
            guard let propertySchema = properties[field] as? [String: Any],
                  let type = propertySchema["type"] as? String else {
                continue
            }
            guard Self.value(value, matchesJSONSchemaType: type) else {
                return BlockResult(block: nil, action: .dropped("field_type_mismatch"))
            }
        }

        repairedBlock["input"] = inputObject
        guard !repairReasons.isEmpty else {
            return BlockResult(block: block, action: .unchanged)
        }
        return BlockResult(block: repairedBlock, action: .repaired(repairReasons.joined(separator: "+")))
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
            "text": "Tool call removed: invalid parameters for \(name) (\(reason))."
        ]
    }

    static func value(_ value: Any, matchesJSONSchemaType type: String) -> Bool {
        switch type.lowercased() {
        case "string":
            return value is String
        case "integer":
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return floor(number.doubleValue) == number.doubleValue
        case "number":
            return (value as? NSNumber).map { !isBoolean($0) } ?? false
        case "boolean":
            return value is Bool
        case "array":
            return value is [Any]
        case "object":
            return value is [String: Any]
        default:
            return true
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
