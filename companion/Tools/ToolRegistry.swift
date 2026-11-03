import Foundation
import Observation

/// The tools the assistant may call, keyed by name.
///
/// Tool sources (built-in tools, MCP servers) register here; tool-calling
/// providers read `definitions` and call `invoke(_:arguments:)`.
@Observable
final class ToolRegistry {
    /// Registration order is kept so the model sees a stable list.
    private(set) var tools: [any AssistantTool] = []

    var definitions: [ToolDefinition] {
        tools.map(\.definition)
    }

    func register(_ tool: any AssistantTool) throws {
        let name = tool.definition.name
        guard !tools.contains(where: { $0.definition.name == name }) else {
            throw ToolError.duplicateTool(name)
        }
        tools.append(tool)
    }

    func unregister(named name: String) {
        tools.removeAll { $0.definition.name == name }
    }

    func tool(named name: String) -> (any AssistantTool)? {
        tools.first { $0.definition.name == name }
    }

    /// Runs the named tool with the model's arguments.
    func invoke(_ name: String, arguments: Data) async throws -> String {
        guard let tool = tool(named: name) else { throw ToolError.unknownTool(name) }
        return try await tool.invoke(arguments: arguments)
    }
}
