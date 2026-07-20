import Foundation
import CoreGraphics
import Carbon.HIToolbox
import SpeakCore

/// Events the hotkey layer emits (a subset of `DictationEvent`).
enum HotkeyEvent: Sendable {
    case optionDown
    case optionUp
    case otherKeyWhileOptionHeld
    case escPressed
    /// Control joined the dictation key — upgrade this utterance to Talk.
    case talkModifierEngaged
    /// ⌘C while an answer is on screen.
    case copyAnswer
    /// ⌘⏎ while an answer is on screen: insert it at the cursor.
    case insertAnswer
}

/// Watches for the push-to-talk key system-wide using an active `CGEventTap` on a
/// dedicated run-loop thread. Never consumes the Option key (so ⌥-combos keep
/// working); consumes Esc only while a dictation is active.
final class HotkeyMonitor: @unchecked Sendable {
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var shouldStop = false
    /// Whether the event tap is currently live (Accessibility granted + installed).
    private(set) var isTapActive = false

    // Configuration + live state, guarded by `lock`.
    private let lock = NSLock()
    private var choice: HotkeyChoice = .rightOption
    private var optionHeld = false
    private var active = false   // recording or processing — controls Esc consumption
    private var panelPresented = false  // an answer is on screen — enables ⌘C / ⌘⏎ / Esc

    /// Called on the main actor for each hotkey event.
    var onEvent: (@Sendable (HotkeyEvent) -> Void)?

    private static let kLeftOption: Int64 = 58
    private static let kRightOption: Int64 = 61
    private static let kLeftControl: Int64 = 59
    private static let kRightControl: Int64 = 62
    private static let kFn: Int64 = 63
    private static let kEsc: Int64 = 53
    private static let kC: Int64 = 8
    private static let kReturn: Int64 = 36

    func updateChoice(_ choice: HotkeyChoice) {
        lock.lock(); self.choice = choice; lock.unlock()
    }

    /// Whether a dictation is active (set by the coordinator) — gates Esc consumption.
    func setActive(_ active: Bool) {
        lock.lock(); self.active = active; lock.unlock()
    }

    /// Whether a Talk answer is on screen. While it is, we consume ⌘C and ⌘⏎ so they
    /// act on the answer rather than on whatever app is frontmost.
    func setAnswerPanelPresented(_ presented: Bool) {
        lock.lock(); self.panelPresented = presented; lock.unlock()
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
        let choice = self.choice
        let wasHeld = self.optionHeld
        let isActive = self.active
        let hasPanel = self.panelPresented
        lock.unlock()

        if type == .flagsChanged {
            let hasControl = event.flags.contains(.maskControl)
            // Control arriving while the dictation key is already down upgrades the
            // in-flight utterance to Talk. This lands here rather than in
            // `matchesChoice` because Control is never itself a dictation key — and
            // because a modifier is a `flagsChanged`, not a `keyDown`, so it can't
            // trip the `otherKeyWhileOptionHeld` passthrough below.
            if wasHeld && hasControl {
                emit(.talkModifierEngaged)
            }

            let isOurKey = matchesChoice(keyCode: keyCode, choice: choice)
            guard isOurKey else { return false }
            let nowDown = isHeld(flags: event.flags, choice: choice)
            if nowDown && !wasHeld {
                lock.lock(); optionHeld = true; lock.unlock()
                emit(.optionDown)
                // Control-then-Option ordering: the upgrade check above only fires
                // when Option was already down, so cover the reverse order here.
                if hasControl { emit(.talkModifierEngaged) }
            } else if !nowDown && wasHeld {
                lock.lock(); optionHeld = false; lock.unlock()
                emit(.optionUp)
            }
            return false // never consume the modifier
        }

        if type == .keyDown {
            if keyCode == Self.kEsc {
                if isActive || hasPanel {
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
            // Any other key while our Option is physically held → modifier combo.
            if wasHeld {
                emit(.otherKeyWhileOptionHeld)
            }
            return false
        }

        return false
    }

    /// Whether this `flagsChanged` came from the key that arms dictation.
    private func matchesChoice(keyCode: Int64, choice: HotkeyChoice) -> Bool {
        switch choice {
        case .eitherOption: return keyCode == Self.kLeftOption || keyCode == Self.kRightOption
        case .leftOption: return keyCode == Self.kLeftOption
        case .rightOption: return keyCode == Self.kRightOption
        case .fn: return keyCode == Self.kFn
        }
    }

    /// Whether the gesture's modifier is currently down, per the event flags.
    private func isHeld(flags: CGEventFlags, choice: HotkeyChoice) -> Bool {
        switch choice {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .eitherOption, .leftOption, .rightOption: return flags.contains(.maskAlternate)
        }
    }

    private func emit(_ event: HotkeyEvent) {
        let handler = onEvent
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
