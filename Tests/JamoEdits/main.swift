import AppKit

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func apply(_ text: String, _ edits: [JamoComposer.Edit]) -> String {
    var result = text
    for edit in edits.reversed() { result = (result as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
    return result
}
let samples = ["", "ㅇㅏㄴㄴㅕㅇ", "앞 ㅇㅏㄴㄴㅕㅇ 뒤", "ㅇㅏ LINK ￼ ㄴㅏ", "ㄷㅏㄺㅏ", "ㄱㅏㅋㅋㅋㄴㅏ",
    "각", "가́ㅇㅏ", "👩‍👩‍👧‍👦 ㅇㅏ é 🇰🇷", "abc ㅋㅋㅋ ㅠㅠ", "ㅇㅏ\r\nㄴㅏ", "ㅗㅏ ㄱㅗㅏㄴ", "ㄱㅏㄳㅏㄳㅏ"]
for text in samples {
    guard let edits = JamoComposer.edits(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { check(false, "plan rejected known case"); exit(1) }
    check(apply(text, edits).utf8.elementsEqual(JamoComposer.compose(text).utf8), "exact existing composition")
    for edit in edits {
        check(Range(edit.range, in: text) != nil, "whole grapheme range")
        check(!(text as NSString).substring(with: edit.range).contains("￼"), "attachment excluded")
    }
}
let islands = "ㅇㅏ middle ￼ ㄴㅏ"
let islandEdits = JamoComposer.edits(in: islands, range: NSRange(location: 0, length: islands.utf16.count))!
check(islandEdits.count == 2, "separated changes remain separate")
check(islandEdits.map(\.replacement) == ["아", "나"], "unchanged interior omitted from payload")
let canonical = "가"
check(JamoComposer.edits(in: canonical, range: NSRange(location: 0, length: canonical.utf16.count))?.first?.replacement.utf8.elementsEqual("가".utf8) == true, "canonical equality does not suppress raw normalization")
let selected = "앞😀 ㅇㅏ 뒤 ㄴㅏ", selectedRange = ("앞😀 ㅇㅏ 뒤 ㄴㅏ" as NSString).range(of: "ㅇㅏ")
check(apply(selected, JamoComposer.edits(in: selected, range: selectedRange)!) == "앞😀 아 뒤 ㄴㅏ", "explicit selection only")
for range in [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1), NSRange(location: Int.max, length: 1), NSRange(location: 1, length: 1)] {
    check(JamoComposer.edits(in: "😀ㅇㅏ", range: range) == nil, "invalid range rejected: \(range)")
}
var state: UInt64 = 0x48414E51
func random(_ maximum: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int((state >> 32) % UInt64(maximum)) }
let pool = ["ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅋ", "ㅏ", "ㅓ", "ㅗ", "ㅜ", "ㅣ", "ㄳ", "ㄺ", "ᄀ", "ᅡ", "ᆨ", " ", "x", "😀", "￼", "가", "́", "\r\n"]
for _ in 0..<6000 {
    var text = ""
    for _ in 0..<random(45) { text += pool[random(pool.count)] }
    guard let edits = JamoComposer.edits(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { check(false, "random provenance reconstruction"); exit(1) }
    check(apply(text, edits).utf8.elementsEqual(JamoComposer.compose(text).utf8), "random exact composition oracle")
    for pair in zip(edits, edits.dropFirst()) { check(NSMaxRange(pair.0.range) < pair.1.range.location, "unchanged island retained") }
}
let long = String(repeating: "ㅇㅏ😀plain￼ㄴㅏ ", count: 1200)
let began = ProcessInfo.processInfo.systemUptime
let longEdits = JamoComposer.edits(in: long, range: NSRange(location: 0, length: long.utf16.count))!
check(longEdits.count == 2400, "long paragraph provenance")
print("MEASURED: manual plan \(long.utf16.count) UTF16 units in \((ProcessInfo.processInfo.systemUptime - began) * 1000) ms")
print("PASS: \(checks) jamo edit provenance, Unicode, selection, unchanged islands and exact composition checks")

if CommandLine.arguments.contains("--native") {
    _ = NSApplication.shared
    let values = ["안녕", "반가워"]
    let payload = JamoPasteboard.make(values)!
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setString(payload.string, forType: .string); board.setData(payload.multipleSelection!, forType: .multipleTextSelection)
    let text = "ㅇㅏㄴㄴㅕㅇ LINK ￼ ㅂㅏㄴㄱㅏㅇㅝ"
    let original = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
    original.addAttribute(.link, value: URL(string: "https://example.invalid/retained")!, range: (text as NSString).range(of: "LINK"))
    let attachment = NSTextAttachment(); attachment.image = NSImage(size: NSSize(width: 16, height: 16))
    original.addAttribute(.attachment, value: attachment, range: (text as NSString).range(of: "￼"))
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 140)); view.isRichText = true; view.importsGraphics = true; view.allowsUndo = true
    view.textStorage!.setAttributedString(original)
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = view; window.makeFirstResponder(view)
    view.selectedRanges = JamoComposer.edits(in: text, range: NSRange(location: 0, length: text.utf16.count))!.map { NSValue(range: $0.range) }
    view.undoManager?.removeAllActions()
    check(view.readSelection(from: board), "native multi paste accepted")
    check(view.string == "안녕 LINK ￼ 반가워", "two distinct replacements applied")
    let link = (view.string as NSString).range(of: "LINK"), image = (view.string as NSString).range(of: "￼")
    check(view.textStorage!.attribute(.link, at: link.location, effectiveRange: nil) != nil, "interior hyperlink retained")
    check((view.textStorage!.attribute(.attachment, at: image.location, effectiveRange: nil) as? NSTextAttachment) === attachment, "original attachment object retained")
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    view.undoManager?.undo()
    check(view.string.utf8.elementsEqual(text.utf8), "one native Undo restores all text")
    check((view.textStorage!.attribute(.attachment, at: (text as NSString).range(of: "￼").location, effectiveRange: nil) as? NSTextAttachment) === attachment, "Undo attachment retained")
    view.undoManager?.redo()
    check(view.string == "안녕 LINK ￼ 반가워", "one native Redo restores all changes")
    check((view.textStorage!.attribute(.attachment, at: image.location, effectiveRange: nil) as? NSTextAttachment) === attachment, "Redo attachment retained")
    print("PASS: native private-pasteboard multi replacement, exact link/attachment object preservation and one Undo/Redo")
}
