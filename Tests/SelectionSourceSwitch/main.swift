import AppKit

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name); checks += 1
}
final class Fixture {
    let owner = SelectionPreservingSourceSwitch()
    let element = AXUIElementCreateApplication(12345)
    let other = AXUIElementCreateApplication(54321)
    var value = "알트탭"
    var selection = CFRange(location: 0, length: 3)
    var source = "com.apple.inputmethod.Korean.2SetKorean"
    var selectedTargets = [String]()
    var writes = [CFRange]()
    var onSwitch: (() -> Void)?
    init() {
        owner.allowed = { true }
        owner.caretText = { _,raw,_ in raw }
        owner.postCommit = { [unowned self] _,key in
            let range=CFRange(location:key==124 ? self.selection.location+self.selection.length:self.selection.location,length:0)
            self.writes.append(range);self.selection=range;return true
        }
        owner.focus = { [unowned self] in self.element }
        owner.editable = { _ in true }
        owner.text = { [unowned self] _ in self.value }
        owner.range = { [unowned self] _ in self.selection }
        owner.currentSource = { [unowned self] in self.source }
        owner.setRange = { [unowned self] _, range in self.writes.append(range); self.selection = range; return true }
        owner.selectSource = { [unowned self] target in self.selectedTargets.append(target); self.source = target; self.onSwitch?(); return 0 }
    }
    func run() { _ = owner.select("com.apple.keylayout.ABC"); check(selectedTargets == ["com.apple.keylayout.ABC"], "exactly one requested source selection") }
}
let good = Fixture()
good.run()
check(good.writes.count == 2 && good.writes[0].location == 0 && good.writes[0].length == 0, "collapse before IME deactivation")
check(good.selection.location == 0 && good.selection.length == 3 && good.value == "알트탭", "restore original full selection without text mutation")
let partial = Fixture(); partial.value = "😀알트탭 뒤"; partial.selection = CFRange(location: 2, length: 3); partial.run()
check(partial.writes.count == 2 && partial.writes[0].location == 2 && partial.selection.location == 2 && partial.selection.length == 3, "partial UTF-16 selection")
for range in [CFRange(location: 0, length: 0), CFRange(location: -1, length: 1), CFRange(location: 3, length: 1), CFRange(location: 1, length: Int.max)] {
    let f = Fixture(); f.selection = range; f.run(); check(f.writes.isEmpty, "empty or invalid selection is not edited")
}
for source in ["unknown", "com.apple.keylayout.ABC", "third.party.korean"] {
    let f = Fixture(); f.source = source; f.run(); check(f.writes.isEmpty, "unrelated source is not edited")
}
for mode in ["permission", "focus", "editable", "text", "range", "size", "deadline", "changed-focus", "changed-text", "changed-range", "changed-source"] {
    let f = Fixture()
    switch mode {
    case "permission": f.owner.allowed = { false }
    case "focus": f.owner.focus = { nil }
    case "editable": f.owner.editable = { _ in false }
    case "text": f.owner.text = { _ in nil }
    case "range": f.owner.range = { _ in nil }
    case "size": f.value = String(repeating: "a", count: 16_385)
    case "deadline": var n = 0; f.owner.now = { n += 1; return Double(n) }
    case "changed-focus": var n = 0; f.owner.focus = { n += 1; return n == 1 ? f.element : f.other }
    case "changed-text": var n = 0; f.owner.text = { _ in n += 1; return n == 1 ? "알트탭" : "changed" }
    case "changed-range": var n = 0; f.owner.range = { _ in n += 1; return n == 1 ? f.selection : CFRange(location: 0, length: 1) }
    case "changed-source": var n = 0; f.owner.currentSource = { n += 1; return n == 1 ? f.source : "changed" }
    default: fatalError()
    }
    f.run(); check(f.writes.isEmpty, "preflight refusal: \(mode)")
}
for mode in ["focus", "text", "range", "permission", "source"] {
    let f = Fixture()
    f.onSwitch = {
        switch mode {
        case "focus": f.owner.focus = { f.other }
        case "text": f.value = "changed"
        case "range": f.selection = CFRange(location: 1, length: 0)
        case "permission": f.owner.allowed = { false }
        case "source": f.source = "other"
        default: fatalError()
        }
    }
    f.run(); check(f.writes.count == 1, "do not restore stale selection after \(mode) changes")
}
let failedCollapse = Fixture(); failedCollapse.owner.postCommit = { _,_ in false }; failedCollapse.run()
check(failedCollapse.writes.isEmpty, "failed AX mutation still requests switch exactly once")
let failedSwitch = Fixture(); failedSwitch.owner.selectSource = { _ in -50 }
check(failedSwitch.owner.select("com.apple.keylayout.ABC") == -50, "switch error retained")
check(failedSwitch.writes.count == 2 && failedSwitch.selection.length == 3, "failed switch restores unchanged selection")
let unconfirmed=Fixture();unconfirmed.owner.postCommit={_,_ in true}
var clockValue=0.0;unconfirmed.owner.now={clockValue+=0.01;return clockValue}
check(unconfirmed.owner.select("com.apple.keylayout.ABC") == -50 && unconfirmed.selectedTargets.isEmpty,"unacknowledged commit cannot race a source switch")
let changedCommit=Fixture();changedCommit.owner.postCommit={_,_ in changedCommit.value="changed";return true}
check(changedCommit.owner.select("com.apple.keylayout.ABC") == -50 && changedCommit.writes.isEmpty && changedCommit.selectedTargets.isEmpty,"changed text after native commit is not rewritten or reselected")
for unavailable in ["focus", "text", "range"] {
    let f=Fixture();var committed=false;var reads=0
    f.owner.postCommit={_,_ in committed=true;f.selection=CFRange(location:0,length:0);return true}
    if unavailable=="focus" {f.owner.focus={if committed {reads+=1;if reads==1{return nil}};return f.element}}
    if unavailable=="text" {f.owner.text={_ in if committed {reads+=1;if reads==1{return nil}};return f.value}}
    if unavailable=="range" {f.owner.range={_ in if committed {reads+=1;if reads==1{return nil}};return f.selection}}
    f.run();check(f.selection.length==3,"transient \(unavailable) failure during commit retains selection")
}
// Deferred editor acknowledgment must yield, never repost or mistake the old
// full selection for completion of a newly posted source-switch cursor.
do {
 let f=Fixture();var time=0.0,posts=0
 f.owner.now={time};f.owner.postCommit={_,_ in posts+=1;return true}
 check(f.owner.select("com.apple.keylayout.ABC",asynchronous:true)==AXError.cannotComplete.rawValue && f.owner.isPending,"switch yields after posting once")
 time=0.08
 check(f.owner.select("com.apple.keylayout.ABC",asynchronous:true)==AXError.cannotComplete.rawValue && posts==1 && f.selectedTargets.isEmpty,"old selection after 40ms is pending, not a failed/reposted switch")
 f.selection=CFRange(location:0,length:0);time=0.10
 check(f.owner.select("com.apple.keylayout.ABC",asynchronous:true)==noErr && !f.owner.isPending,"late confirmed cursor permits one switch")
 check(posts==1 && f.selectedTargets.count==1 && f.selection.length==3,"original selection restored after deferred switch")
}
for reason in ["focus","text","source","timeout","cancel"] {
 let f=Fixture();var time=0.0
 f.owner.now={time};f.owner.postCommit={_,_ in true}
 _=f.owner.select("com.apple.keylayout.ABC",asynchronous:true)
 switch reason {
 case "focus":f.owner.focus={f.other}
 case "text":f.value="changed"
 case "source":f.source="changed"
 case "timeout":time=0.31
 default:f.owner.cancelPending()
 }
 if reason != "cancel" {_=f.owner.select("com.apple.keylayout.ABC",asynchronous:true)}
 check(!f.owner.isPending && f.selectedTargets.isEmpty && f.writes.isEmpty,"deferred switch safely ends on \(reason)")
}
// A typed syllable at a collapsed caret must leave composition before ABC.
for outcome in ["ok","unchanged","focus","text","restoreFailed","restoreDelayed","wrongCaret"] {
    let f=Fixture(), abc="com.apple.keylayout.ABC"
    f.value="앞🙂한 뒤";f.selection=CFRange(location:4,length:0)
    var posts=0,time=0.0
    f.owner.now={time}
    f.owner.postCommit={_,key in posts+=1;check(key==123,"use native left");return true}
    let proof=SelectionPreservingSourceSwitch.TypedCaret(field:f.element,text:f.value,offset:4)
    func step()->Int32 { f.owner.select(abc,asynchronous:true,typedCaret:proof) }
    check(step()==AXError.cannotComplete.rawValue && f.owner.isPending && posts==1,"posted once at original caret")
    if outcome=="unchanged" {time=0.31}
    else {f.selection=CFRange(location:outcome=="wrongCaret" ? 2:3,length:0)}
    if outcome=="focus" {f.owner.focus={f.other}}
    if outcome=="text" {f.value="앞🙂하 뒤"}
    if outcome=="restoreFailed" {f.owner.setRange={_,_ in false}}
    if outcome=="restoreDelayed" {f.owner.setRange={_,_ in true}}
    _=step()
    if ["ok","restoreDelayed"].contains(outcome) {
        check(f.selectedTargets.isEmpty,"caret restoration precedes ABC")
        if outcome=="restoreDelayed" {
            _=step();check(f.selectedTargets.isEmpty && f.owner.isPending,"AX success alone is insufficient")
            f.selection=CFRange(location:4,length:0)
        }
        check(step()==0 && f.selectedTargets==[abc] && f.selection.location==4,"restore exact UTF-16 caret before leaving")
    } else { check(f.selectedTargets.isEmpty && !f.owner.isPending,"unconfirmed caret cannot switch") }
    check(posts==1,"never resend movement")
}
// Reproduce editors whose displayed AXValue and range-addressed text differ.
// Keep the UTF-16 caret inside the paragraph, including an astral character.
for mode in ["ok", "rawChange", "verifiedChange", "initialMismatch", "unreadable", "selectionChange", "lateFocus", "lateDeadline"] {
    let f = Fixture()
    let abc = "com.apple.keylayout.ABC"
    let prefix = "첫 문단🙂\n\n마지막 문단, 아무튼 한"
    var editable = prefix + " 끝"
    let at = prefix.utf16.count
    f.value = editable + "\n"
    f.selection = CFRange(location: at, length: 0)
    let proof = SelectionPreservingSourceSwitch.TypedCaret(field: f.element, text: editable, offset: at)
    var posts = 0
    var readable = true
    var time = 0.0
    f.owner.now = { time }
    f.owner.caretText = { _,raw,caret in
        guard readable else {return nil}
        if posts == 1 && mode == "lateFocus" { f.owner.focus = { f.other } }
        if posts == 1 && mode == "lateDeadline" { time = 0.31 }
        let document = editable as NSString
        return MismatchTextReader.resolve(value: raw, selection: NSRange(location:caret.location,length:caret.length)) { r in
            guard NSMaxRange(r) <= document.length else {return nil}
            return document.substring(with:r)
        }
    }
    f.owner.postCommit = { _,key in
        check(key == 123, "commit preceding syllable once")
        posts += 1
        f.selection = CFRange(location: at-1, length: 0)
        return true
    }
    if mode == "initialMismatch" {editable = editable.replacingOccurrences(of:"마지막",with:"변경된")}
    if mode == "selectionChange" {f.selection = CFRange(location: at-1, length: 1)}
    func step() -> Int32 {f.owner.select(abc, asynchronous:true, typedCaret:proof)}
    let initial = step()
    if mode == "initialMismatch" || mode == "selectionChange" {
        check(initial != noErr && posts == 0 && f.selectedTargets.isEmpty, "stale proof leaves the editor untouched")
        continue
    }
    check(initial == AXError.cannotComplete.rawValue && posts == 1 && f.owner.isPending, "verified editor coordinates start commit")
    if mode == "rawChange" { f.value += "!" }
    if mode == "verifiedChange" { editable = editable.replacingOccurrences(of:"아무튼",with:"다르게") }
    if mode == "unreadable" {
        readable = false
        check(step() == AXError.cannotComplete.rawValue && f.owner.isPending && f.writes.isEmpty, "missing proof postpones restoration")
        readable = true
    }
    _ = step()
    if ["rawChange", "verifiedChange", "lateFocus", "lateDeadline"].contains(mode) {
        check(!f.owner.isPending && f.writes.isEmpty && f.selectedTargets.isEmpty, "changed text prevents a stale caret write")
    } else {
        check(f.selection.location == at && f.writes.count == 1 && f.selectedTargets.isEmpty, "restore the editor's caret offset")
        check(step() == noErr && f.selectedTargets == [abc] && posts == 1, "one ABC selection before the next Q")
    }
}
// At a document end the editor's cursor command and its eventual AX observation
// can arrive on different turns. Never resend Right or accept the older caret.
for mode in ["delayed", "ignored", "denied", "focus", "source", "text", "selection", "movedDuringRead"] {
    let f = Fixture()
    f.value = "앞🙂간\n"
    let body = "앞🙂간", end = body.utf16.count
    let abc = "com.apple.keylayout.ABC"
    let proof = SelectionPreservingSourceSwitch.TypedCaret(field: f.element, text: body, offset: end)
    var keys = [CGKeyCode](), time = 0.0
    f.selection = CFRange(location: end, length: 0)
    f.owner.now = { time }
    f.owner.caretText = { _, _, _ in
        if mode == "movedDuringRead", keys == [123] { f.selection = CFRange(location: 0, length: 0) }
        return body
    }
    f.owner.postCommit = { _, key in keys.append(key); return !(key == 124 && mode == "denied") }
    func step() -> Int32 { f.owner.select(abc, asynchronous: true, typedCaret: proof) }
    _ = step()
    _ = step()
    check(keys == [123] && f.selectedTargets.isEmpty, "no return until the editor acknowledges Left")
    f.selection = CFRange(location: end - 1, length: 0)
    switch mode {
    case "focus": f.owner.focus = { f.other }
    case "source": f.source = "other"
    case "text": f.value = "앞🙂강\n"
    case "selection": f.selection.length = 1
    default: break
    }
    _ = step()
    if ["delayed", "ignored"].contains(mode) {
        for _ in 0..<4 { _ = step() }
        check(keys == [123, 124] && f.owner.isPending && f.selectedTargets.isEmpty, "one return, ABC waits for the actual caret")
        if mode == "delayed" { f.selection = CFRange(location: end, length: 0) } else { time = 0.31 }
        _ = step()
    }
    check(!f.owner.isPending && f.writes.isEmpty, "end restoration cannot race an AX write")
    check(f.selectedTargets == (mode == "delayed" ? [abc] : []), "only verified return releases the switch")
    check(keys == (["delayed", "ignored", "denied"].contains(mode) ? [123, 124] : [123]), "at most one return in the original context")
}
print("PASS: selection-preserving source switch \(checks) checks")
