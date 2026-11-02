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
    var commands=0,writes=0,selections=0,originals=0
    var posts:[(UInt16,Bool)]=[],replayChars=""
    var changedField=false,changedWindow=false
    init(sourceID:String=KoreanKeyboardLayout.twoSetID,label:String="arbitrary presentation",role:String=kAXTextAreaRole){
        source=sourceID
        g=OnsetInputGate(marker:e.marker);g.beat();g.enableReentryTrace()
        e.enabled=true;e.gate=g;e.testSource={self.source};e.testTargetBundleID={self.bundle}
        e.testCanSelect={true};e.testCanReplaceText={self.writes+=1;return true}
        e.testSnapshot={
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
        h.advance(window:root,outside:outside)
        check(h.candidate==nil,"nonempty presentation is not an empty/focus proof")
        check(h.representedEntry(for:field,before:ProcessInfo.processInfo.systemUptime) != nil,"read-only prior representation captured")
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


// Both downs precede the first readable editor. This models the order in
// saved354 manual20/22 without pretending the injected snapshot is a real app.
for bundle in ["com.openai.codex","org.example.editor","com.microsoft.edgemac"] {
for label in ["Codex와 함께 작업하세요","Start here","任意の案内"] {
for role in [kAXTextAreaRole,kAXTextFieldRole] {
for continued in [false,true] {
    let c=Case(label:label,role:role);c.bundle=bundle
    c.original(15,true);c.original(46,true);c.original(15,false)
    c.publish("ㄱㅡ")
    check(c.commands==0 && c.selections==0 && c.posts.isEmpty,"two-key observation alone cannot edit while a key is held")
    c.original(46,false);c.e.sample()
    let rest:[UInt16]=continued ? [3,38,0]:[]
    for code in rest {for down in [true,false] {
        let event=key(code,down)
        c.e.observeDeferredBeforeInput(event.type,event)
        check(c.g.receive(event.type,event)==nil,"following keys join only the proved repair")
    }}
    c.spin()
    check(c.text==(continued ? "그럼":"그"),"two keys before first readable body recover without Space")
    check(c.posts.map{$0.0}==([UInt16(15),46]+rest).flatMap{[$0,$0]},"exact original sequence is replayed once")
    check(c.commands==2 && c.writes==0,"one verified native commit and no direct text writes")
    check(!c.e.recovering && c.e.pending.isEmpty && c.e.retainedInput.isEmpty && c.g.held.isEmpty,"all input drains")
    c.close()
}
}
}
}
// Both keys passed, but the first AX publication lags by one key.
for priorReadable in [false,true] {
for mode in ["split", "normal", "late", "third", "wrong", "caret", "selected", "field", "window", "source", "manual", "pointer", "shortcut"] {
    let c=Case(label:"arbitrary changing display")
    if priorReadable{c.visible=true;c.text="arbitrary changing display";c.selection=NSRange(location:0,length:0);c.e.sample()}
    c.original(15,true);c.original(46,true);c.original(15,false)
    c.publish(mode=="wrong" ? "ㅁ":"ㄱ")
    check(c.commands==0 && c.selections==0 && c.posts.isEmpty,"partial publication cannot authorize editing")
    c.original(46,false)
    c.e.sample()
    if mode=="late"{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.16))}
    if mode=="third"{c.original(3,true);c.original(3,false)}
    if mode=="field"{c.changedField=true}
    if mode=="window"{c.changedWindow=true}
    if mode=="source"{c.source="com.apple.keylayout.ABC"}
    if mode=="manual"{c.e.canBeginRepair={false}}
    if mode=="pointer"{_ = c.g.receive(.leftMouseDown,key(0,true))}
    if mode=="shortcut"{let event=key(0,true);event.flags = .maskCommand;_ = c.g.receive(.keyDown,event)}
    c.text=mode=="normal" ? "그":(mode=="third" ? "ㄱㅡㄹ":"ㄱㅡ")
    c.selection=mode=="caret" ? NSRange(location:0,length:0):(mode=="selected" ? NSRange(location:0,length:2):NSRange(location:c.text.utf16.count,length:0))
    c.e.sample();c.spin()
    if mode=="split" {
        check(c.text=="그" && c.posts.map{$0.0}==[15,15,46,46],"lagging one-key publication can advance to exact two-key repair")
        check(c.commands==2 && c.writes==0 && !c.e.recovering && c.e.retainedInput.isEmpty,"lagging publication completes one verified repair")
    } else {
        check(c.commands==0 && c.selections==0 && c.posts.isEmpty && c.writes==0,"lagging publication preserves guard \(mode)")
    }
    c.close()
}
}
for mode in ["normal","prefix","suffix","caret","selected","missing_prior","unchanged","window","window_after","source","manual","repeat","pointer","shortcut","late","three_keys","wrong_split","field","race"] {
    let c=Case(label:mode=="unchanged" ? "ㄱㅡ":"uninterpreted prior value");c.original(15,true);c.original(46,true);c.original(15,false)
    if mode=="repeat"{let e=key(46,true);e.setIntegerValueField(.keyboardEventAutorepeat,value:1);_ = c.g.receive(.keyDown,e)}
    if mode=="pointer"{_ = c.g.receive(.leftMouseDown,key(0,true))}
    if mode=="shortcut"{let e=key(0,true);e.flags = .maskCommand;_ = c.g.receive(.keyDown,e)}
    if mode=="missing_prior"{c.e.focusHandoff.invalidateEmptyEntries()}
    if mode=="window"{c.changedWindow=true}
    if mode=="source"{c.source="com.apple.keylayout.ABC"}
    if mode=="manual"{c.e.canBeginRepair={false}}
    if mode=="late"{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.16))}
    if mode=="three_keys"{c.original(3,true);c.original(3,false)}
    c.text=mode=="normal" ? "그":(mode=="prefix" ? "앞ㄱㅡ":(mode=="suffix" ? "ㄱㅡ뒤":(mode=="wrong_split" ? "ㄴㅡ":(mode=="three_keys" ? "ㄱㅡㄹ":"ㄱㅡ"))))
    c.selection=NSRange(location:c.text.utf16.count,length:0)
    if mode=="caret"{c.selection=NSRange(location:0,length:0)}
    if mode=="selected"{c.selection=NSRange(location:0,length:2)}
    c.visible=true;c.e.sample()
    if mode=="window_after"{c.changedWindow=true}
    if mode=="field"{c.changedField=true}
    if mode=="race"{c.e.testCanSelect={check(c.g.receive(.keyDown,key(3,true)) != nil,"a concurrent original passes before the atomic claim");return true}}
    c.original(46,false);c.e.sample();c.spin()
    check(c.commands==0 && c.selections==0 && c.posts.isEmpty && c.writes==0,"unproved/normal two-key publication \(mode) remains untouched")
    c.close()
}
for priorReadable in [false,true] {
for wrong in [false,true] {
    let c=Case(label:"Uninterpreted display")
    if priorReadable{c.visible=true;c.text="Uninterpreted display";c.selection=NSRange(location:0,length:0);c.e.sample()}
    c.first(wrong ? "wrong_initial":"normal")
    c.pair();c.spin()
    check(wrong ? c.posts.isEmpty:c.text=="그","first readable mismatch is terminal; exact one-key publication can extend to split pair")
    c.close()
}
}

// Both fixed words keep their original following composition after a delayed
// first publication over a readable prior representation. No OS input is sent.
for (codes,word):([UInt16],String) in [([15,46,3,38,0],"그럼"),([0,37,15,31,12,40,2],"미개방")] {
for firstBeforeSecond in [false,true] {
    let c=Case(label:"arbitrary prior representation")
    c.visible=true;c.text="arbitrary prior representation";c.selection=NSRange(location:0,length:0);c.e.sample()
    let initial=OnsetKeyboardLayout.load(sourceID:c.source)!.variants(code:codes[0],shift:false).first!
    c.original(codes[0],true)
    if firstBeforeSecond{c.publish(initial)}
    c.original(codes[0],false);c.original(codes[1],true)
    c.publish(initial)
    check((firstBeforeSecond || c.e.firstPublication==nil) && c.g.passedObservation() != nil && c.commands==0 && c.selections==0 && c.posts.isEmpty,"partial publication retains history but never authorizes editing")
    let layout=KoreanKeyboardLayout.load(sourceID:c.source)!
    let vowel=layout.keys[Character(PhysicalLetterKeys.letters[codes[1]]!)]!
    c.publish(initial+String(vowel));c.original(codes[1],false);c.e.sample()
    for code in codes.dropFirst(2){for down in [true,false]{let event=key(code,down);c.e.observeDeferredBeforeInput(event.type,event);check(c.g.receive(event.type,event)==nil,"only proved repair owns following word keys")}}
    c.spin()
    check(c.text==word && c.posts.map{$0.0}==codes.flatMap{[$0,$0]},"full normal word and exact once replay after delayed representation")
    check(c.writes==0 && !c.e.recovering && c.e.pending.isEmpty && c.e.retainedInput.isEmpty && c.g.held.isEmpty,"following composition drains without text write or retained input")
    c.close()
}
}
print("\(failures==0 ? "PASS":"FAIL") \(checks) two-key first-publication engine/gate checks; no OS keys posted")
exit(failures==0 ? 0:1)
