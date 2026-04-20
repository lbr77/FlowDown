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
    private static let credentialAccount = "default"
    private static let credentialExpiryLeeway: TimeInterval = 60
    private static let deviceAuthTimeout: TimeInterval = 15 * 60

    struct Credentials: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let idToken: String?
    }

    struct DeviceCodeSession: Equatable {
        let deviceAuthID: String
        let userCode: String
        let verificationURL: String
        let interval: TimeInterval
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

    private struct DeviceCodeRequest: Encodable {
        let clientID: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: String

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case interval
        }
    }

    private struct TokenPollRequest: Encodable {
        let deviceAuthID: String
        let userCode: String

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
        }
    }

    private struct TokenPollSuccessResponse: Decodable {
        let authorizationCode: String
        let codeChallenge: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeChallenge = "code_challenge"
            case codeVerifier = "code_verifier"
        }
    }

    private let keychain = OpenAIOAuthKeychainStore(service: "wiki.qaq.flowdown.openai.oauth")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentDeviceCodeSession: DeviceCodeSession?
    private var deviceCodePollingTask: Task<Void, Never>?
}

extension OpenAIOAuthService {
    func hasCredentials() -> Bool {
        (try? loadCredentials()) != nil
    }

    func isDeviceCodeAuthorizing() -> Bool {
        currentDeviceCodeSession != nil
    }

    func clearCredentials() throws {
        try keychain.delete(account: Self.credentialAccount)
        postCredentialsDidChange()
    }

    func beginDeviceCodeAuthorization(force: Bool = false) async throws -> DeviceCodeSession {
        if currentDeviceCodeSession != nil {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI device code sign-in is already in progress."]
            )
        }

        if force == false, hasCredentials() {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth credentials are already available on this device."]
            )
        }

        let session = try await requestDeviceCode()
        currentDeviceCodeSession = session
        return session
    }

    func completeDeviceCodeAuthorization() async throws {
        guard let session = currentDeviceCodeSession else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI device code sign-in has not started."]
            )
        }

        defer {
            currentDeviceCodeSession = nil
            deviceCodePollingTask = nil
        }

        let pollResponse = try await pollForToken(session: session)
        let redirectURI = Self.issuer.appendingPathComponent("deviceauth/callback").absoluteString
        let credentials = try await exchangeCodeForTokens(
            code: pollResponse.authorizationCode,
            verifier: pollResponse.codeVerifier,
            redirectURI: redirectURI
        )
        try saveCredentials(credentials)
    }

    func cancelDeviceCodeAuthorization() {
        deviceCodePollingTask?.cancel()
        deviceCodePollingTask = nil
        currentDeviceCodeSession = nil
    }

    func resolvedSession() async throws -> OpenAIOAuthSessionMetadata {
        guard var credentials = try loadCredentials() else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth credentials are unavailable. Configure the ChatGPT Codex endpoint again to sign in."]
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
            idToken: credentials.idToken
        )
        return metadata
    }
}

private extension OpenAIOAuthService {
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

    private func requestDeviceCode() async throws -> DeviceCodeSession {
        let url = Self.issuer.appendingPathComponent("api/accounts/deviceauth/usercode")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.codexOriginator, forHTTPHeaderField: "Originator")
        request.httpBody = try encoder.encode(DeviceCodeRequest(clientID: Self.defaultClientID))

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI device code request failed because the server response was invalid."]
            )
        }

        if httpResponse.statusCode == 404 {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Device code login is not enabled for this server."]
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = body?.isEmpty == false ? "\n\n\(body!)" : ""
            throw NSError(
                domain: "OpenAIOAuthService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI device code request failed with status \(httpResponse.statusCode).\(suffix)"]
            )
        }

        let payload: DeviceCodeResponse
        do {
            payload = try decoder.decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FlowDown could not decode the OpenAI device code response: \(error.localizedDescription)"]
            )
        }

        let interval = TimeInterval(payload.interval.trimmingCharacters(in: .whitespaces).prefix(10)) ?? 5
        return DeviceCodeSession(
            deviceAuthID: payload.deviceAuthID,
            userCode: payload.userCode,
            verificationURL: Self.issuer.appendingPathComponent("codex/device").absoluteString,
            interval: max(interval, 5)
        )
    }

    private func pollForToken(session: DeviceCodeSession) async throws -> TokenPollSuccessResponse {
        let url = Self.issuer.appendingPathComponent("api/accounts/deviceauth/token")
        let start = Date()
        let requestBody = try encoder.encode(TokenPollRequest(
            deviceAuthID: session.deviceAuthID,
            userCode: session.userCode
        ))

        while Date().timeIntervalSince(start) < Self.deviceAuthTimeout {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = requestBody

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI device auth poll failed because the server response was invalid."]
                )
            }

            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                let remaining = Self.deviceAuthTimeout - Date().timeIntervalSince(start)
                let sleepDuration = min(session.interval, max(remaining, 0))
                if sleepDuration > 0 {
                    try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
                }
                continue
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = body?.isEmpty == false ? "\n\n\(body!)" : ""
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI device auth failed with status \(httpResponse.statusCode).\(suffix)"]
                )
            }

            do {
                return try decoder.decode(TokenPollSuccessResponse.self, from: data)
            } catch {
                throw NSError(
                    domain: "OpenAIOAuthService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "FlowDown could not decode the OpenAI device auth response: \(error.localizedDescription)"]
                )
            }
        }

        throw NSError(
            domain: "OpenAIOAuthService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Device auth timed out after 15 minutes."]
        )
    }

    func exchangeCodeForTokens(
        code: String,
        verifier: String,
        redirectURI: String,
    ) async throws -> Credentials {
        var request = URLRequest(url: Self.issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.codexOriginator, forHTTPHeaderField: "Originator")
        request.httpBody = URLComponents.formURLEncodedData([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.defaultClientID,
            "code_verifier": verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try requireTokenPayload(data: data, response: response, action: "exchange")
        guard let refreshToken = payload.refreshToken, !refreshToken.isEmpty else {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth exchange did not return a refresh token."]
            )
        }
        return Credentials(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expiresIn),
            idToken: payload.idToken
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
            refreshToken: credentials.refreshToken
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try requireTokenPayload(data: data, response: response, action: "refresh")
        return Credentials(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? credentials.refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expiresIn),
            idToken: payload.idToken ?? credentials.idToken
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
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth \(action) failed because the server response was invalid."]
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = body?.isEmpty == false ? "\n\n\(body!)" : ""
            throw NSError(
                domain: "OpenAIOAuthService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI OAuth \(action) failed with status \(httpResponse.statusCode).\(suffix)"]
            )
        }

        do {
            return try decoder.decode(OpenAITokenResponse.self, from: data)
        } catch {
            throw NSError(
                domain: "OpenAIOAuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "FlowDown could not decode the OpenAI OAuth token response: \(error.localizedDescription)"]
            )
        }
    }

    nonisolated func postCredentialsDidChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .openAIOAuthCredentialsDidChange, object: nil)
        }
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
            isFedrampAccount: envelope?.auth?.chatgptAccountIsFedramp ?? false
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
