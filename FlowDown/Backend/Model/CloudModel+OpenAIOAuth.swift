//
//  CloudModel+OpenAIOAuth.swift
//  FlowDown
//
//  Created by LiBr on 2026/4/19.
//

import ChatClientKit
import Foundation
import Storage

extension CloudModel {
    static let openAICodexOAuthEndpoint = "https://chatgpt.com/backend-api/codex/responses"
    static let openAICodexDefaultModelIdentifier = "gpt-5.4"
    static let openAICodexRecommendedModelIdentifiers = [
        openAICodexDefaultModelIdentifier,
        "gpt-5.3-codex",
    ]
    static let strippedAdditionalHTTPHeaderNames = [
        "HTTP-Referer",
        "X-Title",
    ]
    static let openAICodexBodyFieldPreset: [String: Any] = [
        FlowDownChatClientKitExtension.configurationKey: [
            "environments": [Any](),
            "request_modifiers": [
                FlowDownChatClientKitExtension.predefinedOAuthCodexRequestModifier,
            ],
            "response_modifiers": [String](),
        ],
    ]

    var usesAutomaticOpenAIOAuth: Bool {
        Self.isOpenAICodexOAuthEndpoint(endpoint)
    }

    static func isOpenAICodexOAuthEndpoint(_ endpoint: String) -> Bool {
        guard let normalized = normalizedEndpoint(endpoint) else {
            return false
        }

        return [openAICodexOAuthEndpoint].contains(normalized)
    }

    static func canonicalOpenAICodexOAuthEndpoint(for endpoint: String) -> String? {
        guard isOpenAICodexOAuthEndpoint(endpoint) else {
            return nil
        }

        return openAICodexOAuthEndpoint
    }

    static func normalizedEndpoint(_ endpoint: String) -> String? {
        var normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        normalized = normalized.lowercased()
        guard var components = URLComponents(string: normalized),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else {
            return nil
        }

        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.host = host

        var path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        return components.string
    }

    static func mergedAutomaticOpenAIOAuthBodyFields(
        into bodyFields: [String: Any]
    ) -> [String: Any] {
        var merged = bodyFields
        let configurationKey = FlowDownChatClientKitExtension.configurationKey
        let predefinedModifier = FlowDownChatClientKitExtension.predefinedOAuthCodexRequestModifier

        var configuration = merged[configurationKey] as? [String: Any] ?? [:]
        var requestModifiers = configuration["request_modifiers"] as? [String] ?? []
        if !requestModifiers.contains(predefinedModifier) {
            requestModifiers.append(predefinedModifier)
        }

        configuration["request_modifiers"] = requestModifiers
        configuration["response_modifiers"] = configuration["response_modifiers"] ?? [String]()
        configuration["environments"] = configuration["environments"] ?? [Any]()
        merged[configurationKey] = configuration
        return merged
    }
}

extension Dictionary where Key == String, Value == String {
    func removingLegacyFlowDownHeaders() -> [String: String] {
        removingHTTPHeaders(named: CloudModel.strippedAdditionalHTTPHeaderNames)
    }

    mutating func removeHTTPHeader(named target: String) {
        let matchingKeys = keys.filter { $0.caseInsensitiveCompare(target) == .orderedSame }
        matchingKeys.forEach { removeValue(forKey: $0) }
    }

    func removingHTTPHeaders(named targets: [String]) -> [String: String] {
        var output = self
        targets.forEach { output.removeHTTPHeader(named: $0) }
        return output
    }
}
