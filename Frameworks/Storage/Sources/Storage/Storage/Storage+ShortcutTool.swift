//
//  Storage+ShortcutTool.swift
//  Storage
//
//  Created by LiBr on 15/11/2025.
//

import Foundation
import Logger
import WCDBSwift

public extension Storage {
    private func ensureShortcutToolTableExists() throws {
        guard try !db.isTableExists(ShortcutTool.tableName) else { return }
        try db.create(table: ShortcutTool.tableName, of: ShortcutTool.self)
    }

    private func resetShortcutToolTable() throws {
        if try db.isTableExists(ShortcutTool.tableName) {
            try db.drop(table: ShortcutTool.tableName)
        }
        try db.create(table: ShortcutTool.tableName, of: ShortcutTool.self)
    }

    private func recoverShortcutToolTable(from error: Error) {
        Logger.database.errorFile("shortcut tool table error: \(error)")
        do {
            try resetShortcutToolTable()
        } catch {
            Logger.database.errorFile("failed to rebuild shortcut tool table: \(error)")
        }
    }

    enum ShortcutToolStoreError: LocalizedError {
        case insertFailed(String)
        case fetchFailed(String)
        case notFound
        case deleteFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .insertFailed(reason):
                "Failed to persist shortcut tool: \(reason)"
            case let .fetchFailed(reason):
                "Failed to load shortcut tools: \(reason)"
            case .notFound:
                "Shortcut tool not found."
            case let .deleteFailed(reason):
                "Failed to delete shortcut tool: \(reason)"
            }
        }
    }

    func upsertShortcutTools(_ tools: [ShortcutTool]) throws {
        guard !tools.isEmpty else { return }
        try ensureShortcutToolTableExists()
        do {
            try runTransaction { [weak self] handle in
                guard let self else { return }
                let diff = try diffSyncable(objects: tools, handle: handle)
                try handle.insertOrReplace(tools, intoTable: ShortcutTool.tableName)
                try enqueueShortcutToolChanges(from: diff, handle: handle)
            }
        } catch {
            recoverShortcutToolTable(from: error)
            do {
                try runTransaction { [weak self] handle in
                    guard let self else { return }
                    let diff = try diffSyncable(objects: tools, handle: handle)
                    try handle.insertOrReplace(tools, intoTable: ShortcutTool.tableName)
                    try enqueueShortcutToolChanges(from: diff, handle: handle)
                }
            } catch {
                throw ShortcutToolStoreError.insertFailed(String(describing: error))
            }
        }
    }

    func upsertShortcutTool(_ tool: ShortcutTool) throws {
        try upsertShortcutTools([tool])
    }

    func fetchShortcutTools(includeRemoved: Bool = false) throws -> [ShortcutTool] {
        do {
            try ensureShortcutToolTableExists()
            let condition: Condition? = includeRemoved ? nil : ShortcutTool.Properties.removed == false
            return try db.getObjects(
                fromTable: ShortcutTool.tableName,
                where: condition,
                orderBy: [ShortcutTool.Properties.modified.order(.descending)]
            )
        } catch {
            recoverShortcutToolTable(from: error)
            return []
        }
    }

    func fetchShortcutTool(id: ShortcutTool.ID) throws -> ShortcutTool? {
        do {
            try ensureShortcutToolTableExists()
            return try db.getObject(
                fromTable: ShortcutTool.tableName,
                where: ShortcutTool.Properties.objectId == id && ShortcutTool.Properties.removed == false
            ) as ShortcutTool?
        } catch {
            recoverShortcutToolTable(from: error)
            return nil
        }
    }

    func markShortcutToolRemoved(id: ShortcutTool.ID) throws {
        do {
            try ensureShortcutToolTableExists()
            try runTransaction { [weak self] handle in
                guard let self else { return }
                guard let tool: ShortcutTool = try handle.getObject(
                    fromTable: ShortcutTool.tableName,
                    where: ShortcutTool.Properties.objectId == id
                ) else {
                    throw ShortcutToolStoreError.notFound
                }

                guard tool.update(\.removed, to: true) else { return }
                try handle.insertOrReplace([tool], intoTable: ShortcutTool.tableName)
                try pendingUploadEnqueue(sources: [(tool, .delete)], handle: handle)
            }
        } catch let error as ShortcutToolStoreError {
            throw error
        } catch {
            recoverShortcutToolTable(from: error)
            throw ShortcutToolStoreError.deleteFailed(String(describing: error))
        }
    }

    func setShortcutToolEnabled(id: ShortcutTool.ID, isEnabled: Bool) throws {
        do {
            try ensureShortcutToolTableExists()
            try runTransaction { [weak self] handle in
                guard let self else { return }
                guard let tool: ShortcutTool = try handle.getObject(
                    fromTable: ShortcutTool.tableName,
                    where: ShortcutTool.Properties.objectId == id
                ) else {
                    throw ShortcutToolStoreError.notFound
                }

                guard tool.update(\.isEnabled, to: isEnabled) else { return }
                try handle.insertOrReplace([tool], intoTable: ShortcutTool.tableName)
                try pendingUploadEnqueue(sources: [(tool, .update)], handle: handle)
            }
        } catch let error as ShortcutToolStoreError {
            throw error
        } catch {
            recoverShortcutToolTable(from: error)
            throw ShortcutToolStoreError.insertFailed(String(describing: error))
        }
    }
}

private extension Storage {
    func enqueueShortcutToolChanges(from diff: Storage.DiffSyncableResult<ShortcutTool>, handle: Handle) throws {
        guard !diff.isEmpty else { return }
        var changes: [(any Syncable, UploadQueue.Changes)] = []
        changes.append(contentsOf: diff.insert.map { ($0, .insert) })
        changes.append(contentsOf: diff.updated.map { ($0, .update) })
        changes.append(contentsOf: diff.deleted.map { ($0, .delete) })
        guard !changes.isEmpty else { return }
        try pendingUploadEnqueue(sources: changes, handle: handle)
    }
}
