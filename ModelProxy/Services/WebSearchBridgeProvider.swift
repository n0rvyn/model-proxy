import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOFoundationCompat

struct WebSearchResult: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

protocol WebSearchBridgeProviding: Sendable {
    func search(
        query: String,
        maxResults: Int,
        httpClient: HTTPClient
    ) async throws -> [WebSearchResult]
}

enum WebSearchBridgeProviderError: Error {
    case invalidQuery
    case upstreamFailure(statusCode: Int)
    case invalidResponse
}

// MARK: - Factory

enum WebSearchProviderFactory {
    static func make(from config: WebSearchConfig) -> (any WebSearchBridgeProviding)? {
        switch config.provider {
        case .forwardAsIs:
            return nil
        case .brave:
            let key = config.braveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return BraveWebSearchProvider(apiKey: key)
        case .google:
            let key = config.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let cx = config.googleSearchEngineID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !cx.isEmpty else { return nil }
            return GoogleWebSearchProvider(apiKey: key, searchEngineID: cx)
        case .tavily:
            let key = config.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return TavilyWebSearchProvider(apiKey: key)
        }
    }
}

// MARK: - Brave Search

struct BraveWebSearchProvider: WebSearchBridgeProviding {
    let apiKey: String

    func search(
        query: String,
        maxResults: Int,
        httpClient: HTTPClient
    ) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchBridgeProviderError.invalidQuery }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "count", value: String(min(maxResults, 20)))
        ]

        var request = HTTPClientRequest(url: components.string!)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")
        request.headers.add(name: "X-Subscription-Token", value: apiKey)

        let response = try await httpClient.execute(request, timeout: .seconds(15))
        try checkStatus(response)
        let body = try await collectBody(response)
        return try Self.parseBraveResponse(body, maxResults: maxResults)
    }

    static func parseBraveResponse(_ data: Data, maxResults: Int) throws -> [WebSearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return []
        }
        return results.prefix(maxResults).compactMap { entry in
            guard let title = entry["title"] as? String,
                  let url = entry["url"] as? String else { return nil }
            let snippet = (entry["description"] as? String) ?? ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }
}

// MARK: - Google Custom Search

struct GoogleWebSearchProvider: WebSearchBridgeProviding {
    let apiKey: String
    let searchEngineID: String

    func search(
        query: String,
        maxResults: Int,
        httpClient: HTTPClient
    ) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchBridgeProviderError.invalidQuery }

        var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineID),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "num", value: String(min(maxResults, 10)))
        ]

        var request = HTTPClientRequest(url: components.string!)
        request.method = .GET
        request.headers.add(name: "Accept", value: "application/json")

        let response = try await httpClient.execute(request, timeout: .seconds(15))
        try checkStatus(response)
        let body = try await collectBody(response)
        return try Self.parseGoogleResponse(body, maxResults: maxResults)
    }

    static func parseGoogleResponse(_ data: Data, maxResults: Int) throws -> [WebSearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }
        return items.prefix(maxResults).compactMap { entry in
            guard let title = entry["title"] as? String,
                  let url = entry["link"] as? String else { return nil }
            let snippet = (entry["snippet"] as? String) ?? ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }
}

// MARK: - Tavily

struct TavilyWebSearchProvider: WebSearchBridgeProviding {
    let apiKey: String

    func search(
        query: String,
        maxResults: Int,
        httpClient: HTTPClient
    ) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchBridgeProviderError.invalidQuery }

        let requestBody: [String: Any] = [
            "api_key": apiKey,
            "query": trimmed,
            "max_results": min(maxResults, 10)
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: requestBody, options: [])

        var request = HTTPClientRequest(url: "https://api.tavily.com/search")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(bodyData)

        let response = try await httpClient.execute(request, timeout: .seconds(15))
        try checkStatus(response)
        let body = try await collectBody(response)
        return try Self.parseTavilyResponse(body, maxResults: maxResults)
    }

    static func parseTavilyResponse(_ data: Data, maxResults: Int) throws -> [WebSearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }
        return results.prefix(maxResults).compactMap { entry in
            guard let title = entry["title"] as? String,
                  let url = entry["url"] as? String else { return nil }
            let snippet = (entry["content"] as? String) ?? ""
            return WebSearchResult(title: title, url: url, snippet: snippet)
        }
    }
}

// MARK: - Shared Helpers

private func checkStatus(_ response: HTTPClientResponse) throws {
    let statusCode = Int(response.status.code)
    guard statusCode < 400 else {
        throw WebSearchBridgeProviderError.upstreamFailure(statusCode: statusCode)
    }
}

private func collectBody(_ response: HTTPClientResponse) async throws -> Data {
    var body = Data()
    for try await chunk in response.body {
        if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
            body.append(bytes)
        }
    }
    return body
}
