import Foundation
import GRDB

/// One saved dictation: the raw transcript plus the formatted text that was
/// inserted, with light stats.
public struct DictationRecord: Codable, Equatable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var rawText: String
    public var formattedText: String
    public var durationSec: Double
    public var wordCount: Int
    public var engineID: String
    public var formatterID: String

    public init(id: Int64? = nil,
                createdAt: Date,
                rawText: String,
                formattedText: String,
                durationSec: Double,
                wordCount: Int,
                engineID: String,
                formatterID: String) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.formattedText = formattedText
        self.durationSec = durationSec
        self.wordCount = wordCount
        self.engineID = engineID
        self.formatterID = formatterID
    }

    public static let databaseTableName = "dictation"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persisted dictionary entry (GRDB-backed twin of `DictionaryEntry`).
extension DictionaryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictionaryEntry"

    public init(row: Row) {
        self.init(
            id: row["id"],
            phrase: row["phrase"],
            replacement: row["replacement"],
            matchCase: row["matchCase"],
            sortOrder: row["sortOrder"]
        )
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["phrase"] = phrase
        container["replacement"] = replacement
        container["matchCase"] = matchCase
        container["sortOrder"] = sortOrder
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
