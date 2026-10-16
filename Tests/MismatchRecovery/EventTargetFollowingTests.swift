import AppKit

func runEventTargetFollowingTests(){
    let app=NSRunningApplication.current
    let field=AXUIElementCreateApplication(app.processIdentifier)
    let owner=MismatchRecoveryEngine()
    owner.enabled=true;owner.followsFrontmost=true
    owner.testSource={mismatchKoreanID};owner.canObserve={true}
    var focusReads=0,snapshots=0,posts=0,selections=0
    owner.focusAccess.read={_ in focusReads+=1;Thread.sleep(forTimeInterval:0.05);return field}
    owner.testSnapshot={snapshots+=1;return nil}
    owner.testPost={_ in posts+=1};owner.testSelectSource={_ in selections+=1;return noErr}
    let key=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!
    key.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(app.processIdentifier))
    let began=ProcessInfo.processInfo.systemUptime
    let passed=owner.event(.keyDown,key) != nil
    let elapsed=ProcessInfo.processInfo.systemUptime-began
    print("event focusReads=\(focusReads) snapshots=\(snapshots) elapsedMs=\(elapsed*1000)")
    probeTestCheck(passed && owner.target==nil,"own process is excluded from observation targets")
    probeTestCheck(snapshots>0,"full snapshot verification still runs before candidate detection")
    probeTestCheck(focusReads==0,"ordinary event repeated synchronous target-discovery AX outside the verified snapshot")
    probeTestCheck(posts==0 && selections==0 && !owner.recovering,"unreadable context never edits or replays")
    // Missing recipient keeps the old actual-focus discovery, rather than
    // losing the first key/candidate when a producer omits target metadata.
    let missing=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:false)!
    missing.setIntegerValueField(.eventTargetUnixProcessID,value:0)
    probeTestCheck(owner.event(.keyUp,missing) != nil && focusReads>0,"missing recipient preserves actual-focus discovery")
    let previousReads=focusReads
    owner.followFrontmost()
    probeTestCheck(focusReads>previousReads,"idle target discovery retains actual system focus for nonactivating panels")
    owner.closeSession()
    print("PASS: event recipient avoids blocking AX target discovery; snapshot and idle panel focus checks retained; no posts or source changes")
}
