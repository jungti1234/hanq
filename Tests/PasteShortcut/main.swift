import Carbon
import Foundation

var count = 0
func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    count += 1
}
let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
func id(_ source: TISInputSource) -> String {
    let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)!
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}
func layoutData(_ source: TISInputSource) -> CFData? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
}
let expected: [(String, CGKeyCode)] = [
    ("com.apple.keylayout.ABC", 9), ("com.apple.keylayout.US", 9),
    ("com.apple.keylayout.Dvorak", 47), ("com.apple.keylayout.Dvorak-Right", 43),
    ("com.apple.keylayout.Dvorak-Left", 9), ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
    ("com.apple.keylayout.Russian", 9), ("com.apple.keylayout.French", 9),
    ("com.apple.keylayout.German", 9)
]
for (sourceID, expectedCode) in expected {
    guard let source = sources.first(where: { id($0) == sourceID }), let data = layoutData(source) else {
        fatalError("Required standard layout missing: \(sourceID)")
    }
    for keyboardType: UInt32 in [40, 41, 42, UInt32(LMGetKbdType())] {
        check(PasteShortcut.keyCode(in: data, keyboardType: keyboardType) == expectedCode,
              "Command-V mapping: \(sourceID), keyboard type \(keyboardType)")
    }
    print("PASS: \(sourceID) resolves Command-V to key \(expectedCode)")
}
check(PasteShortcut.keyCode(in: Data() as CFData, keyboardType: 40) == nil, "empty layout is refused")
check(PasteShortcut.currentKeyCode() != nil, "active standard layout resolves without selecting another source")
check(SyntheticInputMarker.manualEdit == 0x454F5448, "manual-edit wire value is unchanged")
print("PASS: \(count) paste-shortcut checks; no source selection, clipboard access or OS key posts")
