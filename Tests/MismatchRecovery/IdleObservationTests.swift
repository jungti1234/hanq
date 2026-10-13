import AppKit

func runIdleObservationTests(){
    let field=AXUIElementCreateApplication(12345)
    for mode in ["resume","key","target","source","epoch","stale","stop","recovering","unsafe","other-edit"] {
        let p=MismatchRecoveryEngine();var source=mismatchKoreanID,safe=true,otherEdit=false
        var candidate=MismatchRecoveryPlan(before:"앞뒤",caret:1);_ = candidate.append(code:15,shift:false)
        p.enabled=true;p.followsFrontmost=false;p.lastSource=mismatchKoreanID;p.locked=field;p.plan=candidate;p.planElement=field;p.planStart=ProcessInfo.processInfo.systemUptime
        p.testSource={source};p.testFastContext={safe};p.canObserve={!otherEdit}
        p.testSnapshot={probeTestCheck(false,"idle timer used synchronous AX");return nil}
        p.testSelectionWritable={_ in true};p.testAsyncRead={_ in}
        var reads=0,selections=0,posts=0,heartbeat=false
        var completion:((MismatchSnapshotResult)->Void)?
        p.testIdleRead={reads+=1;completion=$0}
        p.testSelectSource={_ in selections+=1;return noErr};p.testPost={_ in posts+=1}
        p.sample();p.sample()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.01){heartbeat=true}
        RunLoop.current.run(until:Date().addingTimeInterval(0.03))
        probeTestCheck(reads==1 && heartbeat && !p.recovering && selections==0 && posts==0,"idle wait duplicated work or blocked input loop")
        if mode=="key" {
            let key=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:false)!
            _ = p.event(.keyUp,key)
        }
        if mode=="target"{p.target=NSRunningApplication.current}
        if mode=="source"{source=p.englishID}
        if mode=="epoch"{p.recoveryEpoch+=1}
        if mode=="stop"{p.closeSession()}
        if mode=="recovering"{p.recovering=true}
        if mode=="unsafe"{safe=false}
        if mode=="other-edit"{otherEdit=true}
        var result=MismatchSnapshotResult(snapshot:MismatchSnapshot(element:field,text:"앞r뒤",selection:NSRange(location:2,length:0)),reason:"")
        if mode=="stale"{result.completedAt-=1}
        completion?(result)
        probeTestCheck(selections==(mode=="resume" ? 1:0) && posts==0,"idle reply mode=\(mode) selections=\(selections)")
        if mode=="resume"{probeTestCheck(p.recovering,"fresh coherent idle result lost mismatch")}
        p.closeSession()
    }
    print("PASS: idle AX wait leaves main responsive; one request; fresh mismatch resumes; key/target/source/epoch/age/stop/recovery/safety/edit changes discard replies; no OS posts")
}
