import AppKit
import Carbon
func runSourceInteractionTests() {
    let korean=mismatchKoreanID,english="com.apple.keylayout.ABC",otherKorean=KoreanKeyboardLayout.threeSet390ID
    let field=AXUIElementCreateApplication(getpid());var clock=1.0
    func fixture()->(MismatchRecoveryEngine,()->String,(String)->Void) {
        var source=korean
        let p=MismatchRecoveryEngine();p.enabled=true;p.recovering=true;p.target=NSRunningApplication.current
        p.recoverySourceID=korean;p.intendedSource=korean;p.lastIntendedKorean=korean;p.planElement=field
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+100;p.interactionNow={clock};p.systemSwitch.now={clock};p.systemSwitch.reset(source)
        p.observeSourcesForTests=true;p.testFastContext={true};p.testSource={source}
        p.testEventRecipient={e in e.getIntegerValueField(.keyboardEventKeycode)==125 ? 99999:getpid()}
        p.testSnapshot={MismatchSnapshot(element:field,text:"r",selection:NSRange(location:1,length:0))}
        p.testSelectSource={id in source=id;return noErr};p.testPost={_ in};p.capsSwitchEnabled={true}
        return (p,{source},{source=$0})
    }
    func key(_ code:CGKeyCode,_ time:CGEventTimestamp,_ down:Bool=true,_ pid:Int64=Int64(getpid()))->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];e.timestamp=time
        e.setIntegerValueField(.eventTargetUnixProcessID,value:pid)
        return CGEvent(withDataAllocator:nil,data:e.data!)!
    }
    do {
        let (p,source,set)=fixture()
        probeTestCheck(p.chooseSource(english)==noErr && source()==english,"recovery chooses exact English")
        p.observeRecoverySource(english,at:100)
        probeTestCheck(p.intendedSource==korean && p.recoverySourceBoundaries.isEmpty,"own temporary source does not alter user intent")
        p.potentialCapsSourceSwitch(at:200)
        probeTestCheck(p.sourceWorkPaused && p.intendedSource==korean,"Caps press alone does not invent a source change")
        set(korean);p.observeRecoverySource(korean,at:210)
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==english,"Caps while temporarily English toggles logical Korean to English")
        probeTestCheck(p.intendedSource(at:199)==korean && p.intendedSource(at:201)==english,"Caps boundary retains raw event timestamp")
        let down=key(0,220);_=p.captureEventOrigin(.keyDown,down);_=p.event(.keyDown,down)
        probeTestCheck(p.pending.last.map{p.pendingSources[p.bufferedID($0)]==english} ?? false,"post-Caps key retains English intent")
        p.setUserSourceIntent(otherKorean,at:230)
        let up=key(0,240,false);_=p.captureEventOrigin(.keyUp,up);_=p.event(.keyUp,up)
        probeTestCheck(p.pending.last.map{p.pendingSources[p.bufferedID($0)]==english} ?? false,"release keeps the down's source across another switch")
        probeTestCheck(p.lastIntendedKorean==otherKorean && p.toggledUserSource(english)==otherKorean,"menu-selected Korean layout is retained for the next toggle")
        p.closeSession()
    }
    do {
        let (p,_,_)=fixture();p.capsSwitchEnabled={false};p.potentialCapsSourceSwitch(at:300)
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==korean,"Caps setting OFF does not become a HanQ toggle")
        p.capsSwitchEnabled={true};p.potentialCapsSourceSwitch(at:310);clock+=1.05;p.observeRecoverySource(korean,at:320)
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==korean && p.recoverySourceBoundaries.isEmpty,"no actual source change expires without a guessed toggle")
        p.closeSession()
    }
    do {
        let (p,_,set)=fixture();_=p.chooseSource(english);p.potentialCapsSourceSwitch(at:1000)
        // Press before Caps, then one queued press and one HID-origin press
        // after Caps, before macOS acknowledges the source change.
        let before=key(8,990);_=p.captureEventOrigin(.keyDown,before);_=p.event(.keyDown,before)
        let after=key(0,1010);_=p.captureEventOrigin(.keyDown,after);_=p.event(.keyDown,after)
        let release=key(0,1020,false);_=p.captureEventOrigin(.keyUp,release);_=p.event(.keyUp,release)
        let later=key(11,1030);_=p.captureEventOrigin(.keyDown,later)
        clock+=0.45;p.observeRecoverySource(english)
        probeTestCheck(p.sourceWorkPaused && p.intendedSource==korean,"450ms without actual change must still wait, not guess or resume")
        clock+=0.15;set(korean);p.observeRecoverySource(korean)
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==english,"600ms delayed actual Caps toggles original intent")
        let sources=p.pending.map{p.pendingSources[p.bufferedID($0)] ?? ""}
        probeTestCheck(sources==[korean,english,english],"queued pre-Caps key and post-Caps press/release retain correct languages")
        later.timestamp=2000;_=p.event(.keyDown,later)
        probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==english,"in-flight post-Caps HID origin is resolved before changed event timestamp")
        let beforeRelease=key(8,1040,false);_=p.captureEventOrigin(.keyUp,beforeRelease);_=p.event(.keyUp,beforeRelease)
        probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==korean,"pre-Caps held key release keeps its Korean press")
        p.closeSession()
    }
    do {
        let (p,_,set)=fixture();_=p.chooseSource(english);p.potentialCapsSourceSwitch(at:1100)
        let after=key(0,1110);_=p.captureEventOrigin(.keyDown,after);_=p.event(.keyDown,after)
        clock+=1.05;p.observeRecoverySource(english)
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==korean && p.pendingSources[p.bufferedID(p.pending[0])]==korean,"unconfirmed Caps expiry must not relabel queued keys")
        p.closeSession()
        set(korean);p.observeRecoverySource(korean)
        probeTestCheck(!p.recovering,"late source notification cannot reopen cancelled recovery")
    }
    do {
        let (p,_,set)=fixture();_=p.chooseSource(english);p.potentialCapsSourceSwitch(at:1200)
        p.setUserSourceIntent(otherKorean,at:1230)
        clock+=0.6;set(korean);p.observeRecoverySource(korean)
        probeTestCheck(p.intendedSource==otherKorean && p.intendedSource(at:1210)==english,"late Caps acknowledgement preserves a newer explicit source boundary")
        p.closeSession()
    }
    do {
        let (p,source,set)=fixture();_=p.chooseSource(english)
        p.beginSourceMenu(at:400)
        probeTestCheck(p.sourceMenuPaused && source()==korean,"opening menu restores visible user source before selection")
        var ran=false;p.later(0){ran=true};RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        probeTestCheck(!ran && !p.pausedRecoveryActions.isEmpty,"recovery does not select/edit during menu interaction")
        let navigation=key(125,410,true,99999)
        probeTestCheck(p.event(.keyDown,navigation) != nil && p.pending.isEmpty,"menu navigation is not buffered as field text")
        set(otherKorean);p.observeRecoverySource(otherKorean,at:420)
        probeTestCheck(p.intendedSource==otherKorean,"actual menu change preserves exact selected layout")
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        probeTestCheck(!p.sourceWorkPaused && ran,"menu selection resumes deferred recovery exactly once")
        let down=key(0,430);_=p.captureEventOrigin(.keyDown,down);_=p.event(.keyDown,down)
        probeTestCheck(p.pending.last.map{p.pendingSources[p.bufferedID($0)]==otherKorean} ?? false,"following key carries menu-selected source")
        p.closeSession()
    }
    do {
        let (p,_,_)=fixture();p.beginSourceMenu(at:500)
        let before=p.recoveryDeadline;clock+=2
        let typed=key(0,510);_=p.captureEventOrigin(.keyDown,typed);_=p.event(.keyDown,typed)
        probeTestCheck(!p.sourceWorkPaused && p.pending.count==1 && p.recoveryDeadline>=before+2,"cancelled menu: paused=\(p.sourceWorkPaused) pending=\(p.pending.count) eventPID=\(typed.getIntegerValueField(.eventTargetUnixProcessID)) target=\(p.target?.processIdentifier ?? -1) budgetDelta=\(p.recoveryDeadline-before)")
        p.closeSession()
    }
    for code:CGKeyCode in [53,36] {
        let (p,_,_)=fixture();p.sourceMenuPopupVisible={false};p.beginSourceMenu(at:520)
        p.sourceMenuSawPopup=true
        // Quartz may still name the editor as recipient of the key closing a
        // system menu. It is menu input even when the popup has disappeared.
        let closing=key(code,530)
        probeTestCheck(p.event(.keyDown,closing) != nil && p.pending.isEmpty,"menu closing key must pass without becoming buffered editor input")
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        let release=key(code,540,false)
        probeTestCheck(p.event(.keyUp,release) != nil && p.pending.isEmpty,"menu closing release must pass after deferred recovery resumes")
        probeTestCheck(!p.sourceWorkPaused && !p.suspended,"menu close resumes the same recovery without retaining its closing key")
        p.closeSession()
    }
    do {
        let (p,_,_)=fixture();var popup=true;p.sourceMenuPopupVisible={popup};p.beginSourceMenu(at:550)
        let navigation=key(0,560)
        probeTestCheck(p.event(.keyDown,navigation) != nil && p.pending.isEmpty && p.sourceWorkPaused,"visible system menu owns typing even when Quartz names the editor")
        popup=false;p.sample()
        let release=key(0,570,false)
        probeTestCheck(p.event(.keyUp,release) != nil && p.pending.isEmpty,"menu navigation release cannot be delivered as a queued editor key")
        p.closeSession()
    }
    do {
        let (p,_,set)=fixture();p.beginSourceMenu(at:600);set("com.apple.inputmethod.Unknown");p.observeRecoverySource("com.apple.inputmethod.Unknown",at:610)
        probeTestCheck(p.suspended && !p.recovering,"unknown external source retains safely instead of guessing its layout")
    }
    do {
        let (p,_,_)=fixture();var popup=true;p.sourceMenuPopupVisible={popup};p.beginSourceMenu(at:650);p.sample()
        probeTestCheck(p.sourceMenuPaused && p.sourceMenuSawPopup,"real menu tracking is observed before a cancelled selection")
        popup=false;p.sample()
        probeTestCheck(!p.sourceWorkPaused && p.intendedSource==korean,"menu closure without a source change resumes unchanged intent")
        p.closeSession()
    }
    do {
        let (p,_,_)=fixture();p.systemSwitch.reset(korean)
        _=p.systemSwitch.request(english,valid:{true},current:{korean},select:{_ in noErr})
        p.potentialCapsSourceSwitch(at:700)
        probeTestCheck(p.suspended && !p.recovering,"unsettled internal selection cannot be mislabelled as user Caps")
    }
    do {
        let (p,current,set)=fixture()
        let base="앞🙂뒤"
        var expected=MismatchReplayLedger(before:base,caret:3);expected.append(source:korean,keys:[(15,false)])
        p.ledger=expected;p.intendedSource=english
        p.testSnapshot={MismatchSnapshot(element:field,text:expected.text,selection:expected.selection)}
        var selected:[String]=[],posts=0
        p.testSelectSource={id in selected.append(id);set(id);return noErr}
        p.testPost={_ in posts+=1}
        p.drain()
        RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        probeTestCheck(!p.recovering && !p.suspended && p.retained.isEmpty && current()==english,"source-only final boundary completes in requested English")
        probeTestCheck(selected==[english] && posts==0 && p.koreanRetries==0,"idle source boundary neither reopens Korean nor replays committed text")
        p.closeSession()
    }
    do {
        let (p,current,set)=fixture();set(english);p.systemSwitch.reset(english);p.intendedSource=english
        var expected=MismatchReplayLedger(before:"앞🙂뒤",caret:3);expected.append(source:korean,keys:[(15,false)])
        p.ledger=expected;p.testSnapshot={MismatchSnapshot(element:field,text:expected.text,selection:expected.selection)}
        let release=key(15,800,false);release.setIntegerValueField(.eventSourceUserData,value:1)
        p.pending=[release];p.pendingSources[1]=korean
        var selected:[String]=[],posted:[CGEventType]=[]
        p.testSelectSource={id in selected.append(id);set(id);return noErr};p.testPost={posted.append($0.type)}
        p.drain();RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        probeTestCheck(!p.recovering && !p.suspended && current()==english,"release-only batch keeps final English and finishes")
        probeTestCheck(selected.isEmpty && posted==[.keyUp] && p.koreanRetries==0,"an old release cannot reopen Korean or replay letters")
        p.closeSession()
    }
    print("PASS: Caps ON/OFF, actual-change proof, source ownership, menu pause/resume, layout and release boundaries; no OS posts")
    for mode in ["exact","changed","cancelled"] {
        let p=MismatchRecoveryEngine(),field=AXUIElementCreateApplication(321),other=AXUIElementCreateApplication(322)
        var source=p.englishID,selected:[String]=[],requests=0,done=false
        var reply:((MismatchSnapshotResult)->Void)?
        p.enabled=true;p.recovering=true;p.planElement=field;p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        p.testFastContext={true};p.testSource={source};p.testSelectSource={source=$0;selected.append($0);return noErr}
        p.testPost={_ in probeTestCheck(false,"source wait posted a key")}
        p.testAsyncRead={completion in
            requests+=1
            if requests==1{reply=completion}
            else{DispatchQueue.main.async{completion(MismatchSnapshotResult(snapshot:MismatchSnapshot(element:field,text:"r",selection:NSRange(location:1,length:0)),reason:""))}}
        }
        p.waitSource(p.englishID){done=true}
        source=mismatchKoreanID;p.setUserSourceIntent(p.englishID,at:1)
        if mode=="cancelled"{p.closeSession()}
        reply?(MismatchSnapshotResult(snapshot:MismatchSnapshot(element:mode=="changed" ? other:field,text:"r",selection:NSRange(location:1,length:0)),reason:""))
        RunLoop.current.run(until:Date().addingTimeInterval(0.04))
        probeTestCheck(selected==(mode=="exact" ? [p.englishID]:[]) && done==(mode=="exact"),"user boundary did not restore known phase promptly or unsafe reply selected a source")
        probeTestCheck(p.intendedSource==p.englishID,"temporary phase replaced user intent")
        p.closeSession()
    }
    print("PASS: user switch during pending source wait restores known phase immediately; intent retained; changed field and cancelled reply cannot select")
    do {
        let (p,current,_)=fixture();_=p.chooseSource(english)
        var requests=0,done=false;var reply:((MismatchSnapshotResult)->Void)?
        p.testAsyncRead={completion in
            requests+=1
            if requests==1{reply=completion}
            else{DispatchQueue.main.async{completion(MismatchSnapshotResult(snapshot:MismatchSnapshot(element:field,text:"r",selection:NSRange(location:1,length:0)),reason:""))}}
        }
        p.waitSource(english){done=true}
        p.beginSourceMenu(at:900);p.resumeSourceWork()
        probeTestCheck(current()==korean && p.recoverySourceBoundaries.isEmpty,"menu cancellation retains original intent without inventing an external source boundary")
        reply?(MismatchSnapshotResult(snapshot:MismatchSnapshot(element:field,text:"r",selection:NSRange(location:1,length:0)),reason:""))
        RunLoop.current.run(until:Date().addingTimeInterval(0.04))
        probeTestCheck(done && current()==english && p.intendedSource==korean && p.interruptedSourceRestores==1,"cancelled menu restores interrupted temporary phase promptly while retaining Korean intent")
        p.closeSession()
    }
    print("PASS: menu cancellation keys stay outside editor queue and cancelled source wait resumes promptly")
}
