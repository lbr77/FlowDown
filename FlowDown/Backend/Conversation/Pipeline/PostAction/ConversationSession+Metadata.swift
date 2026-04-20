//
//  ConversationSession+Metadata.swift
//  FlowDown
//
//  Created by Codex on 4/12/26.
//

import ChatClientKit
import Foundation
import Storage
import XMLCoder

struct ConversationMetadata: Equatable {
    let title: String?
    let icon: String?

    var hasGeneratedContent: Bool {
        title != nil || icon != nil
    }
}

private struct ConversationMetadataResponse: Codable {
    let title: String?
    let icon: String?
}

private struct ConversationMetadataXML: Codable {
    let task: String
    let last_user_message: String
    let last_assistant_message: String
    let output_format: OutputFormat

    private enum CodingKeys: String, CodingKey {
        case task
        case last_user_message
        case last_assistant_message
        case output_format
    }

    struct OutputFormat: Codable {
        let title: String
        let icon: String
    }
}

enum ConversationMetadataParser {
    static func parseResponse(_ response: String) -> ConversationMetadata? {
        parseXML(ModelResponseSanitizer.stripReasoning(from: response))
    }

    static func parseXML(_ xmlString: String) -> ConversationMetadata? {
        let extracted = extractUsingXMLCoder(xmlString) ?? extractUsingRegex(xmlString)
        guard let extracted else { return nil }

        let metadata = ConversationMetadata(
            title: normalizedTitle(extracted.title),
            icon: normalizedIcon(extracted.icon),
        )

        return metadata.hasGeneratedContent ? metadata : nil
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }

        var normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingMarkdownBold()

        guard !normalized.isEmpty else { return nil }
        if normalized.count > 32 {
            normalized = String(normalized.prefix(32))
        }
        return normalized
    }

    static func normalizedIcon(_ icon: String?) -> String? {
        guard let icon else { return nil }

        let normalized = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        guard normalized.count == 1 else {
            let firstEmoji = normalized.first { $0.isEmoji }
            return firstEmoji.map(String.init)
        }

        return normalized
    }

    private static func extractUsingXMLCoder(_ xmlString: String) -> ConversationMetadata? {
        let decoder = XMLDecoder()

        guard let data = xmlString.data(using: .utf8),
              let response = try? decoder.decode(ConversationMetadataResponse.self, from: data)
        else {
            return nil
        }

        guard response.title != nil || response.icon != nil else {
            return nil
        }

        return ConversationMetadata(
            title: response.title,
            icon: response.icon,
        )
    }

    private static func extractUsingRegex(_ xmlString: String) -> ConversationMetadata? {
        let metadata = ConversationMetadata(
            title: firstMatch(in: xmlString, pattern: #"<title>(.*?)</title>"#),
            icon: firstMatch(in: xmlString, pattern: #"<icon>(.*?)</icon>"#),
        )

        return metadata.hasGeneratedContent ? metadata : nil
    }

    private static func firstMatch(in xmlString: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators],
        ) else {
            return nil
        }

        let range = NSRange(xmlString.startIndex ..< xmlString.endIndex, in: xmlString)
        guard let match = regex.firstMatch(in: xmlString, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: xmlString)
        else {
            return nil
        }

        let value = String(xmlString[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension ConversationSessionManager.Session {
    func generateConversationMetadata() async -> ConversationMetadata? {
        guard let userMessage = messages.last(where: { $0.role == .user })?.document else {
            return nil
        }
        guard let assistantMessage = messages.last(where: { $0.role == .assistant })?.document else {
            return nil
        }

        let task = """
        Generate conversation metadata from the chat history. Respond ONLY with valid XML in this exact format:
        <conversation>
        <title>3-5 word title in the user's primary language with no prefix, label, or markdown</title>
        <icon>single emoji that best represents the conversation</icon>
        </conversation>
        """

        let conversationData = ConversationMetadataXML(
            task: task,
            last_user_message: userMessage,
            last_assistant_message: assistantMessage,
            output_format: .init(
                title: "your_title_here",
                icon: "💬",
            ),
        )

        do {
            let encoder = XMLEncoder()
            encoder.outputFormatting = .prettyPrinted
            let xmlData = try encoder.encode(conversationData, withRootKey: "conversation")
            let xmlString = String(data: xmlData, encoding: .utf8) ?? ""

            let input: [ChatRequestBody.Message] = [
                .system(content: .text(task)),
                .user(content: .text(xmlString)),
            ]

            guard let model = models.auxiliary else { throw NSError() }
            let response = try await ModelManager.shared.infer(
                with: model,
                input: input,
            )

            return ConversationMetadataParser.parseResponse(response.text)
        } catch {
            Logger.model.errorFile("failed to generate conversation metadata: \(error)")
            return nil
        }
    }
}

private extension String {
    func trimmingMarkdownBold() -> String {
        var result = self
        if result.hasPrefix("**"), result.hasSuffix("**"), result.count > 4 {
            result = String(result.dropFirst(2).dropLast(2))
        }
        return result
    }
}

private extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmoji &&
            (scalar.value > 0x238C || unicodeScalars.count > 1)
    }
}
