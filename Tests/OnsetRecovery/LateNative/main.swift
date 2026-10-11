import AppKit
import Carbon

// Real IME typing in an owned window. Force detachment only by committing the
// first key; all remainder and normal-word expectations come from the real IME.
final class Fixture:NSObject,NSApplicationDelegate {
    var window:NSWindow!,view=NSTextView()
    var original:TISInputSource?,added:[TISInputSource]=[]
    var index=0,writes=0,owner:OnsetRecoveryEngine?
    var received:[(UInt16,NSEvent.EventType,Int64)]=[]
    let eventMarker:Int64=0x4C415445494D4501
    func later(_ action:@escaping ()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+0.04,execute:action)}
    func applicationDidFinishLaunching(_ n:Notification){
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]){[weak self] e in
            self?.received.append((e.keyCode,e.type,e.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0));return e
        }
        window=NSWindow(contentRect:NSRect(x:180,y:180,width:650,height:250),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="HanQ five-layout committed-word verification";window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3){self.next()}
    }
    func finish(_ ok:Bool,_ message:String){
        owner?.closeSession();view.inputContext?.discardMarkedText()
        if let original{TISSelectInputSource(original)}
        for source in added{TISDisableInputSource(source)}
        print("\(ok ? "PASS":"FAIL"): \(message)");fflush(stdout);exit(ok ? 0:1)
    }
    func fresh(){
        view.inputContext?.discardMarkedText();view=NSTextView(frame:NSRect(x:0,y:0,width:650,height:250));view.isRichText=false
        window.contentView=view;window.makeFirstResponder(view)
        view.string="앞🙂뒤";view.setSelectedRange(NSRange(location:3,length:0));received=[]
    }
    func next(){
        guard index<lateLayoutCases.count else{finish(true,"27 normal + 27 detached words: all five real IMEs, source/caret/surroundings and one edit verified");return}
        let item=lateLayoutCases[index];index+=1
        let query=[kTISPropertyInputSourceID as String:item.sourceID] as CFDictionary
        guard let list=TISCreateInputSourceList(query,true)?.takeRetainedValue() as? [TISInputSource],let source=list.first else{finish(false,"missing IME");return}
        if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()){
            guard TISEnableInputSource(source)==noErr else{finish(false,"enable failed");return};added.append(source)
        }
        fresh();guard TISSelectInputSource(source)==noErr else{finish(false,"select failed");return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.type(item.keys,index:0,detach:false){self.normal(item)}}
    }
    func type(_ keys:[(UInt16,Bool)],index:Int,detach:Bool,done:@escaping ()->Void){
        guard NSApp.isActive,window.firstResponder === view else{finish(false,"lost test-window focus");return}
        guard index<keys.count else{later(done);return}
        let (code,shift)=keys[index]
        if shift{let v=CGEvent(keyboardEventSource:nil,virtualKey:56,keyDown:true)!;v.type = .flagsChanged;v.flags = .maskShift;v.setIntegerValueField(.eventSourceUserData,value:eventMarker);if let g=owner?.gate,detach{_ = g.receive(.flagsChanged,v)};v.postToPid(getpid())}
        for down in [true,false]{
            let v=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;v.flags=shift ? .maskShift:[];v.setIntegerValueField(.eventSourceUserData,value:eventMarker)
            // Keep the test's original-key history independent of IME output.
            if let g=owner?.gate,detach{guard g.receive(down ? .keyDown:.keyUp,v) != nil else{finish(false,"original key captured before validation");return}}
            v.postToPid(getpid())
        }
        if shift{let v=CGEvent(keyboardEventSource:nil,virtualKey:56,keyDown:false)!;v.type = .flagsChanged;v.flags=[];v.setIntegerValueField(.eventSourceUserData,value:eventMarker);if let g=owner?.gate,detach{_ = g.receive(.flagsChanged,v)};v.postToPid(getpid())}
        later{
            if detach,index==0{
                // A real cursor key commits the first IME syllable. unmarkText()
                // alone does not end the input context's composition.
                for down in [true,false]{let v=CGEvent(keyboardEventSource:nil,virtualKey:124,keyDown:down)!;v.flags=[];v.setIntegerValueField(.eventSourceUserData,value:self.eventMarker);v.postToPid(getpid())}
                self.later{
                    self.view.inputContext?.discardMarkedText();self.view.unmarkText()
                    self.view.setSelectedRange(NSRange(location:4,length:0))
                    self.type(keys,index:index+1,detach:detach,done:done)
                }
                return
            }
            self.type(keys,index:index+1,detach:detach,done:done)
        }
    }
    func exactEdges(_ item:LateLayoutCase,detached:Bool)->Bool {
        var expected:[(UInt16,NSEvent.EventType)]=[]
        for (i,key) in item.keys.enumerated(){
            expected += [(key.0,.keyDown),(key.0,.keyUp)]
            if detached,i==0{expected += [(124,.keyDown),(124,.keyUp)]}
        }
        return received.count==expected.count && zip(received,expected).allSatisfy{$0.0==$1.0 && $0.1==$1.1 && $0.2==eventMarker}
    }
    func normal(_ item:LateLayoutCase){
        guard exactEdges(item,detached:false),view.string=="앞🙂"+item.joined+"뒤",view.selectedRange()==NSRange(location:3+item.joined.utf16.count,length:0) else{
            finish(false,"normal \(item.sourceID) \(item.name): \(view.string)");return
        }
        fresh()
        let e=OnsetRecoveryEngine(),g=OnsetInputGate(marker:e.marker),field=AXUIElementCreateApplication(getpid())
        owner=e;e.enabled=true;e.gate=g;g.beat()
        let layout=OnsetKeyboardLayout.load(sourceID:item.sourceID)!
        g.configureEarly(false,sourceID:item.sourceID,normal:Set(layout.normal.keys),shifted:Set(layout.shifted.keys))
        e.earlyBaseline=OnsetSnapshot(element:field,text:view.string,selection:view.selectedRange());e.publishPassedBaseline(e.earlyBaseline)
        e.testSnapshot={ [weak self] in guard let self,NSApp.isActive,self.window.firstResponder === self.view else{return nil};return OnsetSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange())}
        e.testOriginalSnapshot={ [weak self] _ in guard let self else{return nil};return OnsetSnapshot(element:field,text:self.view.string,selection:self.view.selectedRange())}
        e.testCanSelect={true};e.testCanReplaceText={true}
        e.testSetRange={ [weak self] _,range in self?.view.setSelectedRange(range);return .success }
        writes=0;e.testReplaceText={ [weak self] _,value in guard let self else{return .cannotComplete};self.writes+=1;self.view.insertText(value,replacementRange:self.view.selectedRange());return .success}
        e.testPost={_ in self.finish(false,"committed repair must not replay physical keys")}
        type(item.keys,index:0,detach:true){
            guard self.exactEdges(item,detached:true),self.view.string=="앞🙂"+item.split+"뒤",self.view.selectedRange()==NSRange(location:3+item.split.utf16.count,length:0) else{self.finish(false,"detached \(item.sourceID) \(item.name): \(self.view.string)");return}
            e.observePassedIdentity();_ = e.samplePassed(e.testSnapshot!())
            self.later{
                guard self.view.string=="앞🙂"+item.joined+"뒤",self.view.selectedRange()==NSRange(location:3+item.joined.utf16.count,length:0),self.writes==1,!e.recovering,e.pending.isEmpty,InputSourceAccess.currentID()==item.sourceID else{self.finish(false,"replacement \(item.sourceID) \(item.name)");return}
                print("PASS native committed",item.sourceID,item.name);fflush(stdout);e.closeSession();self.owner=nil;self.next()
            }
        }
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
