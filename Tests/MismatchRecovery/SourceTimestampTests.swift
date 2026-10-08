import AppKit
func runSourceTimestampTests() {
    let field=AXUIElementCreateApplication(12345),p=MismatchRecoveryEngine()
    p.enabled=true;p.testSource={mismatchKoreanID};p.testFastContext={true}
    var reads=0
    p.testSnapshot={reads+=1;return MismatchSnapshot(element:field,text:"alttab ",selection:NSRange(location:7,length:0))}
    let keySource=CGEventSource(stateID:.privateState)!
    func key(_ code:CGKeyCode,_ timestamp:CGEventTimestamp,_ down:Bool=true)->CGEvent {
        let e=CGEvent(keyboardEventSource:keySource,virtualKey:code,keyDown:down)!;e.flags=[];e.setIntegerValueField(.eventSourceUserData,value:0);e.timestamp=timestamp;return CGEvent(withDataAllocator:nil,data:e.data!)!
    }
    p.noteUserSourceSwitch(at:1000)
    probeTestCheck(p.event(.keyDown,key(17,900)) != nil && reads==0 && p.plan==nil,"older English t passes without Korean detection or AX reads")
    probeTestCheck(p.event(.keyUp,key(17,950,false)) != nil && reads==0,"older release passes")
    _=p.event(.keyDown,key(0,1100))
    probeTestCheck(p.plan?.roman=="a" && p.plan?.before=="alttab ","only post-switch a can become a Korean repair candidate")
    p.recovering=true;p.planElement=field;p.intendedSource=mismatchKoreanID
    p.userToggleDuringRecovery(at:2000)
    _=p.event(.keyDown,key(40,1900));_=p.event(.keyDown,key(0,2100))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending[0])]==mismatchKoreanID,"delayed pre-toggle key retains Korean intent")
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending[1])]==p.englishID,"post-toggle key retains English intent")
    p.userToggleDuringRecovery(at:3000)
    probeTestCheck(p.intendedSource(at:2500)==p.englishID && p.intendedSource(at:3100)==mismatchKoreanID,"multiple rapid boundaries preserve their source intervals")
    // Build the downstream copy with the captured source metadata. Fresh
    // synthetic CGEvents can continue reading their source's cached userData.
    func delivered(_ code:CGKeyCode,_ timestamp:CGEventTimestamp,_ token:Int64)->CGEvent {
        let source=CGEventSource(stateID:.privateState)!;source.userData=token
        let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true)!
        event.flags=[];event.timestamp=timestamp;return event
    }
    let identity=p.captureEventOrigin(.keyDown,key(35,3200))!
    p.userToggleDuringRecovery(at:3300)
    _=p.event(.keyDown,delivered(35,3400,identity))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==mismatchKoreanID,"HID intent survives Quartz retimestamping past a later switch")
    let laterIdentity=p.captureEventOrigin(.keyDown,key(2,3500))!
    _=p.event(.keyDown,delivered(2,3600,laterIdentity))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==p.englishID,"HID capture also preserves post-switch English intent")
    _=p.event(.keyDown,delivered(35,3700,identity))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==p.englishID,"consumed origin identity cannot reuse stale Korean intent")
    // The independent provenance gate stamps before this engine's HID tap.
    // Keep that identity while retaining the existing language-boundary intent.
    let routedToken:Int64=0x4852000100000042
    let routed=delivered(15,3800,routedToken)
    let sharedIdentity=p.captureEventOrigin(.keyDown,routed)
    probeTestCheck(sharedIdentity==routedToken,"provenance identity survives source capture")
    p.userToggleDuringRecovery(at:3900)
    _=p.event(.keyDown,delivered(15,4000,routedToken))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==p.englishID,"provenance-tagged key retains its pre-toggle source")
    let discardedToken:Int64=0x4852000100000043
    _=p.captureEventOrigin(.keyDown,delivered(1,4100,discardedToken))
    p.discardEventOrigin(discardedToken)
    p.userToggleDuringRecovery(at:4200)
    _=p.event(.keyDown,delivered(1,4300,discardedToken))
    probeTestCheck(p.pendingSources[p.bufferedID(p.pending.last!)]==p.englishID,"direct dispatch consumes engine source history")
    print("PASS: source timestamps exclude older English from repair and preserve queued source intervals")
}
