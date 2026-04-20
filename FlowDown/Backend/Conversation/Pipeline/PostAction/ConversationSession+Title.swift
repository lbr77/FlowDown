//
//  ConversationSession+Title.swift
//  FlowDown
//
//  Created by 秋星桥 on 2/18/25.
//

import ChatClientKit
import Foundation
import FoundationModels
import Storage
import XMLCoder

// MARK: - XML Models

private struct TitleResponse: Codable {
    let title: String
}

private struct ConversationXML: Codable {
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
    }
}

// MARK: - FoundationModels Generable

@available(iOS 26.0, macCatalyst 26.0, *)
@Generable(description: "A concise, 3-5 word title summarizing a conversation.")
struct ConversationTitle: Equatable {
    @Guide(description: "A plain, concise, 3-5 word title with no prefix, label or markdown.")
    var title: String
}

extension ConversationSessionManager.Session {
    func generateConversationTitle() async -> String? {
        guard let userMessage = messages.last(where: { $0.role == .user })?.document else {
            return nil
        }
        guard let assistantMessage = messages.last(where: { $0.role == .assistant })?.document else {
            return nil
        }

        let task = "Generate a concise, 3-5 word only title summarizing the chat history, enclosed within the <title> tag. Write in the user's primary language. Do **NOT** include any prefix, label, or markdown syntax."

        let conversationData = ConversationXML(
            task: task,
            last_user_message: userMessage,
            last_assistant_message: assistantMessage,
            output_format: ConversationXML.OutputFormat(title: "your_title_here"),
        )

        do {
            let encoder = XMLEncoder()
            encoder.outputFormatting = .prettyPrinted
            let xmlData = try encoder.encode(conversationData, withRootKey: "conversation")
            let xmlString = String(data: xmlData, encoding: .utf8) ?? ""

            let messages: [ChatRequestBody.Message] = [
                .system(content: .text(task)),
                .user(content: .text(xmlString)),
            ]

            guard let model = models.auxiliary else { throw NSError() }
            let ans = try await ModelManager.shared.infer(
                with: model,
                input: messages,
            )

            let raw = ans.text
            let sanitizedContent = ModelResponseSanitizer.stripReasoning(from: raw)

            if let title = extractTitleFromXML(sanitizedContent) {
                return title
            }

            return ConversationMetadataParser.normalizedTitle(sanitizedContent)
        } catch {
            Logger.model.errorFile("failed to generate title: \(error)")
            return nil
        }
    }

    private func extractTitleFromXML(_ xmlString: String) -> String? {
        ConversationMetadataParser.parseXML(xmlString)?.title
    }

    private func extractTitleUsingXMLCoder(_ xmlString: String) -> String? {
        let decoder = XMLDecoder()

        // Try to decode as TitleResponse directly
        if let data = xmlString.data(using: .utf8),
           let titleResponse = try? decoder.decode(TitleResponse.self, from: data)
        {
            return ConversationMetadataParser.normalizedTitle(titleResponse.title)
        }

        return nil
    }

    private func extractTitleUsingRegex(_ xmlString: String) -> String? {
        let pattern = #"<title>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(xmlString.startIndex ..< xmlString.endIndex, in: xmlString)
        guard let match = regex.firstMatch(in: xmlString, options: [], range: range) else {
            return nil
        }

        guard let titleRange = Range(match.range(at: 1), in: xmlString) else {
            return nil
        }

        return ConversationMetadataParser.normalizedTitle(String(xmlString[titleRange]))
    }
}
