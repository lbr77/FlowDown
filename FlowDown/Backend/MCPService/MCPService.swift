//
//  MCPService.swift
//  FlowDown
//
//  Created by LiBr on 6/29/25.
//
import Combine
import Foundation
import MCP
import Storage

class MCPService: NSObject {
    static let shared = MCPService()

    public let clients: CurrentValueSubject<[ModelContextClient], Never> = .init([])
    public let clientsConn: CurrentValueSubject<[Int64: MCPClient?], Never> = .init([:]) // ModelContextClient.ID(unique) -> MCPClient
    public let tools: CurrentValueSubject<[Int64: [MCPTool]],Never> = .init([:])
    var enabledClients: [ModelContextClient] {
        clients.value.filter(\.isEnabled)
    }

    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()

        updateFromDatabase()

        clients
            .map { $0.filter(\.isEnabled) }
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] enabledMCPClients in
                guard let self else { return }
                refreshClients(enabledClients: enabledMCPClients)
            }
            .store(in: &cancellables)
    }
    public func refreshClients(enabledClients: [ModelContextClient]) {
        // Remove clients that are no longer enabled
        let removedClients = clientsConn.value.keys.filter { key in
            !enabledClients.contains(where: { $0.id == key }) && clientsConn.value[key] != nil // is it
        }
        for key in removedClients {
            guard let cC = clientsConn.value[key] else { continue }
            cC?.disconnect()
            clientsConn.value[key] = nil
        }

        enabledClients.forEach{client in
            guard let clientConn = clientsConn.value[client.id] else { // else connect
                let newClient = MCPClient(properties: client)
                clientsConn.value[client.id] = newClient
                return
            }
        }
        // update tools
        detectTools(enabledClients: enabledClients)
    }

    private func detectTools(enabledClients _: [ModelContextClient]) {
        var result : [Int64: [MCPTool]] = [:]
        enabledClients.forEach { client in // enabled clients
            guard let clientConn = clientsConn.value[client.id] else { return } // get active clients
            // then get tools
            let tools = clientConn?.listTools() // -> [MCPTool]
            // got to collection
            result[client.id] = tools
        }
        // send to subject
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tools.send(result)
        }
    }
}

extension MCPService {
    public func testConfiguration(properties: ModelContextClient) async  -> Bool {
        return await MCPClient.testConfiguration(properties: properties)
    }
}


extension MCPService {
    private func updateFromDatabase() {
        clients.send(sdb.modelContextClientList())
    }

    func create() -> ModelContextClient {
        defer { updateFromDatabase() }
        return sdb.modelContextClientMake()
    }

    func client(with identifier: ModelContextClient.ID?) -> ModelContextClient? {
        guard let identifier else { return nil }
        return sdb.modelContextClientWith(identifier)
    }

    func remove(_ identifier: ModelContextClient.ID) {
        defer { updateFromDatabase() }
        sdb.modelContextClientRemove(identifier: identifier)
    }

    func edit(identifier: ModelContextClient.ID, block: @escaping (inout ModelContextClient) -> Void) {
        defer { updateFromDatabase() }
        sdb.modelContextClientEdit(identifier: identifier, block)
    }
}
