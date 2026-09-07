import Foundation
import SpeakCore

/// How to start the downstream MCP servers, and what to hand Claude Code so that the
/// proxy is the only one it can see.
///
/// `--mcp-config` names exactly one server here, and `--strict-mcp-config` stops the
/// user's own `~/.claude.json` servers from joining it. Both matter: a filesystem MCP
/// the user configured last month for their own work would otherwise appear in this
/// session as a fully-functional file tool, sitting beside a proxy that carefully
/// refuses to expose one.
enum MCPServerConfig {

    // MARK: - What Claude Code is told

    /// The one server Claude Code connects to. `command` is this app's own binary in
    /// relay mode — see `MCPApprovalProxy.relayFlag` for why the server has to be a
    /// separate process and the decisions can't be.
    static func proxyConfigJSON(appExecutable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/usr/bin/false"),
                                socketPath: String = socketPath) -> String {
        let value = JSONValue.object([
            "mcpServers": .object([
                MCPApprovalProxy.serverName: .object([
                    "type": .string("stdio"),
                    "command": .string(appExecutable.path),
                    "args": .array([
                        .string(MCPApprovalProxy.relayFlag),
                        .string(socketPath),
                    ]),
                ]),
            ]),
        ])
        guard let data = try? JSONEncoder().encode(value) else { return #"{"mcpServers":{}}"# }
        return String(decoding: data, as: UTF8.self)
    }

    /// What to pass to `--allowed-tools`. One entry, because Claude Code prefixes every
    /// tool from an MCP server with the server's name, so this covers the whole proxy
    /// and nothing else.
    static let allowedToolsArgument = "mcp__\(MCPApprovalProxy.serverName)"

    /// What to pass to `--disallowed-tools`. Redundant with the allowlist and worth
    /// sending anyway: it means a misconfigured allowlist and a misconfigured launch
    /// have to fail together before Claude gets a file or shell tool.
    static let disallowedToolsArgument = AgentToolAllowlist.deniedBuiltInTools.joined(separator: ",")

    static let socketPath: String = supportDirectory
        .appendingPathComponent("agent-proxy.sock").path

    /// An empty directory the downstream servers run in, for the same reason
    /// `ClaudeCLIFormatter` has one: a server that resolves relative paths, writes a
    /// cache, or looks for project config finds nothing of the user's here.
    static let workingDirectory: URL = {
        let directory = supportDirectory.appendingPathComponent("agent-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("GaithanoSpeak", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    // MARK: - Downstream servers

    /// User overrides, straight from Settings. Blank means "search the usual places" —
    /// the same bargain `ClaudeCLIFormatter.resolveExecutable` makes, and for the same
    /// reason: a launchd-started GUI app has a bare PATH, so nothing is ever simply
    /// "on the path" the way it is in a shell.
    struct Paths: Sendable, Equatable {
        var macosServer: String = ""
        var smartThingsAdapter: String = ""
        var nodeRunner: String = ""

        init(macosServer: String = "", smartThingsAdapter: String = "", nodeRunner: String = "") {
            self.macosServer = macosServer
            self.smartThingsAdapter = smartThingsAdapter
            self.nodeRunner = nodeRunner
        }
    }

    enum Availability: Sendable, Equatable {
        case available
        /// Carries what to tell the user, not just that something is missing. The spec
        /// asks failures to "name the unavailable capability" and offer a way forward.
        case unavailable(String)
    }

    /// Every server that can be started. A missing one is left out rather than returned
    /// broken: the proxy then has no tools for that capability, calls to it come back as
    /// an error the model can explain, and the other two keep working. Failing the whole
    /// session because SmartThings isn't installed would be the wrong trade — most
    /// requests never touch it.
    static func launches(paths: Paths = Paths()) -> [MCPServerLaunch] {
        [macOSLaunch(paths), chromeLaunch(paths), smartThingsLaunch(paths)].compactMap { $0 }
    }

    static func availability(paths: Paths = Paths()) -> [MCPServerID: Availability] {
        [
            .macos: macOSLaunch(paths) != nil
                ? .available
                : .unavailable("macOS control needs `mcp-macos-cua`. Install it, or set its path in Settings."),
            .chrome: chromeLaunch(paths) != nil
                ? .available
                : .unavailable("Chrome control needs Node. Install Node, then add the Playwright MCP extension to Chrome."),
            .smartthings: smartThingsLaunch(paths) != nil
                ? .available
                : .unavailable("SmartThings needs `smartthings-cli` and the adapter. Set the adapter path in Settings."),
            .control: .available,
        ]
    }

    // MARK: macOS

    private static func macOSLaunch(_ paths: Paths) -> MCPServerLaunch? {
        guard let executable = resolve(explicit: paths.macosServer, names: ["mcp-macos-cua"]) else {
            return nil
        }
        return MCPServerLaunch(id: .macos, executable: executable, arguments: [])
    }

    // MARK: Chrome

    /// Microsoft's `playwright-mcp`, run through `npx` so it stays current without the
    /// app shipping a Node dependency.
    ///
    /// `--extension` is the whole point of this configuration: it attaches to the
    /// browser the user is already signed into, through the Playwright MCP extension,
    /// instead of launching a fresh automation profile. Their cookies, SSO sessions, and
    /// 2FA state are what make "book the thing I was looking at" possible at all — a
    /// clean profile would sit at a login wall the assistant has no way through. This is
    /// also why `--isolated` and `--user-data-dir` must never be added here: either one
    /// silently restores the empty profile this flag exists to avoid.
    private static func chromeLaunch(_ paths: Paths) -> MCPServerLaunch? {
        guard let runner = resolve(explicit: paths.nodeRunner, names: ["npx"]) else { return nil }
        return MCPServerLaunch(id: .chrome,
                               executable: runner,
                               arguments: ["-y", "@playwright/mcp@latest", "--extension", "--browser", "chrome"])
    }

    // MARK: SmartThings

    /// The adapter around `smartthings-cli`.
    ///
    /// The CLI is never addressable from the model's side — there is no tool that takes
    /// a command string, and the adapter is what turns a bounded call with validated
    /// arguments into a process invocation. That separation is the reason SmartThings
    /// can expose "every device command the account has" without exposing a shell.
    private static func smartThingsLaunch(_ paths: Paths) -> MCPServerLaunch? {
        guard let executable = resolve(explicit: paths.smartThingsAdapter,
                                       names: ["smartthings-mcp"]) else { return nil }
        return MCPServerLaunch(id: .smartthings, executable: executable, arguments: [])
    }

    // MARK: Finding binaries

    /// Where npm, bun, homebrew, and uv actually put things, in the order they win.
    private static let searchDirectories = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.bun/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    static func resolve(explicit: String, names: [String]) -> URL? {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // An explicit path that doesn't work is an error the user can fix, not a
            // reason to quietly run some other binary with the same name.
            return FileManager.default.isExecutableFile(atPath: trimmed)
                ? URL(fileURLWithPath: trimmed)
                : nil
        }
        for directory in searchDirectories {
            for name in names {
                let path = "\(directory)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }
}

/// Everything needed to start one downstream MCP server.
struct MCPServerLaunch: Sendable {
    var id: MCPServerID
    var executable: URL
    var arguments: [String]
    /// `ClaudeCLIFormatter.childEnvironment()` rather than a copy of it: the PATH repair
    /// a launchd-started GUI app needs is the same repair here, and one definition of it
    /// is what keeps the two from drifting. The thinking variables it also sets are inert
    /// for a server that isn't Claude Code.
    var environment: [String: String] = ClaudeCLIFormatter.childEnvironment()
    var workingDirectory: URL = MCPServerConfig.workingDirectory
}
