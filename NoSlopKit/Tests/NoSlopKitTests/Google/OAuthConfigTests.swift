import Foundation
import Testing
@testable import NoSlopKit

@Suite struct OAuthConfigTests {
    private static func queryItems(of url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    @Test func configFromClientID() throws {
        let c = try #require(GoogleOAuthConfig(clientID: " 123-abc.apps.googleusercontent.com "))
        #expect(c.clientID == "123-abc.apps.googleusercontent.com")
        #expect(c.redirectScheme == "com.googleusercontent.apps.123-abc")
        #expect(c.redirectURI == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(GoogleOAuthConfig(clientID: "nope") == nil)
        let items = Self.queryItems(of: c.authorizationURL(state: "S", codeChallenge: "C"))
        #expect(items.first { $0.name == "response_type" }?.value == "code")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "scope" }?.value == "openid email profile https://www.googleapis.com/auth/youtube")
        #expect(items.first { $0.name == "state" }?.value == "S")
        #expect(items.first { $0.name == "redirect_uri" }?.value == c.redirectURI)
    }

    @Test func theSharedClientIDIsEitherNotSetUpOrAValidOne() {
        #expect(GoogleOAuthConfig.sharedClientID.isEmpty || GoogleOAuthConfig(clientID: GoogleOAuthConfig.sharedClientID) != nil)
        #expect(GoogleOAuthConfig.hasSharedProject == !GoogleOAuthConfig.sharedClientID.isEmpty)
    }

    @Test func theOwnProjectIsUsedOnlyWhenChosenOrWhenThereIsNoSharedOne() {
        let own = " 123-abc.apps.googleusercontent.com "
        #expect(GoogleOAuthConfig.effectiveClientID(useOwnProject: true, ownClientID: own) == "123-abc.apps.googleusercontent.com")
        let notChosen = GoogleOAuthConfig.effectiveClientID(useOwnProject: false, ownClientID: own)
        if GoogleOAuthConfig.hasSharedProject {
            #expect(notChosen == GoogleOAuthConfig.sharedClientID, "the shared project is the default")
        } else {
            #expect(notChosen == "123-abc.apps.googleusercontent.com", "with no shared project the user's own is the only one")
        }
        #expect(GoogleOAuthConfig.effectiveClientID(useOwnProject: true, ownClientID: "  ") == "")
    }

    @Test func aRealisticClientIDWorks() throws {
        let id = "407408718192-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
        let c = try #require(GoogleOAuthConfig(clientID: id))
        #expect(c.redirectScheme == "com.googleusercontent.apps.407408718192-abcdefghijklmnopqrstuvwxyz012345")
        #expect(c.redirectURI.hasSuffix(":/oauth2redirect"))
    }

    @Test func surroundingWhitespaceAndNewlinesAreTrimmed() throws {
        let c = try #require(GoogleOAuthConfig(clientID: "\n\t 123-abc.apps.googleusercontent.com \r\n"))
        #expect(c.clientID == "123-abc.apps.googleusercontent.com")
        #expect(c == GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com"))
    }

    @Test(arguments: [
        "",
        "   ",
        "nope",
        "123-abc",
        "123-abc.googleusercontent.com",
        "123-abc.apps.googleusercontent.com.evil.example",
        ".apps.googleusercontent.com",  // nothing before the suffix
        "123-abc apps.googleusercontent.com",  // space instead of the dot
        "12 3-abc.apps.googleusercontent.com",  // whitespace inside
        "123/abc.apps.googleusercontent.com",  // not valid inside a URL scheme
        "https://123-abc.apps.googleusercontent.com",
        "123-abc.apps.googleusercontent.com/",
    ])
    func malformedClientIDsAreRejected(text: String) {
        #expect(GoogleOAuthConfig(clientID: text) == nil)
    }

    @Test func authorizationURLTargetsGoogleAndCarriesPKCE() throws {
        let c = try #require(GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com"))
        let url = c.authorizationURL(state: "STATE", codeChallenge: "CHALLENGE")
        #expect(url.scheme == "https")
        #expect(url.host == "accounts.google.com")
        #expect(url.path == "/o/oauth2/v2/auth")

        let items = Self.queryItems(of: url)
        #expect(items.first { $0.name == "client_id" }?.value == "123-abc.apps.googleusercontent.com")
        #expect(items.first { $0.name == "code_challenge" }?.value == "CHALLENGE")
        // A public client: exactly these parameters, and in particular no client secret.
        #expect(Set(items.map(\.name)) == ["client_id", "redirect_uri", "response_type", "scope", "code_challenge", "code_challenge_method", "state"])
        #expect(items.count == 7)
    }

    @Test func authorizationURLEncodesValuesSoTheyRoundTrip() throws {
        let c = try #require(GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com"))
        let url = c.authorizationURL(state: "a b&c=d+e/f?g#h", codeChallenge: "x~y_z-1")
        let items = Self.queryItems(of: url)
        #expect(items.first { $0.name == "state" }?.value == "a b&c=d+e/f?g#h")
        #expect(items.first { $0.name == "code_challenge" }?.value == "x~y_z-1")
        // Exactly one query, no fragment smuggled in by the "#".
        #expect(url.fragment == nil)
        #expect(items.count == 7)
    }

    @Test func scopesAreTheDocumentedOnes() {
        #expect(GoogleOAuthConfig.scopes == ["openid", "email", "profile", "https://www.googleapis.com/auth/youtube"])
    }

    @Test func configsAreValueTypes() throws {
        let a = try #require(GoogleOAuthConfig(clientID: "1-a.apps.googleusercontent.com"))
        let b = try #require(GoogleOAuthConfig(clientID: "1-a.apps.googleusercontent.com"))
        let c = try #require(GoogleOAuthConfig(clientID: "2-b.apps.googleusercontent.com"))
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
