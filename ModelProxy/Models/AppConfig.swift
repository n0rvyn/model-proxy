import Foundation
import Observation
import OSLog

// MARK: - Debug Config

struct DebugConfig: Codable, Hashable {
    var isEnabled: Bool = false
    var minimumLogLevel: LogLevel = .info
    var autoCleanupEnabled: Bool = true
    var cleanupAfterDays: Int = 7
    var compressAfterDays: Int = 3

    enum LogLevel: String, Codable, CaseIterable, Comparable {
        case debug, info, warning, error

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.debug, .info, .warning, .error]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
}

// MARK: - App Config

/// Top-level configuration container.
/// Loaded from and persisted to config.json by ConfigStore.
/// `@Observable` so SwiftUI views automatically update when properties change.
@Observable
final class AppConfig: Codable {
    var vendors: [Vendor]
    var clients: [ClientConfig]
    /// Global model routing rules, shared across all clients.
    var modelMappings: [ModelMapping]
    var debug: DebugConfig
    /// User-overridden model pricing ($/1M tokens). Keys are model ID strings.
    var modelPricingOverrides: [String: ModelPrice]

    // MARK: - Init

    init(
        vendors: [Vendor] = [],
        clients: [ClientConfig] = [],
        modelMappings: [ModelMapping] = [],
        debug: DebugConfig = DebugConfig(),
        modelPricingOverrides: [String: ModelPrice] = [:]
    ) {
        self.vendors = vendors
        self.clients = clients
        self.modelMappings = modelMappings
        self.debug = debug
        self.modelPricingOverrides = modelPricingOverrides
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case vendors
        case clients
        case modelMappings
        case debug
        case modelPricingOverrides
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendors = try container.decode([Vendor].self, forKey: .vendors)
        clients = try container.decode([ClientConfig].self, forKey: .clients)
        modelMappings = (try? container.decode([ModelMapping].self, forKey: .modelMappings)) ?? []
        debug = (try? container.decode(DebugConfig.self, forKey: .debug)) ?? DebugConfig()
        modelPricingOverrides = (try? container.decode([String: ModelPrice].self, forKey: .modelPricingOverrides)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendors, forKey: .vendors)
        try container.encode(clients, forKey: .clients)
        try container.encode(modelMappings, forKey: .modelMappings)
        try container.encode(debug, forKey: .debug)
        if !modelPricingOverrides.isEmpty {
            try container.encode(modelPricingOverrides, forKey: .modelPricingOverrides)
        }
    }
}

// MARK: - Default config

extension AppConfig {
    /// Sensible defaults created on first launch.
    static func makeDefault() -> AppConfig {
        let claudeCodeClient = ClientConfig(
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let codexClient = ClientConfig(
            clientName: "Codex",
            port: 8081,
            defaultUpstream: "https://api.openai.com"
        )
        return AppConfig(
            vendors: [],
            clients: [claudeCodeClient, codexClient],
            modelMappings: []
        )
    }
}
