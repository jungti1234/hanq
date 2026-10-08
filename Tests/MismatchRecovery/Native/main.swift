import AppKit
import Carbon

// Isolated real IME integration. Only this test window receives replayed keys.
final class Fixture:NSObject,NSApplicationDelegate {
    var view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:220))
    var window:NSWindow!
    var original:TISInputSource?
    var added:[TISInputSource]=[]
    struct Case { let id:String; let mixed:Bool; var word=false }
    var cases=KoreanKeyboardLayout.supportedIDs.flatMap { [Case(id:$0,mixed:false),Case(id:$0,mixed:true)] } + [Case(id:KoreanKeyboardLayout.twoSetID,mixed:true,word:true)]
    var owner:MismatchRecoveryEngine?
    var timer:Timer?
    var began=0.0
    var posts=0
    func applicationDidFinishLaunching(_ n:Notification){
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        window=NSWindow(contentRect:NSRect(x:180,y:180,width:640,height:220),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="HanQ recovery layout verification";view.isRichText=false;window.contentView=view
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3){self.next()}
    }
    func finish(_ ok:Bool,_ message:String){
        timer?.invalidate();owner?.closeSession()
        if let original{TISSelectInputSource(original)}
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
        guard TISSelectInputSource(source)==noErr else{finish(false,"select failed");return}
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
        let expected=item.word ? "알트탭":"간"
        let initialCount=item.word ? keys.count:(item.mixed ? 2:1)
        let p=MismatchRecoveryEngine(),field=AXUIElementCreateApplication(getpid())
        owner=p;p.enabled=true;p.target=NSRunningApplication.current;p.planElement=field
        p.testSnapshot={ [weak self] in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return nil}
            return MismatchSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange())
        }
        p.testSetRange={ [weak self] _,range in self?.view.setSelectedRange(range);return .success }
        p.testSelectionWritable={_ in true}
        // The engine decides the target IDs; the fixture selects real IMEs directly.
        p.testSelectSource={id in let result=InputSourceAccess.select(id);print("select",id,result,InputSourceAccess.currentID());return result}
        posts=0
        p.testPost={ [weak self] event in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return}
            self.posts+=1;event.postToPid(getpid())
        }
        var candidate=MismatchRecoveryPlan(before:"앞🙂뒤",caret:3,sourceID:id)
        _ = candidate.append(code:keys[0],shift:false)
        if item.mixed {
            for code in keys[1..<initialCount]{_ = candidate.append(code:code,shift:false)}
            let mixed=MismatchRecoveryPlan.character(keys[0],false)! + MismatchKeyboardLayout.render(keys:keys[1..<initialCount].map{($0,false)},sourceID:id)!
            let observed="앞🙂"+mixed+"뒤",range=NSRange(location:3+mixed.utf16.count,length:0)
            candidate=candidate.mixedPlan(text:observed,selection:range)!
            view.unmarkText();view.string=observed;view.setSelectedRange(range)
        } else {
            view.unmarkText();view.string=candidate.expected!;view.setSelectedRange(NSRange(location:4,length:0))
        }
        p.beginRecovery(candidate,p.testSnapshot!()!)
        for code in keys.dropFirst(initialCount){
            for down in [true,false]{
                let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[]
                guard p.event(down ? .keyDown:.keyUp,event)==nil else{finish(false,"queued key escaped: \(id), recovering=\(p.recovering), suspended=\(p.suspended), pending=\(p.pending.count) retained=\(p.retained.count), text=\(self.view.string), active=\(NSApp.isActive)");return}
            }
        }
        began=ProcessInfo.processInfo.systemUptime
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in
            guard let self else{return}
            if !p.recovering {
                self.timer?.invalidate()
                guard self.view.string=="앞🙂"+expected+"뒤",self.view.selectedRange()==NSRange(location:3+expected.utf16.count,length:0),p.retained.isEmpty,p.pending.isEmpty,self.posts==keys.count*2,InputSourceAccess.currentID()==id else{self.finish(false,"\(id): text=\(self.view.string), posts=\(self.posts), retained=\(p.retained.count)");return}
                print("PASS:",id,item.mixed ? "mixed prefix":"ASCII prefix","expected=\(expected); \(keys.count) down/up pairs, source preserved");fflush(stdout)
                p.closeSession();DispatchQueue.main.asyncAfter(deadline:.now()+0.1){self.next()}
            } else if ProcessInfo.processInfo.systemUptime-self.began>8{self.finish(false,"timeout: \(id)")}
        }
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
