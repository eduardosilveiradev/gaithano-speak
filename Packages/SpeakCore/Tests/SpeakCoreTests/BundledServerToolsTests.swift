import Testing
import Foundation
@testable import SpeakCore

/// The allowlist and the servers that satisfy it have to name the same tools.
///
/// This is the bug that made Agent Mode's macOS half useless before either half had
/// ever run: the list was drafted against `mcp-macos-cua`, which turned out to name
/// two of the sixteen tools on it. Nothing failed. The proxy filters what it does not
/// recognise, and filtering *is* the design, so a server whose every tool is unknown
/// looks exactly like a server behaving correctly — the only symptom is an assistant
/// that quietly cannot do anything.
///
/// So the pairing is asserted rather than trusted. A tool renamed on either side now
/// fails here, in the second it takes to run these, instead of during a live run.
@Suite("Bundled MCP servers match the allowlist")
struct BundledServerToolsTests {

    /// Walk up from this file to the repository root. The servers are app-target
    /// resources, so SpeakCore cannot reach them as a bundle — but it can read them
    /// as text, and reading them is all this needs.
    private static func serverSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeakCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SpeakCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("GaithanoSpeak/Resources/MCPServers/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `name: "…"` sitting at a tool declaration's indentation.
    private static func declaredTools(in source: String) -> Set<String> {
        var found: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name: \""), trimmed.hasSuffix("\","),
                  line.hasPrefix("    name:") else { continue }
            let body = trimmed.dropFirst("name: \"".count).dropLast("\",".count)
            found.insert(String(body))
        }
        return found
    }

    @Test("The macOS server implements exactly the allowlisted macOS tools")
    func macOSServerMatches() throws {
        let declared = Self.declaredTools(in: try Self.serverSource("macos.js"))
        #expect(declared == AgentToolAllowlist.macosTools,
                """
                macos.js and AgentToolAllowlist.macosTools disagree.
                Only in the server: \(declared.subtracting(AgentToolAllowlist.macosTools).sorted())
                Only in the allowlist: \(AgentToolAllowlist.macosTools.subtracting(declared).sorted())
                """)
    }

    @Test("The SmartThings adapter implements exactly the allowlisted SmartThings tools")
    func smartThingsServerMatches() throws {
        let declared = Self.declaredTools(in: try Self.serverSource("smartthings.js"))
        #expect(declared == AgentToolAllowlist.smartthingsTools,
                """
                smartthings.js and AgentToolAllowlist.smartthingsTools disagree.
                Only in the server: \(declared.subtracting(AgentToolAllowlist.smartthingsTools).sorted())
                Only in the allowlist: \(AgentToolAllowlist.smartthingsTools.subtracting(declared).sorted())
                """)
    }

    /// The servers must not grow a tool the allowlist would refuse on sight. Such a
    /// tool is unreachable, so shipping one is only a way to mislead the next reader
    /// about what the boundary permits.
    @Test("Neither server ships a tool the forbidden-name check would reject")
    func serversShipNothingForbidden() throws {
        for file in ["macos.js", "smartthings.js"] {
            for tool in Self.declaredTools(in: try Self.serverSource(file)) {
                #expect(!AgentToolAllowlist.isForbiddenName(tool),
                        "\(file) declares \(tool), which the forbidden-name check rejects")
            }
        }
    }

    /// The thing that made the off-the-shelf macOS server unusable: model-supplied
    /// text reaching a shell. Nothing in these files may build a command string.
    @Test("Neither server uses a shell")
    func serversNeverUseAShell() throws {
        for file in ["macos.js", "smartthings.js"] {
            let source = try Self.serverSource(file)
            // `exec` and `execSync` take a command *string* and run it through /bin/sh;
            // `execFile` takes an argument array and does not. The distinction is the
            // whole reason a window title containing a quote is a title here.
            #expect(!source.contains("execSync"), "\(file) uses execSync, which runs a shell")
            #expect(!source.contains("child_process\").exec("), "\(file) uses exec, which runs a shell")
            #expect(!source.contains("shell: true"), "\(file) enables a shell")
        }
    }
}
