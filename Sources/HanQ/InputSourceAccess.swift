import Carbon

// TIS operations only. Target selection and fallback policies belong to callers.
enum InputSourceAccess {
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
