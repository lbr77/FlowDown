//
//  ShortcutToolsManager.swift
//  FlowDown
//
//  Created by LiBr on 15/11/2025.
//

import ChatClientKit
import Combine
import ConfigurableKit
import Foundation
import Logger
import Storage
import UIKit

struct ShortcutToolDraft: Equatable {
    var id: String?
    var name: String
    var detail: String
    var schemaJSON: String
    var shortcutName: String
    var isEnabled: Bool

    init(
        id: String? = nil,
        name: String = "",
        detail: String = "",
        schemaJSON: String = "",
        shortcutName: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.schemaJSON = schemaJSON
        self.shortcutName = shortcutName
        self.isEnabled = isEnabled
    }

    static var empty: ShortcutToolDraft { .init() }
}

final class ShortcutToolsManager {
    struct InvocationEvent {
        enum State {
            case waiting
            case completed(Result<String, Error>)
        }

        let callId: String
        let contextID: String?
        let toolName: String
        let state: State
    }

    private struct PendingInvocation {
        let continuation: CheckedContinuation<String, Error>
        let contextID: String?
        let toolName: String
    }

    static let shared = ShortcutToolsManager()

    private let lock = NSLock()
    private var cachedTools: [ShortcutTool] = []
    private var shortcutModelTools: [ShortcutModelTool] = []
    private var pendingInvocations: [String: PendingInvocation] = [:]
    private var pendingInvocationOrder: [String] = []
    private var pendingExternalDraft: ShortcutToolDraft?
    private var cancellables = Set<AnyCancellable>()

    let invocationEvents = PassthroughSubject<InvocationEvent, Never>()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private let decoder = JSONDecoder()

    private init() {
        NotificationCenter.default.publisher(for: SyncEngine.ShortcutToolChanged)
            .sink { [weak self] _ in
                self?.reloadFromStorage()
            }
            .store(in: &cancellables)

        reloadFromStorage()
    }

    func reloadFromStorage() {
        do {
            let tools = try sdb.fetchShortcutTools()
            updateCache(with: tools)
        } catch {
            Logger.app.errorFile("failed to load shortcut tools: \(error)")
        }
    }

    private func updateCache(with tools: [ShortcutTool]) {
        lock.lock()
        cachedTools = tools
        shortcutModelTools = tools.map {
            ShortcutModelTool(snapshot: .init(tool: $0), manager: self)
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutToolsDidChange, object: nil)
        }
    }

    func listModelTools() -> [ModelTool] {
        lock.lock()
        let tools = shortcutModelTools
        lock.unlock()
        return tools
    }

    func listShortcutModelTools() -> [ShortcutModelTool] {
        lock.lock()
        let tools = shortcutModelTools
        lock.unlock()
        return tools
    }

    func listShortcutTools() -> [ShortcutTool] {
        lock.lock()
        let tools = cachedTools
        lock.unlock()
        return tools
    }

    func draft(for tool: ShortcutTool) -> ShortcutToolDraft {
        .init(
            id: tool.objectId,
            name: tool.name,
            detail: tool.detail,
            schemaJSON: tool.schemaJSON,
            shortcutName: tool.shortcutName,
            isEnabled: tool.isEnabled
        )
    }

    func save(draft: ShortcutToolDraft) throws {
        let prepared = try validateDraft(draft)
        if let identifier = prepared.id,
           let existing = try sdb.fetchShortcutTool(id: identifier)
        {
            existing.update(\.name, to: prepared.name)
            existing.update(\.detail, to: prepared.detail)
            existing.update(\.schemaJSON, to: prepared.schemaJSON)
            existing.update(\.shortcutName, to: prepared.shortcutName)
            existing.update(\.isEnabled, to: prepared.isEnabled)
            existing.markModified()
            try sdb.upsertShortcutTool(existing)
        } else {
            let tool = ShortcutTool(
                deviceId: Storage.deviceId,
                name: prepared.name,
                detail: prepared.detail,
                schemaJSON: prepared.schemaJSON,
                shortcutName: prepared.shortcutName,
                isEnabled: prepared.isEnabled
            )
            try sdb.upsertShortcutTool(tool)
        }
        reloadFromStorage()
    }

    func deleteShortcutTool(id: ShortcutTool.ID) throws {
        try sdb.markShortcutToolRemoved(id: id)
        reloadFromStorage()
    }

    func queueExternalDraft(_ draft: ShortcutToolDraft) {
        lock.lock()
        pendingExternalDraft = draft
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .shortcutToolDraftQueued, object: nil)
        }
    }

    func pollExternalDraft() -> ShortcutToolDraft? {
        lock.lock()
        let draft = pendingExternalDraft
        pendingExternalDraft = nil
        lock.unlock()
        return draft
    }

    func isShortcutEnabled(id: ShortcutTool.ID) -> Bool {
        lock.lock()
        let isEnabled = cachedTools.first { $0.objectId == id }?.isEnabled ?? false
        lock.unlock()
        return isEnabled
    }

    func setShortcutEnabled(id: ShortcutTool.ID, enabled: Bool) {
        do {
            try sdb.setShortcutToolEnabled(id: id, isEnabled: enabled)
            reloadFromStorage()
        } catch {
            Logger.app.errorFile("failed to set shortcut tool enabled: \(error)")
        }
    }

    func handleCallbackURL(_ url: URL) {
        do {
            let payload = try ShortcutJumpHelper.parseCallbackURL(url)
            handleCallbackPayload(payload)
        } catch {
            Logger.app.errorFile("failed to parse shortcut callback: \(error)")
        }
    }

    private func handleCallbackPayload(_ payload: ShortcutJumpHelper.CallbackPayload) {
        guard let (resolvedCallId, pending) = popPendingInvocation() else {
            Logger.app.infoFile("shortcut callback received without pending invocation")
            return
        }

        switch payload.status {
        case .success:
            let result = serializeOutput(payload) ?? payload.encodedResult
            pending.continuation.resume(returning: result)
            publish(.init(callId: resolvedCallId, contextID: pending.contextID, toolName: pending.toolName, state: .completed(.success(result))))
        case .cancelled:
            let error = ShortcutToolsManagerError.shortcutCancelled
            pending.continuation.resume(throwing: error)
            publish(.init(callId: resolvedCallId, contextID: pending.contextID, toolName: pending.toolName, state: .completed(.failure(error))))
        case .failure:
            let message = payload.message?.nilIfEmpty ?? String(localized: "Shortcut reported an unknown error.")
            let error = ShortcutToolsManagerError.shortcutFailed(message)
            pending.continuation.resume(throwing: error)
            publish(.init(callId: resolvedCallId, contextID: pending.contextID, toolName: pending.toolName, state: .completed(.failure(error))))
        }
    }

    private func serializeOutput(_ payload: ShortcutJumpHelper.CallbackPayload) -> String? {
        guard let output = payload.data else {
            return nil
        }

        if case let .string(value) = output {
            return value
        }

        do {
            let data = try encoder.encode(output)
            return String(data: data, encoding: .utf8)
        } catch {
            Logger.app.errorFile("failed to encode shortcut output: \(error)")
            return nil
        }
    }

    func executeShortcut(
        snapshot: ShortcutModelTool.Snapshot,
        argumentsJSON: String,
        anchorView _: UIView,
        contextID: String?
    ) async throws -> String {
        guard isShortcutEnabled(id: snapshot.id) else {
            throw ShortcutToolsManagerError.toolDisabled
        }

        let parameters = try decodeArguments(argumentsJSON)
        let callId = UUID().uuidString
        let url = try ShortcutJumpHelper.makeRunShortcutURL(
            shortcutName: snapshot.shortcutName,
            parameters: parameters
        )

        return try await withCheckedThrowingContinuation { continuation in
            registerContinuation(continuation, for: callId, contextID: contextID, toolName: snapshot.name)

            Task { @MainActor [weak self] in
                UIApplication.shared.open(url, options: [:]) { [weak self] success in
                    guard let self else { return }
                    guard !success else { return }
                    failInvocation(id: callId, error: ShortcutToolsManagerError.failedToOpenShortcut)
                }
            }
        }
    }

    private func decodeArguments(_ json: String) throws -> [String: AnyCodingValue] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw ShortcutToolsManagerError.invalidArguments
        }

        do {
            return try decoder.decode([String: AnyCodingValue].self, from: data)
        } catch {
            throw ShortcutToolsManagerError.invalidArguments
        }
    }

    private func registerContinuation(_ continuation: CheckedContinuation<String, Error>, for callId: String, contextID: String?, toolName: String) {
        let pending = PendingInvocation(continuation: continuation, contextID: contextID, toolName: toolName)
        lock.lock()
        pendingInvocations[callId] = pending
        pendingInvocationOrder.append(callId)
        lock.unlock()
        publish(.init(callId: callId, contextID: contextID, toolName: toolName, state: .waiting))
    }

    private func failInvocation(id: String, error: Error) {
        let pending: PendingInvocation?
        lock.lock()
        pending = pendingInvocations.removeValue(forKey: id)
        if let index = pendingInvocationOrder.firstIndex(of: id) {
            pendingInvocationOrder.remove(at: index)
        }
        lock.unlock()
        guard let pending else { return }
        pending.continuation.resume(throwing: error)
        publish(.init(callId: id, contextID: pending.contextID, toolName: pending.toolName, state: .completed(.failure(error))))
    }

    private func popPendingInvocation() -> (String, PendingInvocation)? {
        lock.lock()
        defer { lock.unlock() }

        while let callId = pendingInvocationOrder.first {
            pendingInvocationOrder.removeFirst()
            if let pending = pendingInvocations.removeValue(forKey: callId) {
                return (callId, pending)
            }
        }

        return nil
    }

    private func publish(_ event: InvocationEvent) {
        DispatchQueue.main.async {
            self.invocationEvents.send(event)
        }
    }

    private func validateDraft(_ draft: ShortcutToolDraft) throws -> ShortcutToolDraft {
        var normalized = draft
        normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty else {
            throw ShortcutToolsManagerError.invalidName
        }

        normalized.detail = normalized.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.shortcutName = normalized.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.shortcutName.isEmpty else {
            throw ShortcutToolsManagerError.invalidShortcutReference
        }

        let schema = normalized.schemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if schema.isEmpty {
            normalized.schemaJSON = """
            {
              "type": "object",
              "properties": {}
            }
            """
        } else {
            guard let data = schema.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                throw ShortcutToolsManagerError.invalidSchema
            }
            normalized.schemaJSON = schema
        }

        return normalized
    }
}

enum ShortcutToolsManagerError: LocalizedError {
    case toolDisabled
    case invalidArguments
    case failedToOpenShortcut
    case shortcutCancelled
    case shortcutFailed(String)
    case invalidName
    case invalidShortcutReference
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .toolDisabled:
            String(localized: "This shortcut tool is disabled.")
        case .invalidArguments:
            String(localized: "Shortcut tool arguments are invalid.")
        case .failedToOpenShortcut:
            String(localized: "Unable to open Shortcuts app.")
        case .shortcutCancelled:
            String(localized: "Shortcut execution was cancelled.")
        case let .shortcutFailed(message):
            String(localized: "Shortcut execution failed: \(message)")
        case .invalidName:
            String(localized: "Name cannot be empty.")
        case .invalidShortcutReference:
            String(localized: "Shortcut name cannot be empty.")
        case .invalidSchema:
            String(localized: "Schema must be valid JSON.")
        }
    }
}

final class ShortcutModelTool: ModelTool, @unchecked Sendable {
    struct Snapshot {
        let id: String
        let name: String
        let detail: String
        let schema: [String: AnyCodingValue]?
        let shortcutName: String
        let functionIdentifier: String

        init(tool: ShortcutTool) {
            id = tool.objectId
            name = tool.name
            detail = tool.detail
            shortcutName = tool.shortcutName
            schema = Snapshot.parseSchema(tool.schemaJSON)
            functionIdentifier = ShortcutModelTool.makeFunctionIdentifier(from: tool.name, id: tool.objectId)
        }

        private static func parseSchema(_ json: String) -> [String: AnyCodingValue]? {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode([String: AnyCodingValue].self, from: data)
        }
    }

    private let snapshot: Snapshot
    private unowned let manager: ShortcutToolsManager

    init(snapshot: Snapshot, manager: ShortcutToolsManager) {
        self.snapshot = snapshot
        self.manager = manager
    }

    override var shortDescription: String {
        snapshot.detail
    }

    override var interfaceName: String {
        snapshot.name
    }

    override var interfaceIcon: String {
        "bolt.circle"
    }

    override var definition: ChatRequestBody.Tool {
        .function(
            name: snapshot.functionIdentifier,
            description: snapshot.detail,
            parameters: snapshot.schema ?? ["type": "object"],
            strict: false
        )
    }

    override class var controlObject: ConfigurableObject {
        .init(
            icon: "bolt.circle",
            title: "Shortcut Tools",
            explain: "Configuration for user-defined shortcuts is available within the Shortcut Tools section.",
            key: "wiki.qaq.ModelTools.ShortcutTools.placeholder",
            defaultValue: true,
            annotation: .boolean
        )
    }

    override var isEnabled: Bool {
        get { manager.isShortcutEnabled(id: snapshot.id) }
        set { manager.setShortcutEnabled(id: snapshot.id, enabled: newValue) }
    }

    override func execute(with input: String, anchorTo view: UIView) async throws -> String {
        try await execute(with: input, anchorTo: view, contextID: nil)
    }

    override func execute(with input: String, anchorTo view: UIView, contextID: String?) async throws -> String {
        try await manager.executeShortcut(snapshot: snapshot, argumentsJSON: input, anchorView: view, contextID: contextID)
    }

    private static func makeFunctionIdentifier(from name: String, id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var buffer = ""
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else if !buffer.hasSuffix("_") {
                buffer.append("_")
            }
        }
        let trimmed = buffer.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if !trimmed.isEmpty {
            return String(trimmed.prefix(60))
        }
        let fallback = id.replacingOccurrences(of: "-", with: "").lowercased()
        return "shortcut_tool_\(fallback.prefix(8))"
    }
}

extension Notification.Name {
    static let shortcutToolsDidChange = Notification.Name("ShortcutToolsManager.shortcutToolsDidChange")
    static let shortcutToolDraftQueued = Notification.Name("ShortcutToolsManager.shortcutToolDraftQueued")
}
