import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) { checks += 1; if !value() { fatalError(label) } }
final class VirtualTime { var now = 0.0; func wait(_ seconds: Double) { now += max(seconds, 0.0001) } }
final class FakeEditor: AutoTestEditor {
    var text = "", selection = NSRange(location: 0, length: 0), roman = "", baseline = ""
    var downs = 0, ups = 0, selections = 0, deletions = 0, releaseCalls = 0
    var dropDown: Int?, cancelAt: Int?, wrongCaret = false, wrongSelection = false
    var onSend: () -> Void = {}
    var sourceReady: () -> Bool = { true }
    func check() throws { if let cancelAt, downs >= cancelAt { throw AutoTestFailure.cancelled } }
    func read() throws -> AutoEditorState { try check(); return .init(text: text, selection: wrongCaret && !text.isEmpty ? NSRange(location: max(0, selection.location - 1), length: 0) : selection, sourceMatches: text.isEmpty || sourceReady()) }
    func send(_ edge: AutoTestEdge, shifted: Bool) throws {
        try check(); onSend(); if edge.modifier { return }
        if !edge.down { ups += 1; return }
        downs += 1; if downs == dropDown { return }
        if selection.length > 0 { text = (text as NSString).replacingCharacters(in: selection, with: ""); selection.length = 0; roman = "" }
        if roman.isEmpty { baseline = text }
        let letter = PhysicalLetterKeys.letters[edge.code]
        let char = letter.map { shifted ? $0.uppercased() : $0 } ?? [UInt16(49): " ", 47: "."][edge.code]!
        roman += char
        let layout = KoreanKeyboardLayout.resolve(sourceID: KoreanKeyboardLayout.twoSetID)
        text = baseline + JamoComposer.compose(String(roman.map { layout.keys[$0] ?? $0 }))
        selection = NSRange(location: text.utf16.count, length: 0)
    }
    func selectAll() throws { try check(); selections += 1; selection = NSRange(location: 0, length: wrongSelection ? 1 : text.utf16.count); roman = "" }
    func deleteSelection() throws { try check(); deletions += 1; text = (text as NSString).replacingCharacters(in: selection, with: ""); selection.length = 0; roman = "" }
    func release(_ held: Set<UInt16>) { releaseCalls += 1 }
}
let cases = AutoInputPlan.cases()
check(cases.count == 100 && cases.map { $0.id } == Array(1...100), "100 unique sequential cases")
check(Dictionary(grouping: cases, by: { $0.expected }).values.allSatisfy { $0.count == 20 }, "five phrases repeated twenty times")
check([0.04, 0.02, 0.008].map { gap in cases.filter { $0.gap == gap }.count } == [35, 35, 30], "speed coverage 35/35/30")
let legacy = AutoInputPlan.cases(count: 30)
check(zip(cases, legacy).allSatisfy { $0.id == $1.id && $0.expected == $1.expected && $0.gap == $1.gap && $0.overwrite == $1.overwrite }, "original 30-case prefix retained")
for item in cases {
    var held = Set<UInt16>(), down = 0, up = 0
    for edge in AutoInputPlan.edges(item.keys, gap: item.gap) {
        check(![UInt16(36), 76, 48].contains(edge.code), "never Return, Enter or Tab")
        if edge.down { check(!held.contains(edge.code), "release before same-key press"); held.insert(edge.code); if !edge.modifier { down += 1 } }
        else { check(held.remove(edge.code) != nil, "no unmatched release"); if !edge.modifier { up += 1 } }
    }
    check(held.isEmpty && down == item.keys.count && up == down, "balanced original pairs")
}
let time = VirtualTime(), editor = FakeEditor(); var results = [AutoCaseResult]()
try AutoInputEngine(editor: editor, scope: "injected-test", clock: { time.now }, pause: time.wait) { results.append($0) }.run(cases)
check(results.count == 100 && results.allSatisfy { $0.bodyAndCaretMatched && $0.pacingQualified }, "complete automatic engine, nominal overlap timing, clear/overwrite and caret")
check(editor.selections == 99 && editor.deletions == 49, "edit only verified prior synthetic draft")
check(editor.text == cases.last!.expected, "final test draft remains visible")
let initial = FakeEditor(); initial.text = "PRIVATE_EXISTING_DRAFT"; initial.selection.location = initial.text.utf16.count
let initialTime = VirtualTime()
do { try AutoInputEngine(editor: initial, scope: "injected-test", clock: { initialTime.now }, pause: initialTime.wait) { _ in fatalError("unexpected result") }.run([cases[0]]); fatalError("existing draft accepted") }
catch { check(error as? AutoTestFailure == .existingDraft && initial.downs == 0 && initial.selections == 0, "no typing/deletion of existing draft") }
for failure in ["drop", "caret", "cancel", "selection"] {
    let e = FakeEditor(), t = VirtualTime(); var rows = [AutoCaseResult](), attempts = [Int](), interrupted = [String]()
    if failure == "drop" { e.dropDown = 3 }
    if failure == "caret" { e.wrongCaret = true }
    if failure == "cancel" { e.cancelAt = 3 }
    if failure == "selection" { e.wrongSelection = true }
    do { try AutoInputEngine(editor: e, scope: "injected-test", clock: { t.now }, pause: t.wait, onBegin: { attempts.append($0.id) }, onAbort: { _, down, _, reason in interrupted.append(reason); check(down == 3, "partial input count recorded") }) { rows.append($0) }.run(Array(cases.prefix(2))); fatalError("failure not detected") }
    catch {
        if failure == "drop" || failure == "caret" { check(error as? AutoTestFailure == .textMismatch && rows.count == 1 && !rows[0].bodyAndCaretMatched, "first mismatch stops and saves evidence") }
        if failure == "cancel" { check(error as? AutoTestFailure == .cancelled && rows.isEmpty && e.downs == 3 && e.releaseCalls == 1, "guard change stops presses and releases owned keys") }
        if failure == "selection" { check(error as? AutoTestFailure == .selectionNotVerified && e.downs == cases[0].keys.count && e.deletions == 0, "unverified selection cannot delete or type") }
        check(!attempts.isEmpty, "failed attempt has a case identity")
        if failure == "cancel" { check(interrupted == ["cancelled"], "interrupted input records reason") }
    }
}
let slow = FakeEditor(), slowTime = VirtualTime(); var slowRows = [AutoCaseResult]()
slow.onSend = { slowTime.wait(0.04) }
try AutoInputEngine(editor: slow, scope: "injected-test", clock: { slowTime.now }, pause: slowTime.wait) { slowRows.append($0) }.run([cases[0]])
check(slowRows[0].bodyAndCaretMatched && !slowRows[0].pacingQualified, "slow delivery cannot prove fast-input coverage")
let late = FakeEditor(), lateTime = VirtualTime(); var lateRows = [AutoCaseResult]()
late.dropDown = cases.prefix(94).reduce(0) { $0 + $1.keys.count } + 3
do { try AutoInputEngine(editor: late, scope: "injected-test", clock: { lateTime.now }, pause: lateTime.wait) { lateRows.append($0) }.run(cases); fatalError("late mismatch accepted") }
catch { check(error as? AutoTestFailure == .textMismatch && lateRows.count == 95 && !lateRows.last!.bodyAndCaretMatched && late.downs == cases.prefix(95).reduce(0) { $0 + $1.keys.count }, "case95 failure stops before later cases and preserves evidence") }
let restoring = FakeEditor(), sourceTime = VirtualTime(); var sourceRows = [AutoCaseResult]()
restoring.sourceReady = { sourceTime.now >= 4 }
try AutoInputEngine(editor: restoring, scope: "injected-test", clock: { sourceTime.now }, pause: sourceTime.wait) { sourceRows.append($0) }.run([cases[0]])
check(sourceRows[0].bodyAndCaretMatched && sourceRows[0].inputSourceMatched, "temporary recovery source can restore within the bounded result wait")
let wrongSource = FakeEditor(), wrongTime = VirtualTime(); wrongSource.sourceReady = { false }; var wrongRows = [AutoCaseResult]()
do { try AutoInputEngine(editor: wrongSource, scope: "injected-test", clock: { wrongTime.now }, pause: wrongTime.wait) { wrongRows.append($0) }.run([cases[0]]); fatalError("wrong final source accepted") }
catch { check(error as? AutoTestFailure == .sourceChanged && wrongRows.count == 1 && !wrongRows[0].inputSourceMatched, "unrestored source is recorded separately from letter mismatch") }
let a = AutoInputPlan.difference(expected: "이렇게", actual: "이게")
check(a.0 == [1] && a.1 == 0, "missing expected second syllable")
let b = AutoInputPlan.difference(expected: "왼쪽", actual: "ㅇㅇ쪽")
check(b.0 == [0] && b.1 == 2, "duplicated onset differs from missing syllable")
let c = AutoInputPlan.difference(expected: "문장", actual: "PRIVATE_ACTUAL_INPUT")
let encoded = try JSONEncoder().encode(AutoCaseResult(id: 1, expectedSynthetic: "문장", nominalGapMilliseconds: 8, overwrite: false, bodyAndCaretMatched: false, pacingQualified: true, observedUTF16Length: 20, selectionLocation: 20, selectionLength: 0, missingExpectedUTF16Indices: c.0, unexpectedUTF16Units: c.1, postedDowns: 3, postedUps: 3, actualDownGapsMilliseconds: [8], scope: "injected-test"))
check(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_ACTUAL_INPUT"), "actual body never persisted")
check(AutoInputPlan.matches(.init(text: "간\n", selection: NSRange(location: 1, length: 0)), "간"), "one AX terminal LF allowed at exact end caret")
check(!AutoInputPlan.matches(.init(text: "간\n\n", selection: NSRange(location: 1, length: 0)), "간"), "interior/extra LF cannot be normalized away")
print("PASS: \(checks) automatic input schedule, full 100-case injected run, draft/selection/cancel/privacy and early/late mismatch checks; no global keys, AX or ChatGPT control")
