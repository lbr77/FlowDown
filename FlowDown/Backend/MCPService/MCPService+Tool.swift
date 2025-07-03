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
                title: "Placeholder",
                explain: "Placeholder",
                key: "wiki.qaq.MCPTools.placeholder",
                defaultValue: true,
                annotation: .boolean
            )
        }
        var _controlObject: ConfigurableObject {
            .init(
                icon: "globe",
                title: tool.name,
                explain: tool.description,
                key: "wiki.qaq.MCPTools.\(tool.name)",
                defaultValue: true,
                annotation: .boolean
            )
        }
        override var isEnabled: Bool {
            ConfigurableKit.value(forKey: self._controlObject.key) ?? true
        }

        override func createConfigurableObjectView() -> UIView {
            return self._controlObject.createView()
        }
    }
}
