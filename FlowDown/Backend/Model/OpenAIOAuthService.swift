//
//  OpenAIOAuthService.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import CryptoKit
import Foundation

struct OpenAIOAuthSessionMetadata: Equatable {
    let accessToken: String
    let accountID: String?
    let isFedrampAccount: Bool
}

extension Notification.Name {
    static let openAIOAuthCredentialsDidChange = Notification.Name("wiki.qaq.flowdown.openai.credentials.didChange")
}

actor OpenAIOAuthService {
    static let shared = OpenAIOAuthService()

    private static let defaultClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = URL(string: "https://auth.openai.com")!
    static let codexOriginator = "codex_cli_rs"
    private static let callbackPath = "/auth/callback"
    private static let credentialAccount = "default"
    private static let credentialExpiryLeeway: TimeInterval = 60

    struct Credentials: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let idToken: String?
    }

    private struct PKCEState {
        let verifier: String
        let challenge: String
        let state: String
    }

    private struct AuthorizationFlow {
        let pkce: PKCEState
        let redirectServer: OpenAIOAuthRedirectServer
        let redirectURL: URL
    }

    private struct NamespacedAuthClaims: Decodable {
        let chatgptAccountID: String?
        let chatgptUserID: String?
        let userID: String?
        let chatgptAccountIsFedramp: Bool?

        enum CodingKeys: String, CodingKey {
            case chatgptAccountID = "chatgpt_account_id"
            case chatgptUserID = "chatgpt_user_id"
            case userID = "user_id"
            case chatgptAccountIsFedramp = "chatgpt_account_is_fedramp"
        }
    }

    private struct IDTokenClaimsEnvelope: Decodable {
        let auth: NamespacedAuthClaims?

        enum CodingKeys: String, CodingKey {
            case auth = "https://api.openai.com/auth"
        }
    }

    private struct RefreshTokenRequest: Encodable {
        let clientID: String
        let grantType: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private let keychain = OpenAIOAuthKeychainStore(service: "wiki.qaq.flowdown.openai.oauth")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentFlow: AuthorizationFlow?
}

extension OpenAIOAuthService {
    func hasCredentials() -> Bool {
        (try? loadCredentials()) != nil
    }

    func isAuthenticating() -> Bool {
        currentFlow != nil
    }

    func clearCredentials() throws {
        try keychain.delete(account: Self.credentialAccount)
        postCredentialsDidChange()
    }

    func beginAuthorization(force: Bool = false) async throws -> URL {
        if currentFlow != nil {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth sign-in is already in progress."],
            )
        }

        if force == false, hasCredentials() {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth credentials are already available on this device."],
            )
        }

        let pkce = Self.generatePKCEState()
        let redirectServer = try OpenAIOAuthRedirectServer(callbackPath: Self.callbackPath)
        let redirectURL = try await redirectServer.start()
        currentFlow = AuthorizationFlow(
            pkce: pkce,
            redirectServer: redirectServer,
            redirectURL: redirectURL,
        )
        return Self.buildAuthorizeURL(pkce: pkce, redirectURL: redirectURL)
    }

    func completeAuthorization(callbackURLString: String) async throws {
        guard let flow = currentFlow else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth sign-in has not started."],
            )
        }

        let callbackURL = try Self.parseCallbackURL(
            callbackURLString,
            expectedRedirectURL: flow.redirectURL,
        )
        try await finishAuthorization(flow: flow, callbackURL: callbackURL)
    }

    func cancelAuthorization() async {
        if let redirectServer = currentFlow?.redirectServer {
            await redirectServer.cancel()
        }
        currentFlow = nil
    }

    func awaitAuthorizationCompletion() async throws {
        guard let flow = currentFlow else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth sign-in has not started."],
            )
        }

        let callbackURL = try await flow.redirectServer.waitForCallbackURL()
        try await finishAuthorization(flow: flow, callbackURL: callbackURL)
    }

    func resolvedSession() async throws -> OpenAIOAuthSessionMetadata {
        guard var credentials = try loadCredentials() else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth credentials are unavailable. Configure the ChatGPT Codex endpoint again to sign in."],
            )
        }

        if credentials.expiresAt.timeIntervalSinceNow <= Self.credentialExpiryLeeway {
            do {
                credentials = try await refreshAccessToken(credentials)
                try saveCredentials(credentials)
            } catch {
                try? clearCredentials()
                throw error
            }
        }

        let metadata = Self.sessionMetadata(
            accessToken: credentials.accessToken,
            idToken: credentials.idToken,
        )
        return metadata
    }
}

private extension OpenAIOAuthService {
    static func parseCallbackURL(
        _ callbackURLString: String,
        expectedRedirectURL: URL
    ) throws -> URL {
        let trimmed = callbackURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let callbackURL = URL(string: trimmed) else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FlowDown could not parse the pasted redirect URL."],
            )
        }

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FlowDown could not read the pasted redirect URL."],
            )
        }

        let redirectComponents = URLComponents(url: expectedRedirectURL, resolvingAgainstBaseURL: false)
        let expectedPort = redirectComponents?.port
        if components.scheme != redirectComponents?.scheme
            || components.host != redirectComponents?.host
            || components.port != expectedPort
            || components.path != redirectComponents?.path
        {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The pasted redirect URL does not match FlowDown's ChatGPT OAuth callback URL."],
            )
        }

        return callbackURL
    }

    func loadCredentials() throws -> Credentials? {
        guard let data = try keychain.load(account: Self.credentialAccount) else {
            return nil
        }
        return try decoder.decode(Credentials.self, from: data)
    }

    func saveCredentials(_ credentials: Credentials) throws {
        try keychain.save(encoder.encode(credentials), account: Self.credentialAccount)
        postCredentialsDidChange()
    }

    func exchangeCodeForTokens(
        code: String,
        verifier: String,
        redirectURL: URL,
    ) async throws -> Credentials {
        var request = URLRequest(url: Self.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.codexOriginator, forHTTPHeaderField: "Originator")
        request.httpBody = URLComponents.formURLEncodedData([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURL.absoluteString,
            "client_id": Self.defaultClientID,
            "code_verifier": verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try requireTokenPayload(data: data, response: response, action: "exchange")
        guard let refreshToken = payload.refreshToken, !refreshToken.isEmpty else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth exchange did not return a refresh token."],
            )
        }
        return Credentials(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expiresIn),
            idToken: payload.idToken,
        )
    }

    func refreshAccessToken(_ credentials: Credentials) async throws -> Credentials {
        var request = URLRequest(url: Self.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.codexOriginator, forHTTPHeaderField: "Originator")
        request.httpBody = try encoder.encode(RefreshTokenRequest(
            clientID: Self.defaultClientID,
            grantType: "refresh_token",
            refreshToken: credentials.refreshToken,
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try requireTokenPayload(data: data, response: response, action: "refresh")
        return Credentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expiresIn),
            idToken: payload.idToken ?? credentials.idToken,
        )
    }

    func requireTokenPayload(
        data: Data,
        response: URLResponse,
        action: String,
    ) throws -> OpenAITokenResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth \(action) failed because the server response was invalid."],
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = body?.isEmpty == false ? "\n\n\(body!)" : ""
            throw NSError(
                domain: "OpenAIOAuthService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth \(action) failed with status \(httpResponse.statusCode).\(suffix)"],
            )
        }

        do {
            return try decoder.decode(OpenAITokenResponse.self, from: data)
        } catch {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FlowDown could not decode the OpenAI OAuth token response: \(error.localizedDescription)"],
            )
        }
    }

    nonisolated func postCredentialsDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .openAIOAuthCredentialsDidChange, object: nil)
        }
    }

    private func finishAuthorization(
        flow: AuthorizationFlow,
        callbackURL: URL,
    ) async throws {
        do {
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let state = components?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            guard state == flow.pkce.state else {
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth returned a mismatched state value."],
                )
            }

            if let errorCode = components?.queryItems?.first(where: { $0.name == "error" })?.value,
               !errorCode.isEmpty
            {
                let description = components?.queryItems?
                    .first(where: { $0.name == "error_description" })?
                    .value?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = description?.isEmpty == false
                    ? description!
                    : "OpenAI OAuth returned an authorization error: \(errorCode)."
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: NSUserCancelledError,
                    userInfo: [NSLocalizedDescriptionKey: message],
                )
            }

            let code = components?.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
            guard !code.isEmpty else {
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth did not return an authorization code."],
                )
            }

            let credentials = try await exchangeCodeForTokens(
                code: code,
                verifier: flow.pkce.verifier,
                redirectURL: flow.redirectURL,
            )
            try saveCredentials(credentials)
        } catch {
            currentFlow = nil
            await flow.redirectServer.cancel()
            throw error
        }

        currentFlow = nil
        await flow.redirectServer.cancel()
    }
}

private extension OpenAIOAuthService {
    struct OpenAITokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private static func buildAuthorizeURL(
        pkce: PKCEState,
        redirectURL: URL
    ) -> URL {
        var components = URLComponents(url: issuer.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: defaultClientID),
            .init(name: "redirect_uri", value: redirectURL.absoluteString),
            .init(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: pkce.state),
            .init(name: "originator", value: codexOriginator),
        ]
        return components.url!
    }

    private static func generatePKCEState() -> PKCEState {
        let verifier = randomBase64URL(count: 32)
        let state = randomBase64URL(count: 16)
        let challengeData = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(challengeData).base64URLEncodedString()
        return PKCEState(verifier: verifier, challenge: challenge, state: state)
    }

    private static func randomBase64URL(count: Int) -> String {
        let bytes = (0 ..< count).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }
}

extension OpenAIOAuthService {
    static func sessionMetadata(
        accessToken: String,
        idToken: String?,
    ) -> OpenAIOAuthSessionMetadata {
        let envelope = idToken
            .flatMap { decodeJWTClaims($0, as: IDTokenClaimsEnvelope.self) }
            ?? decodeJWTClaims(accessToken, as: IDTokenClaimsEnvelope.self)
        let accountID = [
            envelope?.auth?.chatgptAccountID,
        ]
        .compactMap(\.self)
        .first(where: { !$0.isEmpty })

        return OpenAIOAuthSessionMetadata(
            accessToken: accessToken,
            accountID: accountID,
            isFedrampAccount: envelope?.auth?.chatgptAccountIsFedramp ?? false,
        )
    }

    static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        guard let data = jwtPayloadData(token),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    static func decodeJWTClaims<T: Decodable>(
        _ token: String,
        as type: T.Type
    ) -> T? {
        guard let data = jwtPayloadData(token) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private extension URLComponents {
    static func formURLEncodedData(_ items: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension OpenAIOAuthService {
    static func jwtPayloadData(_ token: String) -> Data? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
        payload = payload.replacingOccurrences(of: "_", with: "/")

        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)

        return Data(base64Encoded: payload)
    }
}
