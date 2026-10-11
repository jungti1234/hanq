import AppKit
import Carbon

// This fixture uses no recovery engine or AX mocks. The running HanQ candidate
// observes global HID keys and edits this field through the real AX interface.
final class Field:NSTextView {
    var hiddenRange=false
    var edges:[(UInt16,NSEvent.EventType)]=[]
    var committed:(()->Void)?
    override func accessibilitySelectedTextRange()->NSRange {
        hiddenRange ? NSRange(location:NSNotFound,length:0):super.accessibilitySelectedTextRange()
    }
    override func keyDown(with e:NSEvent){edges.append((e.keyCode,e.type));super.keyDown(with:e)}
    override func keyUp(with e:NSEvent){edges.append((e.keyCode,e.type));if e.keyCode==49{hiddenRange=false};super.keyUp(with:e);if e.keyCode==49{committed?()}}
}
final class Outside:NSButton {
    var first:((NSEvent)->Void)?
    override var acceptsFirstResponder:Bool{true}
    override func keyDown(with e:NSEvent){first?(e)}
    override func keyUp(with e:NSEvent){super.keyUp(with:e)}
}
final class AuditWindow:NSWindow {
    var edges:[(UInt16,NSEvent.EventType)]=[]
    override func sendEvent(_ e:NSEvent){
        if e.type == .keyDown || e.type == .keyUp{edges.append((e.keyCode,e.type))}
        super.sendEvent(e)
    }
}
final class Fixture:NSObject,NSApplicationDelegate {
    var window:AuditWindow!,field=Field(),outside=Outside()
    var original:TISInputSource?,added:[TISInputSource]=[]
    var index=0,receivedFirst=0,firstDown:UInt16?,item:LateLayoutCase?
    let resultURL=URL(fileURLWithPath:CommandLine.arguments[1])
    var rows:[[String:Any]]=[]
    let physical=CommandLine.arguments.contains("--physical") || CommandLine.arguments.contains("--physical-normal")
    let normal=CommandLine.arguments.contains("--physical-normal")
    var samples:[LateLayoutCase] {
        guard normal else{return lateLayoutCases}
        return KoreanKeyboardLayout.supportedIDs.flatMap { id in
            let extra=(id==KoreanKeyboardLayout.gongjinID || id==KoreanKeyboardLayout.hncID) ? "phonetic compound vowel":(id==KoreanKeyboardLayout.twoSetID ? "shift initial":"repeated initial")
            return lateLayoutCases.filter{$0.sourceID==id && ($0.name=="final" || $0.name==extra)}
        }
    }
    var firstAt=0.0
    var physicalHint=""
    func later(_ seconds:Double=0.05,_ action:@escaping ()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:action)}
    func applicationDidFinishLaunching(_ n:Notification){
        if physical,let data=try? Data(contentsOf:resultURL.deletingLastPathComponent().appendingPathComponent("prior.json")),let old=try? JSONSerialization.jsonObject(with:data) as? [String:Any],old["physical_keys"] as? Bool == true,let prior=old["cases"] as? [[String:Any]] {
            for row in prior {
                guard row["pass"] as? Bool == true,index<samples.count,row["source"] as? String==samples[index].sourceID,row["case"] as? String==samples[index].name else{break}
                rows.append(row);index+=1
            }
        }
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let ready:[String:Any]=["pid":Int(getpid()),"source":InputSourceAccess.currentID()]
        try! JSONSerialization.data(withJSONObject:ready).write(to:resultURL.deletingLastPathComponent().appendingPathComponent("ready.json"),options:.atomic)
        window=AuditWindow(contentRect:NSRect(x:150,y:230,width:680,height:320),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="한Q 빌드 검증 · 시험 중 키 입력을 멈춰주세요"
        outside.frame=NSRect(x:20,y:265,width:640,height:40);outside.title="다섯 입력기 · 실제 AX 사후 보정"
        window.contentView!.addSubview(outside)
        outside.first={ [weak self] event in
            guard let self,let item=self.item,event.keyCode==item.keys[0].0 else{self?.finish(false,"unexpected outside key");return}
            if self.normal{self.window.makeFirstResponder(self.field);self.field.keyDown(with:event);return}
            self.receivedFirst+=1;self.firstAt=ProcessInfo.processInfo.systemUptime;self.firstDown=event.keyCode;self.window.makeFirstResponder(self.field)
            self.field.insertText(String(item.split.first!),replacementRange:self.field.selectedRange())
        }
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);later(0.3){self.next()}
    }
    func finish(_ ok:Bool,_ reason:String){
        field.inputContext?.discardMarkedText();if let original{TISSelectInputSource(original)}
        for source in added{TISDisableInputSource(source)}
        let report:[String:Any]=["passed":ok,"reason":reason,"cases":rows,"physical_keys":physical,"fault_injected":!normal,"test":"running HanQ, global HID, real AX and IMEs"]
        try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:resultURL)
        print("\(ok ? "PASS":"FAIL") installed app: \(reason)");fflush(stdout);exit(ok ? 0:1)
    }
    func progress(_ stage:String){
        let row:[String:Any]=["stage":stage,"case":index,"verified":rows.count,"active":NSApp.isActive,"time":Date().timeIntervalSince1970]
        try? JSONSerialization.data(withJSONObject:row).write(to:resultURL.deletingLastPathComponent().appendingPathComponent("progress.json"),options:.atomic)
    }
    func next(){
        progress("next")
        guard index<samples.count else{finish(true,normal ? "all 10 normal physical words confirmed in five IMEs; no forced split":"all 27 delayed first words repaired with original key count, surroundings, caret and selected source");return}
        item=samples[index];index+=1;receivedFirst=0;firstDown=nil;progress("prepare")
        let item=item!,query=[kTISPropertyInputSourceID as String:item.sourceID] as CFDictionary
        guard let list=TISCreateInputSourceList(query,true)?.takeRetainedValue() as? [TISInputSource],let source=list.first else{finish(false,"source unavailable");return}
        if let raw=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()){
            guard TISEnableInputSource(source)==noErr else{finish(false,"enable failed");return};added.append(source)
        }
        field.inputContext?.discardMarkedText();field.removeFromSuperview();field=Field(frame:NSRect(x:20,y:20,width:640,height:230));field.isRichText=false;window.contentView!.addSubview(field)
        window.edges=[];field.string="앞🙂뒤";field.setSelectedRange(NSRange(location:3,length:0));window.makeFirstResponder(field)
        guard TISSelectInputSource(source)==noErr else{finish(false,"source select failed");return}
        if physical {
            let names:[UInt16:String]=[15:"r",40:"k",1:"s",4:"h",17:"t",3:"f",44:"/",29:"0",41:";",20:"3",18:"1",5:"g",0:"a",45:"n",14:"e",34:"i",49:"Space"]
            let keys=item.keys.map{($0.1 ? "Shift+":"")+(names[$0.0] ?? "?")}.joined(separator:" → ")
            outside.title="준비 중 · 잠시 후 표시되는 키를 입력하세요"
            physicalHint="\(index)/\(samples.count)  누를 키: \(keys)  → \(item.joined)"
            let layoutNames=[KoreanKeyboardLayout.twoSetID:"두벌식",KoreanKeyboardLayout.threeSetID:"세벌식",KoreanKeyboardLayout.threeSet390ID:"세벌식 390",KoreanKeyboardLayout.gongjinID:"공진청 로마자",KoreanKeyboardLayout.hncID:"한컴 로마자"]
            window.title="\(layoutNames[item.sourceID]!) · \(normal ? "정상 입력 확인":"분리 보정 확인")"
            field.committed={ [weak self] in guard let self else{return};self.field.committed=nil;self.later(0.4){self.verify(item)} }
        }
        later(0.3){
            self.field.hiddenRange = !self.normal;self.window.makeFirstResponder(self.normal ? self.field:self.outside)
            self.later(0.4){self.type(item.keys,index:0){self.verify(item)}}
        }
    }
    func type(_ keys:[(UInt16,Bool)],index:Int,done:@escaping ()->Void){
        if physical{outside.title=physicalHint;progress("waiting_for_physical_keys");return}
        guard NSApp.isActive,window.isKeyWindow else{finish(false,"fixture focus lost");return}
        progress("send_requested")
        let root=resultURL.deletingLastPathComponent(),completed=root.appendingPathComponent("keys-done.json")
        try? FileManager.default.removeItem(at:completed)
        let request:[String:Any]=["pid":Int(getpid()),"keys":keys.map{["code":Int($0.0),"shift":$0.1]}]
        try! JSONSerialization.data(withJSONObject:request).write(to:root.appendingPathComponent("keys-request.json"),options:.atomic)
        let began=ProcessInfo.processInfo.systemUptime
        func poll(){
            if let data=try? Data(contentsOf:completed),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
                guard value["passed"] as? Bool == true else{self.finish(false,"sender stopped: \(value)");return}
                self.later(0.35,done);return
            }
            guard ProcessInfo.processInfo.systemUptime-began<5 else{self.finish(false,"sender timeout; input not verified");return}
            self.later(0.02,poll)
        }
        poll()
    }
    func verify(_ item:LateLayoutCase){
        progress("verify")
        if physical,!normal,ProcessInfo.processInfo.systemUptime-firstAt>=2 {
            // The production history expires at two seconds. Let the user retry
            // slowly prepared input without counting it as a product failure.
            index-=1;later(0.5){self.next()};return
        }
        let expected="앞🙂"+item.joined+"뒤",caret=NSRange(location:3+item.joined.utf16.count,length:0)
        // Human releases may overlap later downs and cross responder changes.
        // Audit the whole window, with prescribed downs and balanced releases.
        let edges=item.keys.flatMap{[($0.0,NSEvent.EventType.keyDown),($0.0,NSEvent.EventType.keyUp)]}
        var pressed=Set<UInt16>(),balanced=true
        for (code,type) in window.edges {
            if type == .keyDown {if !pressed.insert(code).inserted{balanced=false}}
            else if pressed.remove(code)==nil{balanced=false}
        }
        let ordered=window.edges.count==edges.count && balanced && pressed.isEmpty && window.edges.filter{$0.1 == .keyDown}.map{$0.0}==item.keys.map{$0.0}
        if physical,!ordered {
            progress("retry_incomplete_or_wrong_keys");index-=1;later(0.5){self.next()};return
        }
        let ok=field.string==expected && field.selectedRange()==caret && receivedFirst==(normal ? 0:1) && ordered && InputSourceAccess.currentID()==item.sourceID
        rows.append(["source":item.sourceID,"case":item.name,"pass":ok,"text":field.string,"expected":expected,"caret":field.selectedRange().location,"selectionLength":field.selectedRange().length,"originalEdgeOrder":ordered,"receivedEdges":window.edges.count,"fieldEdges":field.edges.count,"expectedEdges":edges.count])
        print("\(ok ? "PASS":"FAIL") actual AX",item.sourceID,item.name,field.string);fflush(stdout)
        guard ok else{finish(false,"first failing case: \(item.sourceID) \(item.name)");return}
        later(0.15){self.next()}
    }
}
// LaunchServices/CUA reopening an exited fixture supplies no test arguments.
// An unconfigured launch must never trap or alter input sources.
guard CommandLine.arguments.count>=2,!CommandLine.arguments[1].hasPrefix("--") else{exit(0)}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let fixture=Fixture();app.delegate=fixture;app.run()
