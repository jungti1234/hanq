import AppKit
import Carbon

// Isolated real IME integration. Only this test window receives replayed keys.
final class Fixture:NSObject,NSApplicationDelegate {
    var view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:220))
    var window:NSWindow!
    var original:TISInputSource?
    var added:[TISInputSource]=[]
    struct Case { let id:String; var shift=false; var suffix:[UInt16]?=nil; var expected="간" }
    var cases=KoreanKeyboardLayout.supportedIDs.map { Case(id:$0) } + [
        Case(id:KoreanKeyboardLayout.gongjinID,shift:true,expected:"깐"),
        Case(id:KoreanKeyboardLayout.hncID,shift:true,expected:"깐"),
        Case(id:KoreanKeyboardLayout.gongjinID,suffix:[0,14],expected:"개"), // gae
        Case(id:KoreanKeyboardLayout.hncID,suffix:[0,34],expected:"개") // gai
    ]
    var owner:OnsetRecoveryEngine?
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
        let expected="앞🙂"+item.expected+"뒤"
        var keys:[UInt16]
        switch id {
        case KoreanKeyboardLayout.twoSetID:keys=[15,40,1] // rks -> 간
        case KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID:keys=[40,3,1] // kfs -> 간
        default:keys=[5,0,45] // gan -> 간
        }
        if let suffix=item.suffix{keys=[keys[0]]+suffix}
        let p=OnsetRecoveryEngine(),field=AXUIElementCreateApplication(getpid())
        owner=p;p.enabled=true;p.testCanSelect={true}
        let gate=OnsetInputGate(marker:p.marker);gate.beat();p.gate=gate
        p.testSnapshot={ [weak self] in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return nil}
            return OnsetSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange())
        }
        p.testSetRange={ [weak self] _,range in self?.view.setSelectedRange(range);return .success }
        posts=0
        p.testPost={ [weak self] event in
            guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return}
            _ = gate.receive(event.type,event)
            self.posts+=1;event.postToPid(getpid())
        }
        // Simulate only the detached first consonant. The actual IME receives
        // the product engine's replacement and queued vowel/final events.
        p.lastEditable=OnsetSnapshot(element:field,text:"앞🙂뒤",selection:NSRange(location:3,length:0))
        p.unavailableReason="not_supported_text_field";p.sampleEarly(nil)
        let first=CGEvent(keyboardEventSource:nil,virtualKey:keys[0],keyDown:true)!;first.flags=item.shift ? .maskShift:[]
        guard gate.receive(.keyDown,first) != nil else{finish(false,"first key blocked");return}
        view.unmarkText();view.string=item.shift ? "앞🙂ㄲ뒤":"앞🙂ㄱ뒤";view.setSelectedRange(NSRange(location:4,length:0))
        p.sample()
        for code in keys.dropFirst(){
            for down in [true,false]{
                let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;event.flags=[]
                guard gate.receive(down ? .keyDown:.keyUp,event)==nil else{finish(false,"queued key escaped");return}
            }
        }
        began=ProcessInfo.processInfo.systemUptime
        timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){[weak self] _ in
            guard let self else{return}
            if !p.recovering && self.view.string==expected {
                self.timer?.invalidate()
                guard self.view.string==expected,self.view.selectedRange()==NSRange(location:4,length:0),p.pending.isEmpty,self.posts==6,InputSourceAccess.currentID()==id else{self.finish(false,"\(id): text=\(self.view.string), posts=\(self.posts), retained=\(p.pending.count)");return}
                print("PASS:",id,item.expected,"3 down/up pairs, source preserved");fflush(stdout)
                p.closeSession();DispatchQueue.main.asyncAfter(deadline:.now()+0.1){self.next()}
            } else if ProcessInfo.processInfo.systemUptime-self.began>8{self.finish(false,"timeout: \(id), text=\(self.view.string), posts=\(self.posts), recovering=\(p.recovering)")}
        }
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
