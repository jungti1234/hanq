import Carbon

/// Resolve Command-V in the active layout, including Command-specific mappings.
/// Never switch input sources or guess a US key when the layout cannot be read.
enum PasteShortcut {
    static func currentKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        return keyCode(in: data, keyboardType: UInt32(LMGetKbdType()))
    }

    static func keyCode(in data: CFData, keyboardType: UInt32) -> CGKeyCode? {
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var match: CGKeyCode?
        for code: UInt16 in 0..<128 {
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown),
                UInt32((cmdKey >> 8) & 0xff), keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                characters.count, &length, &characters)
            guard status == noErr, dead == 0, length == 1,
                  characters[0] == 0x76 || characters[0] == 0x56 else { continue }
            // More than one candidate is ambiguous; do not send another command.
            guard match == nil else { return nil }
            match = code
        }
        return match
    }
}
