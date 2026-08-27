import Testing
import Foundation
@testable import ModelProxy

struct FeedbackMailTests {

    @Test func mailtoURLTargetsPublishedSupportAddress() throws {
        let url = try #require(FeedbackMail.mailtoURL(version: "2.4", build: "2", osVersion: "Version 15.0"))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:norvynzhang@gmail.com?"))
    }

    /// `&` and `+` in the prefilled text must be percent-encoded, otherwise the
    /// mail client truncates the body at the first `&` or renders `+` as a space.
    @Test func ampersandAndPlusAreEncoded() throws {
        let os = "Version 15.0 A&B +C"
        let url = try #require(FeedbackMail.mailtoURL(version: "2.4", build: "2", osVersion: os))
        let query = try #require(URLComponents(string: url.absoluteString)?.percentEncodedQuery)

        // Exactly one separator: the one between subject and body.
        #expect(query.components(separatedBy: "&").count == 2)
        #expect(query.contains("%26B"))
        #expect(query.contains("%2BC"))
        #expect(!query.contains("+C"))
        #expect(!query.contains(" "))
    }

    @Test func bodyCarriesVersionsAndNothingElse() {
        let body = FeedbackMail.body(version: "2.4", build: "2", osVersion: "Version 15.0 (Build 24A335)")
        #expect(body.contains("ModelProxy 2.4 (2)"))
        #expect(body.contains("macOS Version 15.0 (Build 24A335)"))
        #expect(body.contains("Describe the issue or suggestion:"))
    }

    @Test func subjectIdentifiesTheBuild() {
        #expect(FeedbackMail.subject(version: "2.4", build: "2") == "ModelProxy Feedback - 2.4 (2)")
    }

    @Test func newlinesAreEncoded() throws {
        let url = try #require(FeedbackMail.mailtoURL(version: "2.4", build: "2", osVersion: "Version 15.0"))
        #expect(!url.absoluteString.contains("\n"))
        #expect(url.absoluteString.contains("%0A"))
    }
}
