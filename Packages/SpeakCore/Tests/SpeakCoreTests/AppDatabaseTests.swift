import Testing
import Foundation
@testable import SpeakCore

@Suite("App database")
struct AppDatabaseTests {

    @Test("Migrations create a usable schema and round-trip a dictation")
    func saveAndFetch() throws {
        let db = try AppDatabase.inMemory()
        let record = DictationRecord(
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            rawText: "um hello world",
            formattedText: "Hello world.",
            durationSec: 3.0,
            wordCount: 2,
            engineID: EngineID.parakeet.rawValue,
            formatterID: FormatterID.foundationModel.rawValue
        )
        let saved = try db.save(record)
        #expect(saved.id != nil)

        let all = try db.recentDictations()
        #expect(all.count == 1)
        #expect(all.first?.formattedText == "Hello world.")
    }

    @Test("Recent dictations are newest-first")
    func ordering() throws {
        let db = try AppDatabase.inMemory()
        for i in 0..<3 {
            try db.save(DictationRecord(
                createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                rawText: "r\(i)", formattedText: "f\(i)",
                durationSec: 1, wordCount: 1,
                engineID: "parakeet", formatterID: "deterministic"))
        }
        let all = try db.recentDictations()
        #expect(all.map(\.formattedText) == ["f2", "f1", "f0"])
    }

    @Test("Aggregate stats sum words and average WPM")
    func aggregate() throws {
        let db = try AppDatabase.inMemory()
        try db.save(DictationRecord(createdAt: Date(), rawText: "a", formattedText: "a",
                                    durationSec: 60, wordCount: 100,
                                    engineID: "parakeet", formatterID: "deterministic"))
        try db.save(DictationRecord(createdAt: Date(), rawText: "b", formattedText: "b",
                                    durationSec: 60, wordCount: 200,
                                    engineID: "parakeet", formatterID: "deterministic"))
        let stats = try db.aggregateStats()
        #expect(stats.totalDictations == 2)
        #expect(stats.totalWords == 300)
        #expect(stats.averageWPM == 150) // (100 + 200) / 2
    }

    @Test("Dictionary entries persist and produce a PersonalDictionary")
    func dictionaryRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        try db.upsert(DictionaryEntry(phrase: "gaithano", replacement: "Gaithano", sortOrder: 0))
        try db.upsert(DictionaryEntry(phrase: "js", replacement: "JavaScript", sortOrder: 1))

        let entries = try db.allDictionaryEntries()
        #expect(entries.count == 2)

        let pd = try db.personalDictionary()
        #expect(pd.apply("gaithano uses js") == "Gaithano uses JavaScript")
    }

    @Test("Deleting a dictionary entry removes it")
    func deleteEntry() throws {
        let db = try AppDatabase.inMemory()
        let saved = try db.upsert(DictionaryEntry(phrase: "x", replacement: "Y"))
        try db.deleteDictionaryEntry(id: saved.id!)
        #expect(try db.allDictionaryEntries().isEmpty)
    }
}
