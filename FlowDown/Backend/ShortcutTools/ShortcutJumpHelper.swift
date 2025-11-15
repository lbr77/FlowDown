//
//  ShortcutJumpHelper.swift
//  FlowDown
//
//  Created by LiBr on 2025/03/07.
//

import ChatClientKit
import Foundation

enum ShortcutJumpError: LocalizedError {
    case invalidShortcutName
    case invalidShortcutURL
    case invalidPayloadEncoding
    case invalidCallbackScheme
    case missingCallbackPayload
    case invalidCallbackPayload

    var errorDescription: String? {
        switch self {
        case .invalidShortcutName:
            String(localized: "Shortcut name cannot be empty.")
        case .invalidShortcutURL:
            String(localized: "Unable to construct a valid Shortcuts URL.")
        case .invalidPayloadEncoding:
            String(localized: "Failed to encode shortcut payload.")
        case .invalidCallbackScheme:
            String(localized: "Unsupported callback scheme.")
        case .missingCallbackPayload:
            String(localized: "Shortcut callback is missing required payload.")
        case .invalidCallbackPayload:
            String(localized: "Unable to decode shortcut callback payload.")
        }
    }
}

enum ShortcutJumpHelper {
    static let runShortcutScheme = "shortcuts"
    static let runShortcutHost = "run-shortcut"
    static let callbackScheme = "flowdown"
    static let callbackHost = "shortcut"

    static var defaultCallbackURL: URL {
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        return components.url ?? URL(string: "flowdown://shortcut")!
    }

    struct InvocationPayload: Codable {
        let parameters: [String: AnyCodingValue]
        let metadata: [String: AnyCodingValue]?
        let callbackURL: URL

        init(
            parameters: [String: AnyCodingValue],
            metadata: [String: AnyCodingValue]? = nil,
            callbackURL: URL = ShortcutJumpHelper.defaultCallbackURL
        ) {
            self.parameters = parameters
            self.metadata = metadata
            self.callbackURL = callbackURL
        }
    }

    struct CallbackPayload: Sendable {
        enum Status: String, Codable {
            case success
            case failure
            case cancelled

            init?(statusString: String) {
                switch statusString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "success":
                    self = .success
                case "failure", "failed", "error":
                    self = .failure
                case "cancelled", "canceled":
                    self = .cancelled
                default:
                    return nil
                }
            }
        }

        let status: Status
        let message: String?
        let data: AnyCodingValue?
        let encodedResult: String
    }

    static func makeRunShortcutURL(
        shortcutName: String,
        parameters: [String: AnyCodingValue],
        metadata: [String: AnyCodingValue]? = nil,
        callbackURL: URL = ShortcutJumpHelper.defaultCallbackURL
    ) throws -> URL {
        let payload = InvocationPayload(
            parameters: parameters,
            metadata: metadata,
            callbackURL: callbackURL
        )
        return try makeRunShortcutURL(shortcutName: shortcutName, payload: payload)
    }

    static func makeRunShortcutURL(
        shortcutName: String,
        payload: InvocationPayload
    ) throws -> URL {
        let trimmedName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ShortcutJumpError.invalidShortcutName
        }

        let payloadString = try encodePayload(payload)

        var components = URLComponents()
        components.scheme = runShortcutScheme
        components.host = runShortcutHost
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmedName),
            URLQueryItem(name: "input", value: payloadString),
        ]

        guard let url = components.url else {
            throw ShortcutJumpError.invalidShortcutURL
        }

        return url
    }

    static func encodePayload(_ payload: InvocationPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let jsonString = try String(data: encoder.encode(payload), encoding: .utf8) else {
            throw ShortcutJumpError.invalidPayloadEncoding
        }
        return jsonString
    }

    static func parseCallbackURL(_ url: URL) throws -> CallbackPayload {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host?.lowercased() == callbackHost
        else {
            throw ShortcutJumpError.invalidCallbackScheme
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ShortcutJumpError.invalidCallbackScheme
        }

        var encodedPayload: String?
        if let items = components.queryItems {
            for item in items {
                guard let value = item.value else { continue }
                switch item.name.lowercased() {
                case "result":
                    encodedPayload = value
                default:
                    continue
                }
            }
        }

        guard let payloadString = encodedPayload,
              let data = payloadString.data(using: .utf8)
        else {
            throw ShortcutJumpError.missingCallbackPayload
        }

        do {
            let decoder = JSONDecoder()
            let rawPayload = try decoder.decode(RawCallbackPayload.self, from: data)

            let normalizedStatusString = rawPayload.status
                ?? lookupString("status", in: rawPayload.data)
                ?? lookupString("status", in: rawPayload.output.map { .object($0) })

            guard let statusString = normalizedStatusString,
                  let status = CallbackPayload.Status(statusString: statusString)
            else {
                throw ShortcutJumpError.invalidCallbackPayload
            }

            let normalizedData = rawPayload.data ?? rawPayload.output.map { .object($0) }
            let message = rawPayload.message ?? rawPayload.errorMessage

            return CallbackPayload(
                status: status,
                message: message,
                data: normalizedData,
                encodedResult: payloadString
            )
        } catch {
            throw ShortcutJumpError.invalidCallbackPayload
        }
    }

    private struct RawCallbackPayload: Decodable {
        let status: String?
        let message: String?
        let errorMessage: String?
        let data: AnyCodingValue?
        let output: [String: AnyCodingValue]?
    }

    private static func lookupString(_ key: String, in value: AnyCodingValue?) -> String? {
        guard let value else { return nil }
        if case let .object(dictionary) = value,
           let stored = dictionary[key]
        {
            switch stored {
            case let .string(value):
                return value
            case let .int(value):
                return "\(value)"
            case let .double(value):
                return "\(value)"
            default:
                return nil
            }
        }
        return nil
    }
}
