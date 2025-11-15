//
//  ConversationSession+ExecuteOnce.swift
//  FlowDown
//
//  Created by 秋星桥 on 3/19/25.
//

import AlertController
import ChatClientKit
import Combine
import Foundation
import Storage
import UIKit
import UniformTypeIdentifiers

extension ConversationSession {
    func doMainInferenceOnce(
        _ currentMessageListView: MessageListView,
        _ modelID: ModelManager.ModelIdentifier,
        _ requestMessages: inout [ChatRequestBody.Message],
        _ tools: [ChatRequestBody.Tool]?,
        _ modelWillExecuteTools: Bool,
        linkedContents: [Int: URL],
        requestLinkContentIndex: @escaping (URL) -> Int
    ) async throws -> Bool {
        await requestUpdate(view: currentMessageListView)
        await currentMessageListView.loading()

        let message = appendNewMessage(role: .assistant)
        encodeAdditionalInfoAndAttachToMessage(message, dic: [
            "model_id": modelID,
        ])

        let stream = try await ModelManager.shared.streamingInfer(
            with: modelID,
            input: requestMessages,
            tools: tools
        )
        defer { self.stopThinking(for: message.objectId) }

        var pendingToolCalls: [ToolCallRequest] = []

        let collapseAfterReasoningComplete = ModelManager.shared.collapseReasoningSectionWhenComplete

        for try await resp in stream {
            let reasoningContent = resp.reasoningContent
            let content = resp.content
            pendingToolCalls.append(contentsOf: resp.toolCallRequests)

            message.update(\.reasoningContent, to: reasoningContent)
            message.update(\.document, to: content)

            if !content.isEmpty {
                stopThinking(for: message.objectId)
                if collapseAfterReasoningComplete {
                    message.update(\.isThinkingFold, to: true)
                }
            } else if !reasoningContent.isEmpty {
                startThinking(for: message.objectId)
            }
            await requestUpdate(view: currentMessageListView)
        }
        stopThinking(for: message.objectId)
        await requestUpdate(view: currentMessageListView)

        if collapseAfterReasoningComplete {
            message.update(\.isThinkingFold, to: true)
            await requestUpdate(view: currentMessageListView)
        }

        if !message.document.isEmpty {
            logger.infoFile("\(message.document)")
            let document = fixWebReferenceIfPossible(in: message.document, with: linkedContents.mapValues(\.absoluteString))
            message.update(\.document, to: document)
        }

        if !message.reasoningContent.isEmpty, message.document.isEmpty {
            let document = String(localized: "Thinking finished without output any content.")
            message.update(\.document, to: document)
        }

        await requestUpdate(view: currentMessageListView)
        requestMessages.append(
            .assistant(
                content: .text(message.document),
                toolCalls: pendingToolCalls.map {
                    .init(id: $0.id.uuidString, function: .init(name: $0.name, arguments: $0.args))
                }
            )
        )

        if message.document.isEmpty, message.reasoningContent.isEmpty, !modelWillExecuteTools {
            throw NSError(
                domain: "Inference Service",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "No response from model."),
                ]
            )
        }

        // 请求结束 如果没有启用工具调用就结束
        guard modelWillExecuteTools else {
            assert(pendingToolCalls.isEmpty)
            return false
        }
        guard !pendingToolCalls.isEmpty else { return false }
        assert(modelWillExecuteTools)

        await requestUpdate(view: currentMessageListView)
        await currentMessageListView.loading(with: String(localized: "Utilizing tool call"))

        for request in pendingToolCalls {
            guard let tool = await ModelToolsManager.shared.findTool(for: request) else {
                Logger.chatService.errorFile("unable to find tool for request: \(request)")
                let availableTools = await ModelToolsManager.shared.getEnabledToolsIncludeMCPAndShortcut()
                await Logger.chatService.infoFile("available tools: \(availableTools)")
                throw NSError(
                    domain: "Tool Error",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "Unable to process tool request with name: \(request.name)"),
                    ]
                )
            }
            await currentMessageListView.loading(with: String(localized: "Utilizing tool: \(tool.interfaceName)"))

            // 等待一小会以避免过快执行任务用户还没看到内容
            try await Task.sleep(nanoseconds: 1 * 500_000_000)

            // 检查是否是网络搜索工具，如果是则直接执行
            if let tool = tool as? MTWebSearchTool {
                let webSearchMessage = appendNewMessage(role: .webSearch)
                encodeToolRequestAndAttachToToolMessage(request, message: webSearchMessage)
                let searchResult = try await tool.execute(
                    with: request.args,
                    session: self,
                    webSearchMessage: webSearchMessage,
                    anchorTo: currentMessageListView
                )
                var webAttachments: [RichEditorView.Object.Attachment] = []
                for doc in searchResult {
                    let index = requestLinkContentIndex(doc.url)
                    webAttachments.append(.init(
                        type: .text,
                        name: doc.title,
                        previewImage: .init(),
                        imageRepresentation: .init(),
                        textRepresentation: formatAsWebArchive(
                            document: doc.textDocument,
                            title: doc.title,
                            atIndex: index
                        ),
                        storageSuffix: UUID().uuidString
                    ))
                }
                await currentMessageListView.loading()

                if webAttachments.isEmpty {
                    requestMessages.append(.tool(
                        content: .text(String(localized: "Web search returned no results.")),
                        toolCallID: request.id.uuidString
                    ))
                } else {
                    requestMessages.append(.tool(
                        content: .text(webAttachments.map(\.textRepresentation).joined(separator: "\n")),
                        toolCallID: request.id.uuidString
                    ))
                }
            } else {
                var toolStatus = Message.ToolStatus(name: tool.interfaceName, state: 0, message: "")
                let toolMessage = appendNewMessage(role: .toolHint)
                toolMessage.update(\.toolStatus, to: toolStatus)
                encodeToolRequestAndAttachToToolMessage(request, message: toolMessage)
                await requestUpdate(view: currentMessageListView)

                let isShortcutInvocation = tool is ShortcutModelTool
                let shortcutToolName = tool.interfaceName
                var invocationContextID: String? = request.id.uuidString
                var shortcutLoadingToken: UUID?
                var shortcutLoadingReleased = false
                var shortcutIndicator: AlertProgressIndicatorViewController?
                var shortcutIndicatorDismissed = false
                func presentShortcutIndicatorIfNeeded(title: String.LocalizationValue) {
                    guard shortcutIndicator == nil, !shortcutIndicatorDismissed else { return }
                    Task { @MainActor in
                        guard let controller = currentMessageListView.parentViewController else { return }
                        guard controller.presentedViewController == nil else { return }
                        let indicator = AlertProgressIndicatorViewController(title: title)
                        controller.present(indicator, animated: true)
                        shortcutIndicator = indicator
                    }
                }
                func dismissShortcutIndicatorIfNeeded() {
                    guard !shortcutIndicatorDismissed else { return }
                    shortcutIndicatorDismissed = true
                    Task { @MainActor in
                        if let indicator = shortcutIndicator {
                            indicator.dismiss(animated: true)
                        }
                        shortcutIndicator = nil
                    }
                }
                if isShortcutInvocation {
                    let waitingForShortcutTitle: String.LocalizationValue = "Waiting for Shortcuts callback…"
                    let waitingForShortcutMessage = String(localized: waitingForShortcutTitle)
                    let shortcutCompletedMessage = String(localized: "Tool call for \(shortcutToolName) completed.")
                    shortcutLoadingToken = await currentMessageListView.beginPersistentLoading(with: waitingForShortcutMessage)
                    shortcutCallbackCancellable?.cancel()
                    shortcutCallbackCancellable = ShortcutToolsManager.shared.invocationEvents
                        .filter { $0.contextID == invocationContextID }
                        .sink { [weak self, weak toolMessage, weak currentMessageListView] event in
                            guard let self, let toolMessage, let currentMessageListView else { return }
                            var status = toolMessage.toolStatus ?? Message.ToolStatus(name: event.toolName, state: 0, message: "")
                            switch event.state {
                            case .waiting:
                                status.state = 0
                                status.message = waitingForShortcutMessage
                                presentShortcutIndicatorIfNeeded(title: waitingForShortcutTitle)
                            case let .completed(result):
                                switch result {
                                case .success:
                                    status.state = 1
                                    status.message = shortcutCompletedMessage
                                    dismissShortcutIndicatorIfNeeded()
                                case let .failure(error):
                                    status.state = 2
                                    status.message = error.localizedDescription
                                    dismissShortcutIndicatorIfNeeded()
                                }
                            }
                            toolMessage.update(\.toolStatus, to: status)
                            Task { @MainActor [weak self, weak currentMessageListView] in
                                guard let self, let currentMessageListView else { return }
                                await requestUpdate(view: currentMessageListView)
                                if let token = shortcutLoadingToken {
                                    switch event.state {
                                    case .waiting:
                                        await currentMessageListView.updatePersistentLoading(token: token, message: waitingForShortcutMessage)
                                    case .completed:
                                        await currentMessageListView.endPersistentLoading(token: token)
                                        shortcutLoadingReleased = true
                                    }
                                }
                            }
                        }
                }

                // 标准工具
                do {
                    defer {
                        if isShortcutInvocation {
                            shortcutCallbackCancellable?.cancel()
                            shortcutCallbackCancellable = nil
                            if let token = shortcutLoadingToken {
                                Task { @MainActor [weak currentMessageListView] in
                                    guard let currentMessageListView else { return }
                                    if !shortcutLoadingReleased {
                                        await currentMessageListView.endPersistentLoading(token: token)
                                        shortcutLoadingReleased = true
                                    }
                                }
                            }
                            dismissShortcutIndicatorIfNeeded()
                        }
                    }

                    let result = try await ModelToolsManager.shared.perform(
                        withTool: tool,
                        parms: request.args,
                        anchorTo: currentMessageListView,
                        contextID: invocationContextID
                    )
                    var toolResponseText = result.text

                    let rawAttachmentCount = (result.imageAttachments.count + result.audioAttachments.count)
                    if rawAttachmentCount > 0 {
                        // form a user message for holding attachments
                        let collectorMessage = appendNewMessage(role: .user)

                        var editorObjects: [RichEditorView.Object.Attachment] = []

                        let imageAttachments = result.imageAttachments.map { image in
                            RichEditorView.Object.Attachment(
                                type: .image,
                                name: String(localized: "Tool Provided Image"),
                                previewImage: image.data,
                                imageRepresentation: image.data,
                                textRepresentation: "",
                                storageSuffix: UUID().uuidString
                            )
                        }
                        editorObjects.append(contentsOf: imageAttachments)

                        var audioAttachments: [RichEditorView.Object.Attachment] = []
                        for (index, audio) in result.audioAttachments.enumerated() {
                            await currentMessageListView.loading(with: String(localized: "Transcoding audio attachment \(index + 1)"))
                            do {
                                let fileExtension = audio.mimeType.flatMap { mime in
                                    UTType(mimeType: mime)?.preferredFilenameExtension
                                }
                                let transcoded = try await AudioTranscoder.transcode(
                                    data: audio.data,
                                    fileExtension: fileExtension
                                )
                                var suggestedName = audio.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                if suggestedName.isEmpty {
                                    suggestedName = if result.audioAttachments.count > 1 {
                                        String(localized: "Tool Provided Audio #\(index + 1)")
                                    } else {
                                        String(localized: "Tool Provided Audio")
                                    }
                                }
                                let attachment = try await RichEditorView.Object.Attachment.makeAudioAttachment(
                                    transcoded: transcoded,
                                    storage: nil,
                                    suggestedName: suggestedName
                                )
                                audioAttachments.append(attachment)
                            } catch {
                                Logger.model.errorFile("failed to process audio attachment from tool \(tool.interfaceName): \(error.localizedDescription)")
                            }
                        }
                        editorObjects.append(contentsOf: audioAttachments)
                        let finalAttachmentCount = editorObjects.count
                        collectorMessage.update(\.document, to: String(
                            localized: "Collected \(finalAttachmentCount) attachments from tool \(tool.interfaceName)."
                        ))

                        toolResponseText = collectorMessage.document

                        addAttachments(editorObjects, to: collectorMessage)
                        updateAttachments(editorObjects, for: collectorMessage)
                        await requestUpdate(view: currentMessageListView)

                        // 如果模型支持图片则添加到请求消息中 如果不支持 tool 一般已经返回了需要的 text 信息
                        let modelCapabilities = ModelManager.shared.modelCapabilities(identifier: modelID)
                        let messages = await makeMessageFromAttachments(
                            editorObjects,
                            modelCapabilities: modelCapabilities
                        )
                        requestMessages.append(contentsOf: messages)
                    }

                    // 64k len is quite large already
                    let toolResponseLimit = 64 * 1024
                    if toolResponseText.count > toolResponseLimit {
                        toolResponseText = """
                        \(String(toolResponseText.prefix(toolResponseLimit)))...
                        [truncated output due to length exceeding \(toolResponseLimit) characters]
                        """
                    }

                    toolStatus.state = 1
                    toolStatus.message = toolResponseText
                    toolMessage.update(\.toolStatus, to: toolStatus)
                    await requestUpdate(view: currentMessageListView)
                    requestMessages.append(.tool(content: .text(toolResponseText), toolCallID: request.id.uuidString))
                } catch {
                    toolStatus.state = 2
                    toolStatus.message = error.localizedDescription
                    toolMessage.update(\.toolStatus, to: toolStatus)
                    await requestUpdate(view: currentMessageListView)
                    requestMessages.append(.tool(content: .text("Tool execution failed. Reason: \(error.localizedDescription)"), toolCallID: request.id.uuidString))
                }
            }
        }

        await requestUpdate(view: currentMessageListView)
        return true
    }
}
