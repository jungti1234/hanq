import CoreGraphics
import Foundation

var filter = CommandFilter()
let right = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
let both = CGEventFlags(rawValue: right.rawValue | 0x08)
let left = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
var checks = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError(name) }
    checks += 1
}
func event(_ type: CGEventType, _ key: Int64, _ flags: CGEventFlags, _ active: Bool = true) -> CommandFilter.Result {
    filter.process(type: type, key: key, flags: flags, acceptNewPress: active)
}
check(!event(.flagsChanged, 54, right, false).consume, "inactive passes right")
check(!event(.flagsChanged, 54, right).consume, "passed press stays passed after scope change")
_ = event(.flagsChanged, 54, [])
let down = event(.flagsChanged, 54, right)
check(down.consume && down.edge == "right-down", "right down consumed once")
check(event(.flagsChanged, 54, right).edge == nil, "duplicate does not retrigger")
let typing = event(.keyDown, 8, right.union(.maskShift))
check(!typing.consume && !typing.flags.contains(.maskCommand) && typing.flags.contains(.maskShift), "typing strips right and preserves shift")
let leftDown = event(.flagsChanged, 55, both)
check(!leftDown.consume && leftDown.flags.contains(.maskCommand) && leftDown.flags.rawValue & 0x10 == 0, "left command preserved with right held")
check(event(.keyDown, 8, both).flags.contains(.maskCommand), "left copy flags preserved")
check(!event(.keyUp, 8, right, false).flags.contains(.maskCommand), "drain after scope exit")
let up = event(.flagsChanged, 54, left, false)
check(up.consume && up.edge == "right-up" && !filter.consuming, "release drains after stop")
check(event(.keyDown, 8, left).flags == left, "left untouched after drain")
check(!event(.flagsChanged, 54, right, false).consume, "new right press passes outside scope")
let two = InputSourceSnapshot(id: "com.apple.inputmethod.Korean.2SetKorean", name: "두벌식", languages: ["ko"])
let three = InputSourceSnapshot(id: "test.three", name: "세벌식", languages: ["ko"])
let abc = InputSourceSnapshot(id: "com.apple.keylayout.ABC", name: "ABC", languages: ["en"])
let english = InputSourceSnapshot(id: "test.english", name: "English", languages: ["en"])
let japanese = InputSourceSnapshot(id: "test.japanese", name: "日本語", languages: ["ja"])
func resolve(_ current: InputSourceSnapshot?, _ available: [InputSourceSnapshot] = [two,three,abc,japanese], _ last: String? = "test.three") -> String? {
    KoreanEnglishSwitch.resolve(current: current, available: available, rememberedKorean: last, rememberedEnglish: abc.id)
}
check(resolve(abc) == three.id, "English restores last three-set")
check(resolve(three) == abc.id, "three-set to English")
check(resolve(abc, [two,three,abc], two.id) == two.id, "English restores newly selected two-set")
check(resolve(japanese) == abc.id, "Japanese switches to English")
check(resolve(nil) == nil, "unreadable current source passes")
check(resolve(japanese, [two,japanese]) == nil, "other source without English passes")
check(KoreanEnglishSwitch.resolve(current: japanese, available: [abc,english,two], rememberedKorean: two.id, rememberedEnglish: english.id) == english.id, "other source restores last English")
check(KoreanEnglishSwitch.resolve(current: japanese, available: [english,abc,two], rememberedKorean: two.id, rememberedEnglish: "removed") == abc.id, "other source prefers ABC when remembered English removed")
let chinese = InputSourceSnapshot(id: "test.chinese", name: "Pinyin", languages: ["zh-Hans"])
check(resolve(chinese) == abc.id, "Chinese switches to English")
check(resolve(abc, [abc,japanese]) == nil, "no Korean means no toggle")
check(resolve(three, [two,three]) == nil, "no English means no toggle")
check(resolve(abc, [two,abc]) == two.id, "removed remembered source falls back within Korean")
check(KoreanEnglishSwitch.resolve(current: three, available: [abc,english,three], rememberedKorean: three.id, rememberedEnglish: english.id) == english.id, "remember English layout too")
print("PASS: \(checks) CommandFilter assertions; synthetic logic only, physical verification pending")

var option = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
check(!option.process(type: .flagsChanged, key: 61, flags: rightOption, acceptNewPress: false).consume, "disabled Option passes")
check(!option.process(type: .flagsChanged, key: 61, flags: rightOption, acceptNewPress: true).consume, "passed Option stays passed after source change")
_ = option.process(type: .flagsChanged, key: 61, flags: [], acceptNewPress: false)
check(option.process(type: .flagsChanged, key: 61, flags: rightOption, acceptNewPress: true).edge == "right-down", "enabled Option triggers independently of language")
check(!option.process(type: .keyDown, key: 18, flags: rightOption, acceptNewPress: false).flags.contains(.maskAlternate), "candidate key strips consumed option")
check(option.process(type: .keyDown, key: 18, flags: CGEventFlags(rawValue: rightOption.rawValue | 0x20), acceptNewPress: false).flags.contains(.maskAlternate), "left option retained")
check(option.process(type: .flagsChanged, key: 61, flags: [], acceptNewPress: false).consume && !option.consuming, "release after source change")
print("PASS: \(checks) total logic assertions; native candidate UI verification pending")

var independentCommand = CommandFilter()
var independentOption = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
check(!independentCommand.process(type: .flagsChanged, key: 54, flags: right, acceptNewPress: false).consume, "disabled Korean key passes")
check(independentOption.process(type: .flagsChanged, key: 61, flags: rightOption, acceptNewPress: true).consume, "Hanja works while Korean key disabled")
let capsFlags = rightOption.union(.maskAlphaShift)
let capsEvent = independentOption.process(type: .flagsChanged, key: 57, flags: capsFlags, acceptNewPress: true)
check(!capsEvent.consume && capsEvent.flags.contains(.maskAlphaShift), "Caps Lock event and uppercase flag survive active Hanja")
check(independentOption.process(type: .flagsChanged, key: 61, flags: .maskAlphaShift, acceptNewPress: false).consume, "disabled Hanja drains held key release")
_ = independentCommand.process(type: .flagsChanged, key: 54, flags: [], acceptNewPress: false)
check(independentCommand.process(type: .flagsChanged, key: 54, flags: right, acceptNewPress: true).consume, "Korean key works independently")
let capsWithCommand = independentCommand.process(type: .flagsChanged, key: 57, flags: right.union(.maskAlphaShift), acceptNewPress: true)
check(!capsWithCommand.consume && capsWithCommand.flags.contains(.maskAlphaShift), "Caps Lock preserved with active Korean key")
print("PASS: \(checks) total assertions")

let compositionCases: [(String, String)] = [
    ("ㅇㅏㄴㄴㅕㅇ", "안녕"),
    ("ㅇㅏㄴㄴㅕㅇ ㅇㅣㄱㅓㄴ ㅌㅔㅅㅡㅌㅡㅇㅑ", "안녕 이건 테스트야"),
    ("앞 apple | ㅇㅏㄴㄴㅕㅇ!\nㅋㅋㅋ ㅠㅠ", "앞 apple | 안녕!\nㅋㅋㅋ ㅠㅠ"),
    ("ㄱㅏㄴㅏ", "가나"), ("ㄱㅏㄴ", "간"),
    ("ㄷㅏㄹㄱ", "닭"), ("ㄷㅏㄹㄱㅏ", "달가"),
    ("ㄱㅗㅏㅈㅏ", "과자"), ("ㄲㅏㄲ", "깎"),
    ("ㅏㄴ ㄱ ㅣ", "ㅏㄴ ㄱ ㅣ"), ("ㅋㅋㅋ ㅠㅠ", "ㅋㅋㅋ ㅠㅠ"),
    ("dkssud go zzz!", "dkssud go zzz!"),
    ("\u{110B}\u{1161}\u{11AB}\u{1102}\u{1167}\u{11BC}", "안녕"),
    ("ㄱㅏㄳㅏ", "각사"),
    ("e\u{0301} ㅇㅏ", "e\u{0301} 아"),
    ("완성 한글 macOS 👨‍👩‍👧", "완성 한글 macOS 👨‍👩‍👧")
]
for (input, expected) in compositionCases {
    check(JamoComposer.compose(input).utf8.elementsEqual(expected.utf8), "jamo composition: \(input)")
    check(JamoComposer.compose(expected).utf8.elementsEqual(expected.utf8), "composition is idempotent: \(expected)")
}
let paragraphText = "첫 문단\nㅇㅏㄴㄴㅕㅇ apple ㅂㅏㄴㄱㅏㅇㅝ ㅋㅋㅋ\n끝 문단"
let middle = (paragraphText as NSString).range(of: "ㅇㅏㄴㄴㅕㅇ apple ㅂㅏㄴㄱㅏㅇㅝ ㅋㅋㅋ")
for caret in [middle.location, middle.location + 10, NSMaxRange(middle)] {
    let range = JamoComposer.targetRange(in: paragraphText, selection: NSRange(location: caret, length: 0))!
    check(range == middle, "whole paragraph at beginning, middle and end")
    let replacement = JamoComposer.compose((paragraphText as NSString).substring(with: range))
    check((paragraphText as NSString).replacingCharacters(in: range, with: replacement) == "첫 문단\n안녕 apple 반가워 ㅋㅋㅋ\n끝 문단", "other paragraphs preserved")
}
check(JamoComposer.targetRange(in: "a\r\nb", selection: NSRange(location: 3, length: 0)) == NSRange(location: 3, length: 1), "CRLF paragraph")
check(JamoComposer.targetRange(in: "a\n\nb", selection: NSRange(location: 2, length: 0)) == NSRange(location: 2, length: 0), "empty paragraph")
check(JamoComposer.targetRange(in: "a\n", selection: NSRange(location: 2, length: 0)) == NSRange(location: 2, length: 0), "trailing empty paragraph")
check(JamoComposer.targetRange(in: "", selection: NSRange(location: 0, length: 0)) == NSRange(location: 0, length: 0), "empty field")
check(JamoComposer.targetRange(in: paragraphText, selection: NSRange(location: 0, length: 9)) == NSRange(location: 0, length: 9), "explicit selection overrides paragraph")
check(JamoComposer.targetRange(in: "😀ㅇㅏ", selection: NSRange(location: 2, length: 0)) == NSRange(location: 0, length: 4), "UTF16 paragraph range")
check(JamoComposer.targetRange(in: "a", selection: NSRange(location: 2, length: 0)) == nil, "invalid selection rejected")
check(JamoComposer.hasHanjaTarget(in: "ㅋㅋ 한글", selection: NSRange(location: 5, length: 0)), "leftover jamo elsewhere does not block Hanja")
check(!JamoComposer.hasHanjaTarget(in: "한글 abc", selection: NSRange(location: 6, length: 0)), "English caret does not request Hanja")
check(!JamoComposer.hasHanjaTarget(in: "한글 ", selection: NSRange(location: 3, length: 0)), "space does not request Hanja")
print("PASS: \(checks) total assertions including jamo composition and paragraph scope")

let reportedJamo = "ㄹㅣㄴㅣㅇㅓ"
check(JamoComposer.compose(reportedJamo) == "리니어", "reported jamo composes to Linear")
check(!JamoComposer.hasHanjaTarget(in: reportedJamo, selection: NSRange(location: (reportedJamo as NSString).length, length: 0)), "reported jamo never triggers Hanja at caret")
check(!JamoComposer.hasHanjaTarget(in: reportedJamo, selection: NSRange(location: 0, length: (reportedJamo as NSString).length)), "selected jamo never triggers Hanja")
check(!JamoComposer.hasHanjaTarget(in: "ㄹ한", selection: NSRange(location: 0, length: 2)), "mixed selection ending in syllable is not a Hanja target")
check(JamoComposer.hasHanjaTarget(in: "한국", selection: NSRange(location: 0, length: 2)), "precomposed selection supports Hanja")
check(JamoComposer.hasHanjaTarget(in: "한국", selection: NSRange(location: 2, length: 0)), "precomposed caret supports Hanja")
print("PASS: \(checks) total assertions including reported jamo and Hanja routing")

let hanjaRanges: [(String, NSRange, NSRange?)] = [
    ("한국", NSRange(location: 2, length: 0), NSRange(location: 0, length: 2)),
    ("앞 한국", NSRange(location: 4, length: 0), NSRange(location: 2, length: 2)),
    ("😀한국!", NSRange(location: 4, length: 0), NSRange(location: 2, length: 2)),
    ("앞\n한국", NSRange(location: 4, length: 0), NSRange(location: 2, length: 2)),
    ("한국어", NSRange(location: 2, length: 0), NSRange(location: 0, length: 2)),
    ("한국어", NSRange(location: 1, length: 1), NSRange(location: 1, length: 1)),
    ("한국 ", NSRange(location: 3, length: 0), nil),
    ("한국!", NSRange(location: 3, length: 0), nil),
    ("한국abc", NSRange(location: 5, length: 0), nil),
    ("ㄹ한", NSRange(location: 0, length: 2), nil),
    ("", NSRange(location: 0, length: 0), nil),
    ("한국", NSRange(location: -1, length: 0), nil),
    ("한국", NSRange(location: 1, length: Int.max), nil)
]
for (text, selection, expected) in hanjaRanges {
    check(JamoComposer.hanjaTargetRange(in: text, selection: selection) == expected,
          "Hanja replacement range: \(text), \(selection)")
}
let hanjaText = "앞 😀한국 뒤" as NSString
let hanjaRange = JamoComposer.hanjaTargetRange(in: hanjaText as String, selection: NSRange(location: 6, length: 0))!
check(hanjaText.replacingCharacters(in: hanjaRange, with: "韓國") == "앞 😀韓國 뒤", "Hanja replaces source and preserves surrounding text")
print("PASS: \(checks) total assertions including Hanja replacement ranges")

let sourceText = "앞 😀한국 뒤"
let sourceRange = NSRange(location: 4, length: 2)
func correction(_ current: String, _ caret: Int) -> HanjaReplacement.Correction? {
    HanjaReplacement.correction(original: sourceText, target: sourceRange, current: current,
                                selection: NSRange(location: caret, length: 0))
}
let appended = "앞 😀한국韓國 뒤"
let fix = correction(appended, 8)
check(fix == HanjaReplacement.Correction(range: NSRange(location: 4, length: 4), replacement: "韓國"), "exact appended Hanja detected")
check((appended as NSString).replacingCharacters(in: fix!.range, with: fix!.replacement) == "앞 😀韓國 뒤", "append correction preserves prefix, emoji and suffix")
for (value, caret) in [(sourceText, 6), ("앞 😀韓國 뒤", 6), (appended, 6),
                       ("다른 😀한국韓國 뒤", 9), ("앞 😀한국韓國 수정", 8),
                       ("앞 😀한국ab 뒤", 8), ("앞 😀한국한글 뒤", 8),
                       ("앞 😀한국韓 뒤", 7), ("앞 😀한국韓國語 뒤", 9),
                       ("앞 😀한국(韓國) 뒤", 10), ("앞 😀한국韓a 뒤", 8)] {
    check(correction(value, caret) == nil, "unrelated, ambiguous, cancelled or successful conversion untouched")
}
check(HanjaReplacement.correction(original: "한", target: NSRange(location: 0, length: 1), current: "한𠀀", selection: NSRange(location: 3, length: 0))?.replacement == "𠀀", "supplementary Hanja uses UTF16 caret and scalar count")
check(HanjaReplacement.correction(original: "ㄱ", target: NSRange(location: 0, length: 1), current: "ㄱ國", selection: NSRange(location: 2, length: 0)) == nil, "jamo never removed")
check(HanjaReplacement.correction(original: "한", target: NSRange(location: 1, length: Int.max), current: "한漢", selection: NSRange(location: 2, length: 0)) == nil, "invalid target rejected without overflow")
check(HanjaReplacement.correction(original: sourceText, target: sourceRange, current: appended, selection: NSRange(location: 6, length: 2)) == nil, "candidate selection is not a committed caret")
for key: Int64 in [36, 76, 49, 18, 19, 20, 21, 23, 22, 26, 28, 25] {
    check(HanjaReplacement.input(type: .keyDown, key: key, flags: []) == .confirm, "candidate confirmation key")
}
for key: Int64 in [123, 124, 125, 126, 116, 121] {
    check(HanjaReplacement.input(type: .keyDown, key: key, flags: []) == .navigate, "candidate navigation does not confirm")
}
for key: Int64 in [53, 51, 0, 48] {
    check(HanjaReplacement.input(type: .keyDown, key: key, flags: []) == .cancel, "Escape, deletion, typing and Tab cancel watching")
}
for flags: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
    check(HanjaReplacement.input(type: .keyDown, key: 36, flags: flags) == .cancel, "modified Return cannot confirm")
}
check(HanjaReplacement.input(type: .leftMouseDown, key: 0, flags: []) == .confirm, "candidate mouse choice permits result check")
check(HanjaReplacement.input(type: .rightMouseDown, key: 0, flags: []) == .cancel, "context menu cancels")
check(HanjaReplacement.input(type: nil, key: -1, flags: []) == .cancel, "shutdown cancels watching")
print("PASS: \(checks) total assertions including append correction and candidate input policy")


let twoSetLayout = KoreanKeyboardLayout.load(sourceID: KoreanKeyboardLayout.twoSetID)!

// Explicit Roman selection conversion: keyboard mapping, selection scope and rejection.
let romanCases: [(String, String)] = [
    ("dkssudgktpdy", "안녕하세요"),
    ("fmf dufdjqhwk", "를 열어보자"),
    ("to", "새"),
    ("rhk rhos rho rhl rnj rnp rnl dml", "과 괜 괘 괴 궈 궤 귀 의"),
    ("rkqt rkqtdl dlfrdj dlfr", "값 값이 읽어 읽"),
    ("Rk Ek Qk Tk Wk dO dP", "까 따 빠 싸 짜 얘 예"),
    ("DkSSudgktpdy", "안녕하세요"),
    ("Q W E R T O P", "ㅃ ㅉ ㄸ ㄲ ㅆ ㅒ ㅖ"),
    ("a b c d e f g h i j k l m n o p q r s t u v w x y z", "ㅁ ㅠ ㅊ ㅇ ㄷ ㄹ ㅎ ㅗ ㅑ ㅓ ㅏ ㅣ ㅡ ㅜ ㅐ ㅔ ㅂ ㄱ ㄴ ㅅ ㅕ ㅍ ㅈ ㅌ ㅛ ㅋ"),
    ("zz aa", "ㅋㅋ ㅁㅁ"),
    ("dkssud! 123\tto\r\ndks\n", "안녕! 123\t새\r\n안\n"),
    ("to,.!?@#$%^&*()_+-=[]{};:'\"/\\<>`~", "새,.!?@#$%^&*()_+-=[]{};:'\"/\\<>`~")
]
for (input, expected) in romanCases {
    check(JamoComposer.selectedRomanReplacement(in: input, selection: NSRange(location: 0, length: (input as NSString).length), layout: twoSetLayout) == expected,
          "selected Roman keyboard conversion: \(input)")
}
for input in ["", "123 !?", " \t\n", "한글 abc", "ㄱabc", "éabc", "😀abc", "abc\u{0000}", "abc\u{001B}"] {
    check(JamoComposer.selectedRomanReplacement(in: input, selection: NSRange(location: 0, length: (input as NSString).length), layout: twoSetLayout) == nil,
          "non-Roman selection rejected: \(input)")
}
check(JamoComposer.selectedRomanReplacement(in: "dkssud", selection: NSRange(location: 6, length: 0), layout: twoSetLayout) == nil,
      "caret never converts Roman paragraph")
for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1), NSRange(location: 7, length: 1), NSRange(location: 1, length: Int.max)] {
    check(JamoComposer.selectedRomanReplacement(in: "dkssud", selection: range, layout: twoSetLayout) == nil, "invalid Roman selection rejected")
}
let mixedRoman = "앞 😀 cyworldfmf dufdjqhwk 뒤" as NSString
let selectedRoman = mixedRoman.range(of: "fmf dufdjqhwk")
let convertedRoman = JamoComposer.selectedRomanReplacement(in: mixedRoman as String, selection: selectedRoman, layout: twoSetLayout)!
check(mixedRoman.replacingCharacters(in: selectedRoman, with: convertedRoman) == "앞 😀 cyworld를 열어보자 뒤",
      "UTF16 selection preserves unselected English and surrounding Korean")
print("PASS: \(checks) total assertions including selected Roman conversion")

// Recovery resolves a Korean source independently from switching fallback rules.
let nativeThree = InputSourceSnapshot(id: KoreanKeyboardLayout.threeSetID, name: "세벌식", languages: ["ko"])
let native390 = InputSourceSnapshot(id: KoreanKeyboardLayout.threeSet390ID, name: "세벌식 390", languages: ["ko"])
let recoverySources = [two, nativeThree, native390, abc, japanese, three]
func recoverySource(_ current: InputSourceSnapshot?, _ remembered: String? = nativeThree.id,
                    _ available: [InputSourceSnapshot] = recoverySources) -> String? {
    KoreanEnglishSwitch.romanSourceID(current: current, available: available, rememberedKorean: remembered)
}
check(recoverySource(native390) == native390.id, "current Korean source overrides remembered layout")
check(recoverySource(two) == two.id, "current two-set overrides remembered three-set")
check(recoverySource(abc) == nativeThree.id, "English recovery uses remembered Korean layout")
check(recoverySource(japanese, native390.id) == native390.id, "other language recovery uses remembered Korean layout")
check(recoverySource(abc, nil) == nil, "no remembered Korean leaves layout choice to default")
check(recoverySource(abc, "removed") == nil, "removed source resolves to missing ID for default")
check(recoverySource(abc, nativeThree.id, [two, abc]) == nil, "disabled remembered layout is not used")
check(recoverySource(nil) == nil, "unreadable source resolves to missing ID for default")
check(recoverySource(abc, abc.id) == nil, "non-Korean remembered ID rejected")
check(recoverySource(three, two.id) == three.id, "unknown current Korean is not replaced with two-set")
check(KoreanKeyboardLayout.load(sourceID: three.id) == nil, "unsupported third-party source rejected")
check(KoreanKeyboardLayout.load(sourceID: "com.apple.inputmethod.Korean.HNCRomaja") == nil, "unsupported romanization source rejected")
check(KoreanKeyboardLayout.load(sourceID: nil) == nil, "missing layout rejected")
check(JamoComposer.selectedRomanReplacement(in: "dkssud", selection: NSRange(location: 0, length: 6), layout: KoreanKeyboardLayout.resolve(sourceID: nil)) == "안녕",
      "ASCII selection uses two-set without a supported layout")

// Installed Apple tables are the input; expected words below are independent cases.
// Missing resources must be reported, never silently tested using the two-set map.
let threeSetLayout = KoreanKeyboardLayout.load(sourceID: nativeThree.id)
let threeSet390Layout = KoreanKeyboardLayout.load(sourceID: native390.id)
check(threeSetLayout != nil && threeSet390Layout != nil, "installed Apple three-set and 390 resources are readable")
func roman(_ input: String, _ layout: KoreanKeyboardLayout?) -> String? {
    JamoComposer.selectedRomanReplacement(in: input, selection: NSRange(location: 0, length: input.utf16.count), layout: layout ?? KoreanKeyboardLayout.resolve(sourceID: nil))
}
let threeCases: [(String, String)] = [
    ("mfs kfx", "한 각"), ("jfs hea", "안 녕"),
    ("jfsheamfncj4", "안녕하세요"),
    ("kvfx", "곽"), ("kfX", "값"), ("kf3", "갑"),
    ("kkf", "까"), ("kfxq", "갃"), ("kfxf", "각ㅏ"),
    ("kfa", "강"), ("kfs", "간"), ("kfqq", "갔"),
    ("mfs\t kfx\r\nkfX", "한\t 각\r\n값"),
    ("j", "ㅇ"), ("f", "ㅏ"), ("s", "ㄴ")
]
for (input, expected) in threeCases {
    check(roman(input, threeSetLayout) == expected, "three-set recovery: \(input)")
    check(roman(input, threeSet390Layout) == expected, "390 recovery: \(input)")
}
check(roman("kf!", threeSetLayout) == "갂", "three-set punctuation key carries final consonant")
check(roman("kf!", threeSet390Layout) == "갖", "390 punctuation position differs from three-set")
check(roman("kfD", threeSetLayout) == "갋", "three-set shifted key has its own compound final")
check(roman("kfD", threeSet390Layout) == "갉", "390 shifted key uses distinct compound final")
check(roman("kG", threeSetLayout) == "걔", "three-set shifted vowel")
check(roman("kR", threeSet390Layout) == "걔", "390 shifted vowel")
check(roman("ABC", threeSetLayout) == "ㄷ?ㅋ", "uppercase is Shift, not forced to lowercase")
check(roman("ABC", threeSet390Layout) == "ㄷ!ㄻ", "390 uppercase symbols and final roles")
check(roman("mfs-", threeSetLayout) == "한)", "three-set punctuation follows key position")
check(roman("mfs-", threeSet390Layout) == "한-", "390 punctuation follows own key position")
for layout in [threeSetLayout, threeSet390Layout] {
    for input in ["한글 abc", "😀abc", "abc\u{001B}", "123 !?", "\t\r\n"] {
        check(roman(input, layout) == nil, "three-set keeps selection eligibility: \(input)")
    }
    check(JamoComposer.selectedRomanReplacement(in: "mfs", selection: NSRange(location: 3, length: 0), layout: layout ?? KoreanKeyboardLayout.resolve(sourceID: nil)) == nil,
          "three-set never converts without explicit selection")
    let surrounding = "앞 😀 English mfs 뒤" as NSString
    let range = surrounding.range(of: "mfs")
    let result = JamoComposer.selectedRomanReplacement(in: surrounding as String, selection: range, layout: layout ?? KoreanKeyboardLayout.resolve(sourceID: nil))!
    check(surrounding.replacingCharacters(in: range, with: result) == "앞 😀 English 한 뒤", "three-set preserves unselected UTF16 text")
}
check(JamoComposer.composeThreeSet("\u{1100}\u{1169}\u{1161}\u{11A8}") == "곽", "three-set combines medial before NFC")
check(JamoComposer.composeThreeSet("\u{1100}\u{1161}\u{11AF}\u{11A8}") == "갉", "three-set combines final roles")
check(JamoComposer.composeThreeSet("\u{1100}\u{1161}\u{11A8}\u{1161}") == "각ㅏ", "explicit final never moves into the next initial")
check(KoreanKeyboardLayout.parseSystemLayout(Data("<keyboard>".utf8)) == nil, "malformed layout rejected")
check(KoreanKeyboardLayout.parseSystemLayout(Data("<keyboard/>".utf8)) == nil, "missing maps rejected")
let systemThreePath = "/System/Library/Input Methods/KoreanIM.app/Contents/PlugIns/KIM_Extension.appex/Contents/Resources/3SetHangul.keylayout"
if let xml = try? String(contentsOfFile: systemThreePath, encoding: .utf8) {
    let wrongShift = xml.replacingOccurrences(of: "keys=\"anyShift caps?\"", with: "keys=\"anyOption caps?\"")
    check(KoreanKeyboardLayout.parseSystemLayout(Data(wrongShift.utf8)) == nil, "changed modifier contract rejected")
    let missingKey = xml.replacingOccurrences(of: "<key code=\"0\" output=\"ᆼ\"/>", with: "")
    check(KoreanKeyboardLayout.parseSystemLayout(Data(missingKey.utf8)) == nil, "incomplete printable layout rejected")
    let statefulKey = xml.replacingOccurrences(of: "<key code=\"0\" output=\"ᆼ\"/>", with: "<key code=\"0\" action=\"stateful\"/>")
    check(KoreanKeyboardLayout.parseSystemLayout(Data(statefulKey.utf8)) == nil, "stateful action cannot be treated as direct output")
}
print("PASS: \(checks) total assertions including layout-aware recovery and installed Apple three-set resources")

// End-to-end resolution uses two-set for every unavailable-layout situation.
let fallbackIDs: [String?] = [
    recoverySource(nil), recoverySource(abc, nil), recoverySource(abc, "removed"),
    recoverySource(abc, nativeThree.id, [two, abc]), recoverySource(three),
    "com.apple.inputmethod.Korean.HNCRomaja"
]
for id in fallbackIDs {
    let layout = KoreanKeyboardLayout.resolve(sourceID: id)
    check(roman("dkssudgktpdy", layout) == "안녕하세요", "unavailable source defaults to two-set: \(id ?? "nil")")
    check(roman("dkssud! 123", layout) == "안녕! 123", "fallback preserves two-set punctuation and digits")
}
for id in [nativeThree.id, native390.id] {
    let missing = KoreanKeyboardLayout.resolve(sourceID: id, loader: { _ in nil })
    check(roman("dkssud", missing) == "안녕", "missing three-set resource defaults to two-set")
    let malformed = KoreanKeyboardLayout.resolve(sourceID: id, loader: { _ in
        KoreanKeyboardLayout.parseSystemLayout(Data("<keyboard/>".utf8))
    })
    check(roman("dkssud", malformed) == "안녕", "unreadable three-set resource defaults to two-set")
    let supported = KoreanKeyboardLayout.resolve(sourceID: id)
    check(roman("jfsheamfncj4", supported) == "안녕하세요", "supported three-set still takes precedence")
}
check(roman("한글 abc", KoreanKeyboardLayout.resolve(sourceID: nil)) == nil, "fallback preserves non-ASCII safety condition")
check(roman("123 !?", KoreanKeyboardLayout.resolve(sourceID: nil)) == nil, "fallback still requires a letter")
print("PASS: \(checks) total assertions including two-set fallback policy")
