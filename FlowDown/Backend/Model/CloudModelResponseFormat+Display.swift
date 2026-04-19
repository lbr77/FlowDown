//
//  CloudModelResponseFormat+Display.swift
//  FlowDown
//
//  Created by GPT-5 Codex on 2025/12/06.
//

import Foundation
import Storage

extension CloudModel.ResponseFormat {
    var defaultModelListEndpoint: String {
        switch self {
        case .chatCompletions:
            "$INFERENCE_ENDPOINT$/../../models"
        case .responses:
            "$INFERENCE_ENDPOINT$/../models"
        case .codex:
            ""
        }
    }
}

extension CloudModel.ResponseFormat {
    var localizedTitle: String {
        switch self {
        case .chatCompletions:
            String(localized: "Completions Format")
        case .responses, .codex:
            String(localized: "Responses Format")
        }
    }

    var localizedDescription: String {
        switch self {
        case .chatCompletions:
            String(localized: "Use OpenAI-compatible chat completions.") + " " + "(POST /v1/chat/completions)"
        case .responses, .codex:
            String(localized: "Use OpenAI-compatible chat response format.") + " " + "(POST /v1/responses)"
        }
    }
}

extension CloudModel.ResponseFormat {
    static func inferredFormat(fromEndpoint endpoint: String) -> CloudModel.ResponseFormat? {
        guard let normalized = normalizeEndpoint(endpoint) else { return nil }
        return allCases
            .sorted { $0.longestEndpointSuffixLength > $1.longestEndpointSuffixLength }
            .first { $0.matchesNormalizedEndpoint(normalized) }
    }
}

// MARK: - Helpers

private extension CloudModel.ResponseFormat {
    static func normalizeEndpoint(_ endpoint: String) -> String? {
        var normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        normalized = normalized.lowercased()
        if let fragmentIndex = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<fragmentIndex])
        }
        if let queryIndex = normalized.firstIndex(of: "?") {
            normalized = String(normalized[..<queryIndex])
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.last == "/" {
            normalized.removeLast()
        }
        return normalized.isEmpty ? nil : normalized
    }

    func matchesNormalizedEndpoint(_ endpoint: String) -> Bool {
        endpointSuffixes.contains { endpoint.hasSuffix($0) }
    }

    var endpointSuffixes: [String] {
        switch self {
        case .chatCompletions:
            ["/v1/chat/completions", "/chat/completions"]
        case .responses:
            ["/v1/responses", "/responses"]
        case .codex:
            ["/backend-api/codex/responses", "/backend-api/codex"]
        }
    }

    var longestEndpointSuffixLength: Int {
        endpointSuffixes.map(\.count).max() ?? 0
    }
}
