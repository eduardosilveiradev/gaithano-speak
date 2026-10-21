import Foundation
import os
import SpeakCore

// The MCP proxy Claude Code talks to, and the approval gate it enforces.
//
// The spec's rule that shapes this whole file: "The app must enforce approvals in an
// MCP proxy between Claude Code and each server. Prompt instructions alone are not an
// approval boundary. Claude must not receive a second unproxied route to the same
// operation." So Claude Code is launched with exactly one MCP server — this one — and
// the real servers are our subprocesses, reachable only through here. A prompt that
// says "ask before buying things" is a request; this is the thing that can say no.
//
// Filtering happens twice, on the way out of `tools/list` and again on the way into
// `tools/call`. That looks redundant and isn't: a model can call a tool name it was
// never shown, either because it guessed, because it read one in a web page, or
// because a conversation from before a catalogue refresh is still in its context.

/// Answers approval requests. Implemented on the coordinator side, where the panel and
/// the user's keystrokes are.
///
/// `decide` may take as long as the user does. The proxy stays suspended in the call —
/// the downstream server never sees the request until this returns, which is what makes
/// "deny" mean the action didn't happen rather than that it was undone. The suspension is
/// also what lets `endRun()` land while a prompt is on screen, so Escape cancelling a run
/// isn't queued behind the decision it's cancelling.
protocol AgentApprovalGate: Sendable {
    func decide(_ request: AgentApprovalRequest) async -> ApprovalDecision
}

/// What the panel needs to draw a step. The proxy reports every call it sees, including
/// the ones it refuses — a denied action the user never sees is indistinguishable to
/// them from a feature that silently doesn't work.
protocol AgentProxyObserver: Sendable {
    func proxyDidUpdate(call: AgentToolCall, status: AgentStepStatus, detail: String?)
}


// MARK: - The proxy

actor MCPApprovalProxy {

    /// The name Claude Code knows this server by. Every tool it can call is therefore
    /// `mcp__gaithano__…`, which is also all the runtime has to put in `--allowed-tools`.
    static let serverName = "gaithano"

    /// Handles the app's own tools — model escalation and the model volunteering that
    /// it wants a confirmation. Supplied by the runtime; when it's nil those tools are
    /// simply absent from the catalogue, the same as any other unavailable server.
    typealias ControlHandler = @Sendable (String, [String: JSONValue]) async -> String

    private let gate: AgentApprovalGate
    private let observer: AgentProxyObserver?
    private let controlHandler: ControlHandler?
    private var downstream: [MCPServerID: MCPDownstreamServer] = [:]
    /// Populated from each downstream `tools/list`, intersected with the allowlist.
    private var catalogue: [String: CatalogueEntry] = [:]

    /// "Allow all for this run", and the reason it's keyed by run rather than stored as
    /// a flag: the spec says the grant dies with the request, and a bare Bool survives
    /// exactly one forgotten `endRun` before a follow-up inherits blanket approval for
    /// purchases and door locks. Keying it means a stale grant can't match the next run
    /// even if nobody clears it.
    private var allowAllRunID: String?
    private var activeRunID: String?

    init(gate: AgentApprovalGate,
         observer: AgentProxyObserver? = nil,
         controlHandler: ControlHandler? = nil) {
        self.gate = gate
        self.observer = observer
        self.controlHandler = controlHandler
    }

    struct CatalogueEntry: Sendable {
        var ref: AgentToolRef
        var description: String
        var schema: JSONValue
        /// Argument names the server's own schema flagged as secret. The spec only asks
        /// us to redact "where the server identifies them as sensitive";
        /// `AgentArgumentRedaction` covers the servers that identify nothing, which is
        /// most of them.
        var sensitiveArguments: Set<String>
    }

    // MARK: Lifecycle

    /// Connect the downstream servers that are available and build the catalogue.
    ///
    /// A server that won't start is not a session failure. The spec is explicit that one
    /// unavailable capability must not take the others down with it, so a failed launch
    /// is recorded, its tools stay out of the catalogue, and a call addressed to it comes
    /// back as an error the model can explain to the user.
    func connect(_ launches: [MCPServerLaunch]) async {
        for launch in launches {
            do {
                let server = try MCPDownstreamServer(launch: launch)
                try await server.initialize()
                downstream[launch.id] = server
                ingest(tools: try await server.listTools(), from: launch.id)
            } catch {
                Log.agent.error("""
                    \(launch.id.rawValue, privacy: .public) MCP unavailable: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        if controlHandler != nil {
            for tool in AgentToolAllowlist.tools(for: .control).sorted() {
                let ref = AgentToolRef(server: .control, tool: tool)
                catalogue[ref.qualifiedName] = CatalogueEntry(ref: ref,
                                                              description: Self.controlDescription(tool),
                                                              schema: Self.controlSchema(tool),
                                                              sensitiveArguments: [])
            }
        }
    }

    func shutdown() {
        for server in downstream.values { server.terminate() }
        downstream.removeAll()
        catalogue.removeAll()
        allowAllRunID = nil
        activeRunID = nil
    }

    /// Called when a user request starts. Anything the previous run was granted stops
    /// applying here, whether or not `endRun` was ever delivered.
    func beginRun(id: String) {
        activeRunID = id
        allowAllRunID = nil
    }

    func endRun() {
        activeRunID = nil
        allowAllRunID = nil
    }

    var isAllowAllInForce: Bool {
        allowAllRunID != nil && allowAllRunID == activeRunID
    }

    private func ingest(tools: [MCPDownstreamServer.ToolDescription], from server: MCPServerID) {
        var admitted = 0
        for tool in tools {
            guard AgentToolAllowlist.isAllowed(server: server, tool: tool.name) else { continue }
            let ref = AgentToolRef(server: server, tool: tool.name)
            catalogue[ref.qualifiedName] = CatalogueEntry(ref: ref,
                                                          description: tool.description,
                                                          schema: tool.schema,
                                                          sensitiveArguments: tool.sensitiveArguments)
            admitted += 1
        }
        Log.agent.info("""
            \(server.rawValue, privacy: .public): \(admitted, privacy: .public) of \
            \(tools.count, privacy: .public) tools admitted
            """)
    }

    // MARK: Serving

    /// Read JSON-RPC messages until the peer hangs up. One connection at a time is all
    /// this ever needs: there is one Claude Code session per conversation.
    func serve(_ transport: LineTransport) async {
        while let data = try? await transport.readMessage() {
            guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
                Log.agent.error("proxy received a message it couldn't parse")
                continue
            }
            // Notifications carry no id and expect no reply; `notifications/initialized`
            // is the only one that matters and it needs no action.
            guard let id = message.id else { continue }
            let response = await respond(to: message, id: id)
            if let encoded = try? JSONEncoder().encode(response) {
                try? await transport.send(encoded)
            }
        }
    }

    private func respond(to message: JSONRPCMessage, id: JSONValue) async -> JSONRPCResponse {
        switch message.method {
        case "initialize":
            return .result(id: id, .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string("1.0.0"),
                ]),
            ]))

        case "ping":
            return .result(id: id, .object([:]))

        case "tools/list":
            return .result(id: id, .object(["tools": .array(listing())]))

        case "tools/call":
            return .result(id: id, await call(message.params))

        default:
            // Resources, prompts, sampling, completion: none of them are part of this
            // boundary, and answering "method not found" is how MCP says so.
            return .error(id: id, code: -32601, message: "\(message.method) is not supported")
        }
    }

    /// The catalogue, in a stable order. Only allowlisted tools ever entered it, so
    /// there is nothing to filter here — the filtering already happened at `ingest`.
    private func listing() -> [JSONValue] {
        catalogue.values
            .sorted { $0.ref.qualifiedName < $1.ref.qualifiedName }
            .map { entry in
                .object([
                    "name": .string(entry.ref.qualifiedName),
                    "description": .string("[\(entry.ref.server.displayName)] \(entry.description)"),
                    "inputSchema": entry.schema,
                ])
            }
    }

    // MARK: The gate

    private func call(_ params: JSONValue?) async -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            return Self.toolError("A tool call arrived with no tool name.")
        }
        let rawArguments = params?["arguments"]?.objectValue ?? [:]

        // Second filter. The model may name a tool it was never shown; refusing here is
        // what makes the catalogue a boundary rather than a suggestion.
        guard let entry = catalogue[name], AgentToolAllowlist.isAllowed(name) else {
            Log.agent.error("refused unlisted tool \(name, privacy: .public)")
            return Self.toolError("""
                `\(name)` is not available in this session. Only the tools listed by \
                tools/list can be called, and there is no file, shell, or code-execution \
                tool. Use one of the listed tools or tell the user what you need.
                """)
        }

        let call = agentCall(name: name, entry: entry, arguments: rawArguments)

        switch ActionRiskPolicy.classify(call) {
        case nil:
            observer?.proxyDidUpdate(call: call, status: .running, detail: nil)
        case let .some(category):
            if isAllowAllInForce {
                // Granted, and still shown. "Allow all" removes the question, not the
                // record of what was done with it.
                observer?.proxyDidUpdate(call: call, status: .running, detail: "allowed for this run")
                break
            }
            let request = AgentApprovalRequest(id: "approval-\(call.id)",
                                               call: call,
                                               category: category,
                                               reason: ActionRiskPolicy.reason(for: call, category: category))
            observer?.proxyDidUpdate(call: call, status: .awaitingApproval, detail: request.reason)
            switch await gate.decide(request) {
            case .allow:
                observer?.proxyDidUpdate(call: call, status: .running, detail: nil)
            case .allowAll:
                // No active run means nothing for the grant to be scoped *to*, and a
                // grant with no end is the one thing this must never create. Leaving it
                // nil costs the user one extra confirmation in a state that shouldn't
                // arise; the alternative costs them a blanket approval that never expires.
                allowAllRunID = activeRunID
                observer?.proxyDidUpdate(call: call, status: .running, detail: "allowed for this run")
            case .deny:
                observer?.proxyDidUpdate(call: call, status: .denied, detail: request.reason)
                // An error result rather than a protocol error: the model is meant to
                // read this, reconsider, and either try something else or explain
                // itself to the user.
                return Self.toolError("""
                    The user declined this action. Do not retry it or attempt the same \
                    effect another way. Ask what they would like instead, or continue \
                    with the rest of the task.
                    """)
            }
        }

        return await forward(call: call, entry: entry, arguments: rawArguments)
    }

    private func forward(call: AgentToolCall,
                         entry: CatalogueEntry,
                         arguments: [String: JSONValue]) async -> JSONValue {
        if entry.ref.server == .control {
            guard let controlHandler else {
                return Self.toolError("This session has no control channel.")
            }
            let detail = await controlHandler(entry.ref.tool, arguments)
            observer?.proxyDidUpdate(call: call, status: .completed, detail: detail)
            return Self.toolText(detail)
        }

        guard let server = downstream[entry.ref.server] else {
            observer?.proxyDidUpdate(call: call, status: .failed, detail: "server unavailable")
            return Self.toolError("""
                \(entry.ref.server.displayName) control isn't available in this session. \
                Tell the user which capability is missing; the other capabilities still work.
                """)
        }

        do {
            let result = try await server.callTool(name: entry.ref.tool, arguments: arguments)
            observer?.proxyDidUpdate(call: call, status: .completed, detail: nil)
            return result
        } catch {
            // Deliberately not `.failed`: a call that threw mid-flight may have half
            // happened, and the spec forbids replaying one of those blindly.
            observer?.proxyDidUpdate(call: call, status: .interrupted, detail: error.localizedDescription)
            return Self.toolError("""
                \(entry.ref.server.displayName) did not complete the action \
                (\(error.localizedDescription)). Its outcome is unknown — check the \
                current state before trying again.
                """)
        }
    }

    /// Build the value everything downstream of the gate sees. Redaction happens here,
    /// once, because this is the only place that holds the raw arguments — every later
    /// consumer then gets a call that is display-safe by construction rather than by
    /// remembering.
    private func agentCall(name: String,
                           entry: CatalogueEntry,
                           arguments: [String: JSONValue]) -> AgentToolCall {
        let flattened = arguments.mapValues { $0.displayString }
        return AgentToolCall(id: UUID().uuidString,
                             server: entry.ref.server,
                             tool: entry.ref.tool,
                             target: Self.target(in: flattened),
                             arguments: AgentArgumentRedaction.displayArguments(
                                flattened, serverDeclared: entry.sensitiveArguments))
    }

    /// What the call acts on, in the user's words. Guessed from the argument names the
    /// three servers actually use, in the order that reads best in a sentence — the
    /// panel says "Quit Safari", not "Quit (bundle id com.apple.Safari)".
    private static let targetKeys = [
        "label", "element", "app", "application", "appName", "device", "deviceName",
        "name", "title", "window", "url", "scene",
    ]

    private static func target(in arguments: [String: String]) -> String? {
        for key in targetKeys {
            if let value = arguments[key], !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: MCP result shapes

    /// An error the model can reason about, not a transport failure. MCP draws the
    /// distinction deliberately: a JSON-RPC error means the request was malformed, while
    /// `isError` means the tool ran and has something to say.
    static func toolError(_ text: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(true),
        ])
    }

    static func toolText(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    // MARK: The app's own tools

    private static func controlDescription(_ tool: String) -> String {
        switch tool {
        case "escalate_model":
            return """
                Move this run to a more capable model when the task is too difficult, \
                too uncertain, or too long-running. A run can only move upward.
                """
        case "request_approval":
            return """
                Ask the user to confirm something before you do it. Use it when you \
                believe an action deserves a check even though it wasn't stopped.
                """
        default:
            return tool
        }
    }

    private static func controlSchema(_ tool: String) -> JSONValue {
        switch tool {
        case "escalate_model":
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Why this run needs a more capable model."),
                    ]),
                ]),
                "required": .array([.string("reason")]),
            ])
        default:
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string")]),
                    "reason": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("action")]),
            ])
        }
    }
}

// MARK: - Talking to Claude Code

extension MCPApprovalProxy {

    /// The argv flag that turns this app binary into the stdio server Claude Code spawns.
    ///
    /// Claude Code launches its stdio MCP servers itself, so the thing in `--mcp-config`
    /// has to be an executable — but the approval gate needs the running app, where the
    /// panel and the user are. So the spawned process is this same binary in relay mode:
    /// it copies stdin to a Unix socket and the socket back to stdout, and every decision
    /// is made in the app. The relay knows nothing and decides nothing, which is the
    /// point — there is no second copy of the policy to drift.
    static let relayFlag = "--mcp-approval-relay"

    /// Must be called from the app's entry point *before* AppKit starts. In relay mode
    /// this never returns.
    static func runRelayIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: relayFlag),
              index + 1 < arguments.count else { return }
        runRelay(socketPath: arguments[index + 1])
        exit(0)
    }

    private static func runRelay(socketPath: String) {
        guard let socket = try? UnixSocket.connect(path: socketPath) else {
            // Claude Code surfaces an MCP server's stderr, so this sentence is the whole
            // diagnosis the user gets.
            FileHandle.standardError.write(Data("Gaithano Speak is not running.\n".utf8))
            exit(1)
        }
        // One direction on a thread, the other on this one, so a half-closed pipe ends
        // the process instead of hanging it.
        let outbound = Thread {
            pump(from: socket, to: FileHandle.standardOutput.fileDescriptor)
        }
        outbound.start()
        pump(from: FileHandle.standardInput.fileDescriptor, to: socket)
        close(socket)
    }

    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let sent = buffer.withUnsafeBytes {
                    write(destination, $0.baseAddress!.advanced(by: written), count - written)
                }
                guard sent > 0 else { return }
                written += sent
            }
        }
    }

    /// Host side of that relay: own the socket, and serve one Claude Code session per
    /// connection. Returns once `shutdown()` closes the listener.
    func listen(atPath path: String) async {
        let listener: Int32
        do {
            listener = try UnixSocket.listen(path: path)
        } catch {
            Log.agent.error("proxy couldn't open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { close(listener) }

        while !Task.isCancelled {
            guard let connection = try? await UnixSocket.acceptAsync(listener) else { break }
            await serve(LineTransport(readFD: connection, writeFD: connection))
        }
    }
}

// MARK: - Downstream servers

/// One real MCP server, running as a child process and reachable only from here.
///
/// Request and response are matched synchronously on a serial queue rather than by
/// running a reader loop and a table of pending continuations. That is a real
/// simplification and it costs nothing here: tool calls are serialised by the approval
/// gate anyway — the user can only answer one prompt at a time — so there is never more
/// than one call in flight per server.
///
/// `Process` and its pipes aren't `Sendable`, so as in `ClaudeCLIFormatter` the class is
/// the isolation boundary and its own queue is what makes that safe.
final class MCPDownstreamServer: @unchecked Sendable {

    struct ToolDescription: Sendable {
        var name: String
        var description: String
        var schema: JSONValue
        var sensitiveArguments: Set<String>
    }

    enum Failure: LocalizedError {
        case launch(String)
        case protocolError(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case let .launch(detail): return detail
            case let .protocolError(detail): return detail
            case let .serverError(detail): return detail
            }
        }
    }

    let id: MCPServerID
    private let process = Process()
    private let transport: LineTransport
    private let queue: DispatchQueue
    private var nextID = 1

    init(launch: MCPServerLaunch) throws {
        id = launch.id
        queue = DispatchQueue(label: "com.gaithano.speak.mcp.\(launch.id.rawValue)")

        let input = Pipe()
        let output = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = launch.workingDirectory
        process.standardInput = input
        process.standardOutput = output
        // Servers narrate to stderr. Letting it inherit ours keeps it in the app log
        // instead of filling a 64KB pipe nobody drains and wedging the server.
        process.standardError = FileHandle.standardError

        transport = LineTransport(readFD: output.fileHandleForReading.fileDescriptor,
                                  writeFD: input.fileHandleForWriting.fileDescriptor)
        do {
            try process.run()
        } catch {
            throw Failure.launch("couldn't start \(launch.executable.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func initialize() async throws {
        _ = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("gaithano-speak"),
                "version": .string("1.0.0"),
            ]),
        ]))
        try await notify(method: "notifications/initialized", params: .object([:]))
    }

    func listTools() async throws -> [ToolDescription] {
        let result = try await request(method: "tools/list", params: .object([:]))
        guard let tools = result["tools"]?.arrayValue else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            let schema = tool["inputSchema"] ?? .object(["type": .string("object")])
            return ToolDescription(name: name,
                                   description: tool["description"]?.stringValue ?? name,
                                   schema: schema,
                                   sensitiveArguments: Self.sensitiveArguments(in: schema))
        }
    }

    func callTool(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]))
    }

    func terminate() {
        transport.close()
        if process.isRunning { process.terminate() }
    }

    /// Which arguments the server itself says are secret.
    ///
    /// There is no one way to say it, so all four spellings in the wild are read:
    /// JSON Schema's `writeOnly` and `format: password`, and the `x-sensitive` /
    /// `sensitive` extensions MCP servers tend to invent. Anything a server doesn't
    /// declare is still caught by `AgentArgumentRedaction`'s name list — this is the
    /// half the spec asks for, not the whole defence.
    private static func sensitiveArguments(in schema: JSONValue) -> Set<String> {
        guard let properties = schema["properties"]?.objectValue else { return [] }
        var names: Set<String> = []
        for (name, definition) in properties {
            let flagged = definition["x-sensitive"]?.boolValue == true
                || definition["sensitive"]?.boolValue == true
                || definition["writeOnly"]?.boolValue == true
                || definition["format"]?.stringValue == "password"
            if flagged { names.insert(name) }
        }
        return names
    }

    // MARK: Transport

    private func notify(method: String, params: JSONValue) async throws {
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try transport.sendBlocking(JSONEncoder().encode(message))
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try exchange(method: method, params: params))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking, and only ever called on `queue`.
    private func exchange(method: String, params: JSONValue) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        try transport.sendBlocking(JSONEncoder().encode(message))

        // Skip anything that isn't the answer to this request: servers emit progress
        // notifications and log messages on the same stream, and one of them arriving
        // mid-call must not be mistaken for a result.
        while let data = try transport.readMessageBlocking() {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value["id"]?.numberValue == Double(id) else { continue }
            if let error = value["error"] {
                let detail = error["message"]?.stringValue ?? "unknown error"
                throw Failure.serverError(detail)
            }
            return value["result"] ?? .object([:])
        }
        throw Failure.protocolError("\(id) closed the connection before answering")
    }
}

// MARK: - JSON-RPC framing

/// Newline-delimited JSON over a pair of file descriptors — which is how MCP's stdio
/// transport is framed, and works unchanged over a socket, a pipe, or a process's stdio.
final class LineTransport: @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var buffer = Data()
    private var atEOF = false
    private let queue = DispatchQueue(label: "com.gaithano.speak.mcp.transport", qos: .userInitiated)

    init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
    }

    func readMessage() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try readMessageBlocking())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try sendBlocking(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func readMessageBlocking() throws -> Data? {
        readLock.lock()
        defer { readLock.unlock() }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return Data(line)
            }
            if atEOF { return nil }

            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = chunk.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else {
                atEOF = true
                // A final line with no trailing newline is still a message.
                if buffer.isEmpty { return nil }
                let remaining = buffer
                buffer.removeAll()
                return remaining
            }
        }
    }

    func sendBlocking(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let sent = write(writeFD, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard sent > 0 else { throw MCPDownstreamServer.Failure.protocolError("write failed") }
                written += sent
            }
        }
    }

    func close() {
        Darwin.close(readFD)
        if writeFD != readFD { Darwin.close(writeFD) }
    }
}

/// One message from Claude Code. `id` is absent on notifications, which is exactly how
/// the protocol says "no reply expected".
struct JSONRPCMessage: Decodable, Sendable {
    var id: JSONValue?
    var method: String
    var params: JSONValue?
}

struct JSONRPCResponse: Encodable, Sendable {
    var jsonrpc = "2.0"
    var id: JSONValue
    var result: JSONValue?
    var error: JSONValue?

    static func result(id: JSONValue, _ value: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: value, error: nil)
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: .object([
            "code": .number(Double(code)),
            "message": .string(message),
        ]))
    }
}

// MARK: - Unix sockets

enum UnixSocket {
    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case let .failed(detail) = self { return detail }
            return nil
        }
    }

    /// `sun_path` is 104 bytes on Darwin. Application Support leaves room, but a socket
    /// path that silently truncates would connect two processes to different files, so
    /// it is checked rather than assumed.
    static let maxPathLength = 100

    static func listen(path: String) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else {
            throw Failure.failed("socket path is too long for sun_path")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.failed("socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 4) { destination in
                strncpy(destination, path, maxPathLength)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure.failed("bind(\(path)) failed: \(String(cString: strerror(errno)))")
        }
        // The socket file itself is the boundary between "anything on this machine can
        // drive the desktop" and "only this user can", so it is created 0600.
        chmod(path, 0o600)
        guard Darwin.listen(fd, 4) == 0 else {
            close(fd)
            throw Failure.failed("listen() failed")
        }
        return fd
    }

    static func acceptAsync(_ listener: Int32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.accept(listener, nil, nil)
                if fd >= 0 {
                    continuation.resume(returning: fd)
                } else {
                    continuation.resume(throwing: Failure.failed("accept() failed"))
                }
            }
        }
    }

    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.failed("socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 4) { destination in
                strncpy(destination, path, maxPathLength)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure.failed("connect(\(path)) failed")
        }
        return fd
    }
}

// MARK: - JSON

/// Just enough JSON to proxy someone else's schema faithfully.
///
/// The proxy has to forward tool schemas and arguments it doesn't model — a downstream
/// server's input schema is its business, not ours — so values pass through as a tree
/// rather than as typed structs. `Sendable` because it crosses the actor boundary on
/// every call.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(values) = self { return values[key] }
        return nil
    }

    var stringValue: String? { if case let .string(value) = self { return value } else { return nil } }
    var boolValue: Bool? { if case let .bool(value) = self { return value } else { return nil } }
    var numberValue: Double? { if case let .number(value) = self { return value } else { return nil } }
    var arrayValue: [JSONValue]? { if case let .array(value) = self { return value } else { return nil } }
    var objectValue: [String: JSONValue]? { if case let .object(value) = self { return value } else { return nil } }

    /// One line, for the panel and the risk policy. Numbers lose a trailing `.0` because
    /// "press key 3.0" reads as a bug in the app rather than a coordinate.
    var displayString: String {
        switch self {
        case .null: return ""
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case let .string(value): return value
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
