import Testing
@testable import SpeakCore

@Suite("Hotkey chords")
struct HotkeyChordTests {

    @Test("Each side resolves to its own chord")
    func sidesAreDistinct() {
        #expect(ChordResolver.resolve(held: [.rightControl, .rightOption], active: nil) == .dictation)
        #expect(ChordResolver.resolve(held: [.leftControl, .leftOption], active: nil) == .agent)
    }

    @Test("A chord needs both of its own keys")
    func partialChordsDoNotFire() {
        #expect(ChordResolver.resolve(held: [.rightControl], active: nil) == nil)
        #expect(ChordResolver.resolve(held: [.leftOption], active: nil) == nil)
        #expect(ChordResolver.resolve(held: [], active: nil) == nil)
    }

    /// The whole reason sides are tracked separately: with only the generic
    /// `.maskControl` / `.maskAlternate` flags this combination is indistinguishable
    /// from either real chord.
    @Test("Mixed sides are not a chord")
    func mixedSidesAreNotAChord() {
        #expect(ChordResolver.resolve(held: [.rightControl, .leftOption], active: nil) == nil)
        #expect(ChordResolver.resolve(held: [.leftControl, .rightOption], active: nil) == nil)
    }

    @Test("An unrelated modifier joining a held chord doesn't end it")
    func extraModifiersDoNotBreakAHold() {
        let held: HeldModifiers = [.rightControl, .rightOption, .leftControl]
        #expect(ChordResolver.resolve(held: held, active: .dictation) == .dictation)
    }

    /// Releasing a key must never change where an utterance already being spoken is
    /// going, so the chord that is already down wins over the one that isn't.
    @Test("With both chords satisfied, the active one wins")
    func activeChordWinsATie() {
        let all: HeldModifiers = [.leftControl, .leftOption, .rightControl, .rightOption]
        #expect(ChordResolver.resolve(held: all, active: .agent) == .agent)
        #expect(ChordResolver.resolve(held: all, active: .dictation) == .dictation)
        // Nothing held yet: the everyday gesture breaks the tie.
        #expect(ChordResolver.resolve(held: all, active: nil) == .dictation)
    }

    @Test("Releasing part of the chord ends it")
    func releaseEndsTheChord() {
        #expect(ChordResolver.resolve(held: [.rightControl], active: .dictation) == nil)
        #expect(ChordResolver.resolve(held: [], active: .agent) == nil)
    }
}
