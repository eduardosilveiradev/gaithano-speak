import AppKit
import Darwin
import SpeakCore

/// Delivers a dictated utterance into a running Claude Code session: find the app
/// hosting it, bring it to the front, type the words in, and press Return.
///
/// **How the session is found.** Not by guessing at a list of terminal bundle ids —
/// Claude Code runs in Terminal, iTerm, Warp, Ghostty, VS Code, and whatever ships
/// next. Instead this walks the process tree: every running process named `claude`,
/// up through its parents, until it reaches a pid that `NSRunningApplication` knows
/// about. That pid is the GUI app hosting the session, whatever it happens to be.
/// A session running under a daemon or an ssh login has no such ancestor, so it
/// simply drops out — which is the correct answer, since we couldn't type into it.
///
/// **Why paste and not AppleScript.** Terminals disagree about scripting, and the
/// ones that support it disagree about which pane is "current". A ⌘V into the
/// frontmost window is what the user would have done by hand, and it works in every
/// host including Electron ones.
@MainActor
struct ClaudeCodeHandoff {
    enum Failure: LocalizedError {
        case noSession
        case activationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSession:
                return "No Claude Code session found"
            case let .activationFailed(name):
                return "Couldn't switch to \(name)"
            }
        }
    }

    private let paste = PasteboardInserter()

    /// Type `text` into the session and optionally submit it.
    ///
    /// `bundleID` non-empty pins the target app and skips discovery entirely, for the
    /// case where the walk finds the wrong session (two terminals, two projects).
    func send(_ text: String, submit: Bool, bundleID: String) async throws {
        guard let app = Self.hostApplication(preferredBundleID: bundleID) else {
            throw Failure.noSession
        }

        if !app.isActive {
            app.activate()
            // Activation is asynchronous and the paste goes to whoever has focus, so
            // this waits for it rather than sleeping a hopeful fixed interval.
            guard await Self.waitForActivation(of: app) else {
                throw Failure.activationFailed(app.localizedName ?? "the terminal")
            }
        }

        try await paste.insert(text)

        guard submit else { return }
        // The paste is synthesized too, and the host needs a beat to have processed
        // it — a Return that overtakes the text submits an empty prompt.
        try? await Task.sleep(nanoseconds: 120_000_000)
        try Self.pressReturn()
    }

    // MARK: - Finding the session

    /// The GUI app hosting a Claude Code session, or nil if there isn't one.
    ///
    /// With more than one running, the newest wins: pids increase, so the highest-pid
    /// `claude` is the session the user most recently started, which is the one they
    /// are most likely talking about. A currently-frontmost host beats that — if
    /// they're looking at a session, that's the session.
    static func hostApplication(preferredBundleID: String = "") -> NSRunningApplication? {
        let pinned = preferredBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: pinned).first
        }

        let table = processTable()
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let hosts = table
            .filter { isClaudeCode($0.pid) }
            .sorted { $0.pid > $1.pid }            // newest session first
            .compactMap { guiAncestor(of: $0.pid, in: table, excluding: ourPID) }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           hosts.contains(where: { $0.processIdentifier == frontmost.processIdentifier }) {
            return frontmost
        }
        return hosts.first
    }

    private struct Proc {
        let pid: pid_t
        let ppid: pid_t
    }

    /// Whether a pid is a Claude Code CLI.
    ///
    /// Not by `p_comm`, which is the obvious way and the wrong one: the native
    /// installer's binary lives at `~/.local/share/claude/versions/<version>`, so the
    /// accounting name is a version number like "2.1.224" and matching on "claude"
    /// finds nothing. The executable path carries the identity in both layouts — an
    /// npm install ends in `/claude`, the native one sits under `/claude/versions/`.
    /// The `/claude/` test is case-sensitive on purpose so the Claude desktop app
    /// (`/Applications/Claude.app/...`) doesn't match.
    private static func isClaudeCode(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        if (path as NSString).lastPathComponent == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    /// Every process, from `sysctl`. One call, no shelling out — this runs on the
    /// dictation path.
    private static func processTable() -> [Proc] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        // The table can grow between sizing and reading; `size` comes back updated
        // with what we actually got, so trust it rather than `count`.
        guard procs.withUnsafeMutableBytes({ buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return sysctl(&name, 4, base, &size, nil, 0) == 0
        }) else { return [] }

        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
            Proc(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid)
        }
    }

    /// Walk up from `pid` until a parent turns out to be a GUI application.
    private static func guiAncestor(of pid: pid_t,
                                    in table: [Proc],
                                    excluding ourPID: pid_t) -> NSRunningApplication? {
        var parents: [pid_t: pid_t] = [:]
        for proc in table { parents[proc.pid] = proc.ppid }

        var current = pid
        // Bounded rather than `while true`: a corrupt table shouldn't hang dictation.
        for _ in 0..<24 {
            guard let parent = parents[current], parent > 1 else { return nil }
            if parent != ourPID,
               let app = NSRunningApplication(processIdentifier: parent),
               app.bundleIdentifier != nil {
                return app
            }
            current = parent
        }
        return nil
    }

    // MARK: - Driving it

    /// Poll until the app actually has focus. ~1s cap: if activation hasn't landed by
    /// then something is holding focus (a modal, Stage Manager mid-animation) and
    /// pasting into whatever *does* have it would be worse than failing.
    private static func waitForActivation(of app: NSRunningApplication) async -> Bool {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if app.isActive { return true }
        }
        return false
    }

    private static func pressReturn() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertionError.noEventSource
        }
        let returnKey: CGKeyCode = 36
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw InsertionError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
