import Foundation
import GRDB

/// Owns the SQLite connection, schema migrations, and the queries the UI needs.
/// Constructible in-memory for tests.
public final class AppDatabase: Sendable {
    private let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    /// On-disk database at ~/Library/Application Support/GaithanoSpeak/gaithano.sqlite.
    public static func onDisk(fileManager: FileManager = .default) throws -> AppDatabase {
        let appSupport = try fileManager.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: nil,
                                             create: true)
        let dir = appSupport.appendingPathComponent("GaithanoSpeak", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gaithano.sqlite")
        let pool = try DatabasePool(path: url.path)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "dictation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("rawText", .text).notNull()
                t.column("formattedText", .text).notNull()
                t.column("durationSec", .double).notNull().defaults(to: 0)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("engineID", .text).notNull()
                t.column("formatterID", .text).notNull()
            }
            try db.create(indexOn: "dictation", columns: ["createdAt"])

            try db.create(table: "dictionaryEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("phrase", .text).notNull()
                t.column("replacement", .text).notNull()
                t.column("matchCase", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }

    // MARK: - Dictation queries

    @discardableResult
    public func save(_ record: DictationRecord) throws -> DictationRecord {
        try dbWriter.write { db in
            var r = record
            try r.insert(db)
            return r
        }
    }

    public func recentDictations(limit: Int = 200) throws -> [DictationRecord] {
        try dbWriter.read { db in
            try DictationRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func deleteDictation(id: Int64) throws {
        _ = try dbWriter.write { db in
            try DictationRecord.deleteOne(db, key: id)
        }
    }

    public func aggregateStats() throws -> AggregateStats {
        try dbWriter.read { db in
            let count = try DictationRecord.fetchCount(db)
            let totalWords = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount), 0) FROM dictation") ?? 0
            // Average WPM across records that have a positive duration.
            let avgWPM = try Double.fetchOne(db, sql: """
                SELECT COALESCE(AVG(wordCount / (durationSec / 60.0)), 0)
                FROM dictation WHERE durationSec > 0
                """) ?? 0
            return AggregateStats(totalDictations: count, totalWords: totalWords, averageWPM: avgWPM)
        }
    }

    // MARK: - Dictionary queries

    public func allDictionaryEntries() throws -> [DictionaryEntry] {
        try dbWriter.read { db in
            try DictionaryEntry.order(Column("sortOrder"), Column("id")).fetchAll(db)
        }
    }

    @discardableResult
    public func upsert(_ entry: DictionaryEntry) throws -> DictionaryEntry {
        try dbWriter.write { db in
            var e = entry
            try e.save(db)
            return e
        }
    }

    public func deleteDictionaryEntry(id: Int64) throws {
        _ = try dbWriter.write { db in
            try DictionaryEntry.deleteOne(db, key: id)
        }
    }

    /// A `PersonalDictionary` snapshot for the pipeline.
    public func personalDictionary() throws -> PersonalDictionary {
        PersonalDictionary(entries: try allDictionaryEntries())
    }
}
