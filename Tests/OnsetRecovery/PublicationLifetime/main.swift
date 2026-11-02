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

for invalidation in ["none","pointer","shortcut","window","not_ready","clock_back","deadline","field","source"] {
    let c=Case(priorAge:0.7)
    let h=c.e.focusHandoff
    let firstTime=ProcessInfo.processInfo.systemUptime
    var now=firstTime
    h.now={now}
    let witness=h.representationWitness(for:c.field,before:firstTime)!
    let first=OnsetInputGate.Reservation(code:5,shift:false,time:firstTime,sourceID:c.source)
    var passed=OnsetInputGate.PassedInput(first:first,keys:[(5,false),(46,false)],pressed:[])
    let proof=OnsetFirstPublication(first:first,field:c.field,isCurrent:witness.isCurrent)
    var current=OnsetSnapshot(element:c.field,text:"ㅎㅡ",selection:NSRange(location:2,length:0))
    now=firstTime+0.6
    check(h.representedEntry(for:c.field,before:firstTime)==nil,"pre-key cache expires independently")
    check(proof.matches(passed,current),"witnessed first publication survives old cache expiry")
    switch invalidation {
    case "pointer":c.e.prepareFocusForFirstInput(.leftMouseDown,key(0,true))
    case "shortcut":let event=key(0,true);event.flags = .maskCommand;c.e.prepareFocusForFirstInput(.keyDown,event)
    case "window":c.changedWindow=true
    case "not_ready":h.ready={false}
    case "clock_back":now=firstTime-0.001
    case "deadline":now=firstTime+2
    case "field":current=OnsetSnapshot(element:c.other,text:"ㅎㅡ",selection:NSRange(location:2,length:0))
    case "source":passed=OnsetInputGate.PassedInput(first:.init(code:5,shift:false,time:firstTime,sourceID:"com.apple.keylayout.ABC"),keys:[(5,false),(46,false)],pressed:[])
    default:break
    }
    check(proof.matches(passed,current)==(invalidation=="none"),"existing invalidation remains effective: \(invalidation)")
    c.close()
}
print("PASS \(checks) first-publication lifetime and safety checks; no OS input")
exit(failures==0 ? 0:1)
