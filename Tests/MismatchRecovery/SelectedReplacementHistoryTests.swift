import AppKit
import Carbon

// Real detector events and injected editor snapshots. No global key posting,
// live source selection or AX writes; the selected draft is synthetic.
func runSelectedReplacementHistoryTests(){
    var checks=0
    func check(_ value:Bool,_ label:String){probeTestCheck(value,label);checks+=1}
    let ko=KoreanKeyboardLayout.twoSetID,keys:[UInt16]=[15,40,1,40]
    func next(_ p:MismatchRecoveryPlan?,_ text:String,_ selection:NSRange,_ code:UInt16,_ source:String=KoreanKeyboardLayout.twoSetID)->MismatchRecoveryPlan {
        MismatchRecoveryPlan.next(previous:p,text:text,selection:selection,code:code,shift:false,sourceID:source)!
    }
    // Every nonempty range, including middle replacements with UTF-16 prefix
    // and suffix. Until AX catches up the old selected body never permits edit.
    let draft="ABCDEF"
    for start in 0..<6 {for length in 1...(6-start) {
        let range=NSRange(location:start,length:length)
        var p:MismatchRecoveryPlan?
        for (i,c) in keys.enumerated() {
            p=next(p,draft,range,c)
            check(p!.codes.count==i+1,"unchanged selection retains every earlier key")
            check(!p!.matches(text:draft,selection:range) && p!.partialFailurePlan(text:draft,selection:range)==nil,"stale selection never authorizes an edit")
        }
        let final=(draft as NSString).replacingCharacters(in:range,with:"rksk")
        check(p!.matches(text:final,selection:NSRange(location:start+4,length:0)),"complete replacement is recoverable with both surroundings")
    }}
    for source in KoreanKeyboardLayout.supportedIDs {
        var p:MismatchRecoveryPlan?
        let original="앞🙂OLD뒤",range=NSRange(location:3,length:3)
        let codes:[UInt16]=source==ko ? keys:[5,0,45,0]
        for c in codes.prefix(3){p=next(p,original,range,c,source)}
        let prefix=p!.replayRoman
        p=next(p,"앞🙂"+prefix+"뒤",NSRange(location:3+prefix.utf16.count,length:0),codes[3],source)
        check(p!.codes.count==4 && p!.before=="앞🙂뒤" && p!.caret==3,"delayed output keeps all keys and UTF-16 coordinates in every layout")
        let roman="앞🙂"+p!.replayRoman+"뒤"
        check(p!.matches(text:roman,selection:NSRange(location:7,length:0)),"full ASCII replacement verifies")
        let korean=MismatchKeyboardLayout.render(keys:codes.map{($0,false)},sourceID:source)!
        check(p!.partialFailurePlan(text:"앞🙂"+korean+"뒤",selection:NSRange(location:3+korean.utf16.count,length:0))==nil,"normally composed replacement is never repaired")
    }
    let selected=NSRange(location:0,length:6)
    let first=next(nil,draft,selected,15)
    for (body,range) in [(draft,NSRange(location:1,length:5)),("ABCDEG",selected),(draft,NSRange(location:0,length:0)),("r",NSRange(location:0,length:1))] {
        check(next(first,body,range,40).codes.count==1,"new selection, text or caret starts a new run")
    }
    check(next(first,draft,selected,40,KoreanKeyboardLayout.threeSetID).codes.count==1,"source boundary never borrows selected history")
    // Equal graphemes / browser spaces are insufficient for an unchanged AX
    // snapshot: the original selected UTF-16 units must be identical.
    for (before,after) in [("éXY","e\u{301}XY"),("A B","A\u{a0}B")] {
        let p=next(nil,before,NSRange(location:0,length:3),15)
        check(next(p,after,NSRange(location:0,length:3),40).codes.count==1,"changed literal selected snapshot cannot extend history")
    }
    var capped:MismatchRecoveryPlan?
    for _ in 0..<256{capped=next(capped,draft,selected,15)}
    check(MismatchRecoveryPlan.next(previous:capped,text:draft,selection:selected,code:15,shift:false)==nil,"existing history cap is retained")

    let field=AXUIElementCreateApplication(900001),other=AXUIElementCreateApplication(900002)
    var body=draft,range=selected,focus=field,source=ko,readable=true,writes=0,posts=0,switches=0
    func key(_ c:UInt16,_ down:Bool=true,_ flags:CGEventFlags=[])->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:c,keyDown:down)!
        e.flags=flags;return e
    }
    func rig()->MismatchRecoveryEngine {
        body=draft;range=selected;focus=field;source=ko;readable=true
        let e=MismatchRecoveryEngine();e.enabled=true;e.locked=field;e.lastSource=ko
        e.testSnapshot={readable ? .init(element:focus,text:body,selection:range):nil}
        e.testSource={source};e.testFastContext={true};e.canBeginRepair={false}
        e.testPost={_ in posts+=1};e.testPostAtTap={_,_ in posts+=1}
        e.testSetRange={_,_ in writes+=1;return .success}
        e.testSelectSource={source=$0;switches+=1;return noErr}
        return e
    }
    func type(_ e:MismatchRecoveryEngine,_ c:UInt16){
        check(e.event(.keyDown,key(c)) != nil,"original press passes without delay")
        check(e.event(.keyUp,key(c,false)) != nil,"original release passes once")
    }
    for boundary in ["normal","changed-selection","idle-return","mouse","arrow","delete","select-all","paste","source","field","unreadable","expired"] {
        let e=rig();type(e,15);type(e,40)
        check(e.plan?.replayRoman=="rk","engine preserves selected replacement prefix")
        switch boundary {
        case "changed-selection":range=NSRange(location:1,length:5)
        case "idle-return":
            range=NSRange(location:1,length:5);e.consumeIdleSnapshot(e.testSnapshot!())
            range=selected
        case "mouse":
            let mouse=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
            check(e.event(.leftMouseDown,mouse) != nil,"click passes")
        case "arrow":type(e,123)
        case "delete":type(e,51)
        case "select-all","paste":
            let c:UInt16=boundary=="paste" ? 9:0
            check(e.event(.keyDown,key(c,true,.maskCommand)) != nil,"editing shortcut passes")
            _ = e.event(.keyUp,key(c,false,.maskCommand))
        case "source":source=KoreanKeyboardLayout.threeSetID
        case "field":focus=other
        case "unreadable":readable=false;type(e,1);readable=true
        case "expired":e.planStart=ProcessInfo.processInfo.systemUptime-6
        default:break
        }
        type(e,1)
        check(e.plan?.codes.count==(boundary=="normal" ? 3:1),"selection replacement boundary: \(boundary)")
        check(!e.recovering && e.pending.isEmpty && e.retained.isEmpty,"observation does not acquire input ownership")
    }
    // A full detected prefix must reach the actual repair boundary. Subsequent
    // keys retain their order while replay updates only the verified range.
    let e=rig()
    for c in keys.prefix(3){type(e,c)}
    body="rks";range=NSRange(location:3,length:0)
    e.canBeginRepair={true};e.testSelectionWritable={_ in true}
    var composition:[(UInt16,Bool)]=[],marked:NSRange?,replayed:[UInt16]=[]
    e.testSelectSource={source=$0;switches+=1;composition=[];marked=nil;return noErr}
    e.testSetRange={_,r in writes+=1;range=r;composition=[];marked=nil;return .success}
    e.testPostAtTap={event,_ in
        posts+=1
        guard event.type == .keyDown else{return}
        let c=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        replayed.append(c);composition.append((c,event.flags.contains(.maskShift)))
        let insertion=MismatchKeyboardLayout.render(keys:composition,sourceID:ko)!,r=marked ?? range
        body=(body as NSString).replacingCharacters(in:r,with:insertion)
        marked=NSRange(location:r.location,length:insertion.utf16.count)
        range=NSRange(location:r.location+insertion.utf16.count,length:0)
    }
    check(writes==0 && posts==0 && switches==0,"all preceding observations have zero edit/source/post operations")
    check(e.event(.keyDown,key(40))==nil && e.recovering,"next key waits only after full mismatch is proved")
    check(e.currentPlan?.replayRoman=="rks" && e.currentPlan?.caret==0,"repair includes the first key, not just a suffix")
    check(e.event(.keyUp,key(40,false))==nil,"following release stays paired")
    let deadline=Date().addingTimeInterval(3)
    while e.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    check(!e.recovering && !e.suspended && e.rollbackReason.isEmpty,"mock editor recovery completes")
    check(body=="가나" && range==NSRange(location:2,length:0),"whole word and following key compose in order")
    check(replayed==keys && e.pending.isEmpty && e.retained.isEmpty,"every observed key replays once with no stranded input")
    print("PASS: \(checks) selected replacement history, boundaries and injected full recovery checks")
}
