import AppKit
import Carbon

// Owned synthetic editor only; no global event posting or user text reads.
final class Fixture:NSObject,NSApplicationDelegate {
    let output=URL(fileURLWithPath:CommandLine.arguments[1])
    var original:TISInputSource?,prior:NSRunningApplication?,timer:Timer?,window:NSWindow!
    var views:[NSTextView]=[],stage=0,started=0.0
    func sourceID(_ source:TISInputSource?)->String? {
        guard let source,let property=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return nil}
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }
    let samples=["SYNTHETIC_HINT_252\n","\n","SYNTHETIC_BODY_252","SYNTHETIC_OTHER_FIELD_252"]
    func applicationDidFinishLaunching(_ note:Notification){
        original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue();prior=NSWorkspace.shared.frontmostApplication
        window=NSWindow(contentRect:NSRect(x:240,y:240,width:500,height:140),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="HanQ metadata verification"
        let view=NSTextView(frame:NSRect(x:0,y:0,width:500,height:140));view.isRichText=false;view.setAccessibilityLabel("SYNTHETIC_HINT_252")
        views=[view];window.contentView=view;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
        var selected=false
        if let sources=TISCreateInputSourceList([kTISPropertyInputSourceID as String:"com.apple.inputmethod.Korean.2SetKorean"] as CFDictionary,false)?.takeRetainedValue() as? [TISInputSource],let source=sources.first{selected=TISSelectInputSource(source)==noErr}
        guard selected,sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())=="com.apple.inputmethod.Korean.2SetKorean" else{finish(false);return}
        started=ProcessInfo.processInfo.systemUptime;apply()
        timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){[weak self] _ in self?.tick()}
    }
    func apply(){
        if stage==3 {
            let view=NSTextView(frame:NSRect(x:0,y:0,width:500,height:140));view.isRichText=false;views.append(view)
            window.contentView=view;window.makeFirstResponder(view)
        }
        views.last!.string=samples[stage];views.last!.setSelectedRange(NSRange(location:samples[stage].utf16.count,length:0))
    }
    func tick(){
        guard NSApp.isActive,window.firstResponder === views.last! else{finish(false);return}
        if ProcessInfo.processInfo.systemUptime-started>=Double(stage+1)*0.8 {
            stage+=1
            if stage==samples.count{finish(true)}else{apply()}
        }
    }
    func finish(_ passed:Bool){
        timer?.invalidate();let restoredSelection=original.map{TISSelectInputSource($0)==noErr} ?? false
        let end=Date().addingTimeInterval(1)
        while sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()) != sourceID(original),Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        let restored=restoredSelection && sourceID(original) != nil && sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())==sourceID(original)
        let object:[String:Any]=["passed":passed && restored,"stages":stage,"syntheticLengths":samples.map{$0.utf16.count},"originalSourceRestored":restored,"postedKeys":0]
        try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:output)
        prior?.activate(options:[]);exit(passed && restored ? 0:1)
    }
}
let app=NSApplication.shared,fixture=Fixture();app.delegate=fixture;app.run()
