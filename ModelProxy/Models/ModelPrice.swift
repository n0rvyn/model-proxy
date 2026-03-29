import Foundation

/// Per-model token pricing for cost estimation.
struct ModelPrice: Codable, Sendable, Equatable {
    /// US dollars per 1 million input tokens.
    var inputPerMillion: Double
    /// US dollars per 1 million output tokens.
    var outputPerMillion: Double

    /// Compute cost in dollars for the given token counts.
    func cost(input: Int, output: Int) -> Double {
        Double(input) * inputPerMillion / 1_000_000 + Double(output) * outputPerMillion / 1_000_000
    }
}

// MARK: - Built-in Defaults

extension ModelPrice {
    /// Built-in pricing for mainstream models (as of March 2026).
    /// Keyed by model ID prefix for substring matching.
    static let builtInDefaults: [(prefix: String, price: ModelPrice)] = [
        // Anthropic (verified from platform.claude.com/docs March 2026)
        ("claude-opus-4-6", ModelPrice(inputPerMillion: 5, outputPerMillion: 25)),
        ("claude-opus-4-5", ModelPrice(inputPerMillion: 5, outputPerMillion: 25)),
        ("claude-opus-4-1", ModelPrice(inputPerMillion: 15, outputPerMillion: 75)),
        ("claude-opus-4-0", ModelPrice(inputPerMillion: 15, outputPerMillion: 75)),
        ("claude-opus-4", ModelPrice(inputPerMillion: 5, outputPerMillion: 25)),
        ("claude-sonnet-4", ModelPrice(inputPerMillion: 3, outputPerMillion: 15)),
        ("claude-haiku-4", ModelPrice(inputPerMillion: 1, outputPerMillion: 5)),

        // OpenAI
        ("gpt-4.1", ModelPrice(inputPerMillion: 2, outputPerMillion: 8)),
        ("gpt-4o-mini", ModelPrice(inputPerMillion: 0.15, outputPerMillion: 0.6)),
        ("gpt-4o", ModelPrice(inputPerMillion: 2.5, outputPerMillion: 10)),
        ("o3", ModelPrice(inputPerMillion: 2, outputPerMillion: 8)),
        ("o4-mini", ModelPrice(inputPerMillion: 1.1, outputPerMillion: 4.4)),

        // Google (verified from ai.google.dev/pricing March 2026)
        ("gemini-3.1-pro", ModelPrice(inputPerMillion: 2, outputPerMillion: 12)),
        ("gemini-3-flash", ModelPrice(inputPerMillion: 0.5, outputPerMillion: 3)),
        ("gemini-2.5-pro", ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10)),
        ("gemini-2.5-flash-lite", ModelPrice(inputPerMillion: 0.1, outputPerMillion: 0.4)),
        ("gemini-2.5-flash", ModelPrice(inputPerMillion: 0.3, outputPerMillion: 2.5)),

        // DeepSeek (verified from api-docs.deepseek.com, V3.2 unified pricing)
        ("deepseek-chat", ModelPrice(inputPerMillion: 0.28, outputPerMillion: 0.42)),
        ("deepseek-reasoner", ModelPrice(inputPerMillion: 0.28, outputPerMillion: 0.42)),
    ]

    /// Look up pricing for a model ID. Checks user overrides first, then built-in defaults via prefix match.
    static func lookup(_ modelID: String, overrides: [String: ModelPrice]) -> ModelPrice? {
        // Exact override match.
        if let override = overrides[modelID] { return override }
        // Prefix match in overrides.
        if let match = overrides.first(where: { modelID.hasPrefix($0.key) }) {
            return match.value
        }
        // Built-in longest-prefix match (e.g. "claude-opus-4-6" beats "claude-opus-4").
        return builtInDefaults
            .filter { modelID.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .price
    }
}
