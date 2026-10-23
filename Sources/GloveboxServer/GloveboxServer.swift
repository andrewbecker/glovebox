import MCP
import SimBridge

public enum GloveboxServer {
    public static let version = "0.2.0"

    /// Serves glovebox's tools over stdin and stdout until the client disconnects.
    public static func run() async throws {
        let server = Server(
            name: "glovebox",
            version: version,
            instructions: serverInstructions(debug: ToolCatalog.debugEnabled),
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.entries.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            try await call(params.name, arguments: params.arguments)
        }
        try await server.start(transport: StdioTransport()) { client, _ in
            DriverNote.clientName = "\(client.name) via glovebox"
        }
        await server.waitUntilCompleted()
        // The client is gone: leave no app paused under a debugger.
        await Debugger.shared.detachAll()
    }

    /// Runs one tool call. Failures become error results rather than protocol
    /// errors, so the agent sees the message. Cancellation is rethrown: the
    /// SDK then sends no response, as MCP asks for a cancelled request.
    static func call(_ name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let handler = ToolCatalog.handlers[name] else {
            return .init(content: [.plain(ToolCatalog.unknown(name))], isError: true)
        }
        do {
            return .init(content: try await handler(Arguments(arguments)), isError: false)
        } catch let failure as ToolFailure {
            return .init(content: failure.content, isError: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(content: [.plain(SimBridgeError.message(for: error))], isError: true)
        }
    }
}
