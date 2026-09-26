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
    let webSearchRequestCount: Int
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

    private struct SearchObservation: Sendable {
        let toolCall: ToolCall
        let results: [WebSearchResult]
        /// Anthropic `web_search_tool_result_error` code when this search did not run or failed.
        var errorCode: String? = nil
    }

    struct StepOutcome: Sendable {
        let assistantMessage: [String: Any]
        let toolCalls: [ToolCall]
    }

    private static let bridgedToolName = "web_search"
    private static let bridgedToolTypes: Set<String> = [
        "web_search_20250305",
        "web_search_20260209"
    ]

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
            guard let type = (tool["type"] as? String)?.lowercased() else { return false }
            return bridgedToolTypes.contains(type)
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
            .filter { tool in
                guard let type = (tool["type"] as? String)?.lowercased() else { return false }
                return bridgedToolTypes.contains(type)
            }
            .compactMap { $0["max_uses"] as? Int }
            .max() ?? 3

        let transformedTools = tools.compactMap { tool -> [String: Any]? in
            if let type = (tool["type"] as? String)?.lowercased(),
               bridgedToolTypes.contains(type) {
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
        var searchObservations: [SearchObservation] = []
        // `max_uses` bounds searches, as on Anthropic's server tool. Search-side problems (limit reached,
        // provider error) go back to the model as tool errors and the request still ends with a 200:
        // a non-2xx makes Claude Code retry the whole turn, which reruns every search.
        var searchesRun = 0
        var providerErrorCode: String?
        let maxModelTurns = preparedRequest.maxUses + 2

        func finish(with responseBodyData: Data) throws -> WebSearchBridgeResult {
            let normalized = try portableNormalizer.normalizeJSONBody(responseBodyData)
            let completedSearchCount = searchObservations.filter { $0.errorCode == nil }.count
            let branchBodyData = try bodyDataByReplacingUsage(
                in: normalized.bodyData,
                inputTokens: accumulatedInputTokens,
                outputTokens: accumulatedOutputTokens,
                webSearchRequestCount: nil
            )
            let clientBodyData = try bodyDataByReplacingUsage(
                in: bodyDataByInsertingClientSearchBlocks(
                    in: branchBodyData,
                    observations: searchObservations
                ),
                inputTokens: accumulatedInputTokens,
                outputTokens: accumulatedOutputTokens,
                webSearchRequestCount: completedSearchCount
            )
            let trafficRequestKind = TrafficEntry.RequestKind.webSearchBridge(searchCount: completedSearchCount)
            let clientResponse = preparedRequest.streamRequested
                ? try synthesizeSSE(
                    from: clientBodyData,
                    inputTokens: accumulatedInputTokens,
                    outputTokens: accumulatedOutputTokens,
                    webSearchRequestCount: completedSearchCount,
                    trafficRequestKind: trafficRequestKind
                )
                : ReplayableBranchResponse(
                    statusCode: 200,
                    headers: [("content-type", "application/json")],
                    bodyChunks: [clientBodyData],
                    trafficRequestKind: trafficRequestKind
                )
            let assistantTurn = try portableNormalizer.normalizeJSONBody(branchBodyData).assistantTurn
            return WebSearchBridgeResult(
                clientResponse: clientResponse,
                webSearchRequestCount: completedSearchCount,
                inputTokens: accumulatedInputTokens,
                outputTokens: accumulatedOutputTokens,
                assistantTurn: assistantTurn
            )
        }

        for turn in 0..<maxModelTurns {
            let isLastTurn = turn == maxModelTurns - 1
            if isLastTurn {
                // The model kept searching: this turn must answer from what it already has.
                workingJSON["tool_choice"] = ["type": "none"]
            }
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
            guard !outcome.toolCalls.isEmpty else {
                return try finish(with: response.bodyData)
            }
            guard !isLastTurn else {
                return try finish(with: bodyDataByRemovingToolCalls(from: response.bodyData))
            }

            var resultBlocks: [[String: Any]] = []
            resultBlocks.reserveCapacity(outcome.toolCalls.count)
            for toolCall in outcome.toolCalls {
                let errorCode: String
                if let providerErrorCode {
                    errorCode = providerErrorCode
                } else if searchesRun >= preparedRequest.maxUses {
                    errorCode = "max_uses_exceeded"
                } else {
                    searchesRun += 1
                    do {
                        let results = try await provider.search(
                            query: toolCall.query,
                            maxResults: toolCall.maxResults,
                            httpClient: httpClient
                        )
                        searchObservations.append(SearchObservation(toolCall: toolCall, results: results))
                        resultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolCall.id,
                            "content": formatSearchResults(results, query: toolCall.query)
                        ])
                        continue
                    } catch {
                        // Stop calling a failing provider for the rest of this request.
                        providerErrorCode = searchErrorCode(for: error)
                        errorCode = providerErrorCode ?? "unavailable"
                    }
                }
                searchObservations.append(SearchObservation(toolCall: toolCall, results: [], errorCode: errorCode))
                resultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolCall.id,
                    "is_error": true,
                    "content": searchErrorMessage(for: errorCode)
                ])
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

    /// Anthropic `web_search_tool_result_error` code for a failed provider search.
    nonisolated static func searchErrorCode(for error: Error) -> String {
        switch error {
        case WebSearchBridgeProviderError.upstreamFailure(statusCode: 429):
            return "too_many_requests"
        case WebSearchBridgeProviderError.invalidQuery:
            return "invalid_input"
        default:
            return "unavailable"
        }
    }

    nonisolated static func searchErrorMessage(for errorCode: String) -> String {
        switch errorCode {
        case "max_uses_exceeded":
            return "Web search error (max_uses_exceeded): the search limit for this request is reached. Answer with the results you already have."
        case "too_many_requests":
            return "Web search error (too_many_requests): the search provider is rate limited or out of quota. Answer without further searches."
        case "invalid_input":
            return "Web search error (invalid_input): the query was empty or invalid."
        default:
            return "Web search error (unavailable): the search provider failed. Answer without further searches."
        }
    }

    /// Final-turn fallback when the model still asks for searches: keep its text, drop the calls.
    private nonisolated static func bodyDataByRemovingToolCalls(from responseBody: Data) throws -> Data {
        var json = try jsonObject(responseBody)
        let content = (json["content"] as? [[String: Any]]) ?? []
        var kept = content.filter { ($0["type"] as? String)?.lowercased() != "tool_use" }
        if !kept.contains(where: { ($0["type"] as? String)?.lowercased() == "text" }) {
            kept.append(["type": "text", "text": "Web search stopped: the search limit for this request was reached."])
        }
        json["content"] = kept
        json["stop_reason"] = "end_turn"
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
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
        outputTokens: Int,
        webSearchRequestCount: Int? = nil,
        trafficRequestKind: TrafficEntry.RequestKind? = nil
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
            case "tool_use", "server_tool_use":
                let contentType = lowerType == "server_tool_use" ? "server_tool_use" : "tool_use"
                chunks.append(try eventData(
                    name: "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": index,
                        "content_block": [
                            "type": contentType,
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
            case "web_search_tool_result":
                chunks.append(try eventData(
                    name: "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": index,
                        "content_block": block
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

        var deltaUsage: [String: Any] = [
            "output_tokens": outputTokens
        ]
        if let webSearchRequestCount {
            deltaUsage["server_tool_use"] = [
                "web_search_requests": webSearchRequestCount
            ]
        }
        chunks.append(try eventData(
            name: "message_delta",
            payload: [
                "type": "message_delta",
                "delta": [
                    "stop_reason": json["stop_reason"] as? String ?? "end_turn",
                    "stop_sequence": NSNull()
                ],
                "usage": deltaUsage
            ]
        ))
        chunks.append(try eventData(name: "message_stop", payload: ["type": "message_stop"]))

        return ReplayableBranchResponse(
            statusCode: 200,
            headers: [("content-type", "text/event-stream")],
            bodyChunks: chunks,
            trafficRequestKind: trafficRequestKind
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
        outputTokens: Int,
        webSearchRequestCount: Int?
    ) throws -> Data {
        var json = try jsonObject(responseBody)
        var usage: [String: Any] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens
        ]
        if let webSearchRequestCount {
            usage["server_tool_use"] = [
                "web_search_requests": webSearchRequestCount
            ]
        }
        json["usage"] = usage
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private nonisolated static func bodyDataByInsertingClientSearchBlocks(
        in responseBody: Data,
        observations: [SearchObservation]
    ) throws -> Data {
        guard !observations.isEmpty else { return responseBody }
        var json = try jsonObject(responseBody)
        let existingContent = (json["content"] as? [[String: Any]]) ?? []
        json["content"] = clientSearchBlocks(from: observations) + existingContent
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private nonisolated static func clientSearchBlocks(
        from observations: [SearchObservation]
    ) -> [[String: Any]] {
        observations.flatMap { observation in
            [
                [
                    "type": "server_tool_use",
                    "id": observation.toolCall.id,
                    "name": bridgedToolName,
                    "input": [
                        "query": observation.toolCall.query
                    ]
                ],
                [
                    "type": "web_search_tool_result",
                    "tool_use_id": observation.toolCall.id,
                    "content": observation.errorCode.map { errorCode -> Any in
                        [
                            "type": "web_search_tool_result_error",
                            "error_code": errorCode
                        ]
                    } ?? observation.results.map { result in
                        [
                            "type": "web_search_result",
                            "title": result.title,
                            "url": result.url
                        ]
                    }
                ]
            ]
        }
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
