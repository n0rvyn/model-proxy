import Foundation
import Observation

// MARK: - TrafficEntry

/// One recorded proxy request. No body content is stored.
struct TrafficEntry: Identifiable, Sendable {
    enum RouteType: Sendable {
        case passthrough
        case mapped(targetModel: String)
        case blocked
    }

    enum RequestKind: Sendable, Equatable {
        case generation
        case countTokens
        case auxiliary(endpointPath: String)
        case blocked
        case webSearchBridge(searchCount: Int)

        var endpointLabel: String {
            switch self {
            case .generation:
                return "messages"
            case .countTokens:
                return "count_tokens"
            case .auxiliary(let endpointPath):
                return endpointPath
            case .blocked:
                return "blocked"
            case .webSearchBridge:
                return "web_search"
            }
        }

        var isAuxiliary: Bool {
            switch self {
            case .generation, .blocked, .webSearchBridge:
                return false
            case .countTokens, .auxiliary:
                return true
            }
        }

        var shouldDisplayTPS: Bool {
            switch self {
            case .generation:
                return true
            case .countTokens, .auxiliary, .blocked, .webSearchBridge:
                return false
            }
        }
    }

    let id: UUID
    let model: String
    let routeType: RouteType
    let requestKind: RequestKind
    /// HTTP status returned to the client (200, 403, 502, etc.)
    let httpStatus: Int
    let timestamp: Date
    /// Total request duration in seconds; nil for blocked requests (no upstream call).
    let duration: TimeInterval?
    /// Output tokens from this request; nil when unavailable (blocked, replay, or no usage data).
    let outputTokens: Int?

    init(
        model: String,
        routeType: RouteType,
        requestKind: RequestKind,
        httpStatus: Int,
        duration: TimeInterval? = nil,
        outputTokens: Int? = nil,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.model = model
        self.routeType = routeType
        self.requestKind = requestKind
        self.httpStatus = httpStatus
        self.duration = duration
        self.outputTokens = outputTokens
        self.timestamp = timestamp
    }

    var displayModelLabel: String {
        switch requestKind {
        case .webSearchBridge(let searchCount):
            if searchCount == 1 {
                return "Web Search - \(model)"
            }
            return "Web Search (\(searchCount)) - \(model)"
        case .generation, .countTokens, .auxiliary, .blocked:
            return model
        }
    }

    var routeDisplayLabel: String {
        switch routeType {
        case .passthrough:
            return "pass"
        case .mapped(let targetModel):
            return targetModel
        case .blocked:
            return "blocked"
        }
    }

    var durationDisplayText: String {
        guard let duration else { return "-" }
        if duration < 1 {
            return String(format: "%.1fs", duration)
        } else if duration < 60 {
            return "\(Int(duration))s"
        } else {
            return String(format: "%.1fm", duration / 60)
        }
    }

    var tpsDisplayText: String {
        if case .webSearchBridge = requestKind {
            return "-"
        }
        guard requestKind.shouldDisplayTPS else { return "\u{2014}" }
        guard let outputTokens, outputTokens > 0,
              let duration, duration > 0 else { return "\u{2014}" }
        return "\(Int(Double(outputTokens) / duration))"
    }

    var accessibilitySummary: String {
        switch requestKind {
        case .webSearchBridge(let searchCount):
            let countLabel = searchCount == 1 ? "1 search" : "\(searchCount) searches"
            return "Web Search, \(model), \(countLabel), \(routeDisplayLabel), HTTP \(httpStatus), \(durationDisplayText), \(tpsDisplayText) t/s"
        case .generation, .countTokens, .auxiliary, .blocked:
            return "\(model), \(routeDisplayLabel), HTTP \(httpStatus), \(durationDisplayText), \(tpsDisplayText) t/s"
        }
    }
}

// MARK: - TrafficLog

/// Ring buffer of recent proxy requests. Capped at 50 entries.
/// @MainActor so SwiftUI can observe it directly without cross-actor hops.
@MainActor
@Observable
final class TrafficLog {

    static let maxEntries = 50

    /// Ordered oldest → newest; consumers scroll/display newest last.
    private(set) var entries: [TrafficEntry] = []

    /// Append a new entry, evicting the oldest if the buffer is full.
    func append(_ entry: TrafficEntry) {
        if entries.count >= Self.maxEntries {
            entries.removeFirst()
        }
        entries.append(entry)
    }
}
