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

    /// Called on the main actor for each hotkey event.
    var onEvent: (@Sendable (HotkeyEvent) -> Void)?

    private static let kLeftOption: Int64 = 58
    private static let kRightOption: Int64 = 61
    private static let kLeftControl: Int64 = 59
    private static let kRightControl: Int64 = 62
    private static let kFn: Int64 = 63
    private static let kEsc: Int64 = 53

    func updateChoice(_ choice: HotkeyChoice) {
        lock.lock(); self.choice = choice; lock.unlock()
    }

    /// Whether a dictation is active (set by the coordinator) — gates Esc consumption.
    func setActive(_ active: Bool) {
        lock.lock(); self.active = active; lock.unlock()
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
        lock.unlock()

        if type == .flagsChanged {
            let isOurKey = matchesChoice(keyCode: keyCode, choice: choice)
            guard isOurKey else { return false }
            let nowDown = isHeld(flags: event.flags, choice: choice)
            if nowDown && !wasHeld {
                lock.lock(); optionHeld = true; lock.unlock()
                emit(.optionDown)
            } else if !nowDown && wasHeld {
                lock.lock(); optionHeld = false; lock.unlock()
                emit(.optionUp)
            }
            return false // never consume the modifier
        }

        if type == .keyDown {
            if keyCode == Self.kEsc {
                if isActive {
                    emit(.escPressed)
                    return true // consume Esc while active
                }
                return false
            }
            // Any other key while our Option is physically held → modifier combo.
            if wasHeld {
                emit(.otherKeyWhileOptionHeld)
            }
            return false
        }

        return false
    }

    /// Whether this `flagsChanged` came from a key that participates in the chosen
    /// gesture. For the ⌃⌥ combo BOTH modifiers qualify, so releasing either one
    /// produces an event we can turn into `optionUp`.
    private func matchesChoice(keyCode: Int64, choice: HotkeyChoice) -> Bool {
        switch choice {
        case .controlOption:
            return keyCode == Self.kLeftOption || keyCode == Self.kRightOption
                || keyCode == Self.kLeftControl || keyCode == Self.kRightControl
        case .eitherOption: return keyCode == Self.kLeftOption || keyCode == Self.kRightOption
        case .leftOption: return keyCode == Self.kLeftOption
        case .rightOption: return keyCode == Self.kRightOption
        case .fn: return keyCode == Self.kFn
        }
    }

    /// Whether the gesture's modifier(s) are currently down, per the event flags.
    /// The ⌃⌥ combo requires both simultaneously — pressing them in either order
    /// arms on the second one, and releasing either disarms.
    private func isHeld(flags: CGEventFlags, choice: HotkeyChoice) -> Bool {
        switch choice {
        case .controlOption: return flags.contains(.maskControl) && flags.contains(.maskAlternate)
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
