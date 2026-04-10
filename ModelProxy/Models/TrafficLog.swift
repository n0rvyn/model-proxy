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
            }
        }

        var isAuxiliary: Bool {
            switch self {
            case .generation, .blocked:
                return false
            case .countTokens, .auxiliary:
                return true
            }
        }

        var shouldDisplayTPS: Bool {
            self == .generation
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
