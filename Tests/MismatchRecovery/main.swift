import AppKit
import Carbon
// CLI regression failures must not trigger macOS crash-report dialogs.
func probeTestCheck(_ condition:@autoclosure ()->Bool,_ message:@autoclosure ()->String="",file:StaticString=#fileID,line:UInt=#line){
    guard condition() else{
        fputs("FAIL \(file):\(line) \(message())\n",stderr)
        exit(1)
    }
}
let app=NSApplication.shared;let owner=MismatchRecoveryEngine(detectionOnly: ProcessInfo.processInfo.arguments.contains("--detect-only"));app.setActivationPolicy(.regular)
if ProcessInfo.processInfo.arguments.contains("--test-layouts") {
    runLayoutTests()
} else if ProcessInfo.processInfo.arguments.contains("--test-product") {
    var evaluated=false
    func privateFields()->[String:Any]{evaluated=true;return ["text":"PRIVATE_MISMATCH_PAYLOAD"]}
    owner.log("mismatch_confirmed",privateFields())
    owner.log("key",privateFields())
    probeTestCheck(!evaluated,"production evaluated private payload")
    owner.enabled=true;owner.recovering=true
    let key=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
    owner.pending=[key]
    var posted=0;owner.testPost={_ in posted+=1}
    owner.closeSession()
    probeTestCheck(!owner.enabled && !owner.recovering && owner.pending.isEmpty && owner.retained.count==1 && owner.suspended && posted==0)
    owner.closeSession()
    probeTestCheck(owner.retained.count==1,"teardown duplicated retained input")
    let controller=MismatchRecoveryController()
    controller.engine.recovering=true
    probeTestCheck(!controller.prepareManualEdit())
    controller.engine.recovering=false
    probeTestCheck(controller.prepareManualEdit())
    print("PASS: product privacy, idempotent stop preserves queue without replay, concurrent edits excluded")
} else if ProcessInfo.processInfo.arguments.contains("--test-delivery-progress") {
    runDeliveryProgressTests()
} else if ProcessInfo.processInfo.arguments.contains("--test-editor-coordinates") {
    runEditorCoordinateTests()
} else if ProcessInfo.processInfo.arguments.contains("--test-web-spaces") {
    runWebSpaceTests()
} else if ProcessInfo.processInfo.arguments.contains("--test-replay-verification") {
    let field=AXUIElementCreateApplication(12345)
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    func make()->MismatchRecoveryEngine {
        let p=MismatchRecoveryEngine();p.recovering=true;p.enabled=true;p.planElement=field
        p.testSource={mismatchKoreanID};p.testSelectSource={_ in noErr};p.testPost={_ in}
        return p
    }
    var ledger=MismatchReplayLedger(before:"앞🙂뒤",caret:3)
    ledger.append(source:mismatchKoreanID,keys:[(15,false),(40,false)])
    probeTestCheck(ledger.text=="앞🙂가뒤")
    ledger.append(source:mismatchKoreanID,keys:[(1,false),(40,false)])
    probeTestCheck(ledger.text=="앞🙂가나뒤")
    ledger.append(source:"com.apple.keylayout.ABC",keys:[(0,true)])
    ledger.append(source:mismatchKoreanID,keys:[(2,false),(40,false),(1,false)])
    probeTestCheck(ledger.text=="앞🙂가나A안뒤")
    let snapshot=MismatchSnapshot(element:field,text:ledger.text,selection:ledger.selection)
    let transient=make();var reads=0
    transient.testSnapshot={reads+=1;return reads<=3 ? nil:snapshot}
    transient.verifyBuffered(ledger,before:snapshot,remaining:10);pump(0.10)
    probeTestCheck(!transient.recovering && transient.retained.isEmpty && transient.ledger?.text==ledger.text)
    let missing=make();missing.testSnapshot={MismatchSnapshot(element:field,text:"앞🙂가나Aks뒤",selection:NSRange(location:8,length:0))}
    let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;missing.pending=[key]
    missing.verifyBuffered(ledger,before:snapshot,remaining:1);pump(0.05)
    probeTestCheck(!missing.recovering && missing.retained.count==1 && missing.ledger==nil)
    let changed=make();changed.pending=[key];changed.testSnapshot={MismatchSnapshot(element:AXUIElementCreateApplication(67890),text:ledger.text,selection:ledger.selection)}
    changed.verifyBuffered(ledger,before:snapshot,remaining:10)
    probeTestCheck(!changed.recovering && changed.retained.count==1)
    let buffering=make();buffering.testSnapshot={nil}
    probeTestCheck(buffering.event(.keyDown,key)==nil && buffering.pending.count==1)
    print("PASS: composition across batches; source boundaries; transient AX retries; wrong text never succeeds; changed field retains; AX miss still queues keys")
} else if ProcessInfo.processInfo.arguments.contains("--test-release-sources") {
    let probe=MismatchRecoveryEngine(detectionOnly:false);let field=AXUIElementCreateApplication(12345)
    probe.enabled=true;probe.recovering=true;probe.planElement=field;probe.intendedSource=mismatchKoreanID
    var source=mismatchKoreanID;var switches:[String]=[];var delivered:[String]=[]
    probe.testSource={source};probe.testSelectSource={source=$0;switches.append($0);return noErr}
    probe.testSnapshot={MismatchSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))}
    probe.testPost={delivered.append("\($0.type.rawValue):\($0.getIntegerValueField(.keyboardEventKeycode))")}
    let en=probe.englishID
    let seq:[(Int,Bool,String)]=[(3,true,mismatchKoreanID),(38,true,en),(3,false,mismatchKoreanID),(38,false,en),(5,true,mismatchKoreanID),(31,false,en),(38,true,mismatchKoreanID),(5,false,mismatchKoreanID),(38,false,mismatchKoreanID)]
    for (i,item) in seq.enumerated(){
        let event=CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(item.0),keyDown:item.1)!
        let id=Int64(i+1);event.setIntegerValueField(.eventSourceUserData,value:id)
        probe.bufferedIdentities[ObjectIdentifier(event)]=id
        event.setIntegerValueField(.eventSourceUserData,value:0) // Simulate mutable source metadata.
        probe.pending.append(event);probe.pendingSources[id]=item.2
    }
    probe.drain()
    let deadline=Date().addingTimeInterval(0.5)
    while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(!probe.recovering && probe.pending.isEmpty)
    probeTestCheck(switches==[en,mismatchKoreanID])
    probeTestCheck(delivered==seq.map{"\($0.1 ? 10:11):\($0.0)"})
    print("PASS: crossing releases preserve all nine events in order; exactly English then Korean, no release-driven switches")
} else if ProcessInfo.processInfo.arguments.contains("--test-app-following") {
    let probe=MismatchRecoveryEngine(detectionOnly:false)
    probe.enabled=true;probe.switchTarget(to:NSRunningApplication.current)
    probeTestCheck(probe.target?.processIdentifier==ProcessInfo.processInfo.processIdentifier && probe.ax != nil)
    let epoch=probe.recoveryEpoch
    probe.switchTarget(to:NSRunningApplication.current)
    probeTestCheck(probe.recoveryEpoch==epoch)
    probe.recovering=true
    probe.pending=[CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!]
    var posts=0;probe.testPost={_ in posts+=1}
    probe.switchTarget(to:nil)
    probeTestCheck(!probe.recovering && probe.target==nil && probe.ax==nil && probe.pending.isEmpty && probe.retained.count==1 && posts==0)
    probe.switchTarget(to:NSRunningApplication.current)
    probeTestCheck(probe.target != nil && probe.enabled && probe.retained.count==1)
    print("PASS: bind app, stable app unchanged, app departure retains queued key without posting, new app binds, retained input stays suspended")
} else if ProcessInfo.processInfo.arguments.contains("--test-boundary-gate") {
    var active=false;var switches=0
    let gate=MismatchSwitchGate(accepts:{active},switched:{switches+=1})
    func command(_ down:Bool)->CGEvent {
        let event=CGEvent(keyboardEventSource:nil,virtualKey:54,keyDown:down)!
        event.type = .flagsChanged;event.flags=CGEventFlags(rawValue:down ? 0x100010:0)
        return event
    }
    probeTestCheck(gate.receive(.flagsChanged,command(true)) != nil && switches==0)
    _ = gate.receive(.flagsChanged,command(false))
    active=true
    probeTestCheck(gate.receive(.flagsChanged,command(true)) == nil && switches==1)
    probeTestCheck(gate.receive(.flagsChanged,command(true)) == nil && switches==1)
    let letter=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
    letter.flags=CGEventFlags(rawValue:0x100010)
    probeTestCheck(gate.receive(.keyDown,letter) != nil && !letter.flags.contains(.maskCommand))
    active=false
    probeTestCheck(gate.receive(.flagsChanged,command(false)) == nil && switches==1)
    probeTestCheck(gate.receive(.flagsChanged,command(true)) != nil && switches==1)
    print("PASS: normal switching passes; active press consumed once; following keys cleaned; owned release consumed after recovery")
} else if ProcessInfo.processInfo.arguments.contains("--test-early-retry") {
    let field=AXUIElementCreateApplication(12345)
    var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3)
    _ = candidate.append(code:2,shift:false);_ = candidate.append(code:40,shift:false)
    for restored in [false,true] {
    var replayCandidate=candidate
    if restored { replayCandidate=candidate.restoredKoreanPlan(text:"앞🙂아뒤",selection:NSRange(location:4,length:0))! }
    for suffix in ["","d","dx","dk"] {
        let probe=MismatchRecoveryEngine(detectionOnly:false)
        let snap=MismatchSnapshot(element:field,text:"앞🙂"+suffix+"뒤",selection:NSRange(location:3+suffix.utf16.count,length:0))
        probe.enabled=true;probe.recovering=true;probe.replayStarted=true;probe.currentPlan=candidate;probe.planElement=field
        probe.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        probe.replayIssuedAt=ProcessInfo.processInfo.systemUptime
        probe.testSource={mismatchKoreanID};probe.testSnapshot={snap}
        var cycles=0;probe.testSelectSource={_ in cycles+=1;return noErr}
        probe.pending=[CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:true)!]
        probe.awaitKorean(replayCandidate,remaining:25)
        probeTestCheck(cycles == (suffix=="dk" ? 1:0))
        probeTestCheck(probe.koreanRetries == (suffix=="dk" ? 1:0))
        probeTestCheck(probe.pending.count==1)
        probe.recoveryEpoch+=1;probe.recovering=false
    }
    }
    let probe=MismatchRecoveryEngine(detectionOnly:false)
    probe.enabled=true;probe.planElement=field
    probe.testSelectionWritable={_ in true}
    var beganImmediately=false
    probe.testSelectSource={_ in beganImmediately=probe.recovering;return noErr}
    let snap=MismatchSnapshot(element:field,text:candidate.expected!,selection:NSRange(location:5,length:0))
    probe.beginRecovery(candidate,snap)
    probeTestCheck(beganImmediately && probe.detectionCount==1)
    probe.enabled=false;probe.recoveryEpoch+=1
    print("PASS: exact Roman starts retry immediately; absent/partial/unrelated output waits; pending keys preserved; recovery starts immediately")
} else if ProcessInfo.processInfo.arguments.contains("--test-detection-only") {
    let probe=MismatchRecoveryEngine(detectionOnly:true)
    let field=AXUIElementCreateApplication(12345)
    var candidate=MismatchRecoveryPlan(before:"앞",caret:1);_ = candidate.append(code:40,shift:false)
    let snap=MismatchSnapshot(element:field,text:"앞K",selection:NSRange(location:2,length:0))
    var writes=0
    probe.testPost={_ in writes+=1};probe.testSelectSource={_ in writes+=1;return noErr}
    probe.testSetRange={_,_ in writes+=1;return .success}
    probe.testSelectionWritable={_ in writes+=1;return true}
    let front=NSWorkspace.shared.frontmostApplication?.processIdentifier
    let windowsBefore=Set(NSApp.windows.map(ObjectIdentifier.init))
    probe.beginRecovery(candidate,snap)
    probeTestCheck(probe.detectionCount==1 && !probe.recovering && probe.pending.isEmpty && writes==0)
    probeTestCheck(Set(NSApp.windows.map(ObjectIdentifier.init))==windowsBefore)
    probeTestCheck(NSWorkspace.shared.frontmostApplication?.processIdentifier==front)
    let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!
    probe.enabled=true;probe.testSnapshot={snap}
    probeTestCheck(probe.event(.keyDown,key) != nil && probe.event(.keyUp,key) != nil)
    probe.post(key);_ = probe.chooseSource(mismatchKoreanID);_ = probe.setRange(field,NSRange(location:0,length:1))
    probeTestCheck(writes==0 && probe.pending.isEmpty && !probe.recovering)
    probe.closeSession();probeTestCheck(Set(NSApp.windows.map(ObjectIdentifier.init))==windowsBefore)
    print("PASS: silent detection, no window or focus change, keys pass through, all edit/source/post operations disabled")
} else if ProcessInfo.processInfo.arguments.contains("--test-retry-exhaustion") {
    for changed in [false,true] {
        let probe=MismatchRecoveryEngine(detectionOnly:false);let field=AXUIElementCreateApplication(12345)
        var candidate=MismatchRecoveryPlan(before:"앞🙂",caret:3)
        _ = candidate.append(code:5,shift:false);_ = candidate.append(code:4,shift:false)
        let snap=MismatchSnapshot(element:field,text:changed ? "앞🙂other":candidate.expected!,selection:NSRange(location:5,length:0))
        probe.enabled=true;probe.recovering=true;probe.replayStarted=true;probe.koreanRetries=2
        probe.currentPlan=candidate;probe.planElement=field;probe.testSource={mismatchKoreanID};probe.testSnapshot={snap}
        var delivered:[Int64]=[];probe.testPost={delivered.append($0.getIntegerValueField(.keyboardEventKeycode))}
        for (code,down) in [(5,true),(4,true),(5,false),(4,false)]{
            let event=CGEvent(keyboardEventSource:nil,virtualKey:CGKeyCode(code),keyDown:down)!
            probe.pending.append(event)
        }
        probe.retryKorean(candidate,snap)
        let deadline=Date().addingTimeInterval(0.3)
        while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        probeTestCheck(!probe.recovering && probe.enabled)
        if changed{probeTestCheck(delivered.isEmpty && probe.retained.count==4)}
        else{probeTestCheck(delivered == [5,4,5,4] && probe.pending.isEmpty && probe.retained.isEmpty)}
    }
    print("PASS: repeated failure returns all four gh events once; changed text retains them without editing; recovery ended")
} else if ProcessInfo.processInfo.arguments.contains("--test-modifier-loop") {
    owner.enabled=true;owner.recovering=true
    for code:CGKeyCode in [57,255,38] {
        let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true)!
        event.type = .flagsChanged
        for _ in 0..<100 {
            probeTestCheck(owner.event(.flagsChanged,event) != nil)
            probeTestCheck(owner.pending.isEmpty)
        }
        probeTestCheck(owner.prepareEvent(event)==nil)
    }
    owner.pending=[CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!]
    owner.park("test_failure")
    probeTestCheck(owner.enabled && !owner.recovering && owner.pending.isEmpty && owner.retained.count==1)
    let verify=MismatchRecoveryEngine(detectionOnly:false);let field=AXUIElementCreateApplication(12345)
    var candidate=MismatchRecoveryPlan(before:"앞",caret:1);_ = candidate.append(code:2,shift:false)
    verify.enabled=true;verify.recovering=true;verify.planElement=field;verify.currentPlan=candidate
    verify.testSource={mismatchKoreanID}
    verify.testSnapshot={MismatchSnapshot(element:field,text:"앞x",selection:NSRange(location:2,length:0))}
    var posts=0;verify.testPost={_ in posts+=1}
    verify.pending=[CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!]
    verify.awaitKorean(candidate,remaining:0)
    probeTestCheck(posts==0 && verify.retained.count==1 && verify.enabled && !verify.recovering)
    print("PASS: 300 modifier notifications bypass queue; failed repair retains keys; unchanged English never releases pending keys as success")
} else if ProcessInfo.processInfo.arguments.contains("--test-focus-routing") {
    let application=AXUIElementCreateApplication(12345)
    let other=AXUIElementCreateApplication(12346)
    owner.testFocusedRead={CFEqual($0,application) ? application:nil}
    probeTestCheck(owner.focusedElement(application,pid:12345).map{CFEqual($0,application)} == true)
    owner.testFocusedRead={CFEqual($0,owner.systemAX) ? application:nil}
    probeTestCheck(owner.focusedElement(application,pid:12345).map{CFEqual($0,application)} == true)
    owner.testFocusedRead={_ in other}
    probeTestCheck(owner.focusedElement(application,pid:12345)==nil)
    owner.testFocusedRead={_ in nil}
    probeTestCheck(owner.focusedElement(application,pid:12345)==nil)
    print("PASS: app focus, same-PID system fallback, foreign-PID rejection, missing focus")
} else if ProcessInfo.processInfo.arguments.contains("--test-field-tracking") {
    let first=AXUIElementCreateApplication(12345)
    let second=AXUIElementCreateApplication(12346)
    let a=MismatchSnapshot(element:first,text:"draft",selection:NSRange(location:5,length:0))
    let b=MismatchSnapshot(element:second,text:"",selection:NSRange(location:0,length:0))
    owner.observeAvailability(a)
    probeTestCheck(owner.locked.map{CFEqual($0,first)} == true)
    owner.plan=MismatchRecoveryPlan(before:"draft",caret:5)
    owner.planElement=first;owner.heldKeys=[2]
    owner.observeAvailability(a)
    probeTestCheck(owner.plan != nil && owner.planElement.map{CFEqual($0,first)} == true && owner.heldKeys==[2])
    owner.observeAvailability(b)
    probeTestCheck(owner.locked.map{CFEqual($0,second)} == true)
    probeTestCheck(owner.plan==nil && owner.planElement==nil && owner.heldKeys.isEmpty)
    owner.plan=MismatchRecoveryPlan(before:"",caret:0)
    owner.unavailableReason="selection_unreadable"
    owner.observeAvailability(nil)
    probeTestCheck(owner.plan==nil && owner.lastAvailability=="selection_unreadable")
    owner.observeAvailability(b)
    probeTestCheck(owner.lastAvailability=="tracking")
    print("PASS: initial binding, stable field, recreated field cancellation, unavailable state, resumed tracking")
} else if ProcessInfo.processInfo.arguments.contains("--test-rollback") {
    var checks=0
    func check(_ ok:Bool,_ name:String){probeTestCheck(ok,name);checks+=1}
    func scenario(ignoredCaret:Bool=false,changedText:Bool=false,newField:Bool=false,extraKey:Bool=false,stopDuring:Bool=false){
        let probe=MismatchRecoveryEngine(detectionOnly:false)
        let element=AXUIElementCreateApplication(12345)
        let other=AXUIElementCreateApplication(12346)
        var candidate=MismatchRecoveryPlan(before:"dkdkdkdkdkdkddkdkd",caret:18)
        _ = candidate.append(code:40,shift:false);_ = candidate.append(code:2,shift:false)
        var selection=NSRange(location:18,length:2)
        var posted:[(Int64,CGEventType)]=[]
        var requests=0
        probe.testSource={mismatchKoreanID};probe.testSelectSource={_ in noErr}
        probe.testSnapshot={MismatchSnapshot(element:newField ? other:element,text:changedText ? "changed":candidate.expected!,selection:selection)}
        probe.testSetRange={_,range in
            requests+=1
            if !ignoredCaret{DispatchQueue.main.asyncAfter(deadline:.now()+0.025){selection=range}}
            return .success
        }
        probe.testPost={event in posted.append((event.getIntegerValueField(.keyboardEventKeycode),event.type))}
        probe.enabled=true;probe.recovering=true;probe.currentPlan=candidate;probe.planElement=element
        let original:[(UInt16,Bool)]=[(40,true),(2,true),(2,false),(40,false),(2,true),(40,true),(2,false)]
        for (i,pair) in original.enumerated(){let event=CGEvent(keyboardEventSource:nil,virtualKey:pair.0,keyDown:pair.1)!;event.setIntegerValueField(.eventSourceUserData,value:Int64(i+1));probe.pending.append(event)}
        probe.nextBufferedID=7
        probe.abort("delete_not_verified")
        if extraKey{DispatchQueue.main.asyncAfter(deadline:.now()+0.015){let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:false)!;event.setIntegerValueField(.eventSourceUserData,value:8);probe.pending.append(event);probe.nextBufferedID=8}}
        if stopDuring{probe.stop()}
        let deadline=Date().addingTimeInterval(1)
        while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!probe.recovering,"bounded completion")
        if ignoredCaret || changedText || newField {
            check(posted.isEmpty,"never send into changed field/text or wrong selection")
            check(probe.retained.count==7,"pending keys retained")
            if changedText || newField{check(requests==0,"no cursor mutation on changed context")}
        } else {
            let expected=original.map{(Int64($0.0),$0.1 ? CGEventType.keyDown:.keyUp)} + (extraKey ? [(40,.keyUp)]:[])
            check(posted.count==expected.count,"every event returned")
            check(zip(posted,expected).allSatisfy{$0.0.0==$0.1.0 && $0.0.1==$0.1.1},"original ordering with no duplicate")
            check(probe.pending.isEmpty,"queue drained")
            check(selection==NSRange(location:20,length:0),"caret restored before return")
            check(requests==1,"one cursor restore request")
        }
    }
    scenario()
    scenario(extraKey:true)
    scenario(ignoredCaret:true)
    scenario(changedText:true)
    scenario(newField:true)
    scenario(stopDuring:true)
    print("PASS \(checks) rollback checks: ignored deletion, delayed caret, new input, ignored caret, changed context, stop during rollback")
} else if ProcessInfo.processInfo.arguments.contains("--test-async-snapshot") {
    runAsyncSnapshotTests()
} else if ProcessInfo.processInfo.arguments.contains("--test-fast-overwrite") {
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    let probe=MismatchRecoveryEngine();probe.selectionOverwrite=true;probe.perKeyAX=false
    var text="앞d뒤",selection=NSRange(location:1,length:1),reads=0,posts:[Int64]=[]
    var candidate=MismatchRecoveryPlan(before:"앞뒤",caret:1);_ = candidate.append(code:2,shift:false)
    probe.enabled=true;probe.recovering=true;probe.planElement=field;probe.currentPlan=candidate
    probe.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
    probe.testSource={mismatchKoreanID};probe.testFastContext={true}
    probe.testSnapshot={reads+=1;return MismatchSnapshot(element:field,text:text,selection:selection)}
    probe.testPost={event in
        let code=event.getIntegerValueField(.keyboardEventKeycode);posts.append(code)
        if event.type == .keyDown {
            if code==2 {probeTestCheck(selection==NSRange(location:1,length:1));text="앞ㅇ뒤"}
            else {probeTestCheck(code==40);text="앞아뒤"}
            selection=NSRange(location:2,length:0)
        }
    }
    for down in [true,false] {
        let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;event.flags=[]
        probeTestCheck(probe.event(event.type,event)==nil)
    }
    probeTestCheck(reads==0 && probe.pending.count==2)
    probe.awaitSelection(candidate,MismatchSnapshot(element:field,text:text,selection:selection),selection,remaining:15)
    let end=Date().addingTimeInterval(0.3)
    while probe.recovering && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(!probe.recovering && text=="앞아뒤" && posts==[2,2,40,40] && probe.retained.isEmpty)
    let changed=MismatchRecoveryEngine();changed.enabled=true;changed.recovering=true;changed.perKeyAX=false
    changed.planElement=field;changed.testFastContext={true};changed.testSource={mismatchKoreanID}
    var changedReads=0,changedPosts=0
    changed.testSnapshot={changedReads+=1;return MismatchSnapshot(element:other,text:"",selection:NSRange(location:0,length:0))}
    changed.testPost={_ in changedPosts+=1}
    let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!;event.flags=[]
    probeTestCheck(changed.event(.keyDown,event)==nil && changedReads==0)
    changed.drain()
    probeTestCheck(!changed.recovering && changedPosts==0 && changed.retained.count==1)
    print("PASS: selection overwrite posts no Backspace; queued vowel composes once; key callback makes zero AX reads; changed field receives no replay")
} else if ProcessInfo.processInfo.arguments.contains("--test-snapshot-retry") {
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    for mode in ["resume","changed","timeout","secure"] {
        let probe=MismatchRecoveryEngine();let began=ProcessInfo.processInfo.systemUptime
        var text="",selection=NSRange(location:0,length:0),posts:[Int64]=[]
        var candidate=MismatchRecoveryPlan(before:"",caret:0);_ = candidate.append(code:2,shift:false)
        probe.enabled=true;probe.recovering=true;probe.planElement=field;probe.currentPlan=candidate
        probe.recoveryDeadline=began+1.2;probe.testSource={mismatchKoreanID}
        probe.testSnapshot={
            if mode=="secure" {probe.unavailableReason="secure_input";return nil}
            if mode=="timeout" || ProcessInfo.processInfo.systemUptime-began<0.4 {
                probe.unavailableReason="focused_element_unreadable";return nil
            }
            return MismatchSnapshot(element:mode=="changed" ? other:field,text:text,selection:selection)
        }
        probe.testPost={event in
            posts.append(event.getIntegerValueField(.keyboardEventKeycode))
            if event.type == .keyDown {text=posts.count==1 ? "ㅇ":"아";selection=NSRange(location:1,length:0)}
        }
        for (i,down) in [true,false].enumerated(){
            let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;event.flags=[]
            let id=Int64(i+1);probe.bufferedIdentities[ObjectIdentifier(event)]=id;probe.pendingSources[id]=mismatchKoreanID;probe.pending.append(event)
        }
        probe.nextBufferedID=2;probe.awaitDeletion(candidate,field,remaining:15)
        while probe.recovering && ProcessInfo.processInfo.systemUptime-began<1.5{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        probeTestCheck(!probe.recovering)
        if mode=="resume" {probeTestCheck(text=="아" && posts==[2,2,40,40] && probe.retained.isEmpty && probe.postedBuffered==2)}
        else {probeTestCheck(posts.isEmpty && probe.retained.count==2)}
        if mode=="timeout" {probeTestCheck(ProcessInfo.processInfo.systemUptime-began<1.1)}
        if mode=="secure" {probeTestCheck(ProcessInfo.processInfo.systemUptime-began<0.1)}
    }
    print("PASS: 400ms AX outage resumes original queue exactly once; changed field, persistent outage and secure input never receive keys")
} else if ProcessInfo.processInfo.arguments.contains("--test-source-interruption") {
    let probe=MismatchRecoveryEngine(),field=AXUIElementCreateApplication(12345)
    var source=probe.englishID,text="",selection=NSRange(location:0,length:0)
    var selections=0;var posts:[Int64]=[]
    var candidate=MismatchRecoveryPlan(before:"",caret:0);_ = candidate.append(code:2,shift:false)
    probe.enabled=true;probe.recovering=true;probe.planElement=field;probe.currentPlan=candidate
    probe.testSource={source};probe.testSelectSource={source=$0;selections+=1;return noErr}
    probe.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
    probe.testPost={event in
        let code=event.getIntegerValueField(.keyboardEventKeycode);posts.append(code)
        if event.type == .keyDown {text=code==2 ? "ㅇ":"아";selection=NSRange(location:1,length:0)}
    }
    for (i,down) in [true,false].enumerated(){
        let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;event.flags=[]
        let id=Int64(i+1);probe.bufferedIdentities[ObjectIdentifier(event)]=id;probe.pendingSources[id]=mismatchKoreanID;probe.pending.append(event)
    }
    probe.nextBufferedID=2
    probe.awaitDeletion(candidate,field,remaining:15)
    let end=Date().addingTimeInterval(0.3)
    while probe.recovering && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(!probe.recovering && probe.retained.isEmpty && probe.pending.isEmpty)
    probeTestCheck(selections==1 && posts==[2,2,40,40] && text=="아")
    probeTestCheck(probe.postedBuffered==2 && probe.ledger?.text=="아")
    print("PASS: source interruption after deletion resumes without deleting twice; original d and queued k form 아 exactly once")
    let stalled=MismatchRecoveryEngine();var stalledSource=mismatchKoreanID,requests=0;var completed=false
    stalled.recovering=true;stalled.planElement=field
    stalled.testSource={stalledSource};stalled.testSelectSource={stalledSource=$0;requests+=1;return noErr}
    stalled.testSnapshot={MismatchSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))}
    stalled.waitSource(stalled.englishID,remaining:30){completed=true}
    RunLoop.current.run(until:Date().addingTimeInterval(0.04))
    probeTestCheck(completed && requests==1 && stalledSource==stalled.englishID)
    print("PASS: stalled shortcut selects exact target once before timeout")
    for valid in [true,false] {
        let splitProbe=MismatchRecoveryEngine();var cycles=0
        let before=MismatchSnapshot(element:field,text:"앞ㄴ뒤",selection:NSRange(location:2,length:0))
        let after=MismatchSnapshot(element:field,text:valid ? "앞ㄴㅜ뒤":"앞ㄴㅏ뒤",selection:NSRange(location:3,length:0))
        var expected=MismatchReplayLedger(before:"앞뒤",caret:1);expected.append(source:mismatchKoreanID,keys:[(1,false),(45,false)])
        splitProbe.recovering=true;splitProbe.planElement=field
        splitProbe.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        splitProbe.testSource={mismatchKoreanID};splitProbe.testSnapshot={after}
        splitProbe.testSelectSource={_ in cycles+=1;return noErr}
        splitProbe.verifyBuffered(expected,before:before,remaining:30,roman:"n",reopenComposition:true)
        probeTestCheck(cycles==(valid ? 1:0))
        probeTestCheck(splitProbe.currentPlan?.replayRoman==(valid ? "sn":nil))
        splitProbe.recovering=false;splitProbe.recoveryEpoch+=1
    }
    probeTestCheck(MismatchRecoveryPlan.matchesRestoredBatch(roman:"nfkr djqtd",inserted:"n락 없ㅇ"))
    probeTestCheck(!MismatchRecoveryPlan.matchesRestoredBatch(roman:"nfkr djqtd",inserted:"n락 업ㅇ"))
    probeTestCheck(!MismatchRecoveryPlan.matchesRestoredBatch(roman:"nfkr djqtd",inserted:"n락 없ㅇㅇ"))
    let sourceKeys="snfkr djqtdl gksrmfdmf dlqfu"
    probeTestCheck(MismatchRecoveryPlan.matchesSourceRoundTrip(roman:sourceKeys,inserted:"누락 없이 한그ㄹdmf dlqfu"))
    probeTestCheck(MismatchRecoveryPlan.matchesSourceRoundTrip(roman:"snfkr",inserted:"ㄴn락"))
    probeTestCheck(!MismatchRecoveryPlan.matchesSourceRoundTrip(roman:sourceKeys,inserted:"누락 없이 한그ㄹmf dlqfu"))
    probeTestCheck(!MismatchRecoveryPlan.matchesSourceRoundTrip(roman:sourceKeys,inserted:"누락 없이 한그ㄹddmf dlqfu"))
    print("PASS: exact split and mixed batches accepted; changed or duplicated keys rejected")
} else { exit(2) }
