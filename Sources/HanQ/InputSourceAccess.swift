import Carbon

// TIS operations only. Target selection and fallback policies belong to callers.
enum InputSourceAccess {
    typealias LayoutSnapshot = (selected: String, layout: String, override: String?, selectedAfter: String)
    static func layoutSnapshot() -> LayoutSnapshot {
        let selected = currentID()
        let layout = currentLayoutID()
        let override = currentOverrideID()
        return (selected, layout, override, currentID())
    }
    private static func id(_ source:TISInputSource?)->String? {
        guard let source,let pointer=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return nil}
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    static func currentLayoutID()->String {id(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) ?? "unknown"}
    static func currentOverrideID()->String? {id(TISCopyInputMethodKeyboardLayoutOverride()?.takeRetainedValue())}
    static func currentID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func select(_ id: String) -> OSStatus {
        let query = [kTISPropertyInputSourceID as String: id,
                     kTISPropertyInputSourceIsEnabled as String: true,
                     kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(query, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return OSStatus(-50) }
        return TISSelectInputSource(source)
    }
}

// Both switch owners already serialize input. Neither uses a toggle shortcut
// or re-enters the normal user-switch dispatcher for the temporary selection.
enum TwoSetLayoutRoundTrip {
    static func perform(target: String, source: () -> String, select: (String) -> OSStatus,
                        stillCurrent: () -> Bool, trace: (String) -> Void) {
        let abc = "com.apple.keylayout.ABC"
        trace("round_trip_started")
        let result = select(abc)
        guard stillCurrent() else { return }
        let observed = source()
        if observed == abc { trace("round_trip_abc") }
        guard observed == abc || (result == noErr && observed == target) else {
            trace("round_trip_select_failed"); return
        }
        if select(target) != noErr { trace("round_trip_select_failed") }
    }
}
