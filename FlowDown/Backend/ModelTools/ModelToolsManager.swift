//
//  ModelToolsManager.swift
//  FlowDown
//
//  Created by 秋星桥 on 2/27/25.
//

import AlertController
import AVFoundation
import ChatClientKit
import ConfigurableKit
import Foundation
import MCP
import UIKit

class ModelToolsManager {
    static let shared = ModelToolsManager()

    let tools: [ModelTool]

    static let skipConfirmationKey = "ModelToolsManager.skipConfirmation"
    static var skipConfirmationValue: Bool {
        get { UserDefaults.standard.bool(forKey: ModelToolsManager.skipConfirmationKey) }
        set { UserDefaults.standard.set(newValue, forKey: ModelToolsManager.skipConfirmationKey) }
    }

    static var skipConfirmation: ConfigurableToggleActionView {
        .init().with {
            $0.actionBlock = { skipConfirmationValue = $0 }
            $0.configure(icon: UIImage(systemName: "hammer"))
            $0.configure(title: "Skip Tool Confirmation")
            $0.configure(description: "Skip the confirmation dialog when executing tools.")
            $0.boolValue = skipConfirmationValue
        }
    }

    private init() {
        #if targetEnvironment(macCatalyst)
            tools = [
                MTAddCalendarTool(),
                MTQueryCalendarTool(),

                MTWebScraperTool(),
                MTWebSearchTool(),

                //            MTLocationTool(),

                MTURLTool(),

                MTStoreMemoryTool(),
                MTRecallMemoryTool(),
                MTListMemoriesTool(),
                MTUpdateMemoryTool(),
                MTDeleteMemoryTool(),
            ]
        #else
            tools = [
                MTAddCalendarTool(),
                MTQueryCalendarTool(),

                MTWebScraperTool(),
                MTWebSearchTool(),

                MTLocationTool(),

                MTURLTool(),

                MTStoreMemoryTool(),
                MTRecallMemoryTool(),
                MTListMemoriesTool(),
                MTUpdateMemoryTool(),
                MTDeleteMemoryTool(),
            ]
        #endif

        #if DEBUG
            var registeredToolNames: Set<String> = []
        #endif

        for tool in tools {
            Logger.model.debugFile("registering tool: \(tool.functionName)")
            #if DEBUG
                assert(registeredToolNames.insert(tool.functionName).inserted)
            #endif
        }
    }

    var enabledTools: [ModelTool] {
        tools.filter { tool in
            if tool is MTWebSearchTool { return true }
            return tool.isEnabled
        }
    }

    func getEnabledToolsIncludeMCPAndShortcut() async -> [ModelTool] {
        var result = enabledTools
        let shortcutTools = ShortcutToolsManager.shared
            .listModelTools()
            .filter(\.isEnabled)
        result.append(contentsOf: shortcutTools)
        let mcpTools = await MCPService.shared.listServerTools()
        result.append(contentsOf: mcpTools.filter(\.isEnabled))
        return result
    }

    var configurableTools: [ModelTool] {
        tools.filter { tool in
            if tool is MTWebSearchTool { return false }
            if tool is MTStoreMemoryTool { return false }
            if tool is MTRecallMemoryTool { return false }
            if tool is MTListMemoriesTool { return false }
            if tool is MTUpdateMemoryTool { return false }
            if tool is MTDeleteMemoryTool { return false }
            return true
        }
    }

    func tool(for request: ToolCallRequest) -> ModelTool? {
        Logger.model.debugFile("finding tool call with function name \(request.name)")
        return enabledTools.first {
            $0.functionName.lowercased() == request.name.lowercased()
        }
    }

    func findTool(for request: ToolCallRequest) async -> ModelTool? {
        Logger.model.debugFile("finding tool call with function name \(request.name)")
        let allTools = await getEnabledToolsIncludeMCPAndShortcut()
        return allTools.first {
            $0.functionName.lowercased() == request.name.lowercased()
        }
    }

    struct ToolResultContents: Equatable, Hashable, Codable, Sendable {
        let text: String

        struct Attachment: Equatable, Hashable, Codable, Sendable {
            let name: String
            let data: Data
            let mimeType: String?
        }

        let imageAttachments: [Attachment]
        let audioAttachments: [Attachment]
    }

    func perform(withTool tool: ModelTool, parms: String, anchorTo view: UIView, contextID: String? = nil) async throws -> ToolResultContents {
        if Self.skipConfirmationValue {
            let ans = try await tool.execute(with: parms, anchorTo: view, contextID: contextID)
            return processToolResult(ans)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    let setupContext: (ActionContext) -> Void = { context in
                        context.addAction(title: "Cancel") {
                            context.dispose {
                                let error = NSError(
                                    domain: "ToolCall",
                                    code: 500,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: String(localized: "Tool execution cancelled by user"),
                                    ]
                                )
                                continuation.resume(throwing: error)
                            }
                        }
                        context.addAction(title: "Use Tool", attribute: .accent) {
                            context.dispose {
                                Task.detached(priority: .userInitiated) {
                                    do {
                                        let ans = try await tool.execute(with: parms, anchorTo: view, contextID: contextID)
                                        let result = self.processToolResult(ans)
                                        continuation.resume(returning: result)
                                    } catch {
                                        let error = NSError(
                                            domain: "ToolCall",
                                            code: 500,
                                            userInfo: [
                                                NSLocalizedDescriptionKey: String(localized: "Tool execution failed: \(error.localizedDescription)"),
                                            ]
                                        )
                                        continuation.resume(throwing: error)
                                    }
                                }
                            }
                        }
                    }

                    let alert = if let tool = tool as? MCPTool {
                        AlertViewController(
                            title: "Execute MCP Tool",
                            message: "The model wants to execute '\(tool.toolInfo.name)' from \(tool.toolInfo.serverName). This tool can access external resources.\n\nDescription: \(tool.toolInfo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No description available")",
                            setupActions: setupContext
                        )
                    } else {
                        AlertViewController(
                            title: "Tool Call",
                            message: "Your model is calling a tool: \(tool.interfaceName)",
                            setupActions: setupContext
                        )
                    }

                    // Check if view controller already has a presented view controller
                    guard let parentVC = view.parentViewController else {
                        let error = NSError(
                            domain: "ToolCall",
                            code: 500,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(localized: "Tool execution failed: parent view controller not found."),
                            ]
                        )
                        continuation.resume(throwing: error)
                        return
                    }

                    guard parentVC.presentedViewController == nil else {
                        let error = NSError(
                            domain: "ToolCall",
                            code: 500,
                            userInfo: [
                                NSLocalizedDescriptionKey: String(localized: "Tool execution failed: authorization dialog is already presented."),
                            ]
                        )
                        continuation.resume(throwing: error)
                        return
                    }

                    parentVC.present(alert, animated: true)
                }
            }
        }
    }

    private func processToolResult(_ ans: String) -> ToolResultContents {
        if let value = try? [Tool.Content].decodeContents(ans) {
            var textContent: [String] = []
            var imageAttachments: [ToolResultContents.Attachment] = []
            var audioAttachments: [ToolResultContents.Attachment] = []
            for content in value {
                switch content {
                case let .text(string):
                    textContent.append(string)
                case let .image(dataString, mimeType, metadata):
                    var name = metadata?["name"] as? String ?? ""
                    if name.isEmpty {
                        name = String(localized: "Tool Provided Image")
                        name += " " + mimeType
                    }
                    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let data = parseDataFromString(dataString), UIImage(data: data) != nil {
                        imageAttachments.append(.init(
                            name: name,
                            data: data,
                            mimeType: mimeType.nilIfEmpty
                        ))
                    } else {
                        Logger.model.errorFile("failed to parse image data from string")
                    }
                case let .audio(dataString, mimeType):
                    var name = String(localized: "Tool Provided Audio")
                    if !mimeType.isEmpty {
                        name += " " + mimeType
                    }
                    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let data = parseDataFromString(dataString) {
                        audioAttachments.append(.init(
                            name: name,
                            data: data,
                            mimeType: mimeType.nilIfEmpty
                        ))
                    } else {
                        Logger.model.errorFile("failed to parse audio data from string")
                    }
                case let .resource(uri, mimeType, text):
                    textContent.append("[\(text ?? "Resource") \(mimeType)](\(uri))")
                }
            }
            return .init(
                text: textContent.joined(separator: "\n"),
                imageAttachments: imageAttachments,
                audioAttachments: audioAttachments
            )
        } else {
            return .init(text: ans, imageAttachments: [], audioAttachments: [])
        }
    }

    private func parseDataFromString(_ dataString: String) -> Data? {
        // Handle data URL format: data:image/png;base64,<base64_string>
        if dataString.hasPrefix("data:") {
            // Extract the part after ";base64," or after the first comma
            if let base64Range = dataString.range(of: ";base64,") {
                let base64String = String(dataString[base64Range.upperBound...])
                return Data(base64Encoded: base64String)
            } else if let commaIndex = dataString.firstIndex(of: ",") {
                // Handle data URL without base64 encoding
                let afterComma = String(dataString[dataString.index(after: commaIndex)...])
                // Try base64 first, then fallback to URL-encoded or plain text
                return Data(base64Encoded: afterComma) ?? afterComma.data(using: .utf8)
            }
            return nil
        }

        // Handle URL string (for data URLs parsed as URL)
        if let url = URL(string: dataString), url.scheme == "data" {
            let absoluteString = url.absoluteString
            if let base64Range = absoluteString.range(of: ";base64,") {
                let base64String = String(absoluteString[base64Range.upperBound...])
                return Data(base64Encoded: base64String)
            } else if let commaIndex = absoluteString.firstIndex(of: ",") {
                let afterComma = String(absoluteString[absoluteString.index(after: commaIndex)...])
                return Data(base64Encoded: afterComma) ?? afterComma.data(using: .utf8)
            }
            return nil
        }

        // Try as direct base64 string (most common case for MCP tools)
        if let data = Data(base64Encoded: dataString, options: .ignoreUnknownCharacters) {
            return data
        }

        // Fallback: treat as UTF-8 string data (should rarely happen)
        return dataString.data(using: .utf8)
    }
}
