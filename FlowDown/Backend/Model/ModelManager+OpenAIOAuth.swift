//
//  ModelManager+OpenAIOAuth.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import Foundation
import Storage

extension ModelManager {
    func resolvedCloudAuthentication(
        for model: CloudModel,
        requestSessionID: String? = nil,
    ) async throws -> (
        apiKey: String,
        additionalHeaders: [String: String],
        responseFormat: CloudModel.ResponseFormat
    ) {
        let responseFormat: CloudModel.ResponseFormat = model.usesAutomaticOpenAIOAuth ? .codex : model.response_format
        let sanitizedHeaders = model.headers.removingLegacyFlowDownHeaders()

        guard model.usesAutomaticOpenAIOAuth else {
            return (
                apiKey: model.token,
                additionalHeaders: sanitizedHeaders,
                responseFormat: responseFormat,
            )
        }

        let session = try await OpenAIOAuthService.shared.resolvedSession()
        var headers = sanitizedHeaders.removingHTTPHeaders(
            named: [
                "Authorization",
                "ChatGPT-Account-ID",
                "chatgpt-account-id",
                "session_id",
                "Originator",
                "X-OpenAI-Fedramp",
            ],
        )
        if let accountID = session.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-ID"] = accountID
        }
        if let requestSessionID, !requestSessionID.isEmpty {
            headers["session_id"] = requestSessionID
        }
        headers["Originator"] = OpenAIOAuthService.codexOriginator
        if session.isFedrampAccount {
            headers["X-OpenAI-Fedramp"] = "true"
        }

        return (
            apiKey: session.accessToken,
            additionalHeaders: headers,
            responseFormat: responseFormat,
        )
    }
}
