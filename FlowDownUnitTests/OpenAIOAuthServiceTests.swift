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
