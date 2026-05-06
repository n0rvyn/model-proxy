import Foundation

/// Preset Anthropic model IDs shown in the RoutingTabView source model picker.
/// Users can also type custom model IDs not in this list.
enum KnownAnthropicModels {
    static let current: [String] = [
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
        "claude-haiku-4-5-20251001",
    ]

    static let legacy: [String] = [
        "claude-opus-4-6",
        "claude-sonnet-4-5",
        "claude-opus-4-1-20250805",
        "claude-opus-4-20250514",
        "claude-sonnet-4-20250514",
        "claude-3-7-sonnet-20250219",
        "claude-3-5-haiku-20241022",
        "claude-3-5-sonnet-20241022",
        "claude-3-opus-20240229",
    ]

    static var all: [String] {
        current + legacy
    }

    static func observedSuggestions(from observedModelsOldestToNewest: [String]) -> [String] {
        let knownModels = Set(all)
        var seen: Set<String> = []
        var suggestions: [String] = []

        for model in observedModelsOldestToNewest.reversed() {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !knownModels.contains(trimmed),
                  seen.insert(trimmed).inserted else { continue }
            suggestions.append(trimmed)
        }

        return suggestions
    }
}
