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

var rows:[[String:Any]]=[],queryCounts:[String:[Int]]=[:]
let output=URL(fileURLWithPath:CommandLine.arguments[1])
try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for enabled in [false,true] {
for mode in ["fresh","old","missing","normal"] {
    let c=Case(priorAge:mode=="old" ? 0.7:0)
    c.bundle="org.example.editor"
    // The fixture schedules each publication explicitly, with no idle observer.
    c.e.updateQueued=true
    if mode=="missing"{c.e.focusHandoff.invalidateEmptyEntries()}
    var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,initiallyEnabled:enabled,writer:{captures.append($0)})
    c.e.decisionTrace=trace;c.g.incidentTrace=trace
    let start=ProcessInfo.processInfo.systemUptime
    func at(_ t:Double){let wait=start+t-ProcessInfo.processInfo.systemUptime;if wait>0{RunLoop.current.run(until:Date(timeIntervalSinceNow:wait))}}
    c.original(5,true);at(0.080);c.publish("ㅎ");at(0.081);c.original(5,false);c.e.sample()
    at(0.578);c.original(46,true);at(0.604);c.publish(mode=="normal" ? "흐":"ㅎㅡ")
    at(0.709);c.original(0,true);at(0.723);c.original(46,false);at(0.737);c.publish(mode=="normal" ? "흠":"ㅎㅡㅁ")
    let queries=[c.sourceReads,c.snapshotReads,c.focusReads]
    if enabled{check(queryCounts[mode]==queries,"diagnostic ON adds no source, snapshot or focus queries: \(mode)")}
    else{queryCounts[mode]=queries}
    at(0.850);c.original(0,false);c.e.sample();c.spin()
    trace.flush();trace.mark();trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
    if enabled {
        check(captures.allSatisfy{(try? RecorderTrace.decode(JSONEncoder().encode($0))) != nil},"engine frames are strict")
        let data=try! JSONEncoder().encode(captures.first!)
        let value=String(data:data,encoding:.utf8)!
        for secret in ["org.example.editor","arbitrary presentation","com.apple.inputmethod","sourceID","keycode"]{check(!value.contains(secret),"no input payload: \(secret)")}
        let decisions=captures.flatMap{$0.frames}.filter{$0.kind == .onsetDecision}
        check(!decisions.isEmpty,"real engine branches reach the standard capture")
        if mode=="missing"{check(decisions.contains{$0.category==5},"missing pre-key representation distinguished")}
        else{check(decisions.contains{$0.category==12},"first-publication acceptance distinguished")}
        if mode=="normal"{check(decisions.contains{$0.category==16},"native composition distinguished from repair")}
        if mode=="old"{check(decisions.contains{$0.category==21},"verified repair claim distinguished")}
        try! data.write(to:output.appendingPathComponent("\(mode).json"))
    }else{check(captures.isEmpty,"diagnostic OFF captures nothing")}
    let expected=mode != "missing"
    check((c.text=="흠")==expected,"same final body with diagnostic \(enabled)")
    check(c.originals==6 && c.e.retainedInput.isEmpty && c.g.held.isEmpty,"input order and drain unchanged")
    check(mode=="normal" || mode=="missing" ? c.posts.isEmpty:c.posts.count==6,"normal/unproved input is not replayed")
    rows.append(["enabled":enabled,"mode":mode,"queriesBeforeClaim":queries,"originalEdges":c.originals,"replayEdges":c.posts.count,"composed":c.text=="흠"])
    trace.stopAndFlush();c.close()
}
}
try! JSONSerialization.data(withJSONObject:["cases":rows,"checks":checks,"failures":failures],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
print("PASS \(checks) engine diagnostic ON/OFF, routing, query counts and privacy checks")
exit(failures==0 ? 0:1)
