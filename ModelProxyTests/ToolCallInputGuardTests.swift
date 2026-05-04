import Foundation
import NIOCore
import Testing
@testable import ModelProxy

struct ToolCallInputGuardTests {

    @Test func catalogReadsToolSchemasFromRequestBody() throws {
        let body = try requestBody(tools: [
            ["name": "Bash", "input_schema": objectSchema(required: ["cmd"], properties: [
                "cmd": ["type": "string"]
            ])],
            ["name": "", "input_schema": objectSchema()],
            ["name": "NoSchema"]
        ])

        let catalog = ToolCallInputGuard.ToolCatalog.fromRequestBody(body)

        #expect(catalog.schemasByName.count == 1)
        #expect(catalog.schemasByName["Bash"] != nil)
    }

    @Test func repairsJSONStringInputToObject() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash",
            "input": "{\"cmd\":\"echo hi\"}"
        ])

        guard case .repaired(let reason) = result.action else {
            Issue.record("Expected repaired action"); return
        }
        #expect(reason == "input_string_parsed")
        let block = try #require(result.block)
        let input = try #require(block["input"] as? [String: Any])
        #expect(input["cmd"] as? String == "echo hi")
    }

    @Test func repairsMissingInputToEmptyObjectWhenNoRequiredFields() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: [], properties: [:]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash"
        ])

        guard case .repaired(let reason) = result.action else {
            Issue.record("Expected repaired action"); return
        }
        #expect(reason == "empty_input_inserted")
        let block = try #require(result.block)
        let input = try #require(block["input"] as? [String: Any])
        #expect(input.isEmpty)
    }

    @Test func removesAdditionalPropertiesWhenSchemaDisallowsThem() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(
            required: ["path"],
            properties: ["path": ["type": "string"]],
            additionalProperties: false
        ))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash",
            "input": ["path": "/tmp/a", "extra": true]
        ])

        guard case .repaired(let reason) = result.action else {
            Issue.record("Expected repaired action"); return
        }
        #expect(reason == "additional_properties_removed")
        let block = try #require(result.block)
        let input = try #require(block["input"] as? [String: Any])
        #expect(input["path"] as? String == "/tmp/a")
        #expect(input["extra"] == nil)
    }

    @Test func dropsUnknownTool() {
        let guarder = ToolCallInputGuard(catalog: catalog(required: [], properties: [:]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Unknown",
            "input": [:]
        ])

        #expect(result.block == nil)
        #expect(result.action == .dropped("unknown_tool"))
    }

    @Test func dropsMissingRequiredInput() {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash"
        ])

        #expect(result.block == nil)
        #expect(result.action == .dropped("missing_required_input"))
    }

    @Test func dropsScalarTypeMismatch() {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash",
            "input": ["cmd": 42]
        ])

        #expect(result.block == nil)
        #expect(result.action == .dropped("field_type_mismatch"))
    }

    @Test func dropsUnparseableInputString() {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "Bash",
            "input": "{not-json"
        ])

        #expect(result.block == nil)
        #expect(result.action == .dropped("input_string_parse_failed"))
    }

    @Test func transformJSONLeavesWholeResponseParseFailureUnchanged() {
        let guarder = ToolCallInputGuard(catalog: catalog(required: [], properties: [:]))
        let data = Data("{not-json".utf8)

        let result = guarder.transformJSONResponseBody(data)

        #expect(result.data == data)
        #expect(result.parseFailed == true)
        #expect(result.repairedCount == 0)
        #expect(result.droppedCount == 0)
    }

    @Test func transformJSONReplacesDroppedToolUseWithTextBlock() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "msg_1",
            "type": "message",
            "role": "assistant",
            "content": [[
                "type": "tool_use",
                "id": "toolu_1",
                "name": "Bash",
                "input": ["cmd": 42]
            ]]
        ])

        let result = guarder.transformJSONResponseBody(response)

        #expect(result.droppedCount == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let content = try #require(json["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect((content[0]["text"] as? String)?.contains("field_type_mismatch") == true)
    }

    @Test func sseGuardRepairsToolUseWhenPortableContextIsAbsent() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer(
            portableMode: false,
            toolCallGuard: guarder
        )
        let stream = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        ].joined()
        let output = try push(stream, through: normalizer)
        let payloads = try ssePayloads(output)

        #expect(output.contains("\"type\":\"tool_use\""))
        #expect(output.contains("partial_json"))

        let start = try #require(payloads[safe: 0])
        let startBlock = try #require(start["content_block"] as? [String: Any])
        #expect(startBlock["type"] as? String == "tool_use")
        #expect((startBlock["input"] as? [String: Any])?.isEmpty == true)

        let delta = try #require(payloads[safe: 1])
        let deltaBlock = try #require(delta["delta"] as? [String: Any])
        #expect(deltaBlock["type"] as? String == "input_json_delta")
        #expect(deltaBlock["partial_json"] as? String == "{\"cmd\":\"echo hi\"}")

        let summary = normalizer.toolCallGuardSummary()
        #expect(summary.repairedCount == 0)
        #expect(summary.droppedCount == 0)
    }

    @Test func sseGuardDropsInvalidToolUseWhenPortableContextIsAbsent() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer(
            portableMode: false,
            toolCallGuard: guarder
        )
        let stream = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":42}\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        ].joined()
        let output = try push(stream, through: normalizer)
        let payloads = try ssePayloads(output)

        #expect(!output.contains("\"type\":\"tool_use\""))
        #expect(output.contains("\"type\":\"text\""))
        #expect(output.contains("field_type_mismatch"))

        let start = try #require(payloads[safe: 0])
        let startBlock = try #require(start["content_block"] as? [String: Any])
        #expect(startBlock["type"] as? String == "text")
        #expect(startBlock["text"] as? String == "")

        let delta = try #require(payloads[safe: 1])
        let deltaBlock = try #require(delta["delta"] as? [String: Any])
        #expect(deltaBlock["type"] as? String == "text_delta")
        #expect((deltaBlock["text"] as? String)?.contains("field_type_mismatch") == true)

        let summary = normalizer.toolCallGuardSummary()
        #expect(summary.repairedCount == 0)
        #expect(summary.droppedCount == 1)
        #expect(summary.reasons == ["field_type_mismatch"])
    }

    @Test func sseGuardCommitsDroppedToolUseAsClientVisibleText() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: ["cmd"], properties: [
            "cmd": ["type": "string"]
        ]))
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer(
            portableMode: true,
            toolCallGuard: guarder
        )
        let stream = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Grep\",\"input\":{}}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"TODO\\\"}\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        ].joined()
        let output = try push(stream, through: normalizer)

        #expect(output.contains("Tool call removed"))
        #expect(output.contains("unknown_tool"))
        #expect(!output.contains("\"type\":\"tool_use\""))

        let assistantTurn = try #require(try normalizer.finish())
        let fullBlocks = try messageBlocks(from: assistantTurn.fullMessageData)
        let portableBlocks = try messageBlocks(from: assistantTurn.portableMessageData)

        #expect(fullBlocks.count == 1)
        #expect(fullBlocks[0]["type"] as? String == "text")
        #expect((fullBlocks[0]["text"] as? String)?.contains("unknown_tool") == true)
        #expect(!fullBlocks.contains { $0["type"] as? String == "tool_use" })

        #expect(portableBlocks.count == 1)
        #expect(portableBlocks[0]["type"] as? String == "text")
        #expect((portableBlocks[0]["text"] as? String)?.contains("unknown_tool") == true)
        #expect(!portableBlocks.contains { $0["type"] as? String == "tool_use" })
    }

    @Test func proxyForwarderUsesGuardFromUsedTarget() {
        let catalog = catalog(required: [], properties: [:])
        let primaryTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://primary.example.com",
            apiKey: "pk",
            vendorName: "Primary",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"),
            targetModel: "primary",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: false
        )
        let backupTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://backup.example.com",
            apiKey: "bk",
            vendorName: "Backup",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"),
            targetModel: "backup",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly,
            supportsAnthropicCountTokens: true,
            repairsAnthropicToolCalls: true
        )

        #expect(ProxyForwarder.toolCallGuard(for: primaryTarget, catalog: catalog) == nil)
        #expect(ProxyForwarder.toolCallGuard(for: backupTarget, catalog: catalog) != nil)
    }

    private func requestBody(tools: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": "test",
            "messages": [["role": "user", "content": "hi"]],
            "tools": tools
        ])
    }

    private func push(_ stream: String, through normalizer: PortableSSEStreamNormalizer) throws -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: stream.utf8.count)
        buffer.writeString(stream)
        let chunks = try normalizer.push(chunk: buffer)
        let data = chunks.reduce(into: Data()) { partialResult, chunk in
            partialResult.append(chunk)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func ssePayloads(_ output: String) throws -> [[String: Any]] {
        try output.split(separator: "\n\n").compactMap { event -> [String: Any]? in
            let dataLines = event.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            return try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        }
    }

    private func messageBlocks(from data: Data) throws -> [[String: Any]] {
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["content"] as? [[String: Any]])
    }

    private func catalog(
        required: [String],
        properties: [String: Any],
        additionalProperties: Bool? = nil
    ) -> ToolCallInputGuard.ToolCatalog {
        ToolCallInputGuard.ToolCatalog(schemasByName: [
            "Bash": objectSchema(
                required: required,
                properties: properties,
                additionalProperties: additionalProperties
            )
        ])
    }

    private func objectSchema(
        required: [String] = [],
        properties: [String: Any] = [:],
        additionalProperties: Bool? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": required
        ]
        if let additionalProperties {
            schema["additionalProperties"] = additionalProperties
        }
        return schema
    }
    @Test func trimsWhitespaceFromToolNameBeforeCatalogLookup() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: [], properties: [:]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": " Bash ",
            "input": [:]
        ])

        switch result.action {
        case .unchanged:
            break
        case .repaired:
            Issue.record("Expected unchanged after trim, got repaired")
        case .dropped(let reason):
            Issue.record("Expected match after trim, got dropped: \(reason)")
        }
        let block = try #require(result.block)
        #expect(block["name"] as? String == "Bash")
    }

    @Test func caseInsensitiveToolNameMatch() throws {
        let guarder = ToolCallInputGuard(catalog: catalog(required: [], properties: [:]))
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "bash",
            "input": [:]
        ])

        guard case .repaired(let reason) = result.action else {
            Issue.record("Expected repaired action"); return
        }
        #expect(reason.contains("name_case_normalized"))
        let block = try #require(result.block)
        #expect(block["name"] as? String == "Bash")
    }

    @Test func ambiguousToolNameDropped() throws {
        // Catalog with two tools that differ only by case
        let catalog = ToolCallInputGuard.ToolCatalog(schemasByName: [
            "grep": objectSchema(),
            "Grep": objectSchema()
        ])
        let guarder = ToolCallInputGuard(catalog: catalog)
        let result = guarder.repairToolUseBlock([
            "type": "tool_use",
            "id": "toolu_1",
            "name": "greP",
            "input": [:]
        ])

        guard case .dropped(let reason) = result.action else {
            Issue.record("Expected dropped action"); return
        }
        #expect(reason.contains("ambiguous_tool_name"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
