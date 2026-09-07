import Foundation
import os
import SpeakCore

private let agentLog = Logger(subsystem: Log.subsystem, category: "agent")

/// The app-private temporary storage one Agent Mode conversation lives in: the empty
/// working directory the Claude Code session runs from, the screenshots retained for
/// its 15 minutes, and the tool log.
///
/// **Retention is enforced by deletion, not by asking callers to be careful.** The
/// spec forbids agent screenshots from reaching dictation history, any permanent
/// user-visible history, or the clipboard. Nothing in this file writes to the
/// database or to `NSPasteboard`, and — more usefully — every path handed out points
/// inside a directory that is removed when the conversation resets, expires, or the
/// app quits. A caller that stashed a URL in a history row would be left holding a
/// path to nothing, which is a bug that shows up immediately rather than a leak that
/// shows up in a support thread six months later. `userRequestedCopy(of:)` is the one
/// sanctioned way bytes leave, and it is named so that calling it without a user
/// gesture reads wrong.
///
/// **Screenshots are stored outside the runtime's working directory on purpose.** The
/// runtime hands Claude an empty cwd; if retained captures lived in it, a future
/// Claude Code release that adds a file tool the allowlist doesn't know about yet
/// would find a folder full of pictures of the user's screen. Two independent
/// barriers — no file tools, and nothing to read even if there were — cost one extra
/// directory.
///
/// An `actor` rather than a lock: every operation here is filesystem I/O off the main
/// thread, and the panel, the runtime, and the screenshot service all reach it
/// concurrently.
actor AgentScratchStore {

    /// Where a conversation's directories live.
    ///
    /// The Darwin per-user temp directory, not Application Support: this data is
    /// defined to be worthless after fifteen minutes, and putting it somewhere the OS
    /// already wipes on reboot means a crash that outlives even `purgeStale()` still
    /// cleans itself up. It is `0700` and per-user before we touch it; the subtree we
    /// create is `0700` again so a same-user process can't wander in either.
    static let defaultRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("GaithanoSpeak/agent", isDirectory: true)

    private let root: URL
    private let fileManager = FileManager.default
    /// One directory per conversation, named by a UUID so a stale directory left by a
    /// crash is never mistaken for the live one.
    private var conversationID = UUID()

    init(root: URL = AgentScratchStore.defaultRoot) {
        self.root = root
    }

    // MARK: - Layout

    private var conversationDirectory: URL {
        root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    /// The empty directory the Claude Code session runs from.
    ///
    /// Empty is the requirement, not a detail: `ClaudeCLIFormatter` keeps its own
    /// `claude-cwd` for the same reason, which is that CLAUDE.md discovery walks up
    /// from the cwd and would otherwise pull a real project's instructions and memory
    /// into an unrelated request. Agent Mode can't share that folder — the two run
    /// concurrently and this one is deleted on conversation reset.
    func runtimeWorkingDirectory() throws -> URL {
        try directory(named: "cwd")
    }

    /// Where retained screenshots go. Deliberately a sibling of `cwd`, never a child.
    private func screenshotDirectory() throws -> URL {
        try directory(named: "shots")
    }

    private func directory(named name: String) throws -> URL {
        let url = conversationDirectory.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        return url
    }

    // MARK: - Screenshots

    /// Write a capture and hand back the reference the panel draws a thumbnail from.
    ///
    /// The bytes go to the model as MCP image content; this copy exists only so the
    /// panel has something to render, which is why the two are separate values and
    /// why `AgentScreenshot` carries a URL and no data. See `ScreenshotService`.
    func store(jpeg: Data, capturedAt: Date) throws -> AgentScreenshot {
        let id = UUID()
        // An opaque name. A timestamped or numbered one would let anything that got
        // hold of the directory enumerate the run by guessing, and it buys nothing:
        // the ordering the panel needs is already in `capturedAt`.
        let url = try screenshotDirectory().appendingPathComponent("\(id.uuidString).jpg")
        try jpeg.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return AgentScreenshot(id: id, capturedAt: capturedAt, url: url)
    }

    /// Read a retained screenshot back, for a copy or export the user explicitly asked
    /// for.
    ///
    /// The spec's carve-out is "never the clipboard *unless the user explicitly
    /// asks*", so the carve-out gets a name. Everything else in the app reaches
    /// screenshots as `Data` from the capture that produced them; if a future call
    /// site wants the file, it goes through here and the name makes the missing user
    /// gesture obvious at review.
    func userRequestedCopy(of screenshot: AgentScreenshot) throws -> Data {
        agentLog.info("Exporting an agent screenshot at the user's request")
        return try Data(contentsOf: screenshot.url)
    }

    // MARK: - Tool log

    /// Append one line to the conversation's tool log.
    ///
    /// It lives here rather than in the database because the spec puts it under the
    /// same 15-minute retention as the screenshots — "do not persist screenshots or
    /// tool logs in normal dictation history". A GRDB table would outlive the
    /// conversation by default and need a deletion path nobody would remember to run.
    func appendToolLog(_ line: String) {
        do {
            let url = conversationDirectory.appendingPathComponent("tools.log")
            try fileManager.createDirectory(at: conversationDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let entry = "\(ISO8601DateFormatter().string(from: Date()))\t\(line)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(entry.utf8).write(to: url, options: [.atomic])
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            // A tool log that can't be written must not take a run down with it.
            agentLog.error("Tool log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifetime

    /// End the current conversation and start a fresh one.
    ///
    /// Called on explicit reset and on idle expiry. Both delete: the spec treats an
    /// expired conversation exactly like a reset one, because from the user's side
    /// fifteen minutes of silence and pressing "new conversation" mean the same thing.
    func reset() {
        remove(conversationDirectory)
        conversationID = UUID()
    }

    /// Reset if the conversation has gone idle past `AgentConversation.idleTimeout`.
    /// Returns whether it did, so the coordinator can tear the session down to match.
    func expireIfIdle(_ conversation: AgentConversation, now: Date = Date()) -> Bool {
        guard conversation.isExpired(at: now) else { return false }
        agentLog.info("Agent conversation idle past its window; deleting its scratch data")
        reset()
        return true
    }

    /// Delete everything, current conversation included. For normal termination.
    func purgeAll() {
        remove(root)
        conversationID = UUID()
    }

    /// Delete every conversation directory that isn't the live one.
    ///
    /// Run at launch, where "isn't the live one" means all of them: the spec requires
    /// that a shutdown which couldn't clean up — a crash, a force quit, a panic during
    /// a run — doesn't leave screenshots of the user's screen sitting in temp until
    /// the next reboot.
    func purgeStale() {
        let live = conversationDirectory.lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: nil)
        else { return }
        var removed = 0
        for entry in entries where entry.lastPathComponent != live {
            remove(entry)
            removed += 1
        }
        if removed > 0 {
            agentLog.info("Removed \(removed, privacy: .public) abandoned agent scratch directories")
        }
    }

    private func remove(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — reboot, or a second purge. Not worth a log line.
        } catch {
            agentLog.error("Could not delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
