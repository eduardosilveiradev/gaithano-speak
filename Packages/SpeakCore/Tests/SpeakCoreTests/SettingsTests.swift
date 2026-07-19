import Testing
import Foundation
@testable import SpeakCore

@Suite("App settings persistence")
struct SettingsTests {

    @Test("Round-trips through a UserDefaults store")
    func roundTrip() throws {
        let defaults = UserDefaults(suiteName: "gaithano.test.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)

        var s = AppSettings.default
        s.hotkey = .leftOption
        s.pauseAudioWhileListening = false
        s.playSounds = false
        store.save(s)

        let loaded = store.load()
        #expect(loaded.hotkey == .leftOption)
        #expect(loaded.pauseAudioWhileListening == false)
        #expect(loaded.playSounds == false)
    }

    @Test("Missing keys fall back to defaults (forward-compatible)")
    func lenientDecode() throws {
        // JSON from an older build with only two known fields.
        let json = #"{"hotkey":"leftOption","playSounds":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.hotkey == .leftOption)
        #expect(decoded.playSounds == false)
        // Unspecified fields take their defaults, not a decode failure.
        #expect(decoded.pauseAudioWhileListening == AppSettings.default.pauseAudioWhileListening)
        #expect(decoded.engine == AppSettings.default.engine)
    }
}
