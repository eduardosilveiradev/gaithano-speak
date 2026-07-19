import Foundation
import os

/// Central logging + signposting. Signpost intervals (`capture`, `asr`, `format`,
/// `insert`) are what we inspect in Instruments to check the latency budget.
enum Log {
    static let subsystem = "com.gaithano.speak"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let format = Logger(subsystem: subsystem, category: "format")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")

    static let signposter = OSSignposter(subsystem: subsystem, category: "latency")
}
