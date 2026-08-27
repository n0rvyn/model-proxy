import Foundation

/// Builds the "Send Feedback" mailto URL used by the About section in Settings.
///
/// The prefilled body carries app version and macOS version only. Configuration,
/// vendor names, API keys, and any request/response data are deliberately excluded —
/// see the project constraint on not storing or transmitting API traffic.
enum FeedbackMail {
    /// Support address published in `docs/10-app-store-connect/Support-Page.md`.
    static let recipient = "norvynzhang@gmail.com"

    /// Unreserved characters per RFC 3986. Everything else is percent-encoded, so
    /// `&` and `+` inside subject/body cannot truncate or corrupt the query.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// e.g. `2.4 (2)`
    static var versionDisplay: String {
        "\(appVersion) (\(buildNumber))"
    }

    static func subject(version: String, build: String) -> String {
        "ModelProxy Feedback - \(version) (\(build))"
    }

    static func body(version: String, build: String, osVersion: String) -> String {
        """
        Describe the issue or suggestion:


        ---
        ModelProxy \(version) (\(build))
        macOS \(osVersion)
        """
    }

    static func mailtoURL(version: String, build: String, osVersion: String) -> URL? {
        let subject = encode(subject(version: version, build: build))
        let body = encode(body(version: version, build: build, osVersion: osVersion))
        return URL(string: "mailto:\(recipient)?subject=\(subject)&body=\(body)")
    }

    /// The URL for the running app, filled in from the bundle and the current OS.
    static func currentMailtoURL() -> URL? {
        mailtoURL(version: appVersion, build: buildNumber, osVersion: osVersion)
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
