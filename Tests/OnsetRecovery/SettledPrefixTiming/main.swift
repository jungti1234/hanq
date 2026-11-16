import AppKit

#if !PREFIX_TIMING_TEST
#error("Compile this fixture with -D PREFIX_TIMING_TEST; no live AX fallback is allowed")
#endif

var checks=0,failures=0
var results=[[String:Any]]()
func check(_ value:Bool,_ name:String){checks+=1;if !value{failures+=1;print("FAIL",name)}}
func key(_ code:UInt16,_ down:Bool)->CGEvent {
    let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
    event.flags=[];return event
}
let split="ㄱㅏ나다라마바사",joined="가나다라마바사"
let codes:[UInt16]=[15,40,1,40,14,40,3,40,0,40,12,40,17,40]
let downs=[0,109,228,286,414,471,583,653,774,823,942,986,1119,1169]
let ups=[108,194,287,382,449,564,640,725,821,904,1021,1084,1206,1300]
// Independent editor publications; do not derive the oracle with JamoComposer.
let publications:[(Int,String)]=[(195,"ㄱㅏ"),(247,"ㄱㅏㄴ"),(323,"ㄱㅏ나"),(420,"ㄱㅏ낟"),(501,"ㄱㅏ나다"),(600,"ㄱㅏ나달"),(682,"ㄱㅏ나다라"),(785,"ㄱㅏ나다람"),(852,"ㄱㅏ나다라마"),(959,"ㄱㅏ나다라맙"),(1009,"ㄱㅏ나다라마바"),(1140,"ㄱㅏ나다라마밧"),(1208,split)]

// No global tap, AX query, source selection, clipboard or OS event posting.
// The engine discovers the proof, builds its plan, atomically claims the real
// in-memory gate and runs the product coordinator. Only OS boundaries are fake.
final class Case {
    let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(91001),other=AXUIElementCreateApplication(91002)
    let g:OnsetInputGate,mode:String
    var ended=false,visible=false,text="",selection=NSRange(location:0,length:0)
    var source=onsetKoreanID,front:pid_t?=42,secure=false,changedField=false
    var writes=0,selections=0,legacyWrites=0,legacySelections=0,commands=0,originals=0,spaceUpPassed=0,spaceUpHeld=0
    var posts=[(UInt16,Bool)](),traces=[String](),events=[[String:Any]]()
    var start=0.0,maxLateness=0.0,restoreAt:Double?,readDelayed=false,raced=false
    var legacy:Bool{["default-off","legacy-delayed","no-witness","range-unsupported"].contains(mode)}
    var legacyEarly:Bool{["default-off","legacy-delayed","no-witness"].contains(mode)}
    var hasQueued:Bool{["queued-next","caret-unapplied","caret-changed","source-after-write","focus-after-write","secure-after-write","body-after-write"].contains(mode)}
    init(_ mode:String){
        self.mode=mode;g=OnsetInputGate(marker:e.marker)
        check(!e.prefixCandidateEnabled,"\(mode): product remains opt-in")
        e.prefixCandidateEnabled = !["default-off","legacy-delayed"].contains(mode)
        e.enabled=true;e.gate=g;g.beat();e.testSource={self.source};e.testTargetBundleID={"fixture.editor"}
        e.testCanSelect={true};e.testCanReplaceText={true}
        e.testSnapshot={
            guard self.visible else{self.e.unavailableReason="not_supported_text_field";return nil}
            if ["delayed","uncertain"].contains(self.mode),self.writes==1,!self.readDelayed {
                self.readDelayed=true;Thread.sleep(forTimeInterval:0.08)
            }
            return self.snapshot()
        }
        e.testOriginalSnapshot={_ in self.snapshot()}
        e.testSetRange={element,range in
            if !self.e.prefixCoordinator.busy && self.legacy {
                self.legacySelections+=1
                check(CFEqual(element,self.field) && range==NSRange(location:0,length:9),"\(mode): legacy Space selects exact complete split body")
                self.selection=range;return .success
            }
            self.selections+=1
            check(CFEqual(element,self.field),"\(mode): restore only original field")
            check(range==NSRange(location:8,length:0),"\(mode): restore mapped end, never select suffix")
            if mode=="async-caret" {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.04){self.selection=range;self.restoreAt=ProcessInfo.processInfo.systemUptime}
            }else{
                if mode != "caret-unapplied"{self.selection=mode=="caret-changed" ? NSRange(location:3,length:0):range}
                self.restoreAt=ProcessInfo.processInfo.systemUptime
            }
            if ["delayed","uncertain"].contains(mode){Thread.sleep(forTimeInterval:0.05)}
            if mode=="source-after-write"{self.source="com.apple.keylayout.ABC"}
            if mode=="focus-after-write"{self.front=99}
            if mode=="secure-after-write"{self.secure=true}
            if mode=="body-after-write"{self.text="changed externally"}
            return ["uncertain","caret-unapplied","caret-changed"].contains(mode) ? .cannotComplete:.success
        }
        e.testReplaceText={element,value in
            self.legacyWrites+=1
            check(self.legacy && CFEqual(element,self.field),"\(mode): only advertised legacy fallback uses selected-text replacement")
            check(self.text==split+" " && self.selection==NSRange(location:0,length:9) && value==joined+" ","\(mode): legacy full-body proof and replacement intact")
            let apply={self.text=(self.text as NSString).replacingCharacters(in:self.selection,with:value);self.selection=NSRange(location:self.text.utf16.count,length:0)}
            if mode=="legacy-delayed"{DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:apply)}else{apply()}
            return .success
        }
        e.testPostCommittedUnicode={_,_ in self.legacyWrites+=1;return false}
        e.testPostCompositionCommit={_,_ in self.commands+=1;return false}
        e.testPost={event in
            if self.legacy {
                let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode)),down=event.type == .keyDown
                check(self.legacyEarly && code==49 && !down,"\(mode): legacy may deliver only original Space up, never the passed phrase")
                check(self.text==joined+" " && self.selection==NSRange(location:8,length:0),"\(mode): Space up after verified replacement")
                self.posts.append((code,down));_ = self.g.receive(event.type,event);return
            }
            check(self.hasQueued,"\(mode): never replay already passed phrase")
            check(self.selections==1 && (self.restoreAt.map{ProcessInfo.processInfo.systemUptime-$0>=0.025} ?? false),"\(mode): no next key before stable caret")
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode)),down=event.type == .keyDown
            self.posts.append((code,down));_ = self.g.receive(event.type,event)
            if down {
                if code==15{check(self.text==joined+" " && self.selection==NSRange(location:8,length:0),"next onset at restored caret");self.text=joined+" ㄱ"}
                else if code==46{check(self.text==joined+" ㄱ","next vowel follows its own onset");self.text=joined+" 그"}
                else{check(false,"no foreign replay key")}
                self.selection=NSRange(location:self.text.utf16.count,length:0)
            }
        }
        let coordinator=e.prefixCoordinator
        coordinator.testTargetPID=42;coordinator.testFrontPID={self.front};coordinator.testSecureInput={self.secure}
        // No menu API exists in this fixture. A range-capable field needs no Edit menu.
        coordinator.testRangeSupport={element in
            check(CFEqual(element,self.field),"\(mode): capability on original field")
            if mode=="claim-race",!self.raced {
                self.raced=true
                for down in [true,false]{check(self.g.receive(down ? .keyDown:.keyUp,key(2,down)) != nil,"racing original passes before claim")}
            }
            return mode != "range-unsupported"
        }
        coordinator.testRangeRequest={element,parameters in
            self.writes+=1
            check(CFEqual(element,self.field) && self.g.hasActiveReplayHold(),"\(mode): native range request only after atomic hold")
            let values=parameters as NSDictionary
            var range=CFRange();let raw=values["AXReplacementRange"] as! AXValue
            check(AXValueGetValue(raw,.cfRange,&range) && range.location==0 && range.length==2,"\(mode): request only first pair")
            check(values["AXReplacementText"] as? String=="가","\(mode): request one joined syllable")
            check(self.text==split+" " && self.selection==NSRange(location:9,length:0),"\(mode): complete source body/caret untouched until request")
            check(self.g.passedObservation()==nil,"\(mode): history consumed atomically, not replayed")
            let replacement=values["AXReplacementText"] as! String
            self.text=(self.text as NSString).replacingCharacters(in:NSRange(location:range.location,length:range.length),with:replacement)
            self.selection=NSRange(location:range.location+replacement.utf16.count,length:0)
            if self.hasQueued {
                for code:UInt16 in [15,46]{for down in [true,false]{check(self.g.receive(down ? .keyDown:.keyUp,key(code,down))==nil,"\(mode): following originals held during edit")}}
            }
            return .success
        }
        coordinator.trace={self.traces.append($0)}
        // Preserve the original pre-key representation witness setup.
        let root=AXUIElementCreateApplication(91003),outside=AXUIElementCreateApplication(91004),h=e.focusHandoff
        h.ready={true};h.frontPID={42};h.owner={_ in 42};h.writable={_,_ in true};h.children={_ in []}
        h.read={element,name in
            if name==kAXRoleAttribute{return (CFEqual(element,self.field) ? kAXTextAreaRole:CFEqual(element,root) ? kAXWindowRole:kAXGroupRole) as CFString}
            if name==kAXChildrenAttribute{return (CFEqual(element,root) ? [self.field]:[]) as CFArray}
            if name==kAXWindowAttribute{return root}
            if name==kAXValueAttribute{return "arbitrary presentation" as CFString}
            if name==kAXNumberOfCharactersAttribute{return NSNumber(value:22)}
            if name==kAXSelectedTextRangeAttribute{var range=CFRange(location:0,length:0);return AXValueCreate(.cfRange,&range)!}
            if name==kAXEnabledAttribute{return kCFBooleanTrue}
            if name=="AXHidden"{return kCFBooleanFalse};return nil
        }
        h.batch={element,names in names.map{h.read(element,$0)}}
        if mode=="empty-baseline"{visible=true}
        else if mode != "no-witness"{
            h.advance(window:root,outside:outside)
            check(h.candidate==nil,"\(mode): nonempty presentation is not empty/focus proof")
            check(h.representedEntry(for:field,before:ProcessInfo.processInfo.systemUptime) != nil,"\(mode): pre-key representation captured")
        }
        e.sample()
    }
    func snapshot()->OnsetSnapshot{.init(element:changedField ? other:field,text:text,selection:selection,compositionEnded:ended)}
    func original(_ code:UInt16,_ down:Bool){
        let event=key(code,down);e.observeDeferredBeforeInput(event.type,event)
        let passed=g.receive(event.type,event) != nil
        if legacyEarly && code==49 && !down {
            if passed {
                spaceUpPassed+=1
                check(!e.recovering && !g.ownsInput && text==joined+" ","\(mode): original Space up passes only after legacy completion")
            }else{spaceUpHeld+=1;check(e.recovering && g.ownsInput,"\(mode): unfinished legacy edit retains original Space up")}
        }else{check(passed,"\(mode): unclaimed original \(code)/\(down) passes")}
        originals+=1;events.append(["code":code,"down":down,"ms":(ProcessInfo.processInfo.systemUptime-start)*1000])
    }
    func untouched(_ point:String){
        check(writes==0 && selections==0 && posts.isEmpty && commands==0 && legacyWrites==0,"\(mode): no edit/selection/replay at \(point)")
        check(!g.ownsInput && e.pending.isEmpty && e.retainedInput.isEmpty,"\(mode): no early hold at \(point)")
    }
    func at(_ ms:Int,_ action:()->Void){
        while ProcessInfo.processInfo.systemUptime-start<Double(ms)/1000{g.beat();RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))}
        maxLateness=max(maxLateness,(ProcessInfo.processInfo.systemUptime-start)*1000-Double(ms));action()
    }
    func run(){
        var actions=[(Int,()->Void)]()
        for i in codes.indices{actions.append((downs[i],{self.original(codes[i],true)}));actions.append((ups[i],{self.original(codes[i],false)}))}
        for (ms,value) in publications {actions.append((ms,{
            self.text=self.mode=="normal" ? "가"+String(value.dropFirst(2)):value
            self.selection=NSRange(location:self.text.utf16.count,length:0);self.visible=true;self.e.sample();self.untouched("publication \(ms)ms")
        }))}
        let sorted=actions.sorted(by:{$0.0<$1.0})
        start=ProcessInfo.processInfo.systemUptime;sorted[0].1()
        // Anchor to the gate's actual first event, as the original fixture did.
        // First CGEvent allocation may be slow; it must not move 195ms inside
        // the product's 150ms window.
        guard let first=g.passedObservation()?.first else{check(false,"first event recorded");return}
        start=first.time;events[0]["ms"]=0.0
        for (ms,action) in sorted.dropFirst(){at(ms,action)}
        check(e.firstPublication==nil,"\(mode): 195ms must not authorize 150ms fast proof")
        let proofExpected = !["default-off","legacy-delayed","normal","no-witness"].contains(mode)
        check((e.settledPrefixPublication != nil)==proofExpected,"\(mode): late proof needs opt-in and independent pre-key witness")
        check(text==(mode=="normal" ? joined:split),"\(mode): all already delivered suffix remains")
        // Empty marked range / idle are deliberately insufficient, even ON.
        ended=true;e.sample();untouched("marked ended without Space")
        at(1350){e.sample();untouched("idle without Space")}
        if mode != "no-space" {
            if mode=="expired"{at(2050){};check(g.passedObservation()==nil,"2s history expires without extension")}
            at(1370){original(49,true)}
            at(1380){
                if mode != "space-not-published"{text+=" ";selection=NSRange(location:text.utf16.count,length:0)}
                e.sample()
                if legacyEarly {
                    check(writes==0 && selections==0 && legacyWrites==1 && commands==0,"\(mode): original Space path only, no prefix edit")
                }else{untouched("Space published but still down")}
            }
            if mode != "held-space" {
                at(1400){
                    original(49,false)
                    if mode=="wrong-body"{text="ㄱㅏ나다라바마사 "}
                    if mode=="moved-caret"{selection=NSRange(location:5,length:0)}
                    if mode=="selected"{selection=NSRange(location:4,length:2)}
                    if mode=="source"{source="com.apple.keylayout.ABC"}
                    if mode=="field"{changedField=true}
                    e.sample()
                }
            }
        }
        let negative=["no-space","space-not-published","held-space","default-off","legacy-delayed","normal","no-witness","wrong-body","moved-caret","selected","source","field","expired","claim-race","range-unsupported"].contains(mode)
        let stopped=hasQueued && mode != "queued-next"
        let finishBy=ProcessInfo.processInfo.systemUptime+0.35
        while e.recovering && e.enabled && ProcessInfo.processInfo.systemUptime<finishBy{
            g.beat();e.collectHeld();if e.prefixCoordinator.busy{e.prefixCoordinator.tick()}
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))
        }
        if legacy {
            check(writes==0 && selections==0 && e.prefixCoordinator.transaction==nil,"\(mode): no prefix transaction or ticket")
            check(legacyWrites==1 && legacySelections==1 && commands==0,"\(mode): existing Space recovery remains one exact edit")
            check(text==joined+" " && selection==NSRange(location:8,length:0),"\(mode): original Space recovery body and caret")
            check(posts.count==spaceUpHeld && (!legacyEarly || spaceUpPassed+posts.count==1),"\(mode): original Space up delivered exactly once, passed or drained")
            if mode=="legacy-delayed"{check(spaceUpHeld==1 && spaceUpPassed==0,"delayed legacy replacement genuinely exercises retained Space up")}
            if mode=="default-off"{check(spaceUpPassed==1 && spaceUpHeld==0,"immediate legacy replacement preserves naturally passed Space up")}
            check(e.enabled && !e.recovering && !g.ownsInput && e.pending.isEmpty && e.retainedInput.isEmpty,"\(mode): original Space path drains completely")
        }else if negative {
            untouched("rejected boundary")
            check(e.prefixCoordinator.transaction==nil,"\(mode): rejected observation never gets edit ticket")
            if mode=="held-space"{check(g.passedObservation()?.pressed.contains(49)==true,"held Space remains original history")}
        }else{
            check(writes==1 && selections==1 && legacyWrites==0 && commands==0,"\(mode): one range request and one caret request, no legacy edit/commit")
            if stopped {
                check(!e.enabled && !e.recovering,"\(mode): invalid result fails closed")
                check(posts.isEmpty && e.pending.count+e.retainedInput.count==4,"\(mode): all following originals retained, none released")
                let saved=(e.pending+e.retainedInput).map{UInt16($0.getIntegerValueField(.keyboardEventKeycode))}
                check(saved==[15,15,46,46],"\(mode): retained order unchanged")
                if mode=="caret-unapplied"{check(traces.contains("prefix_stop reason=prefix_caret_timeout"),"unapplied selection has bounded timeout")}
                if mode=="caret-changed"{check(selection==NSRange(location:3,length:0) && traces.contains("prefix_stop reason=prefix_caret_changed"),"different caret is not overwritten")}
            }else{
                check(e.enabled && !e.recovering && !g.ownsInput && e.pending.isEmpty && e.retainedInput.isEmpty,"\(mode): verified completion releases hold")
                check(e.prefixCoordinator.transaction == nil,"\(mode): completed transaction discarded; native history has no owner")
                check((restoreAt.map{ProcessInfo.processInfo.systemUptime-$0>=0.025} ?? false),"\(mode): stable caret verified, not setter return")
                if mode=="queued-next" {
                    check(posts.map{Int($0.0)}==[15,15,46,46] && posts.map{$0.1}==[true,false,true,false],"following originals delivered once and in order")
                    check(text==joined+" 그" && selection==NSRange(location:9,length:0),"next syllable begins at restored caret")
                }else{check(text==joined+" " && selection==NSRange(location:8,length:0) && posts.isEmpty,"\(mode): first pair only; suffix and caret intact; no replay")}
            }
        }
        if mode != "expired"{check(maxLateness<40,"\(mode): original event/publication timing not silently loosened (\(maxLateness)ms)")}
        results.append(["mode":mode,"writes":writes,"selections":selections,"legacyWrites":legacyWrites,"legacySelections":legacySelections,"spaceUpPassed":spaceUpPassed,"spaceUpHeld":spaceUpHeld,"compositionCommands":commands,"posted":posts.count,"pending":e.pending.count,"retained":e.retainedInput.count,"text":text,"selection":[selection.location,selection.length],"enabled":e.enabled,"maxLatenessMs":maxLateness,"events":events,"trace":traces])
        e.closeSession()
    }
}
let modes=["recorded","editor-without-menu","async-caret","delayed","uncertain","empty-baseline","queued-next","no-space","space-not-published","held-space","default-off","legacy-delayed","normal","no-witness","wrong-body","moved-caret","selected","source","field","expired","claim-race","range-unsupported","caret-unapplied","caret-changed","source-after-write","focus-after-write","secure-after-write","body-after-write"]
let chosen=CommandLine.arguments.dropFirst().first
for mode in modes where chosen==nil || chosen==mode {
    let before=failures;Case(mode).run();print("CASE \(mode): \(failures==before ? "PASS":"FAIL")")
}
check(!results.isEmpty,"at least one selected case ran")
let report:[String:Any]=["checks":checks,"failures":failures,"cases":results,"actualOSPosts":0,"actualAXRequests":0,"physical":false]
try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"result.json"))
print("\(failures==0 ? "PASS":"FAIL") \(checks) current-contract recorded-timing assertions; \(results.count) cases; in-memory editor only")
exit(failures==0 ? 0:1)
