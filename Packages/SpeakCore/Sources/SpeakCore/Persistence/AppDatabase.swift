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

        // A real migration rather than a schema bump: dictionary entries are typed
        // by hand and must survive. (`eraseDatabaseOnSchemaChange` above only fires
        // in DEBUG, and this is exactly the data it would throw away.)
        migrator.registerMigration("v2_dictionary_learning") { db in
            try db.alter(table: "dictionaryEntry") { t in
                t.add(column: "source", .text).notNull().defaults(to: DictionaryEntrySource.manual.rawValue)
            }

            try db.create(table: "learnedTerm") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("phrase", .text).notNull()
                t.column("replacement", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("occurrences", .integer).notNull().defaults(to: 0)
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("state", .text).notNull().defaults(to: LearnedTerm.State.pending.rawValue)
            }
            // One row per pair — the count is the whole point, so duplicates would
            // silently stop anything ever reaching its threshold.
            try db.create(indexOn: "learnedTerm", columns: ["phrase", "replacement"], options: .unique)
            try db.create(indexOn: "learnedTerm", columns: ["state"])
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

    // MARK: - Learning queries

    /// Fold one utterance's observations into the learning table and act on any
    /// that crossed their threshold.
    ///
    /// The whole transaction is one write so a crash between "count it" and
    /// "promote it" can't leave a term stuck one occurrence short forever.
    @discardableResult
    public func learn(from observations: [TermObservation],
                      policy: LearningPolicy = .default,
                      now: Date = Date()) throws -> LearningOutcome {
        guard !observations.isEmpty else { return LearningOutcome() }

        return try dbWriter.write { db in
            var outcome = LearningOutcome()

            for observation in observations {
                var term: LearnedTerm
                if var existing = try LearnedTerm
                    .filter(Column("phrase") == observation.phrase
                            && Column("replacement") == observation.replacement)
                    .fetchOne(db) {
                    // Settled means settled — don't keep counting something the
                    // user dismissed or that's already a dictionary entry.
                    guard existing.state == .pending else { continue }
                    existing.occurrences += 1
                    existing.lastSeen = now
                    try existing.update(db)
                    term = existing
                } else {
                    term = LearnedTerm(phrase: observation.phrase,
                                       replacement: observation.replacement,
                                       kind: observation.kind,
                                       occurrences: 1,
                                       firstSeen: now,
                                       lastSeen: now)
                    try term.insert(db)
                }

                switch policy.decision(for: term) {
                case .hold:
                    continue
                case .suggest:
                    outcome.suggested.append(term)
                case .accept:
                    // A rule the user wrote by hand wins. Mark the term accepted
                    // anyway so it stops being counted and re-offered.
                    let collides = try DictionaryEntry
                        .filter(Column("phrase") == observation.phrase)
                        .fetchCount(db) > 0
                    term.state = .accepted
                    try term.update(db)
                    guard !collides else { continue }
                    var entry = term.asDictionaryEntry
                    try entry.insert(db)
                    outcome.accepted.append(entry)
                }
            }

            return outcome
        }
    }

    /// Terms waiting on the user, most-repeated first.
    public func pendingLearnedTerms(policy: LearningPolicy = .default) throws -> [LearnedTerm] {
        try dbWriter.read { db in
            try LearnedTerm
                .filter(Column("state") == LearnedTerm.State.pending.rawValue)
                .order(Column("occurrences").desc, Column("lastSeen").desc)
                .fetchAll(db)
                .filter { policy.decision(for: $0) == .suggest }
        }
    }

    /// Promote a suggestion into the dictionary.
    @discardableResult
    public func acceptLearnedTerm(id: Int64) throws -> DictionaryEntry? {
        try dbWriter.write { db in
            guard var term = try LearnedTerm.fetchOne(db, key: id) else { return nil }
            term.state = .accepted
            try term.update(db)

            guard try DictionaryEntry.filter(Column("phrase") == term.phrase).fetchCount(db) == 0
            else { return nil }
            var entry = term.asDictionaryEntry
            try entry.insert(db)
            return entry
        }
    }

    /// Refuse a suggestion. Permanent — it is never proposed again.
    public func dismissLearnedTerm(id: Int64) throws {
        try dbWriter.write { db in
            guard var term = try LearnedTerm.fetchOne(db, key: id) else { return }
            term.state = .dismissed
            try term.update(db)
        }
    }

    /// Wipe everything learning has recorded, including its promoted entries.
    /// Dismissals go too — this is a reset, not a re-offer.
    public func forgetLearnedTerms() throws {
        _ = try dbWriter.write { db in
            try DictionaryEntry
                .filter(Column("source") == DictionaryEntrySource.learned.rawValue)
                .deleteAll(db)
            try LearnedTerm.deleteAll(db)
        }
    }
}
