import AppKit
import Carbon

func runInitialLayoutTests(){
    typealias B=SourceSwitchBarrier
    let ko=KoreanKeyboardLayout.twoSetID,abc="com.apple.keylayout.ABC",layout="com.apple.keylayout.2SetHangul"
    check(B.classifyInitialLayout(first:ko,layout:abc,override:nil,last:ko) == .conflicting,"coherent ABC without override")
    check(B.classifyInitialLayout(first:ko,layout:abc,override:layout,last:ko) == .unknown,"overridden ABC cannot trigger guard")
    check(B.classifyInitialLayout(first:ko,layout:layout,override:layout,last:ko) == .ready,"actual Korean layout")
    check(B.classifyInitialLayout(first:ko,layout:abc,override:nil,last:abc) == .unknown,"torn read")
    check(B.classifyInitialLayout(first:abc,layout:abc,override:nil,last:abc) == .sourceChanged,"explicit switch away")
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
        b.initialLayout={.conflicting}
        check(b.unfocusedKeyCheck(1000,needsReadyLayout:true) == .layoutNotReady,"entirely ASCII output waits without owning input")
        b.initialLayout={.ready}
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
            b.now={time};b.frontPID={pid};b.frontWindow={_ in window};b.read={nil};b.initialLayout={.ready};b.ready={mode != "busy_recovery"}
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
                b.initialLayout={.conflicting}
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
            b.initialLayout={self.probes+=1;return self.phase}
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
    for pending in [true,false] {
        for (letters,wanted) in [([UInt16(15),40],"가"),([UInt16(15),46,0],"금"),([UInt16(1),40],"나")] {
            for draft in ["","rk","1234567890123456"] {
                let r=Rig(draft,draft.utf16.count);r.request()
                if !pending{r.advance(2);check(!r.b.busy,"no idle wait for layout")}
                for code in letters {check(r.sendKey(code) && r.sendKey(code,false),"both physical edges owned")}
                r.advance(12)
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
        r.advance(12);check(r.body==prior && r.sent.isEmpty,"old representation intact until native layout catches up")
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
        r.advance(60)
        check(r.body=="draft가" && r.sent==[15,115,40,140] && r.saved.isEmpty && r.writes==0 && !r.b.busy &&
              r.stages.contains("initial_original_resumed"),"persistent layout-only conflict never permanently parks healthy native input")
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
