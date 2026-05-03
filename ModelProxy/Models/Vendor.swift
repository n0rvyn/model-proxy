import Foundation

enum VendorDefaults {
    static let supportsThinkingBlocks = false
    static let supportsAnthropicCountTokens = true
    static let repairsAnthropicToolCalls = false

    static func isDeepSeekBaseURL(_ baseURL: String) -> Bool {
        if let host = URL(string: baseURL)?.host?.lowercased() {
            return host == "api.deepseek.com"
        }
        return baseURL.lowercased().contains("api.deepseek.com")
    }

    static func supportsAnthropicCountTokens(forBaseURL baseURL: String) -> Bool {
        isDeepSeekBaseURL(baseURL) ? false : supportsAnthropicCountTokens
    }

    static func repairsAnthropicToolCalls(forBaseURL baseURL: String) -> Bool {
        isDeepSeekBaseURL(baseURL) ? true : repairsAnthropicToolCalls
    }
}

/// A single upstream API provider.
struct Vendor: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Base URL of the vendor's API (without version path),
    /// e.g. "https://dashscope.aliyuncs.com/compatible-mode".
    /// The request URI (including "/v1/...") is appended directly.
    var baseURL: String
    /// API key stored in plaintext in config.json (personal-use tool; not Keychain by design).
    var apiKey: String
    /// Per-vendor connect timeout in seconds. Default 10.
    var connectTimeoutSeconds: Int
    /// Per-vendor read timeout in seconds. Default 120.
    var readTimeoutSeconds: Int
    /// Links to a ClientConfig.id to indicate which tool this vendor is compatible with.
    /// nil = compatible with all clients.
    var compatibleClientID: UUID?
    /// Vendor model IDs available for quick selection in routing forms.
    var supportedModels: [String]
    /// Whether this vendor accepts Anthropic `thinking` content blocks in request history.
    var supportsThinkingBlocks: Bool
    /// Whether this vendor supports Anthropic `/v1/messages/count_tokens`.
    var supportsAnthropicCountTokens: Bool
    /// Whether ModelProxy should repair returned Anthropic `tool_use.input` blocks for this vendor.
    var repairsAnthropicToolCalls: Bool
    /// Which signing domain this vendor belongs to for transcript replay compatibility.
    var signingDomain: SigningDomain
    /// Whether requests to this vendor should preserve raw replay-sensitive transcript blocks.
    var replayPolicy: TranscriptReplayPolicy

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String,
        connectTimeoutSeconds: Int = 10,
        readTimeoutSeconds: Int = 120,
        compatibleClientID: UUID? = nil,
        supportedModels: [String] = [],
        supportsThinkingBlocks: Bool = VendorDefaults.supportsThinkingBlocks,
        supportsAnthropicCountTokens: Bool? = nil,
        repairsAnthropicToolCalls: Bool? = nil,
        signingDomain: SigningDomain? = nil,
        replayPolicy: TranscriptReplayPolicy? = nil
    ) {
        let resolvedSigningDomain = signingDomain ?? SigningDomain.infer(fromBaseURL: baseURL)
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.readTimeoutSeconds = readTimeoutSeconds
        self.compatibleClientID = compatibleClientID
        self.supportedModels = supportedModels
        self.supportsThinkingBlocks = supportsThinkingBlocks
        self.supportsAnthropicCountTokens = supportsAnthropicCountTokens
            ?? VendorDefaults.supportsAnthropicCountTokens(forBaseURL: baseURL)
        self.repairsAnthropicToolCalls = repairsAnthropicToolCalls
            ?? VendorDefaults.repairsAnthropicToolCalls(forBaseURL: baseURL)
        self.signingDomain = resolvedSigningDomain
        self.replayPolicy = replayPolicy ?? TranscriptReplayPolicy.defaultPolicy(for: resolvedSigningDomain)
    }

    // MARK: - Codable (legacy-tolerant)

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey
        case connectTimeoutSeconds, readTimeoutSeconds
        case compatibleClientID
        case supportedModels
        case supportsThinkingBlocks
        case supportsAnthropicCountTokens
        case repairsAnthropicToolCalls
        case signingDomain
        case replayPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        connectTimeoutSeconds = (try? c.decode(Int.self, forKey: .connectTimeoutSeconds)) ?? 10
        readTimeoutSeconds = (try? c.decode(Int.self, forKey: .readTimeoutSeconds)) ?? 120
        compatibleClientID = try? c.decode(UUID.self, forKey: .compatibleClientID)
        supportedModels = (try? c.decode([String].self, forKey: .supportedModels)) ?? []
        supportsThinkingBlocks = (try? c.decode(Bool.self, forKey: .supportsThinkingBlocks))
            ?? VendorDefaults.supportsThinkingBlocks
        supportsAnthropicCountTokens = (try? c.decodeIfPresent(Bool.self, forKey: .supportsAnthropicCountTokens))
            ?? VendorDefaults.supportsAnthropicCountTokens(forBaseURL: baseURL)
        repairsAnthropicToolCalls = (try? c.decodeIfPresent(Bool.self, forKey: .repairsAnthropicToolCalls))
            ?? VendorDefaults.repairsAnthropicToolCalls(forBaseURL: baseURL)
        let resolvedSigningDomain = (try? c.decode(SigningDomain.self, forKey: .signingDomain))
            ?? SigningDomain.infer(fromBaseURL: baseURL)
        signingDomain = resolvedSigningDomain
        replayPolicy = (try? c.decode(TranscriptReplayPolicy.self, forKey: .replayPolicy))
            ?? TranscriptReplayPolicy.defaultPolicy(for: resolvedSigningDomain)
    }
}
