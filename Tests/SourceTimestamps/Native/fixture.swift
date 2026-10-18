import AppKit
import Carbon

// This editor deliberately emits ASCII for original test letters after the
// first Korean switch. Product replay goes through the real input method.
@objc(HanQTimestampApplication) final class TestApplication:NSApplication {
    var fixture:Fixture!
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown,fixture?.armed == true {
            let tag=UInt64(bitPattern:event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)
            if tag>>32 == 0x48414E51 {fixture.armed=false}
            else if let letter=[UInt16(2):"d",UInt16(40):"k"][event.keyCode] {
                fixture.view.insertText(letter,replacementRange:fixture.view.selectedRange());fixture.forced+=1;return
            }
        }
        super.sendEvent(event)
    }
}
final class Fixture:NSObject,NSApplicationDelegate {
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    var view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:180))
    var window:NSWindow!
    var oldViews:[NSTextView]=[]
    var original:TISInputSource?
    var prior:NSRunningApplication?
    var timer:Timer?
    var stage=0,caseIndex=0,forced=0,armed=false
    var deadline=0.0,settle=0.0
    var outcomes:[[String:Any]]=[]
    let prefix="sample "
    func write(_ name:String,_ object:[String:Any]) {try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent(name),options:.atomic)}
    func source()->String {
        guard let s=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),let p=TISGetInputSourceProperty(s,kTISPropertyInputSourceID) else{return ""}
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    func select(_ id:String)->Bool {
        guard let a=TISCreateInputSourceList([kTISPropertyInputSourceID as String:id] as CFDictionary,false)?.takeRetainedValue() as? [TISInputSource],let s=a.first else{return false}
        return TISSelectInputSource(s)==noErr
    }
    func applicationDidFinishLaunching(_ note:Notification) {
        prior=NSWorkspace.shared.frontmostApplication
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        window=NSWindow(contentRect:NSRect(x:180,y:180,width:640,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="HanQ source timestamp verification";view.isRichText=false
        window.contentView=view;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
        timer=Timer.scheduledTimer(withTimeInterval:0.01,repeats:true){[weak self] _ in self?.tick()}
        write("ready.json",["pid":getpid()])
        startCase()
    }
    func request(_ keys:[[String:Any]]) {
        try? FileManager.default.removeItem(at:root.appendingPathComponent("done.json"))
        write("request.json",["pid":getpid(),"keys":keys]);deadline=ProcessInfo.processInfo.systemUptime+8
    }
    func startCase() {
        guard caseIndex<2 else{finish(true,"normal and forced Roman mismatch after actual right Command both passed");return}
        armed=false;forced=0;view.inputContext?.discardMarkedText()
        if caseIndex>0 {
            oldViews.append(view);view=NSTextView(frame:NSRect(x:0,y:0,width:640,height:180));view.isRichText=false
            window.contentView=view;window.makeFirstResponder(view)
        }
        view.string="";view.setSelectedRange(NSRange(location:0,length:0))
        guard select("com.apple.keylayout.ABC") else{finish(false,"ABC unavailable");return}
        stage=0;settle=ProcessInfo.processInfo.systemUptime+0.25;deadline=settle+8
    }
    func tick() {
        let now=ProcessInfo.processInfo.systemUptime
        guard now<deadline else{finish(false,"stage timeout");return}
        guard NSApp.isActive,window.firstResponder === view else{finish(false,"owned fixture lost focus");return}
        if stage==0,now>=settle {
            stage=1;request([1,0,46,35,37,14,49].map{["code":$0,"rightCommand":false,"gap":0.04]});return
        }
        let done=root.appendingPathComponent("done.json")
        guard let d=try? Data(contentsOf:done),let result=try? JSONSerialization.jsonObject(with:d) as? [String:Any] else{return}
        guard result["passed"] as? Bool==true else{finish(false,"sender stopped safely");return}
        if stage==1 {
            guard view.string==prefix,view.selectedRange()==NSRange(location:prefix.utf16.count,length:0) else{finish(false,"English prefix differed");return}
            try? FileManager.default.removeItem(at:done);stage=2
            request([["code":54,"rightCommand":true,"gap":0.3]]);return
        }
        if stage==2 {
            guard source()=="com.apple.inputmethod.Korean.2SetKorean" else{finish(false,"right Command did not select two-set");return}
            try? FileManager.default.removeItem(at:done);armed=caseIndex==1;stage=3
            request([["code":2,"rightCommand":false,"gap":0.15],["code":40,"rightCommand":false,"gap":0.3]]);return
        }
        if stage==3 {
            let expected=prefix+"아"
            if view.string==expected,(caseIndex==0 || forced>0),view.selectedRange()==NSRange(location:expected.utf16.count,length:0),source()=="com.apple.inputmethod.Korean.2SetKorean" {
                outcomes.append(["case":caseIndex==0 ? "normal":"forced_roman","expected":expected,"actual":view.string,"caret":view.selectedRange().location,"forcedOriginalLetters":forced,"matched":true]);caseIndex+=1
                try? FileManager.default.removeItem(at:done);startCase()
            }
        }
    }
    func finish(_ passed:Bool,_ reason:String) {
        timer?.invalidate();armed=false
        let finalSource=source()
        var restored=false,restoreStatus:OSStatus = -1
        if let original,let property=TISGetInputSourceProperty(original,kTISPropertyInputSourceID) {
            let originalID=Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
            restoreStatus=TISSelectInputSource(original)
            let deadline=Date().addingTimeInterval(1)
            while source() != originalID,Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            restored=restoreStatus==noErr && source()==originalID
        }
        let verified=passed && restored
        write("result.json",["passed":verified,"reason":reason,"cases":outcomes,"stage":stage,"caseIndex":caseIndex,"actualSyntheticText":view.string,"caret":view.selectedRange().location,"forcedOriginalLetters":forced,"source":finalSource,"originalSourceRestored":restored,"restoreStatus":restoreStatus])
        if let prior,!prior.isTerminated{prior.activate(options:[])}
        print(verified ? "PASS: \(reason)":"FAIL: \(reason); sourceRestored=\(restored)");exit(verified ? 0:1)
    }
}
let app=TestApplication.shared as! TestApplication
let fixture=Fixture();app.fixture=fixture;app.delegate=fixture;app.run()
