import AppKit
import Carbon

// Exercise the real detector -> beginRecovery boundary. All reads, source
// selections and writes are injected; never send a key or select a live IME.
func runRecoveryStartTests(){
    let field=AXUIElementCreateApplication(12345)
    let cases:[([UInt16],String,InputIncidentTrace.RecoveryReason)]=[
        ([15,40],"rk",.romanMismatch),
        ([15,40],"ㄱㅏ",.decomposedJamo),
        ([15,40,1,40],"간ㅏ",.interruptedComposition),
        ([15,1,40],"r나",.mixedInsertion)
    ]
    var checks=0
    for (keys,inserted,reason) in cases {
        for enabled in [false,true] {
            var captures:[InputIncidentTrace.Capture]=[]
            let trace=InputIncidentTrace(destination:nil,initiallyEnabled:enabled,writer:{captures.append($0)})
            let engine=MismatchRecoveryEngine();engine.enabled=true;engine.incidentTrace=trace
            engine.lastSource=mismatchKoreanID;engine.locked=field;engine.planElement=field
            var plan=MismatchRecoveryPlan(before:"앞 뒤",caret:2)
            for key in keys{_ = plan.append(code:key,shift:false)}
            engine.plan=plan;engine.planStart=ProcessInfo.processInfo.systemUptime
            let snap=MismatchSnapshot(element:field,text:"앞 "+inserted+"뒤",selection:NSRange(location:2+inserted.utf16.count,length:0))
            engine.testSource={mismatchKoreanID};engine.testSnapshot={snap}
            engine.testSelectionWritable={_ in true}
            var selections=0,posts=0
            engine.testSelectSource={_ in selections+=1;return noErr}
            engine.testSetRange={_,_ in posts+=1;return .success};engine.testPost={_ in posts+=1}
            engine.canObserve={true};engine.canBeginRepair={true}
            trace.decision(.handoff,.handoffAccepted)
            engine.consumeIdleSnapshot(snap);trace.flush()
            probeTestCheck(engine.recovering && selections==1 && posts==0,"diagnostic does not change initial source/replay scheduling")
            if enabled {
                probeTestCheck(captures.count==1,"real recovery emits its own pre capture")
                let request=captures[0].capturePreservation!.requests[0]
                probeTestCheck(request.trigger==6 && request.detail==reason.rawValue && request.lane==4,"actual proof branch survives detector-to-capture handoff")
                probeTestCheck(captures[0].frames.contains{$0.kind == .detectionDecision && $0.category==25},"prior decision retained")
            }else{probeTestCheck(captures.isEmpty,"OFF changes no capture state")}
            engine.recoveryEpoch+=1;engine.recovering=false
            trace.stopAndFlush();checks+=1
        }
    }
    // A candidate rejected by the edit safety gate is not a started recovery.
    var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,writer:{captures.append($0)})
    let engine=MismatchRecoveryEngine();engine.incidentTrace=trace;engine.canBeginRepair={false}
    let plan=MismatchRecoveryPlan(before:"",caret:0)
    engine.beginRecovery(plan,MismatchSnapshot(element:field,text:"",selection:NSRange(location:0,length:0)))
    trace.flush();probeTestCheck(captures.isEmpty && !engine.recovering,"blocked recovery never reports started")
    print("PASS: \(checks) real recovery detector ON/OFF cases; fixed cause, unchanged safety/source/post behavior")
}
