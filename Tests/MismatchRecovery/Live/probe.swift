import AppKit
import Carbon
@main struct FirstKeyProbe {
    static func main(){exit(run())}
    static func run()->Int32 {
        let burst=CommandLine.arguments.count==3 && CommandLine.arguments[2]=="--three-keys"
        guard CommandLine.arguments.count==2 || burst,CGPreflightPostEventAccess() else{return 2}
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/hanq-source-live.") else{return 2}
        let mirror=KeyboardStateMirror.shared
        guard mirror.start() else{return 2}
        defer{mirror.stop()}
        var cancelled=false
        let lock=NSLock()
        func stopped()->Bool{lock.lock();defer{lock.unlock()};return cancelled}
        var signals:[DispatchSourceSignal]=[]
        for number:Int32 in [SIGINT,SIGTERM]{
            signal(number,SIG_IGN);let s=DispatchSource.makeSignalSource(signal:number,queue:.global());s.setEventHandler{lock.lock();cancelled=true;lock.unlock()};s.resume();signals.append(s)
        }
        func front()->NSRunningApplication?{CFRunLoopRunInMode(.defaultMode,0.001,false);return NSWorkspace.shared.frontmostApplication}
        var receiver:NSRunningApplication?
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while !stopped(),ProcessInfo.processInfo.systemUptime<deadline {
            if let app=front(),app.bundleIdentifier=="taek.in.hanq.source-interaction-fixture"{receiver=app;break}
            CFRunLoopRunInMode(.defaultMode,0.01,false)
        }
        guard let app=receiver,app.executableURL?.standardizedFileURL == root.appendingPathComponent("SourceInteractionFixture.app/Contents/MacOS/SourceInteractionFixture").standardizedFileURL,let data=try? Data(contentsOf:root.appendingPathComponent("progress.json")),let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any],row["ready"] as? Bool == true,row["monitorReady"] as? Bool == true,row["firstResponderIsField"] as? Bool == true,row["pid"] as? Int == Int(app.processIdentifier),let sourceID=row["originalSource"] as? String else{print("FAIL: owned editor not ready");return 2}
        let first:CGKeyCode
        switch sourceID {
        case "com.apple.inputmethod.Korean.2SetKorean":first=15
        case "com.apple.inputmethod.Korean.3SetKorean","com.apple.inputmethod.Korean.390Sebulshik":first=40
        case "com.apple.inputmethod.Korean.GongjinCheongRomaja","com.apple.inputmethod.Korean.HNCRomaja":first=5
        default:return 2
        }
        guard !burst || first==15,let source=CGEventSource(stateID:.privateState) else{return 2}
        guard (row["eventDetails"] as? [[String:Any]])?.isEmpty == true else{return 2}
        var held=false
        var heldCode=first
        defer{if held,let e=CGEvent(keyboardEventSource:source,virtualKey:heldCode,keyDown:false){e.flags=[];mirror.releasePosted(e,to:app.isTerminated ? nil:app.processIdentifier);Thread.sleep(forTimeInterval:0.05)}}
        for code:CGKeyCode in burst ? [15,40,1]:[first] {
        for down in [true,false] {
            guard !stopped(),mirror.ready,CGEventSource.flagsState(.hidSystemState).intersection([.maskShift,.maskCommand,.maskControl,.maskAlternate]).isEmpty,front()?.processIdentifier==app.processIdentifier,!app.isTerminated,!IsSecureEventInputEnabled(),CGPreflightPostEventAccess(),let e=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return 1}
            e.flags=[];if down{held=true;heldCode=code}
            e.post(tap:.cghidEventTap)
            if !down{held=false}
            Thread.sleep(forTimeInterval:0.008)
        }
        if burst{Thread.sleep(forTimeInterval:0.12)}
        }
        print("POSTED: fixed owned-editor trial, no physical/Caps pass claimed");return 0
    }
}
