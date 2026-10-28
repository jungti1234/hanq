import AppKit
import Carbon
@main struct LateAppKeySender {
    static func main() {
        guard CommandLine.arguments.count==2 || (CommandLine.arguments.count==3 && ["--pause-after-letter","--prefocus-fixture"].contains(CommandLine.arguments[2])) else{exit(2)}
        let pauseForTest=CommandLine.arguments.last=="--pause-after-letter"
        let expectedBundle=CommandLine.arguments.last=="--prefocus-fixture" ? "taek.in.hanq.prefocus-fixture":"taek.in.hanq.late-layout-fixture"
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let mirror=KeyboardStateMirror.shared
        guard CGPreflightPostEventAccess(),mirror.start() else{exit(2)}
        let cancelLock=NSLock();var cancelled=false
        func cancel()->Bool{cancelLock.lock();defer{cancelLock.unlock()};return cancelled}
        var signals:[DispatchSourceSignal]=[]
        for number:Int32 in [SIGINT,SIGTERM] {
            signal(number,SIG_IGN)
            let observer=DispatchSource.makeSignalSource(signal:number,queue:.global())
            observer.setEventHandler{cancelLock.lock();cancelled=true;cancelLock.unlock()}
            observer.resume();signals.append(observer)
        }
        let shiftFlags=CGEventFlags(rawValue:CGEventFlags.maskShift.rawValue|0x02)
        func frontPID()->pid_t? {
            // This command-line sender blocks between edges. NSWorkspace's
            // activation cache can remain stale until its run loop is serviced.
            CFRunLoopRunInMode(.defaultMode,0.001,false)
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        // Bind one owned process for this sender's lifetime. Repeated Launch
        // Services lookup can transiently return nil while the app is alive.
        // Never rebind a sender to another request PID or a replacement process.
        var receiver:NSRunningApplication?
        func run(_ pid:pid_t,_ keys:[[String:Any]],click:[String:Any]?=nil)->Bool {
            CFRunLoopRunInMode(.defaultMode,0.001,false)
            if receiver==nil{receiver=NSRunningApplication(processIdentifier:pid)}
            guard let app=receiver,app.processIdentifier==pid else{print("owned sender stopped: missing_target");fflush(stdout);return false}
            guard app.bundleIdentifier==expectedBundle,!app.isTerminated else{
                print("owned sender stopped: target_identity",app.bundleIdentifier ?? "unavailable",app.isTerminated);fflush(stdout);return false
            }
            let source=CGEventSource(stateID:.privateState)!
            var posted=PostedKeys()
            var restorePoint:CGPoint?
            defer {
                let releases=posted.takeReleases()
                for (index,key) in releases.enumerated() {
                    guard let event=CGEvent(keyboardEventSource:source,virtualKey:key.code,keyDown:false) else{continue}
                    if key.modifier{event.type = .flagsChanged}
                    event.flags=releases.dropFirst(index+1).contains(where:{$0.code==56}) ? shiftFlags:[]
                    // Only the owned receiver gets the release. The final-boundary
                    // copy updates Quartz without delivering input to a new app.
                    mirror.releasePosted(event,to:app.isTerminated ? nil:pid)
                    Thread.sleep(forTimeInterval:0.008)
                }
                if !releases.isEmpty {print("released owned test presses",releases.count);fflush(stdout);Thread.sleep(forTimeInterval:0.05)}
                if let restorePoint,frontPID()==pid{CGWarpMouseCursorPosition(restorePoint)}
            }
            func edge(_ code:UInt16,_ down:Bool,_ shift:Bool,_ modifier:Bool=false)->Bool {
                func safe(_ value:Bool,_ reason:String)->Bool {
                    if !value{print("owned sender stopped:",reason);fflush(stdout)}
                    return value
                }
                guard safe(!cancel(),"cancelled"),safe(mirror.ready,"state_boundary_unavailable"),safe(!app.isTerminated,"target_terminated"),
                      safe(frontPID()==pid,"focus_changed"),
                      safe(!IsSecureEventInputEnabled(),"secure_input"),safe(CGPreflightPostEventAccess(),"post_permission"),
                      let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return false}
                if modifier{event.type = .flagsChanged};event.flags=shift ? shiftFlags:[]
                if down{posted.record(code,down:true,modifier:modifier)}
                event.post(tap:.cghidEventTap)
                if !down{posted.record(code,down:false)}
                if pauseForTest,down,!modifier {
                    let until=ProcessInfo.processInfo.systemUptime+2
                    while !cancel(),!FileManager.default.fileExists(atPath:root.appendingPathComponent("continue").path),ProcessInfo.processInfo.systemUptime<until {Thread.sleep(forTimeInterval:0.002)}
                    if cancel() || !FileManager.default.fileExists(atPath:root.appendingPathComponent("continue").path){return false}
                }
                Thread.sleep(forTimeInterval:0.008);return true
            }
            if let click {
                guard expectedBundle=="taek.in.hanq.prefocus-fixture",frontPID()==pid,
                      let x=click["x"] as? Double,let y=click["y"] as? Double,
                      let delay=click["delay"] as? Double,x.isFinite,y.isFinite,(0.015...0.3).contains(delay),
                      let windows=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] else{return false}
                let point=CGPoint(x:x,y:y)
                let inside=windows.contains{info in
                    guard info[kCGWindowOwnerPID as String] as? Int==Int(pid),info[kCGWindowLayer as String] as? Int==0,
                          let bounds=info[kCGWindowBounds as String] as? [String:Any] else{return false}
                    var rect=CGRect.zero
                    return CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary,&rect) && rect.contains(point)
                }
                guard inside,!cancel(),!IsSecureEventInputEnabled(),CGPreflightPostEventAccess(),
                      let down=CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
                      let up=CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else{return false}
                restorePoint=CGEvent(source:nil)?.location
                down.post(tap:.cghidEventTap)
                // Complete the pair to the same owned receiver if focus changes.
                if frontPID()==pid{up.post(tap:.cghidEventTap)}else{up.postToPid(pid);return false}
                Thread.sleep(forTimeInterval:delay)
            }
            for item in keys {
                guard let code=item["code"] as? Int,(0...127).contains(code),let shift=item["shift"] as? Bool else{print("owned sender stopped: invalid_test_key");fflush(stdout);return false}
                // Owned rollover tests may split only a plain Space pair.
                // PostedKeys still releases it to the bound receiver on abort.
                if let action=item["edge"] as? String {
                    guard code==49,!shift,action=="down" || action=="up",
                          edge(UInt16(code),action=="down",false) else{return false}
                    Thread.sleep(forTimeInterval:(item["gap"] as? Double) ?? 0.03)
                    continue
                }
                if shift && !edge(56,true,true,true){return false}
                guard edge(UInt16(code),true,shift),edge(UInt16(code),false,shift) else{print("owned sender stopped: invalid_test_key");fflush(stdout);return false}
                if shift && !edge(56,false,false,true){return false}
                Thread.sleep(forTimeInterval:(item["gap"] as? Double) ?? 0.03)
            }
            return true
        }
        let began=ProcessInfo.processInfo.systemUptime
        while !cancel(),ProcessInfo.processInfo.systemUptime-began<240 {
            let request=root.appendingPathComponent("keys-request.json")
            if let data=try? Data(contentsOf:request),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let pid=value["pid"] as? Int,let keys=value["keys"] as? [[String:Any]] {
                try? FileManager.default.removeItem(at:request)
                let passed=run(Int32(pid),keys,click:value["click"] as? [String:Any])
                try! JSONSerialization.data(withJSONObject:["passed":passed]).write(to:root.appendingPathComponent("keys-done.json"),options:.atomic)
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        mirror.stop();Thread.sleep(forTimeInterval:0.05)
    }
}
