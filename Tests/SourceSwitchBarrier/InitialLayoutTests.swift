import AppKit
import Carbon

func runInitialLayoutTests(){
    typealias B=SourceSwitchBarrier
    let ko=KoreanKeyboardLayout.twoSetID,abc="com.apple.keylayout.ABC",layout="com.apple.keylayout.2SetHangul"
    let targets = [(ko,layout), (KoreanKeyboardLayout.threeSetID,"com.apple.keylayout.3SetHangul"),
                   (KoreanKeyboardLayout.threeSet390ID,"com.apple.keylayout.390Hangul"),
                   (KoreanKeyboardLayout.gongjinID,"com.apple.keylayout.GJCRomaja"),
                   (KoreanKeyboardLayout.hncID,"com.apple.keylayout.HNCRomaja")]
    for (id, nativeLayout) in targets {
        func classify(_ first: String, _ layout: String, _ override: String?, _ last: String) -> B.InitialLayout {
            B.classifyInitialLayout(first:first,layout:layout,override:override,last:last,target:id)
        }
        check(classify(id,abc,nil,id) == .conflicting,"coherent ABC without override")
        check(classify(id,abc,nativeLayout,id) == .unknown,"overridden ABC cannot trigger guard")
        check(classify(id,nativeLayout,nativeLayout,id) == .ready,"actual Korean layout")
        check(classify(id,abc,nil,abc) == .unknown,"torn read")
        check(classify(abc,abc,nil,abc) == .sourceChanged,"explicit switch away")
        for (other, otherLayout) in targets where other != id {
            check(classify(id,otherLayout,nil,id) == .unknown,"different Korean layout cannot acknowledge this target")
        }
    }
    // A direct switch with no editor never captures originals. The two taps
    // must agree on the first event before any later editor may use its history.
    do {
        let b=B();var t=0.0,pid:pid_t=91
        var window=AXUIElementCreateApplication(4101)
        let originalWindow=window
        b.now={t};b.frontPID={pid};b.frontWindow={_ in window};b.read={nil}
        let first=key(15),second=key(40);first.timestamp=1000;second.timestamp=2000
        check(!b.request(ko,at:900),"outside switch uses direct selection")
        b.didSwitchWithoutField(ko,at:900);t=0.123
        check(!b.receive(.keyDown,first) && b.unfocusedKeyCheck(1000) == .matched,"first outside key stays native and has a matching identity")
        b.initialLayout={_ in .conflicting}
        check(b.unfocusedKeyCheck(1000,needsReadyLayout:true) == .layoutNotReady,"entirely ASCII output waits without owning input")
        b.initialLayout={_ in .ready}
        check(b.unfocusedKeyCheck(1000,needsReadyLayout:true) == .matched,"two-set layout allows the verified native replay")
        t=0.211
        check(!b.receive(.keyDown,second) && b.unfocusedKeyCheck(2000) == .firstDiffers,"later keys cannot claim the first identity")
        pid=92;check(b.unfocusedKeyCheck(1000) == .appChanged,"a different application cannot use the history");pid=91
        window=AXUIElementCreateApplication(4102);check(b.unfocusedKeyCheck(1000) == .windowChanged,"different window in the same application");window=originalWindow
        let click=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
        check(!b.receive(.leftMouseDown,click) && b.unfocusedKeyCheck(1000) != .matched,"pointer invalidation")
        b.didSwitchWithoutField(ko,at:901);t+=0.51
        check(!b.receive(.keyDown,first) && b.unfocusedKeyCheck(1000) != .matched,"first key outside the switch deadline")
        b.didSwitchWithoutField(ko,at:902)
        _=b.receive(.keyDown,first);_=b.request(abc,at:3000)
        check(b.unfocusedKeyCheck(1000) != .matched && !b.busy,"another source switch invalidates the observation")
    }
    // Simulate an unavailable post-switch window with three independent
    // observation points. No OS keys, actual window focus or writes.
    do {
        let root=AXUIElementCreateApplication(4104),component=AXUIElementCreateApplication(4105),other=AXUIElementCreateApplication(4106)
        let own:(AXUIElement)->pid_t?={CFEqual($0,other) ? 92:91}
        func get(_ role:String,_ focus:CFTypeRef,_ window:CFTypeRef,_ subrole:String?=nil)->AXUIElement? {
            InputFocusAccess.outsideWindow(pid:91,element:component,role:role,subrole:subrole,focused:focus,window:window,owner:own)
        }
        check(get(kAXGroupRole,kCFBooleanTrue,root).map{CFEqual($0,root)}==true,"a focused outside node attests its own window")
        check(get(kAXWindowRole,kCFBooleanTrue,kCFNull).map{CFEqual($0,component)}==true,"focused window may attest itself")
        for invalid in [get(kAXTextFieldRole,kCFBooleanTrue,root),get(kAXGroupRole,kCFBooleanFalse,root),get(kAXGroupRole,NSNumber(value:1),root),get(kAXGroupRole,kCFBooleanTrue,other),get(kAXGroupRole,kCFBooleanTrue,kCFNull),get(kAXGroupRole,kCFBooleanTrue,root,"AXSecureTextField")] {
            check(invalid==nil,"unfocused, editable, secure, foreign or unavailable witnesses fail closed")
        }
        for mode in ["prior","direct","direct_slow","conflict","foreign","expired","wrong_request","first_missing","first_moved","last_missing","last_moved","missing_both","other_source","unknown_timestamp","busy_recovery"] {
            let b=B();var time=10.0,pid:pid_t=91,reads=0,posts=0
            var window:AXUIElement?=["direct","direct_slow"].contains(mode) ? root:mode=="conflict" ? other:nil
            b.now={time};b.frontPID={pid};b.frontWindow={_ in window};b.read={nil};b.initialLayout={_ in .ready};b.ready={mode != "busy_recovery"}
            b.readForOutsideSwitch={reads+=1;return(nil,mode=="missing_both" ? nil:(pid,root))}
            b.send={_ in posts+=1}
            let id=mode=="other_source" ? abc:ko, stamp:UInt64=mode=="unknown_timestamp" ? 0:900
            var prior:B.SwitchWindow?
            check(!b.request(id,at:stamp,recordWindow:{prior=$0}),"outside remains a direct switch")
            check(reads==(["other_source","unknown_timestamp","busy_recovery"].contains(mode) ? 0:1),"no extra snapshot outside explicit eligible switches")
            time+=["expired","direct_slow"].contains(mode) ? 0.16:0.01
            if mode=="foreign"{pid=92}
            b.didSwitchWithoutField(id,at:mode=="wrong_request" ? 901:stamp,prior:prior)
            window=mode=="first_missing" ? nil:mode=="first_moved" ? other:root
            let first=key(15);first.timestamp=1000
            check(!b.receive(.keyDown,first),"initial key is always delivered")
            window=mode=="last_missing" ? nil:mode=="last_moved" ? other:root
            let result=b.unfocusedKeyCheck(first.timestamp,needsReadyLayout:true)
            if mode=="prior" {
                check(result == .matchedPreSwitchWindow && result.allowsReplay,"same original window required at first key and before repair")
                b.initialLayout={_ in .conflicting}
                check(!b.unfocusedKeyCheck(first.timestamp,needsReadyLayout:true).allowsReplay,"an unready native layout prevents replay")
            }else if ["direct","direct_slow"].contains(mode){check(result == .matched,"original direct path retained")}
            else{check(!result.allowsReplay,"moved, absent or stale evidence never allows editing: \(mode)")}
            check(posts==0,"observation does not post a key")
        }
    }
    final class Rig {
        let b=B()
        let f=AXUIElementCreateApplication(91),w=AXUIElementCreateApplication(92),other=AXUIElementCreateApplication(93)
        var focus:AXUIElement?,window:AXUIElement?,src="com.apple.keylayout.ABC"
        var body:String,selection:NSRange,time=8.0,phase:B.InitialLayout = .conflicting
        var sent:[Int]=[],saved:[Int]=[],writes=0,probes=0,nativeKeys:[(UInt16,Bool)]=[],stages:[String]=[]
        var original:String,position:Int,nativeKoreanUnderABC=false
        init(_ before:String,_ caret:Int){
            original=before;position=caret;body=before;selection=NSRange(location:caret,length:0)
            focus=f;window=w;b.now={self.time}
            b.source={self.src};b.select={self.src=$0;return noErr}
            b.read={guard let f=self.focus else{return nil};return .init(field:f,text:self.body,selection:self.selection)}
            b.readFocus={self.focus};b.fieldWindow={_ in self.window}
            b.initialLayout={_ in self.probes+=1;return self.phase}
            b.applySelection={_,_ in self.writes+=1;return false}
            b.retained={self.saved += $0.map(Self.edge)}
            b.trace={ self.stages.append($0) }
            b.send={event in
                self.sent.append(Self.edge(event));check(!self.b.receive(event.type,event),"owned replay passes once")
                self.b.observe(event.type,event)
                if event.type == .keyDown {
                    let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                    self.nativeKeys.append((code,event.flags.contains(.maskShift)))
                    let inserted=(self.phase == .ready || self.nativeKoreanUnderABC) ? MismatchKeyboardLayout.render(keys:self.nativeKeys,sourceID:KoreanKeyboardLayout.twoSetID)! : self.nativeKeys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
                    self.body=(self.original as NSString).replacingCharacters(in:NSRange(location:self.position,length:0),with:inserted)
                    self.selection=NSRange(location:self.position+inserted.utf16.count,length:0)
                }
            }
        }
        static func edge(_ e:CGEvent)->Int {Int(e.getIntegerValueField(.keyboardEventKeycode))+(e.type == .keyUp ? 100:0)}
        func advance(_ n:Int=1){for _ in 0..<n {time+=0.02;b.step()}}
        func request(_ timestamp:UInt64=14){check(b.request(KoreanKeyboardLayout.twoSetID,at:timestamp),"explicit boundary accepted")}
        @discardableResult func sendKey(_ code:UInt16,_ down:Bool=true,_ flags:CGEventFlags=[])->Bool{let e=key(code,flags);e.type=down ? .keyDown:.keyUp;return b.receive(e.type,e)}
    }
    // Inject original edges between the two actual source-selection calls, before any
    // first-key readiness path could start. The same FIFO must serve an unreadable field.
    for outside in [false, true] {
        for delayed in [false, true] {
            let r = Rig("rk", 2)
            if outside { r.focus = nil }
            r.b.frontPID = { 91 }; r.b.frontWindow = { _ in r.w }
            var selected: [String] = [], sampled: [Bool] = []
            r.b.observeSwitchCommit = { _, _, inspect in sampled.append(inspect); return r.phase }
            r.b.selectRoundTripSource = { id in
                selected.append(id); r.src = id
                if id == abc {
                    check(r.b.selectingTemporaryABC, "own temporary selection does not update display or source history")
                    for code: UInt16 in [15, 40, 1] {
                        check(r.sendKey(code) && r.sendKey(code, false), "every overlapping edge owned in order")
                    }
                    check(r.sent.isEmpty, "no overlapping event escapes to ABC")
                } else if !delayed { r.phase = .ready }
                return noErr
            }
            let handled = r.b.request(ko, at: 123, rightCommand: true)
            if outside {
                check(!handled, "outside switch takes the direct selection route")
                r.src = ko; r.b.didSwitchWithoutField(ko, at: 123)
            } else {
                check(handled, "editor switch uses existing source barrier"); r.b.step()
            }
            check(sampled == [true] && selected == [abc, ko] && r.sent.isEmpty,
                  "one round trip begins in the commit, before any original is delivered")
            if delayed {
                r.time += 0.004; r.b.step()
                check(r.b.selectingTemporaryABC, "a delayed temporary ABC notification cannot supersede the commit diagnostic")
                check(r.sent.isEmpty && r.b.busy, "keys remain queued until the effective layout catches up")
                r.phase = .ready
            }
            r.advance(16)
            check(r.body == "rk간" && r.selection == NSRange(location:3,length:0)
                  && r.sent == [15,115,40,140,1,101] && r.saved.isEmpty && r.writes == 0 && !r.b.busy,
                  "matching draft survives, overlapping rks reaches the editor exactly once")
            r.b.didSwitchWithoutField(ko, at: 123)
            check(!r.b.selectingTemporaryABC, "future user source changes are observed after the return")
            check(selected == [abc, ko] && sampled.last == false, "duplicate confirmation cannot re-arm")
        }
    }
    for (target, explicit, stamp, phase) in [
        (ko,true,UInt64(44),B.InitialLayout.ready), (ko,true,44,.unknown), (ko,false,44,.conflicting),
        (ko,true,0,.conflicting), (KoreanKeyboardLayout.threeSetID,true,44,.conflicting), (abc,true,44,.conflicting)
    ] {
        let r = Rig("",0); r.phase = phase
        r.focus = nil; r.b.frontPID = { 91 }; r.b.frontWindow = { _ in r.w }
        r.b.observeSwitchCommit = { _, _, _ in phase }
        r.b.selectRoundTripSource = { _ in fatalError("unrequested source cycle") }
        check(!r.b.request(target, at:stamp, rightCommand:explicit), "direct fast-path setup")
        r.src = target; r.b.didSwitchWithoutField(target, at:stamp)
        check(!r.b.busy && r.probes == 0, "no delay or post-selection poll on normal and unrelated switches")
    }
    for reason in ["changedSource", "changedWindow", "persistentLayout", "targetSelectFailed"] {
        let r = Rig("",0); r.focus = nil
        r.b.frontPID = { 91 }; r.b.frontWindow = { _ in r.window }
        r.b.observeSwitchCommit = { _, _, inspect in inspect ? .conflicting : nil }
        var selections: [String] = []
        r.b.selectRoundTripSource = { id in
            selections.append(id)
            if id == ko && reason == "targetSelectFailed" { return -50 }
            r.src = id; return noErr
        }
        check(!r.b.request(ko, at:42, rightCommand:true), "outside failure setup")
        r.src = ko; r.b.didSwitchWithoutField(ko, at:42, prior:.init(pid:91,window:r.w,stamp:42,at:r.time))
        check(r.sendKey(15) && r.sendKey(15,false), "pending original edges held")
        switch reason {
        case "changedSource": r.src = "third"
        case "changedWindow": r.window = r.other; r.phase = .ready
        default: break
        }
        r.time += 0.035; r.advance(3)
        if reason == "persistentLayout" {
            check(r.sent == [15,115] && r.saved.isEmpty && r.stages.contains("round_trip_unconfirmed"), "bounded native fallback")
        } else {
            check(r.sent.isEmpty && r.saved == [15,115], "undelivered edges retained on source or recipient loss")
        }
        check(!r.b.busy && selections == [abc,ko], "failure neither reselects nor duplicates")
    }
    for pending in [true,false] {
        for (letters,wanted) in [([UInt16(15),40],"가"),([UInt16(15),46,0],"금"),([UInt16(1),40],"나")] {
            for draft in ["","rk","1234567890123456"] {
                let r=Rig(draft,draft.utf16.count);r.request()
                if !pending{r.advance(2);check(!r.b.busy,"no idle wait for layout")}
                for code in letters {check(r.sendKey(code) && r.sendKey(code,false),"both physical edges owned")}
                r.advance(2)
                check(r.sent.isEmpty && r.body==draft && r.writes==0,"unsettled layout never releases leading keys or edits draft")
                r.phase = .ready;r.advance(letters.count*2+5)
                check(r.sent==letters.flatMap{[Int($0),Int($0)+100]} && r.body==draft+wanted && r.writes==0 && r.saved.isEmpty && !r.b.busy,"full first run once, original intact")
            }
        }
    }
    // The OS layout and the editor's AX representation are independent.
    // Stale AX can start with either a label or real text that the editor
    // replaces on its own first insertion. No HanQ selection is written.
    for prior in ["Fixture title 16","Existing draft!!"] {
        let r=Rig(prior,0);r.original="";r.position=0;r.request();r.advance(2)
        for c:UInt16 in [15,46,0]{check(r.sendKey(c) && r.sendKey(c,false),"all pre-delivery edges captured")}
        r.advance(2);check(r.body==prior && r.sent.isEmpty,"old representation intact until native layout catches up")
        r.phase = .ready;r.advance(15)
        check(r.body=="금" && r.sent==[15,115,46,146,0,100] && r.writes==0 && !r.b.busy,"native editor replaces initial body exactly once")
    }
    // A newly restored, identical-looking draft is not the buffered keystrokes.
    do {
        let r=Rig("Fixture title 16",0);r.request();r.advance(2)
        for c:UInt16 in [15,40]{_=r.sendKey(c);_=r.sendKey(c,false)}
        r.body="rk";r.selection=NSRange(location:2,length:0);r.phase = .ready;r.advance(8)
        check(r.body=="rk" && r.sent.isEmpty && r.saved==[15,115,40,140] && r.writes==0,"old rk restored during hold is never rewritten")
    }
    do {
        let r=Rig("draft",5);r.nativeKoreanUnderABC=true;r.request();r.advance(2)
        for c:UInt16 in [15,40]{_=r.sendKey(c);_=r.sendKey(c,false)}
        r.advance(3);check(r.sent.isEmpty,"first 60ms remains bounded readiness grace");r.advance(2);check(!r.sent.isEmpty,"persistent conflict releases first original by the first poll after 80ms");r.advance(15)
        check(r.body=="draft가" && r.sent==[15,115,40,140] && r.saved.isEmpty && r.writes==0 && !r.b.busy &&
              r.stages.contains("initial_original_resumed"),"persistent layout-only conflict never permanently parks healthy native input")
    }
    do {
        let r=Rig("draft",5);r.request();r.advance(2)
        for code:UInt16 in [15,40]{_=r.sendKey(code);_=r.sendKey(code,false)}
        r.advance(12)
        check(r.sent==[15,115,40,140] && r.body=="draftrk" && r.stages.contains("initial_transport_completed"),
              "ASCII fallback waits only for transport; stale predicted Korean cannot capture the next key")
        check(!r.b.busy && !r.sendKey(51) && r.saved.isEmpty && r.writes==0,"fresh edit stays native")
    }
    for cause in ["field","window","draft","caret","source","deadline","shortcut","missing"]{
        let r=Rig("rk",2);r.request();r.advance(2)
        for c:UInt16 in [15,40] {check(r.sendKey(c) && r.sendKey(c,false),"start unsafe case")}
        switch cause {
        case "field":r.focus=r.other;r.phase  = .ready
        case "window":r.window=r.other;r.phase  = .ready
        case "draft":r.body="restored";r.phase  = .ready
        case "caret":r.selection=NSRange(location:0,length:0);r.phase  = .ready
        case "source":r.phase  = .sourceChanged
        case "deadline":r.phase = .unknown;r.time+=1.2
        case "missing":r.focus=nil;r.phase  = .ready
        default:let event=key(55,.maskCommand);event.type = .flagsChanged;check(!r.b.receive(.flagsChanged,event),"new shortcut left to original route")
        }
        r.advance(3)
        check(r.sent.isEmpty && r.writes==0 && r.saved==[15,115,40,140] && !r.b.busy,"retain original edges once on "+cause)
    }
    for condition in ["healthy","unknown","expired","untimed","other-field","shortcut","autorepeat","no-request","no-window"] {
        let r=Rig("draft",3)
        if condition != "no-request"{r.request(condition=="untimed" ? 0:42);r.advance(2)}
        if condition=="expired"{r.time+=2}
        if condition=="other-field"{r.focus=r.other}
        if condition=="no-window"{r.window=nil}
        if condition=="healthy"{r.phase  = .ready}
        if condition=="unknown"{r.phase  = .unknown}
        let event=key(15,condition=="shortcut" ? .maskCommand:[])
        if condition=="autorepeat"{event.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
        check(!r.b.receive(.keyDown,event) && r.sent.isEmpty && r.saved.isEmpty && !r.b.busy && r.writes==0,"original fast path "+condition)
    }
}
