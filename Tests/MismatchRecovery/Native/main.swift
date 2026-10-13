import AppKit
import Carbon

// Isolated real IME integration. Only this test window receives replayed keys.
final class Fixture:NSObject,NSApplicationDelegate {
    var view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:220))
    var window:NSWindow!
    var original:TISInputSource?
    var originalRoman:Bool?
    var added:[TISInputSource]=[]
    struct Case { let id:String; let mixed:Bool; var word=false;var action="";var flags:CGEventFlags=[];var suffix="ab" }
    var cases:[Case] = CommandLine.arguments.contains("--english-case")
        ? KoreanKeyboardLayout.supportedIDs.flatMap{id in [Case(id:id,mixed:false,action:"caps-on",flags:[],suffix:"ab"),Case(id:id,mixed:false,action:"caps-on",flags:.maskShift,suffix:"AB"),Case(id:id,mixed:false,action:"caps-on",flags:.maskAlphaShift,suffix:"AB"),Case(id:id,mixed:false,action:"caps-on",flags:[.maskShift,.maskAlphaShift],suffix:"AB")]}
        : (CommandLine.arguments.contains("--source-interactions") || (CommandLine.arguments.contains("--source-interactions-single") || CommandLine.arguments.contains("--source-interactions-idle")))
        ? KoreanKeyboardLayout.supportedIDs.flatMap{id in ((CommandLine.arguments.contains("--source-interactions-single") || CommandLine.arguments.contains("--source-interactions-idle")) ? ["caps-on","menu-English"]:["caps-on","caps-off","menu-English","menu-Korean"]).map{Case(id:id,mixed:false,action:$0)}}
        : KoreanKeyboardLayout.supportedIDs.flatMap { [Case(id:$0,mixed:false),Case(id:$0,mixed:true)] } + [Case(id:KoreanKeyboardLayout.twoSetID,mixed:true,word:true)]
    var owner:MismatchRecoveryEngine?
    var timer:Timer?
    var began=0.0
    var posts=0
    func applicationDidFinishLaunching(_ n:Notification){
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        originalRoman=try? RomanSwitchController.isEnabled()
        if CommandLine.arguments.contains("--source-interactions") || (CommandLine.arguments.contains("--source-interactions-single") || CommandLine.arguments.contains("--source-interactions-idle")) {
            for id in KoreanKeyboardLayout.supportedIDs {
                guard let list=TISCreateInputSourceList([kTISPropertyInputSourceID as String:id] as CFDictionary,true)?.takeRetainedValue() as? [TISInputSource],let source=list.first else{finish(false,"missing matrix input source");return}
                if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()){
                    guard TISEnableInputSource(source)==noErr else{finish(false,"enable matrix source failed");return};added.append(source)
                }
            }
        }
        window=NSWindow(contentRect:NSRect(x:180,y:180,width:640,height:220),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="HanQ recovery layout verification";view.isRichText=false;window.contentView=view
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3){self.next()}
    }
    func finish(_ ok:Bool,_ message:String){
        timer?.invalidate();owner?.closeSession()
        if let original{TISSelectInputSource(original)}
        if let originalRoman{try? RomanSwitchController.setEnabled(originalRoman)}
        for source in added{TISDisableInputSource(source)}
        print(ok ? "PASS: \(message)":"FAIL: \(message)");fflush(stdout);exit(ok ? 0:1)
    }
    func next(){
        guard !cases.isEmpty else{finish(true,"all five native IMEs repaired original key + queued vowel/final without source substitution");return}
        guard NSApp.isActive,window.firstResponder === view else{finish(false,"fixture lost focus");return}
        view.inputContext?.discardMarkedText()
        view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:220));view.isRichText=false
        window.contentView=view;window.makeFirstResponder(view)
        let item=cases.removeFirst();let id=item.id
        let query=[kTISPropertyInputSourceID as String:id] as CFDictionary
        guard let sources=TISCreateInputSourceList(query,true)?.takeRetainedValue() as? [TISInputSource],let source=sources.first else{finish(false,"source missing: \(id)");return}
        if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()){
            guard TISEnableInputSource(source)==noErr else{finish(false,"enable failed");return};added.append(source)
        }
        guard InputSourceAccess.select("com.apple.keylayout.ABC")==noErr, TISSelectInputSource(source)==noErr else{finish(false,"select failed");return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.repair(item)}
    }
    func repair(_ item:Case){
        let id=item.id
        var keys:[UInt16]
        switch id {
        case KoreanKeyboardLayout.twoSetID:keys=[15,40,1] // rks -> 간
        case KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID:keys=[40,3,1] // kfs -> 간
        default:keys=[5,0,45] // gan -> 간
        }
        if item.word{keys=[2,40,3,7,46,7,31,12]}
        if (CommandLine.arguments.contains("--source-interactions-single") || CommandLine.arguments.contains("--source-interactions-idle")){keys=Array(keys.prefix(1))}
        var expected=item.word ? "알트탭":((CommandLine.arguments.contains("--source-interactions-single") || CommandLine.arguments.contains("--source-interactions-idle")) ? "ㄱ":"간")
        if CommandLine.arguments.contains("--source-interactions-idle"){expected="ㄱ"}
        let initialCount=item.word || !item.action.isEmpty ? keys.count:(item.mixed ? 2:1)
        let p=MismatchRecoveryEngine(),field=AXUIElementCreateApplication(getpid())
        owner=p;p.enabled=true;p.target=NSRunningApplication.current;p.planElement=field
        p.testSnapshot={ [weak self] in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return nil}
            return MismatchSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange())
        }
        p.testSetRange={ [weak self] _,range in self?.view.setSelectedRange(range);return .success }
        p.testSelectionWritable={_ in true}
        var finalSource=id,following:[UInt16]=[]
        if !item.action.isEmpty {
            do{try RomanSwitchController.setEnabled(item.action != "caps-off")}catch{finish(false,"Roman Switch state verification failed");return}
            p.capsSwitchEnabled={(try? RomanSwitchController.isEnabled()) == true}
            p.testEventRecipient={_ in getpid()}
            var injected=false
            let other=id==KoreanKeyboardLayout.threeSet390ID ? KoreanKeyboardLayout.gongjinID:KoreanKeyboardLayout.threeSet390ID
            if item.action=="caps-on" || item.action=="menu-English"{finalSource="com.apple.keylayout.ABC";following=[0,11];expected+=item.suffix}
            else if item.action=="caps-off" {following=keys;expected+="간"}
            else {finalSource=other;following=other==KoreanKeyboardLayout.gongjinID ? [5,0,45]:[40,3,1];expected+="간"}
            p.systemSwitch.didSelect={ [weak p] selected,result in
                guard let p,!injected,selected=="com.apple.keylayout.ABC",result==noErr else{return};injected=true
                let timestamp=MismatchRecoveryEngine.sourceEventTime()
                if item.action.hasPrefix("caps-") {
                    p.potentialCapsSourceSwitch(at:timestamp)
                    if item.action=="caps-on" {guard InputSourceAccess.select(id)==noErr else{self.finish(false,"simulated Caps source selection failed");return};p.observeRecoverySource(id,at:timestamp+1)}
                }else {
                    p.beginSourceMenu(at:timestamp)
                    guard InputSourceAccess.select(finalSource)==noErr else{self.finish(false,"menu source selection failed");return}
                    p.observeRecoverySource(finalSource,at:timestamp+1)
                }
            }
        }
        if CommandLine.arguments.contains("--source-interactions-idle"){following=[];expected="ㄱ"}
        // Default uses the production explicit selector, without a source test
        // double. The legacy branch is a separate comparison fixture only.
        if CommandLine.arguments.contains("--legacy-source-switch") {
            let legacy=LegacySourceSwitch()
            p.testSelectSource={target in let result=legacy.request(marker:p.marker,valid:{NSApp.isActive && self.window.firstResponder === self.view});print("legacy request",target,result);return result}
            p.testSource={legacy.busy ? "legacy_transition_in_flight":InputSourceAccess.currentID()}
        }
        var selectedAt=0.0,staleDowns=0
        let activationLag=CommandLine.arguments.contains("--activation-lag") || CommandLine.arguments.contains("--activation-lag-long")
        let activationDelay=CommandLine.arguments.contains("--activation-lag-long") ? 0.15:0.08
        let coalescing=CommandLine.arguments.contains("--cycle-coalescing")
        var englishSelectedAt=0.0,clientReady=true
        if activationLag || coalescing {
            p.systemSwitch.didSelect={selected,result in
                guard result==noErr else{return}
                let now=ProcessInfo.processInfo.systemUptime
                if selected==p.englishID{englishSelectedAt=now}
                if selected==id{selectedAt=now;clientReady=now-englishSelectedAt>=0.08}
            }
        }
        posts=0
        p.testPost={ [weak self] event in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return}
            self.posts+=1
            if InputSourceAccess.currentID()==id,((activationLag && ProcessInfo.processInfo.systemUptime-selectedAt<activationDelay) || (coalescing && !clientReady)) {
                if event.type == .keyDown,let code=UInt16(exactly:event.getIntegerValueField(.keyboardEventKeycode)),let roman=MismatchRecoveryPlan.character(code,event.flags.contains(.maskShift)) {
                    staleDowns+=1
                    // Preserve posted-event timing: the editor receives the key
                    // after beginRecovery returns and later input is queued.
                    DispatchQueue.main.async{self.view.insertText(roman,replacementRange:self.view.selectedRange())}
                }
                return
            }
            if CommandLine.arguments.contains("--session-post"){event.post(tap:.cgSessionEventTap)}
            else if CommandLine.arguments.contains("--hid-post"){event.post(tap:.cghidEventTap)}
            else{event.postToPid(getpid())}
        }
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3,sourceID:id)
        _ = candidate.append(code:keys[0],shift:false)
        if !item.action.isEmpty {for code in keys.dropFirst(){_ = candidate.append(code:code,shift:false)}}
        if item.mixed {
            for code in keys[1..<initialCount]{_ = candidate.append(code:code,shift:false)}
            let mixed=MismatchRecoveryPlan.character(keys[0],false)! + MismatchKeyboardLayout.render(keys:keys[1..<initialCount].map{($0,false)},sourceID:id)!
            let observed="앞🙂"+mixed+"뒤",range=NSRange(location:3+mixed.utf16.count,length:0)
            candidate=candidate.mixedPlan(text:observed,selection:range)!
            view.unmarkText();view.string=observed;view.setSelectedRange(range)
        } else {
            view.unmarkText();view.string=candidate.expected!;view.setSelectedRange(NSRange(location:3+candidate.roman.utf16.count,length:0))
        }
        p.beginRecovery(candidate,p.testSnapshot!()!)
        for code in item.action.isEmpty ? Array(keys.dropFirst(initialCount)):following {
            for down in [true,false]{
                let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=item.flags
                guard p.event(down ? .keyDown:.keyUp,event)==nil else{finish(false,"queued key escaped: \(id), recovering=\(p.recovering), suspended=\(p.suspended), pending=\(p.pending.count) retained=\(p.retained.count), text=\(self.view.string), active=\(NSApp.isActive)");return}
            }
        }
        began=ProcessInfo.processInfo.systemUptime
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in
            guard let self else{return}
            if !p.recovering {
                self.timer?.invalidate()
                let eventCount=(keys.count+(item.action.isEmpty ? 0:following.count)+staleDowns)*2
                guard self.view.string=="앞🙂"+expected+"뒤",self.view.selectedRange()==NSRange(location:3+expected.utf16.count,length:0),!p.suspended,p.retained.isEmpty,p.pending.isEmpty,self.posts==eventCount,InputSourceAccess.currentID()==finalSource else{self.finish(false,"\(id) \(item.action): text=\(self.view.string), posts=\(self.posts), suspended=\(p.suspended), retained=\(p.retained.count), source=\(InputSourceAccess.currentID()) intended=\(p.intendedSource)");return}
                print("PASS:",id,item.action.isEmpty ? (item.mixed ? "mixed prefix":"ASCII prefix"):item.action,"expected=\(expected); \(eventCount/2) down/up pairs, source=\(finalSource)");fflush(stdout)
                p.closeSession();DispatchQueue.main.asyncAfter(deadline:.now()+0.1){self.next()}
            } else if ProcessInfo.processInfo.systemUptime-self.began>8{self.finish(false,"timeout: \(id)")}
        }
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
