//
//  MCPService+Client.swift
//  FlowDown
//
//  Created by LiBr on 6/30/25.
//

import MCP
import Storage
extension MCPService{
    class MCPClient {
        private var client: Client?
        private var properties: ModelContextClient?
        public var id: ModelContextClient.ID {
            properties?.id ?? .init()
        }

        init(properties: ModelContextClient) {
            print("[+] New MCPService with url: \(properties.endpoint)")
            self.properties = properties
            self.client = Client(
                name: properties.name,
                version: "1.0.0",
            )
            
        }
        public func listTools() -> [MCPTool] {
            print("[+] Get Tool called.")
            return []
        }
        public static func testConfiguration(properties: ModelContextClient) async -> Bool {
            print("[+] Testing MCPClient configuration with endpoint: \(properties.endpoint)")
            // todo: implement here.
            return true
        }
        public func disconnect() {
            
        }
    }

}
