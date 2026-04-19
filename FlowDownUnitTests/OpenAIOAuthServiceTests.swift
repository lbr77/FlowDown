@testable import FlowDown
import Foundation
import Testing

@Suite(.serialized)
struct OpenAIOAuthServiceTests {
    @Test
    func `decode jwt claims extracts payload`() throws {
        let token = try Self.makeJWT(payload: [
            "account_id": "acct_123",
            "sid": "sid_456",
            "sub": "user_789",
        ])

        let claims = OpenAIOAuthService.decodeJWTClaims(token)

        #expect(claims?["account_id"] as? String == "acct_123")
        #expect(claims?["sid"] as? String == "sid_456")
        #expect(claims?["sub"] as? String == "user_789")
    }

    @Test
    func `session metadata prefers namespaced workspace claims`() throws {
        let token = try Self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "org_123",
                "chatgpt_account_is_fedramp": true,
            ],
            "sub": "user_789",
        ])

        let metadata = OpenAIOAuthService.sessionMetadata(
            accessToken: "access_abc",
            idToken: token,
        )

        #expect(metadata.accessToken == "access_abc")
        #expect(metadata.accountID == "org_123")
        #expect(metadata.isFedrampAccount == true)
    }

    @Test
    func `session metadata falls back to access token claims`() throws {
        let accessToken = try Self.makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "org_from_access",
            ],
        ])

        let metadata = OpenAIOAuthService.sessionMetadata(
            accessToken: accessToken,
            idToken: nil,
        )

        #expect(metadata.accessToken == accessToken)
        #expect(metadata.accountID == "org_from_access")
        #expect(metadata.isFedrampAccount == false)
    }

    @Test
    func `begin authorization includes codex oauth parameters`() async throws {
        let service = OpenAIOAuthService.shared
        let url = try await service.beginAuthorization(force: true)
        defer {
            Task {
                await service.cancelAuthorization()
            }
        }

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
        #expect(queryItems["response_type"] == "code")
        #expect(queryItems["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(queryItems["scope"] == "openid profile email offline_access api.connectors.read api.connectors.invoke")
        #expect(queryItems["code_challenge_method"] == "S256")
        #expect(queryItems["id_token_add_organizations"] == "true")
        #expect(queryItems["codex_cli_simplified_flow"] == "true")
        #expect(queryItems["originator"] == OpenAIOAuthService.codexOriginator)

        let redirectURI = try #require(queryItems["redirect_uri"])
        let redirectURL = try #require(URL(string: redirectURI))
        #expect(redirectURL.host == "localhost")
        #expect(redirectURL.path == "/auth/callback")
        #expect(redirectURL.port != nil)
    }
}

private extension OpenAIOAuthServiceTests {
    static func makeJWT(payload: [String: Any]) throws -> String {
        let header = try base64URLJSON([
            "alg": "none",
            "typ": "JWT",
        ])
        let payload = try base64URLJSON(payload)
        return "\(header).\(payload).signature"
    }

    static func base64URLJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
