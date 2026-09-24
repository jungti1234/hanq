import AppKit
import Carbon
func testCheck(_ condition:@autoclosure ()->Bool,_ message:@autoclosure ()->String="",file:StaticString=#filePath,line:UInt=#line){
    guard condition() else{
        FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message())\n".utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.arguments.contains("--test-layouts") {
    func key(_ code:UInt16,_ down:Bool=true,_ shift:Bool=false)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=shift ? .maskShift:[];return e}
    var cases=0
    for id in [KoreanKeyboardLayout.twoSetID,KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID] {
        guard let layout=OnsetKeyboardLayout.load(sourceID:id),let system=KoreanKeyboardLayout.load(sourceID:id) else{testCheck(false,"installed layout missing: \(id)");exit(1)}
        let vowel:UInt16=id==onsetKoreanID ? 40:3
        for shift in [false,true] {
            for code in (shift ? layout.shifted:layout.normal).keys.sorted() {
                let variants=layout.variants(code:code,shift:shift)
                for original in variants {
                    let p=OnsetRecoveryEngine();p.enabled=true;p.testSource={id};p.testCanSelect={true}
                    let g=OnsetInputGate(marker:p.marker);g.beat();p.gate=g
                    p.unavailableReason="not_supported_text_field";p.sampleEarly(nil)
                    testCheck(g.receive(.keyDown,key(code,true,shift)) != nil && g.reservation()?.sourceID==id,"reserve actual layout initial")
                    testCheck(g.receive(.keyDown,key(vowel))==nil,"vowel held")
                    let field=AXUIElementCreateApplication(12345);var text=original;var range=NSRange(location:1,length:0);var sent:[UInt16]=[]
                    p.testSnapshot={OnsetSnapshot(element:field,text:text,selection:range)}
                    p.testSetRange={_,r in range=r;return .success}
                    p.testPost={e in
                        _ = g.receive(e.type,e)
                        guard e.type == .keyDown else{return}
                        let k=UInt16(e.getIntegerValueField(.keyboardEventKeycode));sent.append(k)
                        if sent.count==1{testCheck(k==code && e.flags.contains(.maskShift)==shift && range==NSRange(location:0,length:1));text=variants.last!;range=NSRange(location:1,length:0)}
                        else{testCheck(k==vowel && range.length==0);text="composed";range=NSRange(location:8,length:0)}
                    }
                    p.sample();let deadline=Date().addingTimeInterval(0.5)
                    while p.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
                    testCheck(!p.recovering && p.enabled && sent==[code,vowel] && p.pending.isEmpty,"correct layout key and following vowel: \(id), \(code), \(shift)")
                    p.closeSession();cases+=1
                }
            }
            if system.kind == .threeSet {
                for (code,char) in (shift ? system.shiftedPhysicalKeys:system.physicalKeys) {
                    if let scalar=char.unicodeScalars.first,(0x11A8...0x11C2).contains(scalar.value){testCheck(layout.variants(code:code,shift:shift).isEmpty,"final consonant never reclassified as initial")}
                }
            }
        }
    }
    testCheck(OnsetKeyboardLayout.load(sourceID:"custom.korean")==nil && OnsetKeyboardLayout.load(sourceID:"com.apple.keylayout.ABC")==nil,"no guessed two-set fallback")
    for phase in [0,1,2] {
        let p=OnsetRecoveryEngine();p.enabled=true;p.testCanSelect={true};let g=OnsetInputGate(marker:p.marker);g.beat();p.gate=g
        var source=KoreanKeyboardLayout.threeSetID;var sent=0
        p.testSource={source};p.unavailableReason="not_supported_text_field";p.sampleEarly(nil)
        _=g.receive(.keyDown,key(40));_=g.receive(.keyDown,key(3))
        let field=AXUIElementCreateApplication(12345);var range=NSRange(location:1,length:0)
        p.testSnapshot={OnsetSnapshot(element:field,text:"ㄱ",selection:range)}
        p.testSetRange={_,r in range=r;if phase==1{source=onsetKoreanID};return .success}
        p.testPost={e in _=g.receive(e.type,e);if e.type == .keyDown{sent+=1;range=NSRange(location:1,length:0);if phase==2{source=onsetKoreanID}}}
        if phase==0{source=onsetKoreanID}
        p.sample();let deadline=Date().addingTimeInterval(0.5)
        while p.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        testCheck(sent==(phase==2 ? 1:0) && !p.enabled && !p.pending.isEmpty,"source change must not send held vowel with a different layout")
        p.closeSession()
    }
    print("PASS: \(cases) installed-layout initial key/Shift/jamo representation cases; finals excluded; source changes fenced; simulated editor, no native IME assertion")
} else if ProcessInfo.processInfo.arguments.contains("--test-ack-timeout") {
    func key(_ marker:Int64=0)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;e.flags=[];e.setIntegerValueField(.eventSourceUserData,value:marker);return e}
    let field=AXUIElementCreateApplication(12345)
    for scenario in 0..<3 {
        let p=OnsetRecoveryEngine();let g=OnsetInputGate(marker:p.marker);g.beat();_ = g.begin();p.gate=g
        p.enabled=true;p.recovering=true;p.postedToGate=2
        var posts=0;var stops=0;var stale=false
        p.testPost={_ in posts+=1};p.didStop={stops+=1}
        p.testSource={scenario==1 ? "English":onsetKoreanID}
        p.testSnapshot={scenario==0 ? nil:OnsetSnapshot(element:field,text:"ㄱ",selection:NSRange(location:1,length:0))}
        p.pending=[key()];p.scheduleRecovery(0.001){stale=true}
        p.pauseForContext("test_missing_ack")
        p.resumeIfReady(now:10);p.resumeIfReady(now:10.2)
        testCheck(p.enabled && p.waitingForContext && g.holdUntil==0,"normal input stays released during bounded wait")
        if scenario==2{_ = g.receive(.keyDown,key(p.marker))}
        p.resumeIfReady(now:10.251)
        testCheck(!p.enabled && !p.waitingForContext && !g.healthy() && p.retainedInput.count==1 && posts==0 && stops==1,"missing or partial ack retires session even without readable Korean context")
        p.emergencyStop("late_failure");testCheck(stops==1,"late failure cannot extend restart backoff")
        RunLoop.current.run(until:Date().addingTimeInterval(0.005));testCheck(!stale,"old recovery task invalidated")
    }
    let p=OnsetRecoveryEngine();let g=OnsetInputGate(marker:p.marker);g.beat();p.gate=g;p.enabled=true;p.waitingForContext=true;p.postedToGate=1
    p.testSource={onsetKoreanID};p.testSnapshot={OnsetSnapshot(element:field,text:"ㄱ",selection:NSRange(location:1,length:0))}
    p.resumeIfReady(now:20);_ = g.receive(.keyDown,key(p.marker))
    p.resumeIfReady(now:20.2);p.resumeIfReady(now:20.301)
    testCheck(p.enabled && !p.waitingForContext && p.acknowledgmentWaitBegan==nil,"delayed acknowledgment permits normal resume")
    p.closeSession()
    let d=OnsetRecoveryEngine();let dg=OnsetInputGate(marker:d.marker);dg.beat();_ = dg.begin();d.gate=dg
    var clock=0.0;d.acknowledgmentClock={clock};d.enabled=true;d.recovering=true;d.postedToGate=1;d.planElement=field
    d.testSource={onsetKoreanID};d.testSnapshot={OnsetSnapshot(element:field,text:"ㄱ",selection:NSRange(location:1,length:0))};d.testPost={_ in testCheck(false,"empty drain must not repost")}
    d.drain([]);RunLoop.current.run(until:Date().addingTimeInterval(0.01));clock=0.251
    RunLoop.current.run(until:Date().addingTimeInterval(0.01));testCheck(!d.enabled && !d.recovering,"empty drain acknowledgment wait is bounded too")
    let c=OnsetRecoveryController();c.active=true;var time=0.0;var ready=true;var launches=0
    c.now={time};c.testConditions={(true,ready,false,42)};c.launchEngine={e in launches+=1;e.enabled=true;e.gate=OnsetInputGate(marker:e.marker);e.gate?.beat()}
    c.tick();let old=c.engine!;old.waitingForContext=true;old.postedToGate=1;old.retainedInput=[key()]
    old.resumeIfReady(now:0);old.resumeIfReady(now:0.251)
    time=0.5;c.tick();testCheck(launches==1,"backoff")
    ready=false;time=2;c.tick();testCheck(launches==1,"permission/lifecycle blocks restart")
    ready=true;c.tick();let fresh=c.engine!
    testCheck(launches==2 && fresh !== old && fresh.pending.isEmpty && fresh.retainedInput.count==1,"restart quarantines old keys instead of replaying")
    let freshGate=fresh.gate!;_ = freshGate.begin()
    testCheck(freshGate.receive(.keyDown,key(old.marker)) != nil && freshGate.seenCount()==0 && freshGate.take().isEmpty,"late old-session event neither counts nor gets buffered")
    _ = freshGate.receive(.keyDown,key(fresh.marker));testCheck(freshGate.seenCount()==1,"new-session acknowledgment accepted")
    c.stop();time=100;c.tick();testCheck(launches==2,"explicit lifecycle stop blocks restart")
    print("PASS: missing/partial/delayed acknowledgment, unreadable/source-changed context, bounded drain, no replay, late events, permission/backoff and explicit stop")
} else if ProcessInfo.processInfo.arguments.contains("--test-shift-onset") {
    func key(_ code:CGKeyCode,_ down:Bool,_ flags:CGEventFlags)->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=flags;return e
    }
    for shiftCode:CGKeyCode in [56,60] {
        for (code,jamo,syllable):(CGKeyCode,String,String) in [(15,"ㄲ","까"),(14,"ㄸ","따"),(12,"ㅃ","빠"),(17,"ㅆ","싸"),(13,"ㅉ","짜")] {
            let p=OnsetRecoveryEngine();p.enabled=true;p.testCanSelect={true}
            let g=OnsetInputGate(marker:p.marker);g.beat();p.gate=g;g.configureEarly(true)
            let shiftDown=key(shiftCode,true,.maskShift);shiftDown.type = .flagsChanged
            testCheck(g.receive(.flagsChanged,shiftDown) != nil)
            testCheck(g.receive(.keyDown,key(code,true,.maskShift)) != nil)
            testCheck(g.reservation()?.shift==true,"Shift before consonant must preserve the outside hint")
            let shiftUp=key(shiftCode,false,[]);shiftUp.type = .flagsChanged
            let follow=[key(code,false,.maskShift),shiftUp,key(40,true,[]),key(40,false,[])]
            for e in follow{testCheck(g.receive(e.type,e)==nil)}
            let field=AXUIElementCreateApplication(12345);var text=jamo;var range=NSRange(location:1,length:0)
            var sent:[CGEvent]=[]
            p.testSource={onsetKoreanID};p.testSnapshot={OnsetSnapshot(element:field,text:text,selection:range)}
            p.testSetRange={_,r in range=r;return .success}
            p.testPost={e in
                sent.append(e);_ = g.receive(e.type,e)
                if e.type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode)==Int64(code) {
                    testCheck(e.flags.contains(.maskShift) && range==NSRange(location:0,length:1))
                    range=NSRange(location:1,length:0)
                }
                if e.type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode)==40 {
                    testCheck(!e.flags.contains(.maskShift) && range.length==0);text=syllable
                }
            }
            p.sample();let deadline=Date().addingTimeInterval(0.5)
            while p.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
            testCheck(text==syllable && !p.recovering && p.pending.isEmpty,"code=\(code) text=\(text) sent=\(sent.count) pending=\(p.pending.count) status=\(p.statusText)")
            testCheck(sent.count==6 && sent[3].type == .flagsChanged && !sent[3].flags.contains(.maskShift),"Shift release stays ordered before vowel")
            p.closeSession()
        }
    }
    for (code,flags):(CGKeyCode,CGEventFlags) in [(55,.maskCommand),(58,.maskAlternate),(59,.maskControl),(57,.maskAlphaShift),(63,.maskSecondaryFn),(56,[.maskShift,.maskCommand])] {
        let g=OnsetInputGate(marker:99);g.beat();g.configureEarly(true)
        let e=key(code,true,flags);e.type = .flagsChanged
        _=g.receive(.flagsChanged,e);_ = g.receive(.keyDown,key(15,true,.maskShift))
        testCheck(g.reservation()==nil,"other modifiers still invalidate the hint")
    }
    let expired=OnsetInputGate(marker:99);expired.beat();expired.hintUntil=0
    let e=key(56,true,.maskShift);e.type = .flagsChanged
    _=expired.receive(.flagsChanged,e);_ = expired.receive(.keyDown,key(15,true,.maskShift))
    testCheck(expired.reservation()==nil,"Shift does not renew an expired hint")
    print("PASS: left/right Shift plus all five double consonants; ordered release and vowel; shortcuts and expired hints excluded; simulated IME only")
} else if ProcessInfo.processInfo.arguments.contains("--test-early-capture") {
    func key(_ code:CGKeyCode,_ down:Bool=true)->CGEvent{let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=[];return e}
    for alreadyCollected in [false,true] {
        let p=OnsetRecoveryEngine();p.enabled=true;p.testCanSelect={true}
        let g=OnsetInputGate(marker:p.marker);g.beat();p.gate=g;g.configureEarly(true)
        testCheck(g.receive(.keyDown,key(15)) != nil)
        for (k,d):(CGKeyCode,Bool) in [(15,false),(40,true),(40,false),(1,true),(1,false)]{testCheck(g.receive(d ? .keyDown:.keyUp,key(k,d))==nil)}
        if alreadyCollected{p.collectHeld()}
        let field=AXUIElementCreateApplication(12345);var text="ㄱ";var range=NSRange(location:1,length:0);var codes:[Int64]=[]
        p.testSource={onsetKoreanID};p.testSnapshot={OnsetSnapshot(element:field,text:text,selection:range)}
        p.testSetRange={_,r in range=r;return .success}
        p.testPost={e in
            _=g.receive(e.type,e)
            guard e.type == .keyDown else{return}
            let k=e.getIntegerValueField(.keyboardEventKeycode);codes.append(k)
            if k==15{testCheck(range==NSRange(location:0,length:1));range=NSRange(location:1,length:0)}
            if k==40{testCheck(text=="ㄱ" && range.length==0);text="가"}
            if k==1{testCheck(text=="가");text="간"}
        }
        p.sample()
        let deadline=Date().addingTimeInterval(0.5)
        while p.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        testCheck(text=="간" && codes==[15,40,1] && p.pending.isEmpty && p.enabled && !p.recovering)
        p.closeSession()
    }
    for prefix in [false,true] {
        let p=OnsetRecoveryEngine();let g=OnsetInputGate(marker:p.marker);g.beat();_ = g.begin();p.gate=g
        let field=AXUIElementCreateApplication(12345);p.planElement=field;p.enabled=true;p.recovering=true;p.testSource={onsetKoreanID}
        p.currentPlan=OnsetRecoveryPlan(before:"",caret:0,allowSingle:true,roman:"ㄱ",codes:[(15,false)])
        p.testSnapshot={g.stop();return OnsetSnapshot(element:field,text:"ㄱ",selection:NSRange(location:1,length:0))}
        var posted=0;p.testPost={_ in posted+=1}
        if prefix{p.drain([key(15),key(15,false)])}else{p.pending=[key(40)];p.drain([])}
        testCheck(posted==0 && p.postedBuffered==0 && p.pending.count==(prefix ? 2:1),"rejected post must retain unposted events")
    }
    let expired=OnsetInputGate(marker:99);expired.beat();expired.configureEarly(true);expired.hintUntil=0
    testCheck(expired.receive(.keyDown,key(15)) != nil && expired.reservation()==nil,"expired outside hint cannot authorize edit")
    let productGate=OnsetInputGate(marker:99);productGate.beat();productGate.configureEarly(true)
    let synthetic=key(15);synthetic.setIntegerValueField(.eventSourceUserData,value:0x454F5448)
    testCheck(productGate.receive(.keyDown,synthetic) != nil && productGate.reservation()==nil,"HanQ synthetic keys cannot reserve onset input")
    let busy=OnsetRecoveryEngine();busy.enabled=true;busy.canBeginRepair={false};busy.gate=productGate
    busy.unavailableReason="not_supported_text_field";busy.testSource={onsetKoreanID};busy.sampleEarly(nil)
    testCheck(productGate.receive(.keyDown,key(15)) != nil && productGate.reservation()==nil,"manual edits disarm early capture")
    print("PASS: actual early gate + sample + selection + drain composes gan; precollected keys preserved; clipboard unused; rejected physical/prefix posts retained; stale hints skipped")
} else if ProcessInfo.processInfo.arguments.contains("--test-restart") {
    let c=OnsetRecoveryController();c.active=true
    var time=0.0;var ready=false;var allowed=true;var launches=0;var probe=false
    c.now={time};c.testConditions={ (allowed,ready,probe,42) }
    c.launchEngine={e in launches+=1;e.enabled=true}
    c.tick();testCheck(launches==0,"no creation without permission/lifecycle readiness")
    ready=true;c.tick();testCheck(launches==1)
    let old=c.engine!;old.pending=[CGEvent(keyboardEventSource:nil,virtualKey:4,keyDown:true)!]
    old.emergencyStop("tap_disabled")
    time=0.5;c.tick();testCheck(launches==1,"backoff prevents tight restart loop")
    time=1;c.tick();testCheck(launches==2 && c.engine!.enabled && c.engine!.pending.isEmpty && c.engine!.retainedInput.count==1)
    old.didStop?();testCheck(!c.failed,"old engine callback cannot stop replacement")
    ready=false;c.tick();time=10;c.tick();testCheck(launches==2,"wait for restored permission")
    ready=true;c.tick();testCheck(launches==3)
    c.engine!.emergencyStop("gate_lock_timeout");allowed=false;time=30;c.tick();testCheck(launches==3,"explicit disable blocks restart")
    allowed=true;probe=true;c.tick();testCheck(launches==3,"probe excludes product gate")
    probe=false;c.tick();testCheck(launches==4)
    for _ in 0..<12{c.engine!.emergencyStop("tap_create_failed");time+=8;c.tick()}
    testCheck(launches==16 && c.retryDelay==8,"repeated failure never permanently latches off")
    c.stop();time+=100;c.tick();testCheck(launches==16,"explicit lifecycle stop prevents queued tick restart")
    print("PASS: permission/lifecycle restoration, gate retry backoff, unlimited retries, retained input quarantine, stale callback exclusion, explicit stop")
} else if ProcessInfo.processInfo.arguments.contains("--test-integration") {
    testCheck(OnsetRecoveryController.recoveryAllowed(arguments:["HanQ"]),"recovery enabled by default")
    testCheck(!OnsetRecoveryController.recoveryAllowed(arguments:["HanQ","--disable-onset-recovery"]),"diagnostic opt-out")
    testCheck(OnsetRecoveryController.recoveryAllowed(arguments:["HanQ","--diagnose-input"]),"logging does not disable repair")
    for pid:pid_t in [1,42,5678] { testCheck(OnsetRecoveryController.supports(pid:pid,ownPID:9999)) }
    testCheck(!OnsetRecoveryController.supports(pid:9999,ownPID:9999))
    testCheck(!OnsetRecoveryController.supports(pid:nil))
    testCheck(!OnsetRecoveryController.supports(pid:0))
    testCheck(OnsetRecoveryController.needsRebind(currentPID:42,frontPID:43))
    testCheck(!OnsetRecoveryController.needsRebind(currentPID:42,frontPID:42))
    let controller=OnsetRecoveryController();let engine=OnsetRecoveryEngine()
    let gate=OnsetInputGate(marker:123);gate.beat();testCheck(gate.begin())
    engine.gate=gate;engine.enabled=true;engine.recovering=true
    engine.pending=[CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!]
    controller.engine=engine
    testCheck(!controller.prepareManualEdit(),"manual editing cannot overlap repair")
    controller.stop()
    testCheck(!gate.healthy() && !engine.enabled && !engine.recovering)
    testCheck(engine.pending.count==1 && controller.timer==nil,"teardown retains pending input without sending")
    testCheck(controller.prepareManualEdit())
    controller.stop()
    engine.log("privacy_check",["text":"PRIVATE_ONSET_PAYLOAD","code":40,"events":["PRIVATE_ONSET_PAYLOAD"]])
    print("PASS: product teardown stops gate, retains unsent input, prevents manual edit overlap")
} else if ProcessInfo.processInfo.arguments.contains("--test-field-tracking") {
    let owner=OnsetRecoveryEngine()
    let first=AXUIElementCreateApplication(12345)
    let second=AXUIElementCreateApplication(12346)
    let a=OnsetSnapshot(element:first,text:"draft",selection:NSRange(location:5,length:0))
    let b=OnsetSnapshot(element:second,text:"",selection:NSRange(location:0,length:0))
    owner.observeAvailability(a)
    testCheck(owner.locked.map{CFEqual($0,first)} == true)
    owner.plan=OnsetRecoveryPlan(before:"draft",caret:5)
    owner.planElement=first;owner.matchCount=1;owner.heldKeys=[2]
    owner.observeAvailability(a)
    testCheck(owner.plan != nil && owner.matchCount==1)
    owner.observeAvailability(b)
    testCheck(owner.locked.map{CFEqual($0,second)} == true)
    testCheck(owner.plan==nil && owner.planElement==nil && owner.matchCount==0 && owner.heldKeys.isEmpty)
    owner.plan=OnsetRecoveryPlan(before:"",caret:0)
    owner.unavailableReason="selection_unreadable"
    owner.observeAvailability(nil)
    testCheck(owner.plan==nil && owner.lastAvailability=="selection_unreadable")
    owner.observeAvailability(b)
    testCheck(owner.lastAvailability=="tracking")
    print("PASS: initial binding, stable field, recreated field cancellation, unavailable state, resumed tracking")
} else if ProcessInfo.processInfo.arguments.contains("--test-recovery") || ProcessInfo.processInfo.arguments.contains("--test-selection-retry") {
    let probe=OnsetRecoveryEngine();let element=AXUIElementCreateApplication(12345)
    var candidate=OnsetRecoveryPlan(before:"",caret:0);candidate.allowSingle=true;candidate.roman="ㅈ";candidate.codes=[(13,false)]
    var text="ㅈ";var selection=NSRange(location:1,length:0);var codes:[Int64]=[]
    probe.testSource={onsetKoreanID}
    probe.testSnapshot={OnsetSnapshot(element:element,text:text,selection:selection)}
    var selectionRequests=0
    let ignoreFirst=ProcessInfo.processInfo.arguments.contains("--test-selection-retry")
    probe.testSetRange={_,range in
        selectionRequests+=1
        if !ignoreFirst || selectionRequests>1{DispatchQueue.main.asyncAfter(deadline:.now()+0.01){selection=range}}
        return .success
    }
    probe.testPost={event in
        guard event.type == .keyDown else{return}
        let code=event.getIntegerValueField(.keyboardEventKeycode);codes.append(code)
        testCheck(code != 7 && code != 51,"no cut or delete in selected replacement")
        if code==13{testCheck(selection==NSRange(location:0,length:1));text="ㅈ"}
        else if code==40{text="자"}
        else if code==1{text="잔"}
        selection=NSRange(location:text.utf16.count,length:0)
    }
    probe.enabled=true;probe.recovering=true;probe.currentPlan=candidate;probe.planElement=element
    probe.replaceAndReplay(candidate,OnsetSnapshot(element:element,text:text,selection:selection))
    DispatchQueue.main.asyncAfter(deadline:.now()+0.005){
        for code:CGKeyCode in [40,1]{for down in [true,false]{let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;probe.nextBufferedID+=1;event.setIntegerValueField(.eventSourceUserData,value:probe.nextBufferedID);probe.pending.append(event)}}
    }
    let deadline=Date().addingTimeInterval(2)
    while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    guard !probe.recovering && codes==[13,40,1] && probe.pending.isEmpty && text=="잔" else { print("FAIL recovery codes=\(codes) pending=\(probe.pending.count) status=\(probe.statusText) requests=\(selectionRequests)"); exit(1) }
    if ignoreFirst{testCheck(selectionRequests==2,"ignored first selection retried once");print("PASS: ignored first selection request recovered by one bounded retry")}
    print("PASS: single consonant replay followed by buffered vowel and final consonant; simulated editor, no source switching or actual key posting")
} else if ProcessInfo.processInfo.arguments.contains("--test-selected-replacement") {
    for applied in [true,false] {
        let probe=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
        var text="ㅈ";var selection=NSRange(location:0,length:1);var codes:[Int64]=[]
        var candidate=OnsetRecoveryPlan(before:"",caret:0);candidate.allowSingle=true;candidate.roman="ㅈ";candidate.codes=[(13,false)]
        probe.recovering=true;probe.enabled=true;probe.currentPlan=candidate;probe.planElement=field
        probe.testSource={onsetKoreanID};probe.testSnapshot={OnsetSnapshot(element:field,text:text,selection:selection)}
        probe.testPost={event in
            guard event.type == .keyDown else{return}
            let code=event.getIntegerValueField(.keyboardEventKeycode);codes.append(code)
            testCheck(code != 7 && code != 51,"no cut or deletion")
            if code==13 && applied{DispatchQueue.main.asyncAfter(deadline:.now()+0.04){selection=NSRange(location:1,length:0)}}
            if code==40{testCheck(selection.length==0,"same text alone must not release vowel");text="자"}
            if code==1{text="잔"}
        }
        for code:CGKeyCode in [40,1]{for down in [true,false]{probe.pending.append(CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!)}}
        probe.awaitSelection(candidate,probe.testSnapshot!()!,selection,remaining:75)
        let deadline=Date().addingTimeInterval(1)
        while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        testCheck(!probe.recovering)
        if applied{testCheck(codes==[13,40,1] && text=="잔" && probe.pending.isEmpty)}
        else{testCheck(codes==[13] && probe.pending.count==4)}
    }
    print("PASS: selected replacement waits for selection collapse despite identical text; no cut/delete; buffered vowel/final order; unhandled replacement retains keys")
} else if ProcessInfo.processInfo.arguments.contains("--test-superseded") {
    for scenario in [0,1,2,3,4,6,7] {
        let p=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
        let candidate=OnsetRecoveryPlan(before:"앞뒤",caret:1,allowSingle:true,roman:"ㅈ",codes:[(13,false)])
        var text="앞ㅈ오뒤";var selection=NSRange(location:3,length:0)
        var codes:[Int64]=[];var ranges=0
        p.recovering=true;p.enabled=true;p.currentPlan=candidate;p.planElement=field
        p.testSource={onsetKoreanID}
        if scenario==2{text="변ㅈ오뒤"}
        if scenario==3{selection=NSRange(location:1,length:1)}
        if scenario==4{p.replayStarted=true}
        p.testSnapshot={OnsetSnapshot(element:scenario==6 ? AXUIElementCreateApplication(12346):field,text:text,selection:selection)}
        if scenario==7{p.testSource={"other"}}
        p.testSetRange={_,_ in ranges+=1;return .success}
        p.testPost={e in codes.append(e.getIntegerValueField(.keyboardEventKeycode))}
        for down in [true,false]{p.pending.append(CGEvent(keyboardEventSource:nil,virtualKey:38,keyDown:down)!)}
        if scenario<2 {
            let before=OnsetSnapshot(element:field,text:"앞ㅈ뒤",selection:NSRange(location:2,length:0))
            if scenario==0{p.replaceAndReplay(candidate,before)}
            else{p.awaitSelection(candidate,before,NSRange(location:1,length:1),remaining:75)}
            // More typing while held input drains must retain its ordering too.
            p.pending.append(CGEvent(keyboardEventSource:nil,virtualKey:2,keyDown:true)!)
            let deadline=Date().addingTimeInterval(0.5)
            while p.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
            testCheck(!p.recovering && p.enabled && p.pending.isEmpty)
            testCheck(codes==[38,38,2] && ranges==0 && text=="앞ㅈ오뒤","skip without editing; deliver held keys once in order; stay enabled")
        }else{
            testCheck(!p.skipSupersededRepair(candidate,p.testSnapshot!()!),"unsafe context must not use skip path")
            testCheck(codes.isEmpty && p.pending.count==2)
        }
    }
    print("PASS: superseded repair before selection/during selection drains input without disabling; changed prefix/selection/field/source and started edits rejected")
} else if ProcessInfo.processInfo.arguments.contains("--test-selection-read") {
    for scenario in 0..<4 {
        let p=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
        let c=OnsetRecoveryPlan(before:"ㅎㅎ",caret:2,allowSingle:true,roman:"ㅎ",codes:[(5,false)])
        var text="ㅎㅎㅎ";var range=NSRange(location:2,length:1);var reads=0;var codes:[Int64]=[]
        p.enabled=true;p.recovering=true;p.currentPlan=c;p.planElement=field
        p.selectionRequestAt=ProcessInfo.processInfo.systemUptime;p.testSource={onsetKoreanID}
        p.testSnapshot={
            reads+=1
            if reads<=3 || scenario==1 || scenario==3 {
                p.unavailableReason=scenario==3 ? "target_not_frontmost":"not_supported_text_field";return nil
            }
            p.unavailableReason=""
            return OnsetSnapshot(element:scenario==2 ? AXUIElementCreateApplication(12346):field,text:text,selection:range)
        }
        p.testPost={e in
            guard e.type == .keyDown else{return}
            let k=e.getIntegerValueField(.keyboardEventKeycode);codes.append(k)
            if k==5{range=NSRange(location:3,length:0)}
            if k==4{text="ㅎㅎ호"}
            if k==2{text="ㅎㅎ홍"}
        }
        for k:CGKeyCode in [4,2]{for down in [true,false]{p.pending.append(CGEvent(keyboardEventSource:nil,virtualKey:k,keyDown:down)!)}}
        p.awaitSelection(c,OnsetSnapshot(element:field,text:text,selection:NSRange(location:3,length:0)),range,remaining:75)
        let limit=Date().addingTimeInterval(0.5)
        while p.recovering && Date()<limit{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        testCheck(!p.recovering)
        if scenario==0{testCheck(p.enabled && codes==[5,4,2] && text=="ㅎㅎ홍" && p.pending.isEmpty)}
        else if scenario==1{testCheck(p.enabled && p.waitingForContext && codes.isEmpty && p.retainedInput.count==4)}
        else{testCheck(!p.enabled && codes.isEmpty && p.pending.count==4)}
        if scenario==3{testCheck(reads<=2,"actual app change must not wait for AX recovery")}
    }
    print("PASS: transient selection read recovers and delivers hong; persistent failure, changed field and app stop without replay")
} else if ProcessInfo.processInfo.arguments.contains("--test-auto-resume") {
    let p=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
    let gate=OnsetInputGate(marker:p.marker);gate.beat();testCheck(gate.begin());p.gate=gate
    p.enabled=true;p.recovering=true;p.testSource={onsetKoreanID}
    var readable=false;var range=NSRange(location:1,length:0);var posts=0;var stale=false
    p.testSnapshot={ readable ? OnsetSnapshot(element:field,text:"ㅎ",selection:range):nil }
    p.testPost={_ in posts+=1}
    p.pending=[CGEvent(keyboardEventSource:nil,virtualKey:4,keyDown:true)!]
    p.scheduleRecovery(0.01){stale=true}
    p.pauseForContext("selection_context_changed")
    testCheck(p.enabled && !p.recovering && p.waitingForContext && p.pending.isEmpty && p.retainedInput.count==1)
    testCheck(gate.receive(.keyDown,CGEvent(keyboardEventSource:nil,virtualKey:2,keyDown:true)!) != nil,"waiting must pass normal input")
    p.resumeIfReady(now:0);testCheck(p.waitingForContext)
    readable=true;p.resumeIfReady(now:1);p.resumeIfReady(now:1.05);testCheck(p.waitingForContext)
    range=NSRange(location:0,length:1);p.resumeIfReady(now:1.2);testCheck(p.waitingForContext)
    range=NSRange(location:1,length:0);p.resumeIfReady(now:2);p.resumeIfReady(now:2.11)
    testCheck(!p.waitingForContext && p.enabled && posts==0 && p.retainedInput.count==1)
    RunLoop.current.run(until:Date().addingTimeInterval(0.02));testCheck(!stale,"old recovery callbacks cannot affect resumed work")
    p.pauseForContext("selection_context_changed");p.closeSession();readable=true
    p.resumeIfReady(now:3);p.resumeIfReady(now:4);testCheck(!p.enabled,"user stop must prevent resume")
    print("PASS: unavailable field pauses; normal keys pass; stable collapsed field resumes; retained input is not replayed; stale work and explicit stop cannot resume")
} else if ProcessInfo.processInfo.arguments.contains("--test-prefix-delay") {
    for visible in [true,false] {
        let probe=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
        var text="";var codes:[Int64]=[]
        probe.recovering=true;probe.enabled=true;probe.planElement=field
        var candidate=OnsetRecoveryPlan(before:"",caret:0);candidate.allowSingle=true;candidate.roman="ㅈ";candidate.codes=[(13,false)]
        probe.currentPlan=candidate;probe.testSource={onsetKoreanID}
        probe.testSnapshot={OnsetSnapshot(element:field,text:text,selection:NSRange(location:text.utf16.count,length:0))}
        probe.testPost={event in
            guard event.type == .keyDown else{return}
            let code=event.getIntegerValueField(.keyboardEventKeycode);codes.append(code)
            if code==13 && visible{DispatchQueue.main.asyncAfter(deadline:.now()+0.04){text="ㅈ"}}
            if code==40{testCheck(text=="ㅈ","vowel must wait for visible consonant");text="자"}
        }
        for down in [true,false]{probe.pending.append(CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:down)!)}
        probe.drain([CGEvent(keyboardEventSource:nil,virtualKey:13,keyDown:true)!,CGEvent(keyboardEventSource:nil,virtualKey:13,keyDown:false)!])
        let deadline=Date().addingTimeInterval(1)
        while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.002))}
        testCheck(!probe.recovering)
        if visible{testCheck(codes==[13,40] && text=="자" && probe.pending.isEmpty)}
        else{testCheck(codes==[13] && probe.pending.count==2,"unconfirmed prefix must retain following keys")}
    }
    print("PASS: delayed prefix blocks vowel until visible; missing prefix retains queued keys without replay")
} else if ProcessInfo.processInfo.arguments.contains("--test-drain") {
    let probe=OnsetRecoveryEngine();let field=AXUIElementCreateApplication(12345)
    probe.recovering=true;probe.enabled=true;probe.planElement=field
    probe.testSource={onsetKoreanID}
    probe.currentPlan=OnsetRecoveryPlan(before:"",caret:0,allowSingle:true,roman:"ㅈ",codes:[(13,false)])
    var prefixText=""
    probe.testSnapshot={OnsetSnapshot(element:field,text:prefixText,selection:NSRange(location:prefixText.utf16.count,length:0))}
    var posted:[String]=[]
    probe.testPost={event in posted.append("\(event.getIntegerValueField(.keyboardEventKeycode)):\(event.type.rawValue)");if posted.count==1{prefixText="ㅈ"};if posted.count==3{prefixText="자"}}
    func event(_ code:UInt16,_ down:Bool)->CGEvent{CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!}
    let prefix=[event(13,true),event(13,false)]
    let buffered=(0..<100).map{event($0 % 4 == 0 ? 1:40,$0 % 2 == 0)}
    probe.drain(prefix)
    DispatchQueue.main.async{
        for (i,e) in buffered.enumerated(){e.setIntegerValueField(.eventSourceUserData,value:Int64(i+1));probe.pending.append(e)}
        probe.nextBufferedID=100
    }
    let deadline=Date().addingTimeInterval(2)
    while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
    let expected=(prefix+buffered).map{"\($0.getIntegerValueField(.keyboardEventKeycode)):\($0.type.rawValue)"}
    testCheck(posted==expected,"prefix and newly buffered events in exact order")
    testCheck(!probe.recovering && probe.pending.isEmpty && probe.postedBuffered==100)
    print("PASS: burst prefix + 100 events added during replay, no omissions or duplicates at posting boundary")
} else if ProcessInfo.processInfo.arguments.contains("--test-rollback") {
    var checks=0
    func check(_ ok:Bool,_ name:String){testCheck(ok,name);checks+=1}
    func scenario(ignoredCaret:Bool=false,changedText:Bool=false,newField:Bool=false,extraKey:Bool=false,stopDuring:Bool=false){
        let probe=OnsetRecoveryEngine()
        let element=AXUIElementCreateApplication(12345)
        let other=AXUIElementCreateApplication(12346)
        let candidate=OnsetRecoveryPlan(before:"dkdkdkdkdkdkddkdkd",caret:18,allowSingle:true,roman:"ㅈ",codes:[(13,false)])
        var selection=NSRange(location:18,length:1)
        var posted:[(Int64,CGEventType)]=[]
        var requests=0
        probe.testSource={onsetKoreanID}
        probe.testSnapshot={OnsetSnapshot(element:newField ? other:element,text:changedText ? "changed":candidate.expected!,selection:selection)}
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
        probe.abort("selection_not_applied")
        if extraKey{DispatchQueue.main.asyncAfter(deadline:.now()+0.015){let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:false)!;event.setIntegerValueField(.eventSourceUserData,value:8);probe.pending.append(event);probe.nextBufferedID=8}}
        if stopDuring{probe.stop()}
        let deadline=Date().addingTimeInterval(1)
        while probe.recovering && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(!probe.recovering,"bounded completion")
        if ignoredCaret || changedText || newField {
            check(posted.isEmpty,"never send into changed field/text or wrong selection")
            check(probe.pending.count==7,"pending keys retained")
            if changedText || newField{check(requests==0,"no cursor mutation on changed context")}
        } else {
            let expected=original.map{(Int64($0.0),$0.1 ? CGEventType.keyDown:.keyUp)} + (extraKey ? [(40,.keyUp)]:[])
            check(posted.count==expected.count,"every event returned")
            check(zip(posted,expected).allSatisfy{$0.0.0==$0.1.0 && $0.0.1==$0.1.1},"original ordering with no duplicate")
            check(probe.pending.isEmpty,"queue drained")
            check(selection==NSRange(location:19,length:0),"caret restored before return")
            check(requests==1,"one cursor restore request")
        }
    }
    scenario()
    scenario(extraKey:true)
    scenario(ignoredCaret:true)
    scenario(changedText:true)
    scenario(newField:true)
    scenario(stopDuring:true)
    print("PASS \(checks) rollback checks: failed selection, delayed caret, new input, ignored caret, changed context, stop during rollback")
}
