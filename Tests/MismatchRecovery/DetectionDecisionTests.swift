import AppKit
import Carbon

func runDetectionDecisionTests() {
    typealias Reason=InputIncidentTrace.DecisionReason
    let cases:[(String,Reason)]=[("roman",.romanSource),("blocked",.observationBlocked),("old",.preSwitchKey),("snapshot",.snapshotUnavailable),("key",.candidateRejectedKey),("recorded",.candidateRecorded)]
    let field=AXUIElementCreateApplication(12345)
    var checks=0
    func check(_ condition:Bool,_ message:String){checks+=1;probeTestCheck(condition,message)}
    for (name,reason) in cases {
        var baseline:(Bool,Int,String?,Int)?
        for enabled in [false,true] {
            var captures:[InputIncidentTrace.Capture]=[]
            let trace=enabled ? InputIncidentTrace(destination:nil,writer:{captures.append($0)}):InputIncidentTrace(destination:nil)
            let engine=MismatchRecoveryEngine();engine.enabled=true;engine.incidentTrace=trace;engine.lastSource=mismatchKoreanID;engine.locked=field
            var reads=0,sourceReads=0
            engine.testSource={sourceReads+=1;return name=="roman" ? "com.apple.keylayout.ABC":mismatchKoreanID}
            engine.testFastContext={true};engine.canObserve={name != "blocked"};engine.canBeginRepair={false}
            engine.testSnapshot={reads+=1;return name=="snapshot" ? nil:MismatchSnapshot(element:field,text:"synthetic ",selection:NSRange(location:10,length:0))}
            engine.noteUserSourceSwitch(at:200)
            let source=CGEventSource(stateID:.privateState)!;source.userData=0
            let event=CGEvent(keyboardEventSource:source,virtualKey:name=="key" ? 36:2,keyDown:true)!
            event.flags=[];event.timestamp=name=="old" ? 100:300
            let beforeFlags=event.flags,beforeTime=event.timestamp,beforeTag=event.getIntegerValueField(.eventSourceUserData)
            // Mirror the real earlier HID observation. The later mismatch
            // metadata callback may legitimately miss a busy trace lock while
            // the asynchronous decision is being recorded.
            trace.event(.hid,.keyDown,event)
            let passed=engine.event(.keyDown,event) != nil
            trace.event(.mismatch,.keyDown,event);trace.mark();trace.flush()
            let outcome=(passed,reads,engine.plan?.roman,sourceReads)
            check(passed && !engine.recovering && engine.pending.isEmpty,"diagnostics must not create a repair or consume the event")
            check(event.flags==beforeFlags && event.timestamp==beforeTime && event.getIntegerValueField(.eventSourceUserData)==beforeTag,"diagnostics must preserve event routing state")
            if let baseline {
                check(outcome==baseline,"diagnostics ON/OFF must preserve passing, AX/source read counts and candidate")
                let frames=captures[0].frames
                let decisions=frames.filter{$0.kind == .detectionDecision && $0.edge==InputIncidentTrace.DecisionSite.event.rawValue}
                let input=frames.first{$0.kind == .event && $0.lane == .hid}!
                check(decisions.count==1 && decisions[0].category==reason.rawValue && decisions[0].event==input.event,"actual branch reason must correlate to the input")
            }else{baseline=outcome;check(captures.isEmpty,"disabled trace does not publish")}
        }
    }
    // A verified candidate rejected by repair eligibility is separate from an
    // observation skip. No selection or key posting should be reached.
    var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
    let engine=MismatchRecoveryEngine();engine.incidentTrace=trace;engine.canBeginRepair={false}
    var plan=MismatchRecoveryPlan(before:"",caret:0);_=plan.append(code:2,shift:false)
    engine.beginRecovery(plan,.init(element:field,text:"d",selection:NSRange(location:1,length:0)))
    trace.mark();trace.flush()
    check(captures[0].frames.contains{$0.kind == .detectionDecision && $0.category==Reason.repairBlocked.rawValue},"repair rejection is distinguishable from detection")
    check(!engine.recovering,"repair eligibility remains unchanged")
    print("PASS: \(checks) detection decisions; actual skip branches and diagnostics ON/OFF preserve delivery, reads, candidate and event state; no OS posts")
}
