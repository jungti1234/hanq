import AppKit

var checks=0,failures=0
func check(_ value:Bool,_ name:String){checks+=1;if !value{failures+=1;print("FAIL",name)}}
func key(_ code:UInt16,_ down:Bool,shift:Bool=false)->CGEvent {
    let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
    event.flags=shift ? .maskShift:[];return event
}

// No global tap, AX query, source selection, clipboard or OS event posting.
// Only the product engine/gate run; every OS-facing operation is injected.
final class Case {
    let e=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(91001)
    let other=AXUIElementCreateApplication(91002)
    let g:OnsetInputGate
    var visible=false,text="",selection=NSRange(location:0,length:0)
    var source=KoreanKeyboardLayout.twoSetID,bundle="com.openai.codex"
    var commands=0,writes=0,selections=0,originals=0,sourceReads=0,snapshotReads=0,focusReads=0
    var posts:[(UInt16,Bool)]=[],replayChars=""
    var changedField=false,changedWindow=false
    init(sourceID:String=KoreanKeyboardLayout.twoSetID,label:String="arbitrary presentation",role:String=kAXTextAreaRole,priorAge:Double=0){
        source=sourceID
        g=OnsetInputGate(marker:e.marker);g.beat();g.enableReentryTrace()
        e.enabled=true;e.gate=g;e.testSource={self.sourceReads+=1;return self.source};e.testTargetBundleID={self.bundle}
        e.testCanSelect={true};e.testCanReplaceText={self.writes+=1;return true}
        e.testSnapshot={
            self.snapshotReads+=1
            guard self.visible else{self.e.unavailableReason="not_supported_text_field";return nil}
            return .init(element:self.changedField ? self.other:self.field,text:self.text,selection:self.selection)
        }
        e.testOriginalSnapshot={_ in .init(element:self.field,text:self.text,selection:self.selection)}
        e.testSetRange={_,range in self.selections+=1;self.selection=range;return .success}
        e.testReplaceText={_,_ in self.writes+=1;return .failure}
        e.testPostCompositionCommit={_,event in
            self.commands+=1
            if event.type == .keyUp{self.selection=NSRange(location:self.text.utf16.count-1,length:0)}
            return true
        }
        e.testPost={event in
            let code=UInt16(event.getIntegerValueField(.keyboardEventKeycode)),down=event.type == .keyDown
            self.posts.append((code,down));_ = self.g.receive(event.type,event)
            if down {
                let layout=KoreanKeyboardLayout.load(sourceID:self.source)!
                let shift=event.flags.contains(.maskShift)
                let char:Character
                if code==49{char=" "}
                else if !layout.physicalKeys.isEmpty{char=(shift ? layout.shiftedPhysicalKeys:layout.physicalKeys)[code]!}
                else{let letter=PhysicalLetterKeys.letters[code]!;char=layout.keys[Character(shift ? letter.uppercased():letter)]!}
                self.replayChars.append(char)
                switch layout.kind {
                case .twoSet:self.text=JamoComposer.compose(self.replayChars,combineStandalone:true)
                case .threeSet:self.text=JamoComposer.composeNativeThreeSet(self.replayChars)
                case .gongjinRoman,.hncRoman:self.text=JamoComposer.composeRomanized(self.replayChars,kind:layout.kind)
                }
                self.selection=NSRange(location:self.text.utf16.count,length:0)
            }
        }
        let root=AXUIElementCreateApplication(91003),outside=AXUIElementCreateApplication(91004)
        let h=e.focusHandoff
        h.ready={true};h.frontPID={42};h.owner={_ in 42}
        h.writable={_,_ in true};h.children={_ in []}
        h.read={element,name in
            self.focusReads+=1
            if name==kAXRoleAttribute{return (CFEqual(element,self.field) ? role:CFEqual(element,root) ? kAXWindowRole:kAXGroupRole) as CFString}
            if name==kAXChildrenAttribute{return (CFEqual(element,root) ? [self.field]:[]) as CFArray}
            if name==kAXWindowAttribute{return self.changedWindow ? self.other:root}
            if name==kAXValueAttribute{return label as CFString}
            if name==kAXNumberOfCharactersAttribute{return NSNumber(value:label.utf16.count)}
            if name==kAXSelectedTextRangeAttribute{var range=CFRange(location:0,length:0);return AXValueCreate(.cfRange,&range)!}
            if name==kAXEnabledAttribute{return kCFBooleanTrue}
            if name=="AXHidden"{return kCFBooleanFalse}
            return nil
        }
        h.batch={element,names in names.map{h.read(element,$0)}}
        h.now={ProcessInfo.processInfo.systemUptime-priorAge}
        h.advance(window:root,outside:outside)
        h.now={ProcessInfo.processInfo.systemUptime}
        if !label.isEmpty {check(h.candidate==nil,"nonempty presentation is not an empty/focus proof")}
        if !label.isEmpty && priorAge<=0.75 {check(h.representedEntry(for:field,before:ProcessInfo.processInfo.systemUptime) != nil,"read-only prior representation captured")}
        e.sample()
    }
    func original(_ code:UInt16,_ down:Bool,shift:Bool=false){
        let event=key(code,down,shift:shift)
        e.observeDeferredBeforeInput(event.type,event)
        check(g.receive(event.type,event) != nil,"unclaimed original passes")
        originals+=1
    }
    func publish(_ value:String){text=value;selection=NSRange(location:value.utf16.count,length:0);visible=true;e.sample()}
    func first(_ mode:String="normal",delay:Double=0,code:UInt16=15,shift:Bool=false,value:String="ㄱ"){
        original(code,true,shift:shift)
        if delay>0{RunLoop.current.run(until:Date(timeIntervalSinceNow:delay))}
        if mode != "missing"{publish(mode=="wrong_initial" ? "ㅁ":value)}
        check(commands==0 && selections==0 && posts.isEmpty,"one unanchored consonant never authorizes editing")
        original(code,false,shift:shift)
    }
    func pair(_ normal:Bool=false,held:Bool=false){
        original(46,true);publish(normal ? "그":"ㄱㅡ")
        check(commands==0 && selections==0,"a held following key cannot authorize replay")
        if !held{original(46,false);e.sample()}
    }
    func spin(){
        let deadline=Date(timeIntervalSinceNow:0.3)
        while e.recovering && Date()<deadline{g.beat();RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))}
    }
    func close(){e.closeSession()}
}


import AppKit

// The real engine and read-only handoff run against injected AX replies.
// No real app, focus write, input tap, source switch, clipboard or key post.
extension Case {
    func idlePresentation(_ mode:String) {
        let h=e.focusHandoff
        let root=AXUIElementCreateApplication(91003)
        let outside=AXUIElementCreateApplication(91004)
        let unreadable=AXUIElementCreateApplication(91005)
        let previousRead=h.read
        h.read={element,name in
            if CFEqual(element,root) && name==kAXChildrenAttribute{return [unreadable] as CFArray}
            if CFEqual(element,unreadable){return nil}
            if CFEqual(element,self.field) {
                if mode=="missing_count" && name==kAXNumberOfCharactersAttribute{return nil}
                if mode=="selected" && name==kAXSelectedTextRangeAttribute{
                    var range=CFRange(location:0,length:1);return AXValueCreate(.cfRange,&range)!
                }
            }
            return previousRead(element,name)
        }
        h.invalidateEmptyEntries()
        var simulated=ProcessInfo.processInfo.systemUptime-6.8
        let start=simulated
        h.now={simulated}
        // A previously focused field remains a read-only search hint. The
        // current window walk is incomplete, and supplies no focus authority.
        h.enteredEditor(field)
        for step in 0...340 {
            simulated=start+Double(step)*0.020
            h.advance(window:root,outside:outside)
        }
        h.now={ProcessInfo.processInfo.systemUptime}
        check(h.candidate==nil,"ambiguous window never authorizes focus")
        if mode=="invalidated"{h.invalidateEmptyEntries()}
        if mode=="wrong_window"{changedWindow=true}
        e.sample()
    }
}

let expectedRefresh=ProcessInfo.processInfo.environment["HANQ_EXPECT_REFRESH"]=="1"
var rows:[[String:Any]]=[]
for mode in ["presentation", "normal", "missing_count", "selected", "invalidated", "wrong_window", "different_field", "fast_presentation", "fast_missing_count"] {
    let c=Case(label:"synthetic prior presentation")
    c.bundle="org.example.injected-editor"
    c.e.updateQueued=true
    let fast=mode.hasPrefix("fast_")
    c.idlePresentation(mode=="fast_missing_count" ? "missing_count":mode)
    let beforeKey=ProcessInfo.processInfo.systemUptime
    let witnessed=c.e.focusHandoff.representedEntry(for:c.field,before:beforeKey) != nil
    let shouldWitness=expectedRefresh && ["presentation","normal","different_field","fast_presentation"].contains(mode)
    check(witnessed==shouldWitness,"pre-key witness after 6.8s: \(mode)")
    var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,initiallyEnabled:true,writer:{captures.append($0)})
    c.e.decisionTrace=trace;c.g.incidentTrace=trace
    let started=ProcessInfo.processInfo.systemUptime
    func at(_ t:Double){let remaining=started+t-ProcessInfo.processInfo.systemUptime;if remaining>0{RunLoop.current.run(until:Date(timeIntervalSinceNow:remaining))}}
    c.original(5,true)
    at(0.007);c.original(5,false)
    at(fast ? 0.049:0.068);c.publish("ㅎ")
    let firstProof=c.e.firstPublication != nil
    check(c.posts.isEmpty && c.commands==0 && c.selections==0,"single key remains unedited: \(mode)")
    if mode=="different_field"{c.changedField=true}
    at(fast ? 0.083:0.572);c.original(46,true)
    at(fast ? 0.103:0.596);c.publish(mode=="normal" ? "흐":"ㅎㅡ")
    check(c.posts.isEmpty,"held following key is not replayed: \(mode)")
    at(fast ? 0.142:0.650);c.original(46,false);c.e.sample();c.spin()
    at(fast ? 0.200:0.692);c.original(0,true)
    // The controlled editor independently supplies the final composition.
    // This is not reconstruction of the user's unrecorded key identities.
    c.publish(mode=="normal" || (["presentation","fast_presentation"].contains(mode) && expectedRefresh) ? "흠":"ㅎㅡㅁ")
    at(fast ? 0.250:0.750);c.original(0,false);c.e.sample();c.spin()
    trace.flush();trace.mark();trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
    let decisions=captures.flatMap{$0.frames}.filter{$0.kind == .onsetDecision}
    let shouldRepair=["presentation","fast_presentation"].contains(mode) && expectedRefresh
    check((!c.posts.isEmpty)==shouldRepair,"verified replay eligibility: \(mode)")
    check(firstProof==shouldWitness,"first publication proof: \(mode)")
    check(c.originals==6 && c.e.retainedInput.isEmpty && c.g.held.isEmpty,"originals pass and no input retained: \(mode)")
    check(shouldRepair ? c.posts.count==4:c.posts.isEmpty,"only verified first pair is replayed: \(mode)")
    check(captures.allSatisfy{(try? RecorderTrace.decode(JSONEncoder().encode($0))) != nil},"strict standard metadata: \(mode)")
    rows.append([
        "mode":mode,"simulatedIdleMilliseconds":6800,"preKeyWitness":witnessed,"firstPublicationProof":firstProof,
        "repairEdges":c.posts.count,"compositionCommands":c.commands,"selectionWrites":c.selections,
        "originalEdges":c.originals,"sourceReads":c.sourceReads,"snapshotReads":c.snapshotReads,
        "readOnlyFocusReads":c.focusReads,"decisionReasons":decisions.map{$0.category},
        "finalBodyComposed":c.text=="흠","candidateFocus":c.e.focusHandoff.candidate != nil,
    ])
    trace.stopAndFlush();c.close()
}
let result:[String:Any]=["cases":rows,"checks":checks,"failures":failures,
    "injectedOnly":true,"actualAppOrInputTest":false,"freshOriginalContextUnknown":true]
try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
print("RESULT \(checks) checks, \(failures) failures; controlled injected handoff/engine only")
exit(failures==0 ? 0:1)
