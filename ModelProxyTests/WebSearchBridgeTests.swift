import Testing
import Foundation
import AsyncHTTPClient
@testable import ModelProxy

struct WebSearchBridgeTests {

    @Test func shouldHandleMappedVendorWebSearchRequestsOnly() throws {
        let mappedTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://example.com",
            apiKey: "key",
            vendorName: "MiniMax",
            vendorID: UUID(),
            targetModel: "MiniMax-M2.7",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )
        let passthroughTarget = RoutingSnapshot.RouteTarget(
            baseURL: "https://api.anthropic.com",
            apiKey: "key",
            vendorName: "passthrough",
            vendorID: nil,
            targetModel: nil,
            isPassthrough: true,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .anthropicOfficial,
            replayPolicy: .transparent
        )
        let request = try requestBody(stream: true)

        #expect(WebSearchBridge.shouldHandle(bodyData: request, target: mappedTarget, requestKind: .generation) == true)
        #expect(WebSearchBridge.shouldHandle(bodyData: request, target: passthroughTarget, requestKind: .generation) == false)
        #expect(WebSearchBridge.shouldHandle(bodyData: request, target: mappedTarget, requestKind: .countTokens) == false)
    }

    @Test func prepareRequestRewritesServerToolToFunctionToolAndDisablesStreaming() throws {
        let prepared = try WebSearchBridge.prepareRequest(bodyData: try requestBody(stream: true))
        let json = try #require(try JSONSerialization.jsonObject(with: prepared.bodyData) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])

        #expect(prepared.streamRequested == true)
        #expect(prepared.maxUses == 4)
        #expect((json["stream"] as? Bool) == false)
        #expect(tools.count == 2)
        #expect((tools.first?["name"] as? String) == "web_search")
        #expect(tools.first?["input_schema"] != nil)
    }

    @Test func stepOutcomeExtractsWebSearchToolCall() throws {
        let response = try assistantResponseBody(content: [
            ["type": "tool_use", "id": "toolu_search", "name": "web_search", "input": ["query": "swift testing", "max_results": 3]]
        ], usage: ["input_tokens": 10, "output_tokens": 2])
        let outcome = try WebSearchBridge.stepOutcome(from: response)

        #expect(outcome.toolCalls == [
            WebSearchBridge.ToolCall(id: "toolu_search", query: "swift testing", maxResults: 3)
        ])
    }

    @Test func executeLoopsThroughSearchAndReturnsFinalAssistantResponse() async throws {
        let normalizer = PortableContentNormalizer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        var seenRequests: [[String: Any]] = []
        var turnIndex = 0
        let provider = StubWebSearchProvider(results: [
            WebSearchResult(title: "Swift Testing", url: "https://example.com/swift-testing", snippet: "Testing package overview")
        ])

        let result = try await WebSearchBridge.execute(
            bodyData: try requestBody(stream: false),
            httpClient: httpClient,
            portableNormalizer: normalizer,
            provider: provider,
            performModelTurn: { bodyData in
                let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                seenRequests.append(json)
                defer { turnIndex += 1 }
                if turnIndex == 0 {
                    return WebSearchBridge.ModelResponse(
                        statusCode: 200,
                        headers: [("content-type", "application/json")],
                        bodyData: try assistantResponseBody(content: [
                            ["type": "tool_use", "id": "toolu_search", "name": "web_search", "input": ["query": "swift testing", "max_results": 3]]
                        ], usage: ["input_tokens": 10, "output_tokens": 1])
                    )
                }
                return WebSearchBridge.ModelResponse(
                    statusCode: 200,
                    headers: [("content-type", "application/json")],
                    bodyData: try assistantResponseBody(content: [
                        ["type": "text", "text": "Found useful Swift testing references."]
                    ], usage: ["input_tokens": 12, "output_tokens": 5])
                )
            }
        )

        #expect(seenRequests.count == 2)
        let secondMessages = try #require(seenRequests[1]["messages"] as? [[String: Any]])
        #expect(secondMessages.count == 3)
        let toolResults = try #require(secondMessages.last?["content"] as? [[String: Any]])
        #expect(toolResults.first?["type"] as? String == "tool_result")
        #expect((toolResults.first?["content"] as? String)?.contains("https://example.com/swift-testing") == true)
        #expect(result.inputTokens == 22)
        #expect(result.outputTokens == 6)
        #expect(result.clientResponse.statusCode == 200)
        #expect(result.clientResponse.headers.contains { $0.0 == "content-type" && $0.1 == "application/json" })

        let finalBody = try #require(result.clientResponse.bodyChunks.first)
        let finalJSON = try #require(try JSONSerialization.jsonObject(with: finalBody) as? [String: Any])
        let content = try #require(finalJSON["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Found useful Swift testing references.")
        let usage = try #require(finalJSON["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 22)
        #expect(usage["output_tokens"] as? Int == 6)
        #expect(result.assistantTurn != nil)
    }

    // MARK: - Provider Response Parsing

    @Test func braveProviderParsesWebResults() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "web": [
                "results": [
                    ["title": "Swift Testing", "url": "https://swift.org/testing", "description": "Testing framework for Swift"],
                    ["title": "XCTest Docs", "url": "https://developer.apple.com/xctest", "description": "Apple testing docs"],
                    ["title": "No URL Entry"],
                ]
            ]
        ], options: [.sortedKeys])

        let results = try BraveWebSearchProvider.parseBraveResponse(json, maxResults: 5)
        #expect(results.count == 2)
        #expect(results[0].title == "Swift Testing")
        #expect(results[0].url == "https://swift.org/testing")
        #expect(results[0].snippet == "Testing framework for Swift")
        #expect(results[1].url == "https://developer.apple.com/xctest")
    }

    @Test func googleProviderParsesItems() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "items": [
                ["title": "SwiftUI Guide", "link": "https://developer.apple.com/swiftui", "snippet": "Build apps with SwiftUI"],
                ["title": "Missing Link"],
            ]
        ], options: [.sortedKeys])

        let results = try GoogleWebSearchProvider.parseGoogleResponse(json, maxResults: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "SwiftUI Guide")
        #expect(results[0].url == "https://developer.apple.com/swiftui")
        #expect(results[0].snippet == "Build apps with SwiftUI")
    }

    @Test func tavilyProviderParsesResults() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "results": [
                ["title": "Actor Isolation", "url": "https://docs.swift.org/actors", "content": "Swift actor isolation explained"],
                ["title": "Concurrency", "url": "https://docs.swift.org/concurrency", "content": "Structured concurrency in Swift"],
            ]
        ], options: [.sortedKeys])

        let results = try TavilyWebSearchProvider.parseTavilyResponse(json, maxResults: 5)
        #expect(results.count == 2)
        #expect(results[0].title == "Actor Isolation")
        #expect(results[1].snippet == "Structured concurrency in Swift")
    }

    @Test func factoryReturnsNilWhenAPIKeyIsEmpty() {
        let config = WebSearchConfig(provider: .brave, braveAPIKey: "")
        #expect(WebSearchProviderFactory.make(from: config) == nil)

        let configWithKey = WebSearchConfig(provider: .brave, braveAPIKey: "test-key")
        #expect(WebSearchProviderFactory.make(from: configWithKey) != nil)
    }

    @Test func factoryReturnsNilForGoogleWithoutSearchEngineID() {
        let config = WebSearchConfig(provider: .google, googleAPIKey: "key", googleSearchEngineID: "")
        #expect(WebSearchProviderFactory.make(from: config) == nil)

        let full = WebSearchConfig(provider: .google, googleAPIKey: "key", googleSearchEngineID: "cx123")
        #expect(WebSearchProviderFactory.make(from: full) != nil)
    }

    @Test func synthesizeSSEProducesValidEventStream() throws {
        let body = try assistantResponseBody(content: [
            ["type": "text", "text": "Here are the results."],
            ["type": "tool_use", "id": "toolu_1", "name": "web_search", "input": ["query": "swift"]]
        ], usage: ["input_tokens": 50, "output_tokens": 20])

        let response = try WebSearchBridge.synthesizeSSE(from: body, inputTokens: 50, outputTokens: 20)
        #expect(response.statusCode == 200)
        #expect(response.headers.contains { $0.0 == "content-type" && $0.1 == "text/event-stream" })

        let combined = response.bodyChunks.reduce(Data()) { $0 + $1 }
        let text = String(data: combined, encoding: .utf8) ?? ""

        let eventNames = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("event: ") }
            .map { String($0.dropFirst("event: ".count)) }

        #expect(eventNames.first == "message_start")
        #expect(eventNames.last == "message_stop")
        #expect(eventNames.contains("content_block_start"))
        #expect(eventNames.contains("content_block_delta"))
        #expect(eventNames.contains("content_block_stop"))
        #expect(eventNames.contains("message_delta"))

        // Verify usage tokens in message_start and message_delta
        let dataLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }
        let messageStartData = try #require(dataLines.first)
        let startJSON = try #require(
            try JSONSerialization.jsonObject(with: Data(messageStartData.dropFirst("data: ".count).utf8)) as? [String: Any]
        )
        let messageUsage = try #require((startJSON["message"] as? [String: Any])?["usage"] as? [String: Any])
        #expect(messageUsage["input_tokens"] as? Int == 50)

        let messageDeltaData = try #require(dataLines.dropLast().last)
        let deltaJSON = try #require(
            try JSONSerialization.jsonObject(with: Data(messageDeltaData.dropFirst("data: ".count).utf8)) as? [String: Any]
        )
        let deltaUsage = try #require(deltaJSON["usage"] as? [String: Any])
        #expect(deltaUsage["output_tokens"] as? Int == 20)
    }

    @Test func executeThrowsMaxUsesExceeded() async throws {
        let normalizer = PortableContentNormalizer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let provider = StubWebSearchProvider(results: [
            WebSearchResult(title: "Result", url: "https://example.com", snippet: "Snippet")
        ])

        var turnCount = 0
        await #expect(throws: WebSearchBridgeError.maxUsesExceeded(limit: 2)) {
            _ = try await WebSearchBridge.execute(
                bodyData: try requestBody(stream: false, maxUses: 2),
                httpClient: httpClient,
                portableNormalizer: normalizer,
                provider: provider,
                performModelTurn: { _ in
                    turnCount += 1
                    return WebSearchBridge.ModelResponse(
                        statusCode: 200,
                        headers: [("content-type", "application/json")],
                        bodyData: try assistantResponseBody(content: [
                            ["type": "tool_use", "id": "toolu_\(turnCount)", "name": "web_search", "input": ["query": "test"]]
                        ], usage: ["input_tokens": 10, "output_tokens": 1])
                    )
                }
            )
        }
        #expect(turnCount == 2)
    }

    @Test func stepOutcomeThrowsMixedToolUseUnsupported() throws {
        let response = try assistantResponseBody(content: [
            ["type": "tool_use", "id": "toolu_search", "name": "web_search", "input": ["query": "swift"]],
            ["type": "tool_use", "id": "toolu_bash", "name": "bash", "input": ["cmd": "ls"]]
        ], usage: ["input_tokens": 10, "output_tokens": 2])

        #expect(throws: WebSearchBridgeError.mixedToolUseUnsupported) {
            _ = try WebSearchBridge.stepOutcome(from: response)
        }
    }

    @Test func executeThrowsOnUpstreamFailure() async throws {
        let normalizer = PortableContentNormalizer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let provider = StubWebSearchProvider(results: [])

        await #expect(
            throws: WebSearchBridgeError.upstreamFailure(
                statusCode: 500,
                bodyPreview: "{\"error\": \"internal\"}"
            )
        ) {
            _ = try await WebSearchBridge.execute(
                bodyData: try requestBody(stream: false),
                httpClient: httpClient,
                portableNormalizer: normalizer,
                provider: provider,
                performModelTurn: { _ in
                    WebSearchBridge.ModelResponse(
                        statusCode: 500,
                        headers: [],
                        bodyData: Data("{\"error\": \"internal\"}".utf8)
                    )
                }
            )
        }
    }

    @Test func executeHandlesMultipleToolCallsInSingleTurn() async throws {
        let normalizer = PortableContentNormalizer()
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        var searchQueries: [String] = []
        let provider = CountingWebSearchProvider { query in
            searchQueries.append(query)
            return [WebSearchResult(title: "Result for \(query)", url: "https://example.com/\(query)", snippet: "Snippet")]
        }

        var turnIndex = 0
        let result = try await WebSearchBridge.execute(
            bodyData: try requestBody(stream: false),
            httpClient: httpClient,
            portableNormalizer: normalizer,
            provider: provider,
            performModelTurn: { bodyData in
                defer { turnIndex += 1 }
                if turnIndex == 0 {
                    return WebSearchBridge.ModelResponse(
                        statusCode: 200,
                        headers: [("content-type", "application/json")],
                        bodyData: try assistantResponseBody(content: [
                            ["type": "tool_use", "id": "toolu_1", "name": "web_search", "input": ["query": "swift concurrency"]],
                            ["type": "tool_use", "id": "toolu_2", "name": "web_search", "input": ["query": "swift actors"]]
                        ], usage: ["input_tokens": 15, "output_tokens": 3])
                    )
                }
                return WebSearchBridge.ModelResponse(
                    statusCode: 200,
                    headers: [("content-type", "application/json")],
                    bodyData: try assistantResponseBody(content: [
                        ["type": "text", "text": "Found references on both topics."]
                    ], usage: ["input_tokens": 20, "output_tokens": 8])
                )
            }
        )

        #expect(searchQueries.count == 2)
        #expect(searchQueries.contains("swift concurrency"))
        #expect(searchQueries.contains("swift actors"))
        #expect(result.inputTokens == 35)
        #expect(result.outputTokens == 11)

        let finalBody = try #require(result.clientResponse.bodyChunks.first)
        let finalJSON = try #require(try JSONSerialization.jsonObject(with: finalBody) as? [String: Any])
        let content = try #require(finalJSON["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Found references on both topics.")
    }

    @Test func sanitizeToolsForVendorRemovesWebSearchAndKeepsOthers() throws {
        let body = try requestBody(stream: false)
        let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
        let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "bash")
    }
}

private struct StubWebSearchProvider: WebSearchBridgeProviding {
    let results: [WebSearchResult]

    func search(query: String, maxResults: Int, httpClient: HTTPClient) async throws -> [WebSearchResult] {
        Array(results.prefix(maxResults))
    }
}

private struct CountingWebSearchProvider: WebSearchBridgeProviding {
    let handler: @Sendable (String) -> [WebSearchResult]

    func search(query: String, maxResults: Int, httpClient: HTTPClient) async throws -> [WebSearchResult] {
        handler(query)
    }
}

private func requestBody(stream: Bool, maxUses: Int = 4) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "model": "claude-sonnet-4-6",
        "stream": stream,
        "messages": [
            ["role": "user", "content": "Search for Swift testing references"]
        ],
        "tools": [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": maxUses],
            [
                "name": "bash",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "cmd": ["type": "string"]
                    ],
                    "required": ["cmd"]
                ]
            ]
        ]
    ], options: [.sortedKeys])
}

private func assistantResponseBody(content: [[String: Any]], usage: [String: Int]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "model": "MiniMax-M2.7",
        "content": content,
        "stop_reason": "end_turn",
        "usage": usage
    ], options: [.sortedKeys])
}
