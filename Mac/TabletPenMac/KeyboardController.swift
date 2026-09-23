import Foundation
import CoreGraphics

/// Injects keyboard and scroll-wheel events into macOS via CGEvent.
/// Requires Accessibility permission (same grant CursorController relies on).
final class KeyboardController {
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Map our modifier bitmask (see KeyEventData.mod*) to CGEventFlags.
    private func flags(from modifiers: UInt8) -> CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & KeyEventData.modShift != 0 { f.insert(.maskShift) }
        if modifiers & KeyEventData.modControl != 0 { f.insert(.maskControl) }
        if modifiers & KeyEventData.modOption != 0 { f.insert(.maskAlternate) }
        if modifiers & KeyEventData.modCommand != 0 { f.insert(.maskCommand) }
        return f
    }

    /// Post a key down/up for a macOS virtual keycode, applying held modifiers.
    func postKey(_ event: KeyEventData) {
        guard let e = CGEvent(keyboardEventSource: source,
                              virtualKey: CGKeyCode(event.keyCode),
                              keyDown: event.isDown) else { return }
        e.flags = flags(from: event.modifiers)
        e.post(tap: .cghidEventTap)
    }

    /// Type arbitrary text as unicode — no per-character keycode table needed,
    /// so symbols/accents/emoji all work.
    func typeText(_ text: String) {
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Inject a scroll-wheel event. Positive dy scrolls up, positive dx scrolls right.
    func scroll(_ delta: ScrollDelta) {
        guard let e = CGEvent(scrollWheelEvent2Source: source,
                              units: .pixel,
                              wheelCount: 2,
                              wheel1: Int32(delta.dy),
                              wheel2: Int32(delta.dx),
                              wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }
}
