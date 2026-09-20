import Foundation
import CoreGraphics

/// A narrowly matched IME append result. Never infer a deletion from a general
/// text diff: the complete original must remain, with only Hanja added at the
/// end of the requested Hangul range.
enum HanjaReplacement {
    enum Input { case confirm, navigate, cancel }

    static func input(type: CGEventType?, key: Int64, flags: CGEventFlags) -> Input {
        let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        if type == .leftMouseDown && plain { return .confirm }
        guard type == .keyDown, plain else { return .cancel }
        if [36, 76, 49, 18, 19, 20, 21, 23, 22, 26, 28, 25].contains(key) { return .confirm }
        if [123, 124, 125, 126, 116, 121].contains(key) { return .navigate }
        return .cancel
    }

    struct Correction: Equatable {
        let range: NSRange
        let replacement: String
    }

    static func correction(original: String, target: NSRange, current: String,
                           selection: NSRange) -> Correction? {
        let before = original as NSString
        let after = current as NSString
        guard target.location >= 0, target.length > 0,
              target.location <= before.length,
              target.length <= before.length - target.location else { return nil }
        let hangul = before.substring(with: target)
        guard hangul.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) else { return nil }
        let addedLength = after.length - before.length
        guard addedLength > 0 else { return nil }
        let end = NSMaxRange(target)
        guard selection == NSRange(location: end + addedLength, length: 0),
              after.substring(to: end).utf8.elementsEqual(before.substring(to: end).utf8),
              after.substring(from: end + addedLength).utf8.elementsEqual(before.substring(from: end).utf8) else { return nil }
        let added = after.substring(with: NSRange(location: end, length: addedLength))
        // Require one ideograph per source syllable. Ambiguous partial-word,
        // formatted or mixed-script output is left untouched.
        guard added.unicodeScalars.count == hangul.unicodeScalars.count,
              added.unicodeScalars.allSatisfy({ scalar in
                  (0x3400...0x4DBF).contains(scalar.value)
                      || (0x4E00...0x9FFF).contains(scalar.value)
                      || (0xF900...0xFAFF).contains(scalar.value)
                      || (0x20000...0x2FA1F).contains(scalar.value)
                      || (0x30000...0x323AF).contains(scalar.value)
              }) else { return nil }
        return Correction(range: NSRange(location: target.location, length: target.length + addedLength),
                          replacement: added)
    }
}
