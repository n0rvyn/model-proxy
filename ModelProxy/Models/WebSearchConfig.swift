import Foundation

struct WebSearchConfig: Codable, Hashable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case forwardAsIs
        case brave
        case google
        case tavily

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .forwardAsIs: return "Forward to Vendor"
            case .brave: return "Brave Search"
            case .google: return "Google Custom Search"
            case .tavily: return "Tavily"
            }
        }

        var registrationURL: String {
            switch self {
            case .forwardAsIs: return ""
            case .brave: return "https://brave.com/search/api/"
            case .google: return "https://developers.google.com/custom-search/v1/introduction"
            case .tavily: return "https://tavily.com"
            }
        }
    }

    var provider: Provider = .forwardAsIs
    var braveAPIKey: String = ""
    var googleAPIKey: String = ""
    var googleSearchEngineID: String = ""
    var tavilyAPIKey: String = ""
}
