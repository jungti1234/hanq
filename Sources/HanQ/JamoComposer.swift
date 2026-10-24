import Foundation

/// Greedy modern two-set composition. Existing syllables, punctuation and foreign
/// text are boundaries; standalone consonants/vowels are never discarded.
enum JamoComposer {
    // Apple ignores finals after an incomplete three-set initial or medial.
    // Share this rule between automatic onset and wrong-language recovery.
    static func composeNativeThreeSet(_ text:String)->String {
        var accepted=""
        for scalar in text.unicodeScalars {
            if (0x11A8...0x11C2).contains(scalar.value),
               let last=composeThreeSet(accepted,preserveStandaloneFinals:true).unicodeScalars.last,
               (0x3131...0x3163).contains(last.value) { continue }
            accepted.unicodeScalars.append(scalar)
        }
        return composeThreeSet(accepted,preserveStandaloneFinals:true)
    }
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
        let result: String
        switch layout.kind {
        case .twoSet: result = compose(jamo)
        case .threeSet: result = composeThreeSet(jamo)
        case .gongjinRoman, .hncRoman: result = composeRomanized(jamo, kind: layout.kind)
        }
        return result == selected ? nil : result
    }

    /// Three-set tables preserve initial/medial/final roles. Never feed these
    /// through the two-set greedy composer, which would move finals to initials.
    static func composeThreeSet(_ text: String, preserveStandaloneFinals:Bool=false) -> String {
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
            case 0x11A8...0x11C2: return preserveStandaloneFinals ? String(scalar):String(finals[Int(scalar.value - 0x11A7)])
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
    private static let initialIndexes=Dictionary(uniqueKeysWithValues:initials.enumerated().map{($0.element,$0.offset)})
    private static let vowelIndexes=Dictionary(uniqueKeysWithValues:vowels.enumerated().map{($0.element,$0.offset)})
    private static let finalIndexes=Dictionary(uniqueKeysWithValues:finals.enumerated().map{($0.element,$0.offset)})
    private static let splitFinals=Dictionary(uniqueKeysWithValues:finalPairs.map{($0.value,$0.key)})

    static func compose(_ text: String, vowelCombinations:[String:Character]?=nil,combineStandalone:Bool=false) -> String {
        let vowelPairs=vowelCombinations ?? Self.vowelPairs
        // NFC respects explicit choseong/jungseong/jongseong roles in NFD text.
        var normalized = ""
        var run = ""
        for scalar in text.unicodeScalars {
            if (0x1100...0x11FF).contains(scalar.value) { run.unicodeScalars.append(scalar) }
            else {
                if !run.isEmpty {normalized += run.precomposedStringWithCanonicalMapping}
                run = ""
                normalized.unicodeScalars.append(scalar)
            }
        }
        if !run.isEmpty {normalized += run.precomposedStringWithCanonicalMapping}
        var chars = Array(normalized)
        var result = ""
        var i = 0
        func vowel(at index: Int) -> Bool { index < chars.count && vowelIndexes[chars[index]] != nil }
        while i < chars.count {
            guard let initial = initialIndexes[chars[i]], vowel(at: i + 1) else {
                // A detached initial leaves an IME run starting with a medial.
                // Native typing still combines its standalone vowel keys.
                if combineStandalone,i+1<chars.count,
                   let combined=vowelPairs[String(chars[i...i+1])] {
                    chars[i+1]=combined;i+=1;continue
                }
                result.append(chars[i]); i += 1; continue
            }
            var v = chars[i + 1]
            var next = i + 2
            if next < chars.count, let combined = vowelPairs[String([v, chars[next]])] {
                v = combined; next += 1
            }
            // A precombined final cluster before a vowel splits across syllables.
            if next < chars.count, vowel(at: next + 1),
               let pair = splitFinals[chars[next]] {
                chars.replaceSubrange(next...next, with: Array(pair))
            }
            var final = 0
            if next < chars.count, let candidate = finalIndexes[chars[next]], candidate > 0,
               !vowel(at: next + 1) {
                final = candidate; next += 1
                if next < chars.count, !vowel(at: next + 1),
                   let combined = finalPairs[String([finals[final], chars[next]])],
                   let combinedIndex = finalIndexes[combined] {
                    final = combinedIndex; next += 1
                }
            }
            let code = 0xAC00 + (initial * 21 + vowelIndexes[v]!) * 28 + final
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

    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// Manual-edit provenance only. The hot composition path above is unchanged.
    /// Retain every unchanged source character, including islands between edits.
    static func edits(in text: String, range: NSRange) -> [Edit]? {
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= ns.length,
              range.length <= ns.length - range.location, Range(range, in: text) != nil else { return nil }
        if range.length > 0 {
            guard ns.rangeOfComposedCharacterSequences(for: range) == range else { return nil }
        } else if range.location < ns.length {
            guard ns.rangeOfComposedCharacterSequence(at: range.location).location == range.location else { return nil }
        }
        let original = ns.substring(with: range)
        struct Cell { let character: Character; let range: NSRange }
        var cells: [Cell] = [], offset = 0, boundaries: Set<Int> = [0]
        for character in original {
            let value = String(character), span = NSRange(location: offset, length: value.utf16.count)
            let normalized = character.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) }
                ? compose(value) : value
            cells += normalized.map { Cell(character: $0, range: span) }
            offset += span.length
            boundaries.insert(offset)
        }
        var pieces: [Edit] = [], i = 0
        func vowel(_ index: Int) -> Bool { index < cells.count && vowelIndexes[cells[index].character] != nil }
        func emit(_ end: Int, _ value: String) {
            let span = NSRange(location: cells[i].range.location,
                               length: NSMaxRange(cells[end - 1].range) - cells[i].range.location)
            if let last = pieces.last, span.location < NSMaxRange(last.range) {
                pieces[pieces.count - 1].range.length = max(NSMaxRange(last.range), NSMaxRange(span)) - last.range.location
                pieces[pieces.count - 1].replacement += value
            } else { pieces.append(Edit(range: span, replacement: value)) }
        }
        while i < cells.count {
            guard let initial = initialIndexes[cells[i].character], vowel(i + 1) else {
                emit(i + 1, String(cells[i].character)); i += 1; continue
            }
            var v = cells[i + 1].character, next = i + 2
            if next < cells.count, let combined = vowelPairs[String([v, cells[next].character])] {
                v = combined; next += 1
            }
            if next < cells.count, vowel(next + 1), let pair = splitFinals[cells[next].character] {
                let span = cells[next].range
                cells.replaceSubrange(next...next, with: pair.map { Cell(character: $0, range: span) })
            }
            var final = 0
            if next < cells.count, let candidate = finalIndexes[cells[next].character], candidate > 0, !vowel(next + 1) {
                final = candidate; next += 1
                if next < cells.count, !vowel(next + 1),
                   let combined = finalPairs[String([finals[final], cells[next].character])],
                   let combinedIndex = finalIndexes[combined] { final = combinedIndex; next += 1 }
            }
            let code = 0xAC00 + (initial * 21 + vowelIndexes[v]!) * 28 + final
            emit(next, String(Unicode.Scalar(code)!)); i = next
        }
        let source = original as NSString
        var edits: [Edit] = []
        for piece in pieces where !source.substring(with: piece.range).utf8.elementsEqual(piece.replacement.utf8) {
            if let last = edits.last, NSMaxRange(last.range) == piece.range.location {
                edits[edits.count - 1].range.length += piece.range.length
                edits[edits.count - 1].replacement += piece.replacement
            } else { edits.append(piece) }
        }
        var verified = "", cursor = 0
        for edit in edits {
            guard boundaries.contains(edit.range.location), boundaries.contains(NSMaxRange(edit.range)),
                  edit.range.location >= cursor else { return nil }
            verified += source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            verified += edit.replacement
            cursor = NSMaxRange(edit.range)
        }
        verified += source.substring(from: cursor)
        guard verified.utf8.elementsEqual(compose(original).utf8) else { return nil }
        return edits.map { Edit(range: NSRange(location: range.location + $0.range.location, length: $0.range.length), replacement: $0.replacement) }
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

extension JamoComposer {
    // Apple Romanized layouts have phonetic vowel combinations absent in two-set.
    static func composeRomanized(_ text:String,kind:KoreanKeyboardLayout.Kind)->String {
        var pairs: [String:Character] = kind == .gongjinRoman ? ["ㅏㅔ":"ㅐ","ㅔㅗ":"ㅓ","ㅔㅜ":"ㅡ","ㅣㅏ":"ㅑ","ㅣㅔ":"ㅖ","ㅣㅣ":"ㅢ","ㅣㅗ":"ㅛ","ㅣㅜ":"ㅠ","ㅗㅔ":"ㅚ","ㅗㅗ":"ㅜ","ㅜㅏ":"ㅘ","ㅜㅔ":"ㅞ","ㅜㅣ":"ㅟ"] : ["ㅏㅣ":"ㅐ","ㅓㅣ":"ㅔ","ㅣㅏ":"ㅑ","ㅣㅓ":"ㅕ","ㅣㅗ":"ㅛ","ㅣㅜ":"ㅠ","ㅗㅏ":"ㅘ","ㅗㅣ":"ㅚ","ㅜㅓ":"ㅝ","ㅜㅣ":"ㅟ","ㅡㅣ":"ㅢ"]
        if kind == .gongjinRoman{pairs.merge(["ㅑㅔ":"ㅒ","ㅖㅗ":"ㅕ","ㅞㅗ":"ㅝ","ㅘㅔ":"ㅙ"]){_,new in new}}
        let vowels=Set(Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"))
        let initials=Set(Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"))
        var output:[Character]=[]
        let chars=Array(text);var i=0
        while i<chars.count {
            if i+1<chars.count {
                let pair=String(chars[i...i+1])
                if let combined=pairs[pair]{output.append(combined);i+=2;continue}
                if pair=="ㄴㄱ" {
                    let syllable=output.count>=2 && vowels.contains(output[output.count-1]) && initials.contains(output[output.count-2])
                    let nextVowel=i+2<chars.count && vowels.contains(chars[i+2])
                    if !syllable || !nextVowel{output.append("ㅇ");i+=2;continue}
                }
            }
            if let last=output.last,let combined=pairs[String([last,chars[i]])]{output[output.count-1]=combined}
            else{output.append(chars[i])};i+=1
        }
        return JamoComposer.compose(String(output),vowelCombinations:[:])
    }
}
