import Foundation

/// Description of a tool that a model can call, in the shape providers expect:
/// a name, a description, and a JSON Schema for the arguments.
nonisolated struct ToolDefinition: Equatable, Sendable {
    /// Unique, stable identifier, e.g. `read_file` or `github.create_issue`.
    let name: String
    /// What the tool does, written for the model.
    let description: String
    /// JSON Schema (as a JSON string) describing the `arguments` object.
    let parametersSchema: String
}

/// An action the assistant can take on the user's behalf: edit a file, run a
/// command, or forward a call to an MCP server.
///
/// Conform a type to this protocol and register it in `ToolRegistry`. Providers
/// that report `ProviderCapabilities.toolCalling` receive the registered
/// definitions and route tool calls back here. No tools ship yet; see ROADMAP.md.
nonisolated protocol AssistantTool: Sendable {
    var definition: ToolDefinition { get }

    /// Runs the tool. `arguments` is the JSON object the model produced; the
    /// returned text is sent back to the model as the tool result.
    func invoke(arguments: Data) async throws -> String
}

nonisolated enum ToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case duplicateTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "No tool named \"\(name)\" is registered."
        case .duplicateTool(let name): return "A tool named \"\(name)\" is already registered."
        }
    }
}
