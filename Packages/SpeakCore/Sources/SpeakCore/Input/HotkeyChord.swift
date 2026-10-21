import Foundation

/// Which physical modifier keys are currently down.
///
/// Sides are tracked separately because the two chords this app listens for differ
/// *only* by side — right Control+Option dictates, left Control+Option runs the
/// agent. (Dictation is right Command+Option: the built-in keyboard has no right
/// Control.) `CGEventFlags.maskControl` and `.maskAlternate` are set by either side and
/// so cannot tell the two apart; the caller derives these bits from the
/// device-dependent flags instead (`NX_DEVICEL*`/`NX_DEVICER*`), which is the only
/// place the left/right distinction actually exists in an event.
public struct HeldModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let leftControl  = HeldModifiers(rawValue: 1 << 0)
    public static let rightControl = HeldModifiers(rawValue: 1 << 1)
    public static let leftOption   = HeldModifiers(rawValue: 1 << 2)
    public static let rightOption  = HeldModifiers(rawValue: 1 << 3)
    public static let rightCommand = HeldModifiers(rawValue: 1 << 4)
}

/// A press-and-hold gesture. Two chords, two destinations, and no overlap: the side
/// of the keyboard *is* the mode, so a user never has to remember a third key or
/// watch the overlay to know where their words are going.
public enum HotkeyChord: String, Sendable, Equatable, CaseIterable {
    /// Right Command + Right Option — transcribe, format, insert at the cursor.
    case dictation
    /// Left Control + Left Option — hand the utterance to the agent.
    case agent

    /// The keys that must be down for this chord to be engaged.
    public var required: HeldModifiers {
        switch self {
        case .dictation: return [.rightCommand, .rightOption]
        case .agent: return [.leftControl, .leftOption]
        }
    }
}

/// Turns a set of held modifiers into the chord that is engaged, if any.
public enum ChordResolver {

    /// Which chord `held` engages, given the one that was already engaged.
    ///
    /// Two deliberate details:
    ///
    /// * **Superset, not equality.** Once a chord is down, an extra modifier joining
    ///   it (a Shift the user is holding for something else, or the other side's
    ///   Control) must not silently end the recording mid-sentence.
    /// * **`active` wins.** With all four keys down both chords are satisfied, and
    ///   the answer has to be whichever one the user actually started — releasing a
    ///   key must never *change* the destination of an utterance already being
    ///   spoken. Only when nothing is engaged does the tie break to `.dictation`,
    ///   the everyday gesture.
    public static func resolve(held: HeldModifiers, active: HotkeyChord?) -> HotkeyChord? {
        if let active, held.isSuperset(of: active.required) { return active }
        for chord in HotkeyChord.allCases where held.isSuperset(of: chord.required) {
            return chord
        }
        return nil
    }
}
