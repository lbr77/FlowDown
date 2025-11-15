//
//  ShortcutTool.swift
//  Storage
//
//  Created by LiBr on 15/11/2025.
//

import Foundation
import WCDBSwift

public final class ShortcutTool: Identifiable, Codable, TableNamed, DeviceOwned, TableCodable {
    public static let tableName: String = "ShortcutTool"

    public var id: String { objectId }

    public package(set) var objectId: String = UUID().uuidString
    public package(set) var deviceId: String = ""

    public package(set) var name: String = ""
    public package(set) var detail: String = ""
    public package(set) var schemaJSON: String = ""
    public package(set) var shortcutName: String = ""
    public package(set) var isEnabled: Bool = true

    public package(set) var creation: Date = .now
    public package(set) var modified: Date = .now
    public package(set) var removed: Bool = false

    public enum CodingKeys: String, CodingTableKey {
        public typealias Root = ShortcutTool
        public static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindColumnConstraint(objectId, isPrimary: true, isNotNull: true, isUnique: true)
            BindColumnConstraint(deviceId, isNotNull: true)

            BindColumnConstraint(creation, isNotNull: true)
            BindColumnConstraint(modified, isNotNull: true)
            BindColumnConstraint(removed, isNotNull: false, defaultTo: false)

            BindColumnConstraint(name, isNotNull: true, defaultTo: "")
            BindColumnConstraint(detail, isNotNull: true, defaultTo: "")
            BindColumnConstraint(schemaJSON, isNotNull: true, defaultTo: "")
            BindColumnConstraint(shortcutName, isNotNull: true, defaultTo: "")
            BindColumnConstraint(isEnabled, isNotNull: true, defaultTo: true)

            BindIndex(creation, namedWith: "_creationIndex")
            BindIndex(modified, namedWith: "_modifiedIndex")
            BindIndex(name, namedWith: "_nameIndex")
        }

        case objectId
        case deviceId
        case name
        case detail
        case schemaJSON
        case shortcutName
        case isEnabled
        case creation
        case modified
        case removed
    }

    public init(
        deviceId: String,
        name: String,
        detail: String,
        schemaJSON: String,
        shortcutName: String,
        isEnabled: Bool = true
    ) {
        self.deviceId = deviceId
        self.name = name
        self.detail = detail
        self.schemaJSON = schemaJSON
        self.shortcutName = shortcutName
        self.isEnabled = isEnabled
    }

    public func markModified(_ date: Date = .now) {
        modified = date
    }
}

extension ShortcutTool: Updatable {
    @discardableResult
    public func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ShortcutTool, Value>, to newValue: Value) -> Bool {
        let oldValue = self[keyPath: keyPath]
        guard oldValue != newValue else { return false }
        assign(keyPath, to: newValue)
        return true
    }

    public func assign<Value>(_ keyPath: ReferenceWritableKeyPath<ShortcutTool, Value>, to newValue: Value) {
        self[keyPath: keyPath] = newValue
        markModified()
    }

    package func update(_ block: (ShortcutTool) -> Void) {
        block(self)
        markModified()
    }
}

extension ShortcutTool: Equatable {
    public static func == (lhs: ShortcutTool, rhs: ShortcutTool) -> Bool {
        lhs.objectId == rhs.objectId &&
            lhs.deviceId == rhs.deviceId &&
            lhs.name == rhs.name &&
            lhs.detail == rhs.detail &&
            lhs.schemaJSON == rhs.schemaJSON &&
            lhs.shortcutName == rhs.shortcutName &&
            lhs.isEnabled == rhs.isEnabled &&
            lhs.creation == rhs.creation &&
            lhs.modified == rhs.modified &&
            lhs.removed == rhs.removed
    }
}

extension ShortcutTool: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(objectId)
        hasher.combine(deviceId)
        hasher.combine(name)
        hasher.combine(detail)
        hasher.combine(schemaJSON)
        hasher.combine(shortcutName)
        hasher.combine(isEnabled)
        hasher.combine(creation)
        hasher.combine(modified)
        hasher.combine(removed)
    }
}
