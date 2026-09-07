import Foundation
import CoreGraphics
import Carbon.HIToolbox
import SpeakCore

/// Events the hotkey layer emits (a subset of `DictationEvent`).
enum HotkeyEvent: Sendable {
    /// One of the two chords went down. Which one decides where the utterance goes,
    /// and it is fixed at this moment — see `HotkeyChord`.
    case chordDown(HotkeyChord)
    case chordUp(HotkeyChord)
    case otherKeyWhileOptionHeld
    case escPressed
    /// ⌘C while an answer is on screen.
    case copyAnswer
    /// ⌘⏎ while an answer is on screen: insert it at the cursor.
    case insertAnswer
}

/// The keyboard half of the Agent Mode approval gate.
///
/// Deliberately its own enum rather than three more `HotkeyEvent` cases. Adding a
/// case to `HotkeyEvent` breaks the exhaustive switch in `RecordingCoordinator`,
/// which is owned elsewhere while Agent Mode is being built in parallel — and a
/// separate channel is the version of this that merges cleanly. Fold it into
/// `HotkeyEvent` once the coordinator handles it; the case names are already the
/// ones it will want.
enum HotkeyApprovalEvent: Sendable {
    /// `Y` — run the held call once.
    case approvalAllow
    /// `N` — refuse this one call and let the model reconsider.
    case approvalDeny
    /// `A` — approve every remaining action for the rest of this request.
    case approvalAllowAll

    /// The decision to hand the gate. Named the same as the panel's buttons emit, so
    /// the keyboard and the mouse cannot drift apart.
    var decision: ApprovalDecision {
        switch self {
        case .approvalAllow: return .allow
        case .approvalDeny: return .deny
        case .approvalAllowAll: return .allowAll
        }
    }
}

/// Watches for the two push-to-talk chords system-wide using an active `CGEventTap`
/// on a dedicated run-loop thread. Never consumes a modifier (so ⌃⌥-combos keep
/// working); consumes Esc only while a dictation is active, and the bare letters
/// `Y` / `N` / `A` only while an Agent Mode approval is actually pending.
final class HotkeyMonitor: @unchecked Sendable {
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var shouldStop = false
    /// Whether the event tap is currently live (Accessibility granted + installed).
    private(set) var isTapActive = false

    // Configuration + live state, guarded by `lock`.
    private let lock = NSLock()
    /// The chord currently held, or nil. Also the `wasHeld` flag the keyDown path
    /// reads to spot a modifier combo.
    private var activeChord: HotkeyChord?
    private var active = false   // recording or processing — controls Esc consumption
    private var panelPresented = false  // an answer is on screen — enables ⌘C / ⌘⏎ / Esc
    private var approvalPending = false // the agent is stopped at the gate — enables Y / N / A

    /// Called on the main actor for each hotkey event.
    var onEvent: (@Sendable (HotkeyEvent) -> Void)?

    /// Called on the main actor when the user answers an approval from the keyboard.
    /// Only ever fires while `setApprovalPending(true)` is in force.
    var onApprovalEvent: (@Sendable (HotkeyApprovalEvent) -> Void)?

    private static let kEsc: Int64 = 53
    private static let kC: Int64 = 8
    private static let kReturn: Int64 = 36
    private static let kA: Int64 = 0
    private static let kY: Int64 = 16
    private static let kN: Int64 = 45

    /// Every modifier that makes a keypress something other than a bare letter.
    /// `.maskNonCoalesced` and friends are always set on a real event, so testing
    /// `flags.isEmpty` would never be true and the approval keys would never fire.
    private static let modifierMask: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn
    ]

    /// Whether a dictation is active (set by the coordinator) — gates Esc consumption.
    func setActive(_ active: Bool) {
        lock.lock(); self.active = active; lock.unlock()
    }

    /// Whether a Talk answer is on screen. While it is, we consume ⌘C and ⌘⏎ so they
    /// act on the answer rather than on whatever app is frontmost.
    func setAnswerPanelPresented(_ presented: Bool) {
        lock.lock(); self.panelPresented = presented; lock.unlock()
    }

    /// Whether Agent Mode is holding a tool call at the approval gate.
    ///
    /// This flag is the entire licence to consume `Y`, `N` and `A`. They are ordinary
    /// letters, so a wider window would swallow a keystroke out of every text field on
    /// the machine — the same reason ⌘C is only taken while an answer panel is up. It
    /// must be cleared the moment the gate resolves, including when the run is
    /// cancelled or fails out from under it.
    func setApprovalPending(_ pending: Bool) {
        lock.lock(); self.approvalPending = pending; lock.unlock()
    }

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "com.gaithano.speak.hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func runLoop() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Retry until the tap can be created. tapCreate returns nil until
        // Accessibility is granted, so this self-heals when the user grants it
        // mid-session — no relaunch needed.
        var port: CFMachPort?
        while !shouldStop {
            port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hotkeyTapCallback,
                userInfo: refcon
            )
            if port != nil { break }
            Log.hotkey.notice("Event tap unavailable (Accessibility not yet granted); retrying…")
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard let port, !shouldStop else { return }

        self.tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isTapActive = true
        Log.hotkey.info("Hotkey tap installed")
        CFRunLoopRun()
    }

    func stop() {
        shouldStop = true
        isTapActive = false
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tapPort = nil
        runLoopSource = nil
    }

    // Called from the C callback (on the tap thread).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Re-enable if the system disabled our tap (timeout / user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        lock.lock()
        let wasHeld = self.activeChord != nil
        let isActive = self.active
        let hasPanel = self.panelPresented
        let hasApproval = self.approvalPending
        lock.unlock()

        if type == .flagsChanged {
            // Recompute the whole picture from this event rather than tracking
            // per-key transitions: `flagsChanged` carries the full modifier state, so
            // a missed event (the tap being re-enabled after a timeout, a key released
            // while another app had a higher-priority tap) heals on the next one
            // instead of leaving a chord stuck down.
            let held = Self.heldModifiers(in: event.flags)
            lock.lock()
            let previous = activeChord
            let resolved = ChordResolver.resolve(held: held, active: previous)
            activeChord = resolved
            lock.unlock()
            if resolved != previous {
                if let previous { emit(.chordUp(previous)) }
                if let resolved { emit(.chordDown(resolved)) }
            }
            return false // never consume the modifier
        }

        if type == .keyDown {
            if keyCode == Self.kEsc {
                if isActive || hasPanel || hasApproval {
                    emit(.escPressed)
                    return true // consume Esc while active or showing an answer
                }
                return false
            }
            // Answer-panel shortcuts. Consumed so they don't also reach the app
            // underneath — ⌘C especially would otherwise clobber the user's clipboard
            // with whatever that app had selected.
            if hasPanel {
                let flags = event.flags
                if keyCode == Self.kC && flags.contains(.maskCommand) {
                    emit(.copyAnswer)
                    return true
                }
                // ⌘⏎ rather than ⌥⏎: Option is the dictation key, so holding it would
                // start a new recording before Return ever arrived.
                if keyCode == Self.kReturn && flags.contains(.maskCommand) {
                    emit(.insertAnswer)
                    return true
                }
            }
            // Agent Mode approval keys, bare only. A modified press (⌘A, ⌃N) belongs
            // to whatever app is frontmost and passes straight through; only the
            // unmodified letter is ours, and only inside the gate's window.
            if hasApproval && event.flags.intersection(Self.modifierMask).isEmpty {
                let decision: HotkeyApprovalEvent? = switch keyCode {
                case Self.kY: .approvalAllow
                case Self.kN: .approvalDeny
                case Self.kA: .approvalAllowAll
                default: nil
                }
                if let decision {
                    // Autorepeat is consumed but not emitted: holding `A` down would
                    // otherwise resolve this approval and then race the next one the
                    // runtime raises, answering a question the user never read.
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        emitApproval(decision)
                    }
                    return true
                }
            }
            // Any other key while one of our chords is physically held → combo.
            if wasHeld {
                emit(.otherKeyWhileOptionHeld)
            }
            return false
        }

        return false
    }

    /// Read left/right Control and Option out of an event's flags.
    ///
    /// `.maskControl` / `.maskAlternate` are set by *either* side and so cannot tell
    /// ⌃⌥ on the right from ⌃⌥ on the left — which is the entire distinction between
    /// dictating and running the agent. The device-dependent bits below
    /// (`NX_DEVICEL*` / `NX_DEVICER*`, from `IOKit/hidsystem/IOLLEvent.h`) are the
    /// only place that side survives in a `CGEvent`.
    private static func heldModifiers(in flags: CGEventFlags) -> HeldModifiers {
        let raw = flags.rawValue
        var held: HeldModifiers = []
        if raw & 0x0000_0001 != 0 { held.insert(.leftControl) }
        if raw & 0x0000_2000 != 0 { held.insert(.rightControl) }
        if raw & 0x0000_0020 != 0 { held.insert(.leftOption) }
        if raw & 0x0000_0040 != 0 { held.insert(.rightOption) }
        return held
    }

    private func emit(_ event: HotkeyEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    private func emitApproval(_ event: HotkeyApprovalEvent) {
        let handler = onApprovalEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

/// Top-level C callback. Reads back the monitor from `userInfo` and forwards.
private func hotkeyTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let consume = monitor.handle(type: type, event: event)
    return consume ? nil : Unmanaged.passUnretained(event)
}
