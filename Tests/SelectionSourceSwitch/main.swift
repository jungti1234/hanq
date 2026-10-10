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
        owner.postCommit = { [unowned self] _,key in
            let range=CFRange(location:key==124 ? self.selection.location+self.selection.length:self.selection.location,length:0)
            self.writes.append(range);self.selection=range;return true
        }
        owner.postCommitAndSelectAll={ [unowned self] _ in
            self.writes.append(CFRange(location:self.value.utf16.count,length:0))
            self.selection=CFRange(location:0,length:self.value.utf16.count);self.writes.append(self.selection);return true
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
let commitOnly=Fixture()
check(commitOnly.owner.commitSelection(field:commitOnly.element,text:commitOnly.value,range:NSRange(location:0,length:3))==0,"explicit selection can commit without changing language")
check(commitOnly.selectedTargets.isEmpty && commitOnly.source.hasPrefix("com.apple.inputmethod.Korean."),"commit-only never requests an input-source change")
check(commitOnly.writes.count==2 && commitOnly.selection.length==3,"commit-only restores full selection after cursor acknowledgment")
for context in ["field","text","range"] {
 let f=Fixture()
 let result=f.owner.commitSelection(field:context=="field" ? f.other:f.element,text:context=="text" ? "changed":f.value,range:NSRange(location:0,length:context=="range" ? 2:3))
 check(result != 0 && f.writes.isEmpty && f.selectedTargets.isEmpty,"commit-only pins requested \(context)")
}
let lostNativeSelection=Fixture();lostNativeSelection.selection=CFRange(location:3,length:0)
check(lostNativeSelection.owner.commitSelection(field:lostNativeSelection.element,text:lostNativeSelection.value,range:NSRange(location:0,length:3))==0 && lostNativeSelection.selection.length==3,"native select-all survives an IME collapsing the earlier AX selection")
let nativeRecipe=SelectionPreservingSourceSwitch().commitSelectionEvents()!
check(nativeRecipe.map{$0.getIntegerValueField(.keyboardEventKeycode)}==[124,124,55,0,0,55],"native commit precedes complete Command-A press/release")
check(nativeRecipe.last!.flags.isEmpty && Set(nativeRecipe.map{$0.getIntegerValueField(.eventSourceStateID)}).count==1,"native selection uses one private state and releases Command")
// Deferred editor acknowledgment must yield, never repost or mistake the old
// full selection for completion of a newly posted cursor/select-all sequence.
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
do {
 let f=Fixture();var time=0.0,cursorPosts=0,selectPosts=0
 f.owner.now={time};f.owner.postCommit={_,key in check(key==124,"select-all commits towards selection end");cursorPosts+=1;return true}
 f.owner.postSelectAll={_ in selectPosts+=1;return true}
 func poll()->OSStatus{f.owner.commitSelection(field:f.element,text:"알트탭",range:NSRange(location:0,length:3),asynchronous:true)}
 check(poll()==AXError.cannotComplete.rawValue,"select-all yields after commit")
 time=0.08
 check(poll()==AXError.cannotComplete.rawValue && cursorPosts==1 && selectPosts==0,"stale full selection is not acknowledgment")
 f.selection=CFRange(location:3,length:0)
 check(poll()==AXError.cannotComplete.rawValue && selectPosts==1,"select-all posted only after cursor acknowledgment")
 check(poll()==AXError.cannotComplete.rawValue && selectPosts==1,"wait for actual full selection without duplicate shortcut")
 f.selection=CFRange(location:0,length:3)
 check(poll()==noErr && f.selectedTargets.isEmpty,"selection acknowledged without changing source")
}
// A delayed select-all must not post its shortcut after the original editor,
// text, source or permission changed, or after its acknowledgment deadline.
for reason in ["focus","text","source","permission","timeout"] {
 let f=Fixture();var time=0.0,cursorPosts=0,selectPosts=0
 f.owner.now={time};f.owner.postCommit={_,_ in cursorPosts+=1;return true}
 f.owner.postSelectAll={_ in selectPosts+=1;return true}
 func poll()->OSStatus{f.owner.commitSelection(field:f.element,text:"알트탭",range:NSRange(location:0,length:3),asynchronous:true)}
 check(poll()==AXError.cannotComplete.rawValue,"select-all starts before \(reason)")
 f.selection=CFRange(location:3,length:0)
 switch reason {
 case "focus":f.owner.focus={f.other}
 case "text":f.value="changed"
 case "source":f.source="com.apple.keylayout.ABC"
 case "permission":f.owner.allowed={false}
 default:time=0.31
 }
 check(poll() == -50,"select-all rejects changed \(reason)")
 check(cursorPosts==1 && selectPosts==0 && f.selectedTargets.isEmpty && f.writes.isEmpty,"no delayed shortcut or source switch after \(reason)")
}
print("PASS: selection-preserving source switch \(checks) checks")
