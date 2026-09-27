import AppKit

func runAsyncSnapshotTests(){
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    var heartbeat=false,finished=false
    let worker=MismatchSnapshotWorker(read:{_ in
        probeTestCheck(!Thread.isMainThread)
        Thread.sleep(forTimeInterval:0.2)
        return MismatchSnapshotResult(snapshot:nil,reason:"test_outage")
    })
    worker.request(pid:0){_ in probeTestCheck(Thread.isMainThread);finished=true}
    DispatchQueue.main.asyncAfter(deadline:.now()+0.02){heartbeat=true}
    pump(0.07);probeTestCheck(heartbeat && !finished,"worker blocked main run loop")
    pump(0.2);probeTestCheck(finished)

    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    for mode in ["resume","changed","cancelled","unsafe","stale"] {
        let probe=MismatchRecoveryEngine();probe.asyncRecoveryReads=true
        var text="앞d뒤",selection=NSRange(location:1,length:1),posts:[Int64]=[]
        var safe=true,requests=0
        var waiting:((MismatchSnapshotResult)->Void)?
        var candidate=MismatchRecoveryPlan(before:"앞뒤",caret:1);_ = candidate.append(code:2,shift:false)
        probe.enabled=true;probe.recovering=true;probe.planElement=field;probe.currentPlan=candidate
        probe.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2
        probe.testFastContext={safe};probe.testSource={mismatchKoreanID}
        probe.testSnapshot={probeTestCheck(false,"async recovery used synchronous snapshot");return nil}
        probe.testAsyncRead={completion in
            requests+=1
            if requests==1{waiting=completion;return}
            DispatchQueue.main.async{
                completion(MismatchSnapshotResult(snapshot:MismatchSnapshot(element:field,text:text,selection:selection),reason:""))
            }
        }
        probe.testPost={event in
            let code=event.getIntegerValueField(.keyboardEventKeycode);posts.append(code)
            if event.type == .keyDown {
                probeTestCheck(code==2 || code==40)
                text=code==2 ? "앞ㅇ뒤":"앞아뒤";selection=NSRange(location:2,length:0)
            }
        }
        let before=MismatchSnapshot(element:field,text:text,selection:selection)
        probe.awaitSelection(candidate,before,selection,remaining:15)
        probeTestCheck(requests==1 && posts.isEmpty)
        for down in [true,false] {
            let key=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!;key.flags=[]
            probeTestCheck(probe.event(key.type,key)==nil)
        }
        probeTestCheck(probe.pending.count==2 && posts.isEmpty)
        if mode=="cancelled"{probe.park("test_cancelled")}
        if mode=="unsafe"{safe=false}
        var result=MismatchSnapshotResult(snapshot:MismatchSnapshot(element:mode=="changed" ? other:field,text:text,selection:selection),reason:"")
        if mode=="stale"{result.completedAt-=1}
        waiting?(result)
        if mode=="stale"{probeTestCheck(posts.isEmpty,"stale result edited text")}
        pump(0.15)
        if mode=="resume" || mode=="stale" {
            probeTestCheck(!probe.recovering && text=="앞아뒤" && posts==[2,2,40,40] && probe.retained.isEmpty,"queued vowel not delivered exactly once")
        }else{
            probeTestCheck(!probe.recovering && posts.isEmpty && probe.retained.count==2,"unsafe/late read replayed keys")
        }
    }
    print("PASS: blocked worker leaves main responsive; queued keys preserved; changed focus, cancelled epoch, unsafe context and stale result cannot replay")
}

func runWebSpaceTests(){
    // Edge changes the trailing NBSP to a regular space when d is inserted.
    var first=MismatchRecoveryPlan(before:"앞🙂\u{00a0}",caret:4)
    _ = first.append(code:2,shift:false)
    probeTestCheck(first.matches(text:"앞🙂 d",selection:NSRange(location:5,length:0)),"first d lost after NBSP change")
    let second=MismatchRecoveryPlan.next(previous:first,text:"앞🙂 d",selection:NSRange(location:5,length:0),code:37,shift:false)!
    probeTestCheck(second.replayRoman=="dl" && second.caret==4,"candidate discarded first key")
    var captured=second;captured.captureObserved(text:"앞🙂 dl")
    probeTestCheck(captured.before=="앞🙂 ","observed surroundings must be preserved")
    probeTestCheck(!first.matches(text:"뒤🙂 d",selection:NSRange(location:5,length:0)))
    probeTestCheck(!first.matches(text:"앞🙂  d",selection:NSRange(location:6,length:0)))
    probeTestCheck(!first.matches(text:"앞🙂\td",selection:NSRange(location:5,length:0)))

    let field=AXUIElementCreateApplication(12345)
    let p=MismatchRecoveryEngine();p.recovering=true;p.enabled=true;p.planElement=field
    p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2
    p.intendedSource=mismatchKoreanID;p.testSource={mismatchKoreanID}
    var ledger=MismatchReplayLedger(before:"앞🙂",caret:3)
    ledger.append(source:mismatchKoreanID,keys:[(49,false)])
    p.ledger=ledger
    var actual="앞🙂\u{00a0}",selection=NSRange(location:4,length:0),posts:[Int64]=[]
    p.testSnapshot={MismatchSnapshot(element:field,text:actual,selection:selection)}
    p.testPost={event in
        posts.append(event.getIntegerValueField(.keyboardEventKeycode))
        if event.type == .keyDown{actual="앞🙂 ㄱ";selection=NSRange(location:5,length:0)}
    }
    for (i,down) in [true,false].enumerated(){
        let e=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:down)!;e.flags=[]
        p.bufferedIdentities[ObjectIdentifier(e)]=Int64(i+1);p.pendingSources[Int64(i+1)]=mismatchKoreanID;p.pending.append(e)
    }
    p.nextBufferedID=2
    p.verifyBuffered(ledger,before:MismatchSnapshot(element:field,text:"앞🙂",selection:NSRange(location:3,length:0)),remaining:0,roman:" ")
    let end=Date().addingTimeInterval(0.2)
    while p.recovering && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    probeTestCheck(posts==[15,15] && p.pending.isEmpty && p.retained.isEmpty && !p.recovering,"space verification stranded queued key")
    probeTestCheck(actual=="앞🙂 ㄱ" && p.postedBuffered==2)
    print("PASS: NBSP boundary preserves first key; queued key delivered once; changed text/length/tab rejected")
}

func runEditorCoordinateTests(){
    // Replay the two live v42 failures: terminal paragraph representation and
    // a transient sample between first key receipt and text confirmation.
    var first=MismatchRecoveryPlan(before:"앞🙂\u{00a0}\n",caret:4)
    _ = first.append(code:2,shift:false)
    probeTestCheck(first.matches(text:"앞🙂 d",selection:NSRange(location:5,length:0)))
    var continued=MismatchRecoveryPlan.next(previous:first,text:"앞🙂 d",selection:NSRange(location:5,length:0),code:4,shift:false)!
    probeTestCheck(continued.replayRoman=="dh" && continued.caret==4)
    probeTestCheck(continued.matches(text:"앞🙂 dh",selection:NSRange(location:6,length:0)))
    continued.captureObserved(text:"앞🙂 dh")
    probeTestCheck(continued.before=="앞🙂 " && continued.roman=="dh")
    probeTestCheck(!first.matches(text:"뒤🙂 d",selection:NSRange(location:5,length:0)))
    probeTestCheck(!first.matches(text:"앞🙂 d뒤",selection:NSRange(location:5,length:0)))
    var interior=MismatchRecoveryPlan(before:"앞\n뒤",caret:1);_ = interior.append(code:2,shift:false)
    probeTestCheck(!interior.matches(text:"앞d뒤",selection:NSRange(location:2,length:0)))
    var twoLines=MismatchRecoveryPlan(before:"앞\n\n",caret:1);_ = twoLines.append(code:2,shift:false)
    probeTestCheck(!twoLines.matches(text:"앞d",selection:NSRange(location:2,length:0)))
    let field=AXUIElementCreateApplication(12345),other=AXUIElementCreateApplication(12346)
    let p=MismatchRecoveryEngine();p.testSource={mismatchKoreanID};p.locked=field;p.planElement=field
    p.plan=first;p.planStart=ProcessInfo.processInfo.systemUptime
    p.unavailableReason="editor_coordinates_unverified";p.observeAvailability(nil)
    probeTestCheck(p.plan?.roman=="d","temporary read discarded first key")
    p.observeAvailability(MismatchSnapshot(element:field,text:"앞🙂 d",selection:NSRange(location:5,length:0)))
    probeTestCheck(p.plan?.matches(text:"앞🙂 d",selection:NSRange(location:5,length:0))==true)
    p.observeAvailability(MismatchSnapshot(element:other,text:"앞🙂 d",selection:NSRange(location:5,length:0)))
    probeTestCheck(p.plan==nil,"candidate crossed field boundary")
    p.plan=first;p.planStart=ProcessInfo.processInfo.systemUptime-0.3;p.observeAvailability(nil)
    probeTestCheck(p.plan==nil,"expired candidate retained")
    p.plan=first;p.planStart=ProcessInfo.processInfo.systemUptime;p.testSource={"com.apple.keylayout.ABC"};p.observeAvailability(nil)
    probeTestCheck(p.plan==nil,"candidate retained across source change")

    probeTestCheck(MismatchTextReader.isBoundaryResponse(.noValue))
    probeTestCheck(MismatchTextReader.isBoundaryResponse(.illegalArgument))
    probeTestCheck(!MismatchTextReader.isBoundaryResponse(.cannotComplete))
    probeTestCheck(!MismatchTextReader.isBoundaryResponse(.parameterizedAttributeUnsupported))
    let native="앞🙂\n가나다\n끝",web="앞🙂\n가나다끝"
    for (value,canonical) in [(native,native),(native,web)] {
        for caret in [0,1,4,canonical.utf16.count] {
            let read:(NSRange)->String?={r in guard NSMaxRange(r)<=canonical.utf16.count else{return nil};return (canonical as NSString).substring(with:r)}
            probeTestCheck(MismatchTextReader.resolve(value:value,selection:NSRange(location:caret,length:0),read:read)==canonical)
        }
    }
    probeTestCheck(MismatchTextReader.resolve(value:native,selection:NSRange(location:2,length:0),read:{_ in nil})==nil)
    var calls=0
    probeTestCheck(MismatchTextReader.resolve(value:"abc",selection:NSRange(location:1,length:0),read:{r in calls+=1;return calls==1 ? "abc":"xyz"})==nil)
    probeTestCheck(MismatchTextReader.resolve(value:"abc",selection:NSRange(location:1,length:0),read:{_ in "a"})==nil)
    // A native selection and a browser selection retain their own offsets.
    let read:(NSRange)->String?={r in guard NSMaxRange(r)<=web.utf16.count else{return nil};return (web as NSString).substring(with:r)}
    probeTestCheck(MismatchTextReader.resolve(value:native,selection:NSRange(location:4,length:2),read:read)==web)
    var plan=MismatchRecoveryPlan(before:web,caret:web.utf16.count)
    _ = plan.append(code:2,shift:false)
    probeTestCheck(plan.matches(text:web+"d",selection:NSRange(location:web.utf16.count+1,length:0)))
    print("PASS: native/browser coordinate domains, multiline and emoji, beginning/middle/end/selection; unsupported/inconsistent/short reads rejected")
}

func runDeliveryProgressTests(){
    // Reproduce Notes: text for an earlier batch is confirmed just before the
    // old total deadline, while a space down/up still waits in the queue.
    let p=MismatchRecoveryEngine(),field=AXUIElementCreateApplication(12345)
    p.enabled=true;p.recovering=true;p.planElement=field;p.testSource={mismatchKoreanID};p.intendedSource=mismatchKoreanID
    p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+0.03
    p.postedBuffered=2;p.verifiedProgressEvents=0
    var ledger=MismatchReplayLedger(before:"아",caret:1)
    ledger.append(source:mismatchKoreanID,keys:[(49,false)])
    p.ledger=ledger
    var text="아 ",posts:[Int64]=[]
    p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:NSRange(location:text.utf16.count,length:0))}
    p.testPost={event in
        posts.append(event.getIntegerValueField(.keyboardEventKeycode))
        if event.type == .keyDown{text+=" "}
    }
    for (i,down) in [true,false].enumerated(){
        let e=CGEvent(keyboardEventSource:nil,virtualKey:49,keyDown:down)!;e.flags=[]
        let id=Int64(i+3);p.bufferedIdentities[ObjectIdentifier(e)]=id;p.pendingSources[id]=mismatchKoreanID;p.pending.append(e)
    }
    p.nextBufferedID=4
    p.verifyBuffered(ledger,before:MismatchSnapshot(element:field,text:"아",selection:NSRange(location:1,length:0)),remaining:1,roman:" ")
    RunLoop.current.run(until:Date().addingTimeInterval(0.12))
    probeTestCheck(text=="아  " && posts==[49,49],"pending space lost or earlier batch resent")
    probeTestCheck(p.pending.isEmpty && p.retained.isEmpty && !p.recovering && p.postedBuffered==4)

    let clock=MismatchRecoveryEngine();clock.recovering=true;clock.recoveryDeadline=2.5
    clock.confirmDeliveryProgress(0,now:0.2)
    clock.confirmDeliveryProgress(2,now:2.4)
    probeTestCheck(clock.recoveryDeadline==4.9)
    clock.confirmDeliveryProgress(4,now:4.8)
    probeTestCheck(clock.recoveryDeadline==7.3,"continuous verified delivery expired at old total deadline")
    let deadline=clock.recoveryDeadline
    clock.confirmDeliveryProgress(4,now:6.0)
    clock.confirmDeliveryProgress(2,now:6.1)
    probeTestCheck(clock.recoveryDeadline==deadline,"duplicate/stale acknowledgment extended stalled delivery")
    clock.rollingBack=true;clock.confirmDeliveryProgress(6,now:6.2)
    probeTestCheck(clock.recoveryDeadline==deadline)
    print("PASS: pending space delivered exactly once after verified progress; continuous typing exceeds old total deadline; repeated/stale/rollback results do not renew")
}
