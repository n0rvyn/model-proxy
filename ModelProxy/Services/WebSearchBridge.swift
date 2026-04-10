import Foundation
import AsyncHTTPClient

enum WebSearchBridgeError: Error, Equatable {
    case invalidRequest
    case upstreamFailure(statusCode: Int, bodyPreview: String)
    case maxUsesExceeded(limit: Int)
    case invalidToolQuery
    case mixedToolUseUnsupported
}

struct WebSearchBridgeResult: Sendable {
    let clientResponse: ReplayableBranchResponse
    let inputTokens: Int
    let outputTokens: Int
    let assistantTurn: PortableAssistantTurn?
}

enum WebSearchBridge {
    struct ModelResponse: Sendable {
        let statusCode: Int
        let headers: [(String, String)]
        let bodyData: Data
    }

    struct PreparedRequest: Sendable {
        let bodyData: Data
        let streamRequested: Bool
        let maxUses: Int
    }

    struct ToolCall: Sendable, Equatable {
        let id: String
        let query: String
        let maxResults: Int
    }

    struct StepOutcome: Sendable {
        let assistantMessage: [String: Any]
        let toolCalls: [ToolCall]
    }

    private static let bridgedToolName = "web_search"
    private static let bridgedToolType = "web_search_20250305"

    nonisolated static func shouldHandle(
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        requestKind: TrafficEntry.RequestKind
    ) -> Bool {
        guard !target.isPassthrough, requestKind == .generation else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]] else {
            return false
        }
        return tools.contains { tool in
            (tool["type"] as? String)?.lowercased() == bridgedToolType
        }
    }

    nonisolated static func prepareRequest(bodyData: Data) throws -> PreparedRequest {
        guard var json = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw WebSearchBridgeError.invalidRequest
        }
        guard let tools = json["tools"] as? [[String: Any]], !tools.isEmpty else {
            throw WebSearchBridgeError.invalidRequest
        }

        let maxUses = tools
            .filter { ($0["type"] as? String)?.lowercased() == bridgedToolType }
            .compactMap { $0["max_uses"] as? Int }
            .max() ?? 3

        let transformedTools = tools.compactMap { tool -> [String: Any]? in
            if (tool["type"] as? String)?.lowercased() == bridgedToolType {
                return bridgedFunctionToolDefinition()
            }
            return tool
        }

        let streamRequested = json["stream"] as? Bool ?? false
        json["tools"] = transformedTools
        json["stream"] = false

        return PreparedRequest(
            bodyData: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
            streamRequested: streamRequested,
            maxUses: maxUses
        )
    }

    static func execute(
        bodyData: Data,
        httpClient: HTTPClient,
        portableNormalizer: any PortableContentNormalizing,
        provider: any WebSearchBridgeProviding,
        performModelTurn: @Sendable (Data) async throws -> ModelResponse
    ) async throws -> WebSearchBridgeResult {
        let preparedRequest = try prepareRequest(bodyData: bodyData)
        var workingJSON = try jsonObject(preparedRequest.bodyData)
        var accumulatedInputTokens = 0
        var accumulatedOutputTokens = 0

        for _ in 0..<preparedRequest.maxUses {
            let response = try await performModelTurn(
                try JSONSerialization.data(withJSONObject: workingJSON, options: [.sortedKeys])
            )
            guard response.statusCode < 400 else {
                let preview = String(data: response.bodyData.prefix(512), encoding: .utf8) ?? "<non-UTF8>"
                throw WebSearchBridgeError.upstreamFailure(statusCode: response.statusCode, bodyPreview: preview)
            }

            if let (input, output) = ResponseRelay.extractUsageFromJSONBody(response.bodyData) {
                accumulatedInputTokens += input
                accumulatedOutputTokens += output
            }

            let outcome = try stepOutcome(from: response.bodyData)
            let normalized = try portableNormalizer.normalizeJSONBody(response.bodyData)

            guard !outcome.toolCalls.isEmpty else {
                let finalBodyData = try bodyDataByReplacingUsage(
                    in: normalized.bodyData,
                    inputTokens: accumulatedInputTokens,
                    outputTokens: accumulatedOutputTokens
                )
                let clientResponse = preparedRequest.streamRequested
                    ? try synthesizeSSE(from: finalBodyData, inputTokens: accumulatedInputTokens, outputTokens: accumulatedOutputTokens)
                    : ReplayableBranchResponse(
                        statusCode: 200,
                        headers: [("content-type", "application/json")],
                        bodyChunks: [finalBodyData]
                    )
                let assistantTurn = try portableNormalizer.normalizeJSONBody(finalBodyData).assistantTurn
                return WebSearchBridgeResult(
                    clientResponse: clientResponse,
                    inputTokens: accumulatedInputTokens,
                    outputTokens: accumulatedOutputTokens,
                    assistantTurn: assistantTurn
                )
            }

            let resultBlocks = try await outcome.toolCalls.mapAsync { toolCall in
                let results = try await provider.search(
                    query: toolCall.query,
                    maxResults: toolCall.maxResults,
                    httpClient: httpClient
                )
                return [
                    "type": "tool_result",
                    "tool_use_id": toolCall.id,
                    "content": formatSearchResults(results, query: toolCall.query)
                ] as [String: Any]
            }

            let messages = (workingJSON["messages"] as? [[String: Any]]) ?? []
            workingJSON["messages"] = messages + [
                outcome.assistantMessage,
                [
                    "role": "user",
                    "content": resultBlocks
                ]
            ]
        }

        throw WebSearchBridgeError.maxUsesExceeded(limit: preparedRequest.maxUses)
    }

    nonisolated static func stepOutcome(
        from responseBody: Data
    ) throws -> StepOutcome {
        guard let responseJSON = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let assistantMessage = assistantMessage(from: responseJSON),
              let contentBlocks = assistantMessage["content"] as? [[String: Any]] else {
            throw WebSearchBridgeError.invalidRequest
        }

        let webSearchCalls = contentBlocks.filter { block in
            (block["type"] as? String)?.lowercased() == "tool_use"
            && (block["name"] as? String) == bridgedToolName
        }

        if !webSearchCalls.isEmpty {
            let nonWebSearchToolUseExists = contentBlocks.contains { block in
                (block["type"] as? String)?.lowercased() == "tool_use"
                && (block["name"] as? String) != bridgedToolName
            }
            if nonWebSearchToolUseExists {
                throw WebSearchBridgeError.mixedToolUseUnsupported
            }
        }

        let toolCalls = try webSearchCalls.map(toolCall(from:))
        return StepOutcome(
            assistantMessage: assistantMessage,
            toolCalls: toolCalls
        )
    }

    nonisolated static func synthesizeSSE(
        from finalBodyData: Data,
        inputTokens: Int,
        outputTokens: Int
    ) throws -> ReplayableBranchResponse {
        let json = try jsonObject(finalBodyData)
        guard let contentBlocks = json["content"] as? [[String: Any]] else {
            throw WebSearchBridgeError.invalidRequest
        }
        let id = (json["id"] as? String) ?? "msg_bridge_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let role = (json["role"] as? String) ?? "assistant"
        let model = (json["model"] as? String) ?? "web-search-bridge"

        var chunks: [Data] = []
        chunks.append(try eventData(
            name: "message_start",
            payload: [
                "type": "message_start",
                "message": [
                    "id": id,
                    "type": "message",
                    "role": role,
                    "model": model,
                    "content": [],
                    "stop_reason": NSNull(),
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": inputTokens,
                        "output_tokens": 0
                    ]
                ]
            ]
        ))

        for (index, block) in contentBlocks.enumerated() {
            let lowerType = (block["type"] as? String)?.lowercased()
            switch lowerType {
            case "text":
                chunks.append(try eventData(
                    name: "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": index,
                        "content_block": [
                            "type": "text",
                            "text": ""
                        ]
                    ]
                ))
                chunks.append(try eventData(
                    name: "content_block_delta",
                    payload: [
                        "type": "content_block_delta",
                        "index": index,
                        "delta": [
                            "type": "text_delta",
                            "text": block["text"] as? String ?? ""
                        ]
                    ]
                ))
                chunks.append(try eventData(
                    name: "content_block_stop",
                    payload: [
                        "type": "content_block_stop",
                        "index": index
                    ]
                ))
            case "tool_use":
                chunks.append(try eventData(
                    name: "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": index,
                        "content_block": [
                            "type": "tool_use",
                            "id": block["id"] as? String ?? "",
                            "name": block["name"] as? String ?? "",
                            "input": [:]
                        ]
                    ]
                ))
                let inputData = try JSONSerialization.data(withJSONObject: block["input"] ?? [:], options: [.sortedKeys])
                chunks.append(try eventData(
                    name: "content_block_delta",
                    payload: [
                        "type": "content_block_delta",
                        "index": index,
                        "delta": [
                            "type": "input_json_delta",
                            "partial_json": String(data: inputData, encoding: .utf8) ?? "{}"
                        ]
                    ]
                ))
                chunks.append(try eventData(
                    name: "content_block_stop",
                    payload: [
                        "type": "content_block_stop",
                        "index": index
                    ]
                ))
            default:
                continue
            }
        }

        chunks.append(try eventData(
            name: "message_delta",
            payload: [
                "type": "message_delta",
                "delta": [
                    "stop_reason": json["stop_reason"] as? String ?? "end_turn",
                    "stop_sequence": NSNull()
                ],
                "usage": [
                    "output_tokens": outputTokens
                ]
            ]
        ))
        chunks.append(try eventData(name: "message_stop", payload: ["type": "message_stop"]))

        return ReplayableBranchResponse(
            statusCode: 200,
            headers: [("content-type", "text/event-stream")],
            bodyChunks: chunks
        )
    }

    private nonisolated static func bridgedFunctionToolDefinition() -> [String: Any] {
        [
            "name": bridgedToolName,
            "description": "Search the public web and return relevant results with titles, URLs, and snippets.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search query"
                    ],
                    "max_results": [
                        "type": "integer",
                        "description": "Maximum number of results to return"
                    ]
                ],
                "required": ["query"]
            ]
        ]
    }

    private nonisolated static func assistantMessage(from responseJSON: [String: Any]) -> [String: Any]? {
        guard let role = responseJSON["role"] as? String,
              let content = responseJSON["content"] else {
            return nil
        }
        return [
            "role": role,
            "content": content
        ]
    }

    private nonisolated static func toolCall(from block: [String: Any]) throws -> ToolCall {
        guard let id = block["id"] as? String,
              let input = block["input"] as? [String: Any] else {
            throw WebSearchBridgeError.invalidToolQuery
        }

        let query = (input["query"] as? String)
            ?? (input["search_query"] as? String)
            ?? (input["text"] as? String)
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebSearchBridgeError.invalidToolQuery
        }

        let maxResults = input["max_results"] as? Int ?? 5
        return ToolCall(id: id, query: query, maxResults: max(1, min(maxResults, 8)))
    }

    private nonisolated static func formatSearchResults(_ results: [WebSearchResult], query: String) -> String {
        guard !results.isEmpty else {
            return "No search results found for query: \(query)"
        }

        let lines = results.enumerated().map { index, result in
            [
                "\(index + 1). \(result.title)",
                "URL: \(result.url)",
                "Snippet: \(result.snippet)"
            ].joined(separator: "\n")
        }

        return "Search results for: \(query)\n\n" + lines.joined(separator: "\n\n")
    }

    private nonisolated static func bodyDataByReplacingUsage(
        in responseBody: Data,
        inputTokens: Int,
        outputTokens: Int
    ) throws -> Data {
        var json = try jsonObject(responseBody)
        json["usage"] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private nonisolated static func eventData(name: String, payload: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var data = Data("event: \(name)\n".utf8)
        data.append(Data("data: ".utf8))
        data.append(json)
        data.append(Data("\n\n".utf8))
        return data
    }

    private nonisolated static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchBridgeError.invalidRequest
        }
        return json
    }
}

private extension Array {
    func mapAsync<T: Sendable>(
        _ transform: @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
