import Foundation
import os

/// Central logging + signposting. Signpost intervals (`capture`, `asr`, `format`,
/// `insert`, `answer`) are what we inspect in Instruments to check the latency budget.
enum Log {
    static let subsystem = "com.gaithano.speak"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let format = Logger(subsystem: subsystem, category: "format")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    static let talk = Logger(subsystem: subsystem, category: "talk")
    /// Agent Mode: the Claude Code session, the MCP proxy, screenshots, and preflight.
    /// One category rather than four, because reading an agent run means reading all of
    /// them interleaved — a tool call, the approval it waited on, and the capture that
    /// verified it are one story.
    static let agent = Logger(subsystem: subsystem, category: "agent")

    static let signposter = OSSignposter(subsystem: subsystem, category: "latency")
}
