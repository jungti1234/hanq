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
    // Native arm64 HID tick values are much smaller than session nanoseconds.
    // Reproduce the false pre-switch branch with the same provenance adapter.
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:3,numerator:125,denominator:3)==125,"Mach ticks convert with integer precision")
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:123,numerator:1,denominator:1)==123,"unit timebase preserves timestamps")
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:1,numerator:125,denominator:3)==41,"fractional nanoseconds round down")
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:UInt64.max,numerator:2,denominator:2)==UInt64.max,"full-width multiplication avoids intermediate overflow")
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:UInt64.max,numerator:125,denominator:3)==0,"unrepresentable clock value has no invented ordering")
    probeTestCheck(MismatchEventClock.nanoseconds(fromHIDTicks:100,numerator:1,denominator:0)==0 && MismatchEventClock.nanoseconds(fromHIDTicks:100,numerator:0,denominator:1)==0,"invalid timebase cannot poison the switch watermark")
    do {
        let engine=MismatchRecoveryEngine();engine.enabled=true;engine.testSource={mismatchKoreanID};engine.testFastContext={true}
        var reads=0;engine.testSnapshot={reads+=1;return MismatchSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))}
        engine.noteUserSourceSwitch(at:100000)
        let hid=key(2,3000)
        let tag=engine.captureEventOrigin(.keyDown,hid)!
        _=engine.event(.keyDown,delivered(2,200000,tag))
        probeTestCheck(reads==0 && engine.plan==nil,"unconverted native tick value reproduces false pre-switch rejection")
    }
    let clockNow:UInt64=1_000_000_000_000
    probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(23_999_999_997,observedAt:clockNow,numerator:125,denominator:3)==999_999_999_875,"hardware HID ticks select the compatible monotonic clock")
    probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(clockNow-125,observedAt:clockNow,numerator:125,denominator:3)==clockNow-125,"already-nanosecond posted HID is never double converted")
    probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(clockNow-125,observedAt:clockNow,numerator:1,denominator:1)==clockNow-125,"unit clocks remain exact")
    probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(UInt64.max,observedAt:clockNow,numerator:125,denominator:3)==0,"future/overflow clocks cannot poison the source boundary")
    probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(0,observedAt:clockNow,numerator:125,denominator:3)==0,"zero clock remains unknown")
    for raw:UInt64 in [23_952_000_000,998_000_000_000] {
        probeTestCheck(MismatchEventClock.normalizeHIDTimestamp(raw,observedAt:clockNow,numerator:125,denominator:3)==998_000_000_000,"genuinely old keys retain their age in either HID representation")
    }
    for old in [false,true] {
        let engine=MismatchRecoveryEngine();engine.enabled=true;engine.testSource={mismatchKoreanID};engine.testFastContext={true}
        var snapshots=0
        engine.testSnapshot={snapshots+=1;return MismatchSnapshot(element:field,text:"",selection:NSRange(location:0,length:0))}
        // A synthetic 125/3 timebase makes the test independent of its host.
        let hid=key(2,old ? 2000:3000)
        let normalized=MismatchEventClock.nanoseconds(fromHIDTicks:hid.timestamp,numerator:125,denominator:3)
        engine.noteUserSourceSwitch(at:100000)
        let gate=MismatchSwitchGate(accepts:{false},switched:{_ in})
        var forwarded=0
        gate.forwarded={type,event,time in forwarded+=1;engine.captureEventOrigin(type,event,at:time)}
        _=gate.receive(.keyDown,hid,at:normalized)
        let token=hid.getIntegerValueField(.eventSourceUserData)
        probeTestCheck(hid.timestamp==(old ? 2000:3000) && forwarded==1,"normalization leaves delivered event timestamp unchanged")
        _=engine.event(.keyDown,delivered(2,200000,token))
        probeTestCheck(old ? engine.plan==nil && snapshots==0:engine.plan?.roman=="d" && snapshots>0,old ? "genuinely pre-switch HID key remains excluded after downstream retiming":"post-switch HID key creates candidate despite smaller raw tick value")
    }
    do {
        var switchTime:CGEventTimestamp=0,capsTime:CGEventTimestamp=0,forwardedTime:CGEventTimestamp=0
        let gate=MismatchSwitchGate(accepts:{true},switched:{switchTime=$0})
        gate.forwarded={_,_,time in forwardedTime=time}
        let command=key(54,3000);command.type = .flagsChanged;command.flags=CGEventFlags(rawValue:0x10|CGEventFlags.maskCommand.rawValue)
        _=gate.receiveHID(.flagsChanged,command)
        probeTestCheck(switchTime==MismatchEventClock.hidTimestamp(command) && command.timestamp==3000,"native right Command uses normalized boundary without mutating raw event")
        let caps=key(57,4000);caps.type = .flagsChanged;caps.flags=[]
        gate.acceptsExternalSource={true};gate.capsChanged={capsTime=$0}
        _=gate.receiveHID(.flagsChanged,caps)
        probeTestCheck(capsTime==MismatchEventClock.hidTimestamp(caps) && forwardedTime==capsTime,"native Caps and ordinary provenance use the same normalized domain")
    }
    do {
        let engine=MismatchRecoveryEngine()
        let command=key(54,3000);command.type = .flagsChanged
        let token=engine.captureEventOrigin(.flagsChanged,command,at:125000)!
        let source=CGEventSource(stateID:.privateState)!;source.userData=token
        let downstream=CGEvent(keyboardEventSource:source,virtualKey:54,keyDown:true)!
        downstream.type = .flagsChanged;downstream.timestamp=900000
        probeTestCheck(engine.takeSourceSwitchTimestamp(.flagsChanged,downstream)==125000,"normal switch retains physical HID boundary despite session retiming")
        probeTestCheck(engine.takeSourceSwitchTimestamp(.flagsChanged,downstream)==900000,"consumed normal switch cannot reuse a stale provenance entry")
    }
    print("PASS: source timestamps normalize HID ticks, exclude older English and preserve queued source intervals")
}
