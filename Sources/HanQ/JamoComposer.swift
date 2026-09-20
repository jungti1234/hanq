import Foundation

/// Greedy modern two-set composition. Existing syllables, punctuation and foreign
/// text are boundaries; standalone consonants/vowels are never discarded.
enum JamoComposer {
    /// Explicit ASCII selections only. A layout must be resolved by the caller;
    /// the caller resolves unknown sources to the two-set default.
    static func selectedRomanReplacement(in text: String, selection: NSRange,
                                         layout: KoreanKeyboardLayout) -> String? {
        let ns = text as NSString
        guard selection.location >= 0, selection.length > 0,
              selection.location <= ns.length,
              selection.length <= ns.length - selection.location else { return nil }
        let selected = ns.substring(with: selection)
        let scalars = selected.unicodeScalars
        guard scalars.allSatisfy({ (0x20...0x7E).contains($0.value) || [9, 10, 13].contains($0.value) }),
              scalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) else { return nil }
        let jamo = String(selected.map { layout.keys[$0] ?? $0 })
        let result = layout.kind == .twoSet ? compose(jamo) : composeThreeSet(jamo)
        return result == selected ? nil : result
    }

    /// Three-set tables preserve initial/medial/final roles. Never feed these
    /// through the two-set greedy composer, which would move finals to initials.
    static func composeThreeSet(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if let last = scalars.last, let combined = combineThreeSet(last.value, scalar.value),
               let value = Unicode.Scalar(combined) {
                scalars[scalars.count - 1] = value
            } else { scalars.append(scalar) }
        }
        let normalized = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
        // IMEs display incomplete syllables as compatibility jamo, not isolated
        // conjoining characters. Composition above has already retained their roles.
        return normalized.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x1100...0x1112: return String(initials[Int(scalar.value - 0x1100)])
            case 0x1161...0x1175: return String(vowels[Int(scalar.value - 0x1161)])
            case 0x11A8...0x11C2: return String(finals[Int(scalar.value - 0x11A7)])
            default: return String(scalar)
            }
        }.joined()
    }

    private static func combineThreeSet(_ first: UInt32, _ second: UInt32) -> UInt32? {
        if first == second, let combined: UInt32 = [0x1100: 0x1101, 0x1103: 0x1104,
            0x1107: 0x1108, 0x1109: 0x110A, 0x110C: 0x110D][first] { return combined }
        if (0x1161...0x1175).contains(first), (0x1161...0x1175).contains(second),
           let value = vowelPairs[String([vowels[Int(first - 0x1161)], vowels[Int(second - 0x1161)]])],
           let index = vowels.firstIndex(of: value) { return 0x1161 + UInt32(index) }
        if first == second, first == 0x11A8 || first == 0x11BA { return first == 0x11A8 ? 0x11A9 : 0x11BB }
        if (0x11A8...0x11C2).contains(first), (0x11A8...0x11C2).contains(second),
           let value = finalPairs[String([finals[Int(first - 0x11A7)], finals[Int(second - 0x11A7)]])],
           let index = finals.firstIndex(of: value) { return 0x11A7 + UInt32(index) }
        return nil
    }

    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let vowels = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private static let finals = Array(" ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    private static let vowelPairs: [String: Character] = ["ㅗㅏ":"ㅘ", "ㅗㅐ":"ㅙ", "ㅗㅣ":"ㅚ", "ㅜㅓ":"ㅝ", "ㅜㅔ":"ㅞ", "ㅜㅣ":"ㅟ", "ㅡㅣ":"ㅢ"]
    private static let finalPairs: [String: Character] = ["ㄱㅅ":"ㄳ", "ㄴㅈ":"ㄵ", "ㄴㅎ":"ㄶ", "ㄹㄱ":"ㄺ", "ㄹㅁ":"ㄻ", "ㄹㅂ":"ㄼ", "ㄹㅅ":"ㄽ", "ㄹㅌ":"ㄾ", "ㄹㅍ":"ㄿ", "ㄹㅎ":"ㅀ", "ㅂㅅ":"ㅄ"]

    static func compose(_ text: String) -> String {
        // NFC respects explicit choseong/jungseong/jongseong roles in NFD text.
        var normalized = ""
        var run = ""
        for scalar in text.unicodeScalars {
            if (0x1100...0x11FF).contains(scalar.value) { run.unicodeScalars.append(scalar) }
            else {
                normalized += run.precomposedStringWithCanonicalMapping
                run = ""
                normalized.unicodeScalars.append(scalar)
            }
        }
        normalized += run.precomposedStringWithCanonicalMapping
        var chars = Array(normalized)
        var result = ""
        var i = 0
        func vowel(at index: Int) -> Bool { index < chars.count && vowels.contains(chars[index]) }
        while i < chars.count {
            guard let initial = initials.firstIndex(of: chars[i]), vowel(at: i + 1) else {
                result.append(chars[i]); i += 1; continue
            }
            var v = chars[i + 1]
            var next = i + 2
            if next < chars.count, let combined = vowelPairs[String([v, chars[next]])] {
                v = combined; next += 1
            }
            // A precombined final cluster before a vowel splits across syllables.
            if next < chars.count, vowel(at: next + 1),
               let pair = finalPairs.first(where: { $0.value == chars[next] })?.key {
                chars.replaceSubrange(next...next, with: Array(pair))
            }
            var final = 0
            if next < chars.count, let candidate = finals.firstIndex(of: chars[next]), candidate > 0,
               !vowel(at: next + 1) {
                final = candidate; next += 1
                if next < chars.count, !vowel(at: next + 1),
                   let combined = finalPairs[String([finals[final], chars[next]])],
                   let combinedIndex = finals.firstIndex(of: combined) {
                    final = combinedIndex; next += 1
                }
            }
            let code = 0xAC00 + (initial * 21 + vowels.firstIndex(of: v)!) * 28 + final
            result.unicodeScalars.append(Unicode.Scalar(code)!)
            i = next
        }
        return result
    }

    /// Explicit paragraph separators bound the range; visual wrapping does not.
    static func targetRange(in text: String, selection: NSRange) -> NSRange? {
        let ns = text as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= ns.length,
              selection.length <= ns.length - selection.location else { return nil }
        if selection.length > 0 { return selection }
        var start = 0
        var contentsEnd = 0
        ns.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: selection)
        return NSRange(location: start, length: contentsEnd - start)
    }

    static func hasHanjaTarget(in text: String, selection: NSRange) -> Bool {
        hanjaTargetRange(in: text, selection: selection) != nil
    }

    /// Select the Hangul immediately before the caret so the IME receives a
    /// replacement range, not an insertion point. AX ranges use UTF-16 offsets.
    static func hanjaTargetRange(in text: String, selection: NSRange) -> NSRange? {
        let ns = text as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= ns.length,
              selection.length <= ns.length - selection.location else { return nil }
        // An explicit selection must consist entirely of precomposed Hangul.
        // At a caret, inspect the preceding scalar. Never infer a target from
        // an unreadable editor or just the last syllable of a mixed selection.
        if selection.length > 0 {
            return ns.substring(with: selection).unicodeScalars.allSatisfy {
                (0xAC00...0xD7A3).contains($0.value)
            } ? selection : nil
        }
        var start = selection.location
        while start > 0, (0xAC00...0xD7A3).contains(Int(ns.character(at: start - 1))) {
            start -= 1
        }
        guard start < selection.location else { return nil }
        return NSRange(location: start, length: selection.location - start)
    }
}
