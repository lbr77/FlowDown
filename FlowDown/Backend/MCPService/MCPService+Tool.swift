//
//  MCPService+Tool.swift
//  FlowDown
//
//  Created by LiBr on 6/29/25.
//
import MCP
import ConfigurableKit

// TODO: support tools.
extension MCPService {
    class MCPTool: ModelTool {
        var tool: Tool
        var client: Client
        init(tool: Tool, client: Client) {
            self.tool = tool
            self.client = client
        }
        override var functionName: String {
            tool.name
        }
        override var interfaceName: String {
            tool.name
        }
        override var shortDescription: String {
            tool.description
        }
        override class var controlObject: ConfigurableObject {
            .init(
                icon: "globe",
                title: String(localized: "Web Scraper"),
                explain: String(localized: "Allows LLM to fetch and read content from web pages."),
                key: "wiki.qaq.MCPTools.",
                defaultValue: true,
                annotation: .boolean
            )
        }
    }
}
