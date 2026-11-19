import Foundation

/// Policy for handling models that have no routing rule.
enum UnmappedModelPolicy: String, Codable, CaseIterable, Sendable {
    /// Forward to defaultUpstream unchanged (current key, current model).
    case passthrough
    /// Forward to a chosen fallback vendor (vendor's key, original model name).
    case routeAll
    /// Reject with HTTP 403.
    case block
}

enum ClaudeConnectionMode: String, Codable, CaseIterable, Sendable {
    case subscription
    case vendorOnly
}

/// Configuration for a single AI client tool (e.g., Claude Code or Codex).
/// Each client gets its own proxy port. The proxy identifies the tool by port and
/// uses `defaultUpstream` as the passthrough target for unmapped models.
struct ClientConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Display name, e.g. "Claude Code" or "Codex".
    var clientName: String
    /// Localhost port this client's proxy listener binds to.
    var port: Int
    /// Passthrough target URL for unmapped models.
    /// Claude Code default: "https://api.anthropic.com"
    /// Codex default: configured per-installation endpoint.
    var defaultUpstream: String
    /// How to handle models with no routing rule.
    var unmappedPolicy: UnmappedModelPolicy
    /// Vendor to route unmapped models to when policy is `.routeAll`.
    var fallbackVendorID: UUID?
    /// Model name to substitute when routing to fallback vendor; nil = keep original model name.
    var fallbackTargetModel: String?
    /// Token for the local proxy listener. Subscription mode can run without one.
    var localAuthToken: String?
    var claudeConnectionMode: ClaudeConnectionMode

    nonisolated static let localAuthHeader = "X-ModelProxy-Token"

    var isClaudeCode: Bool { clientName.lowercased().contains("claude") }
    var isVendorOnly: Bool { isClaudeCode && claudeConnectionMode == .vendorOnly }

    static func isValidLocalAuthToken(_ token: String) -> Bool {
        token.utf8.allSatisfy { (32...126).contains($0) }
    }

    func claudeQuickStartCommand(maskToken: Bool = false) -> String? {
        let token = localAuthToken ?? ""
        guard Self.isValidLocalAuthToken(token), !isVendorOnly || !token.isEmpty else { return nil }
        var command = "env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS"
        command += " ANTHROPIC_BASE_URL=http://127.0.0.1:\(port) CLAUDE_CODE_GATEWAY_HINT_HEADERS=1"
        if !token.isEmpty {
            let value = maskToken ? "••••••••" : token
            if isVendorOnly {
                command += " ANTHROPIC_AUTH_TOKEN=\(Self.shellQuote(value))"
            } else {
                command += " ANTHROPIC_CUSTOM_HEADERS=\(Self.shellQuote("\(Self.localAuthHeader): \(value)"))"
            }
        }
        return command + " claude"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    init(
        id: UUID = UUID(),
        clientName: String,
        port: Int,
        defaultUpstream: String,
        unmappedPolicy: UnmappedModelPolicy = .passthrough,
        fallbackVendorID: UUID? = nil,
        fallbackTargetModel: String? = nil,
        localAuthToken: String? = nil,
        claudeConnectionMode: ClaudeConnectionMode = .subscription
    ) {
        self.id = id
        self.clientName = clientName
        self.port = port
        self.defaultUpstream = defaultUpstream
        self.unmappedPolicy = unmappedPolicy
        self.fallbackVendorID = fallbackVendorID
        self.fallbackTargetModel = fallbackTargetModel
        self.localAuthToken = localAuthToken
        self.claudeConnectionMode = claudeConnectionMode
    }

    // MARK: - Codable (legacy-tolerant)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientName = try c.decode(String.self, forKey: .clientName)
        port = try c.decode(Int.self, forKey: .port)
        defaultUpstream = (try? c.decode(String.self, forKey: .defaultUpstream)) ?? ""
        unmappedPolicy = (try? c.decode(UnmappedModelPolicy.self, forKey: .unmappedPolicy)) ?? .passthrough
        fallbackVendorID = try? c.decode(UUID.self, forKey: .fallbackVendorID)
        fallbackTargetModel = try? c.decode(String.self, forKey: .fallbackTargetModel)
        localAuthToken = try c.decodeIfPresent(String.self, forKey: .localAuthToken)
        claudeConnectionMode = try c.decodeIfPresent(ClaudeConnectionMode.self, forKey: .claudeConnectionMode) ?? .subscription
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientName, forKey: .clientName)
        try c.encode(port, forKey: .port)
        try c.encode(defaultUpstream, forKey: .defaultUpstream)
        try c.encode(unmappedPolicy, forKey: .unmappedPolicy)
        try c.encodeIfPresent(fallbackVendorID, forKey: .fallbackVendorID)
        try c.encodeIfPresent(fallbackTargetModel, forKey: .fallbackTargetModel)
        try c.encodeIfPresent(localAuthToken, forKey: .localAuthToken)
        try c.encode(claudeConnectionMode, forKey: .claudeConnectionMode)
    }

    enum CodingKeys: String, CodingKey {
        case id, clientName, port, defaultUpstream, unmappedPolicy, fallbackVendorID, fallbackTargetModel
        case localAuthToken, claudeConnectionMode
    }
}
