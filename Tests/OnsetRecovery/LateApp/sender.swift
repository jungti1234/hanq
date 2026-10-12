import AppKit
import Carbon
@main struct LateAppKeySender {
    static func main() {
        guard CommandLine.arguments.count==2 || (CommandLine.arguments.count==3 && CommandLine.arguments[2]=="--pause-after-letter") else{exit(2)}
        let pauseForTest=CommandLine.arguments.count==3
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
        func run(_ pid:pid_t,_ keys:[[String:Any]])->Bool {
            guard let app=NSRunningApplication(processIdentifier:pid),app.bundleIdentifier=="taek.in.hanq.late-layout-fixture",!app.isTerminated else{return false}
            let source=CGEventSource(stateID:.privateState)!
            var posted=PostedKeys()
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
            }
            func edge(_ code:UInt16,_ down:Bool,_ shift:Bool,_ modifier:Bool=false)->Bool {
                guard !cancel(),mirror.ready,!app.isTerminated,
                      frontPID()==pid,
                      !IsSecureEventInputEnabled(),CGPreflightPostEventAccess(),
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
            for item in keys {
                guard let code=item["code"] as? Int,(0...127).contains(code),let shift=item["shift"] as? Bool else{return false}
                if shift && !edge(56,true,true,true){return false}
                guard edge(UInt16(code),true,shift),edge(UInt16(code),false,shift) else{return false}
                if shift && !edge(56,false,false,true){return false}
                Thread.sleep(forTimeInterval:0.03)
            }
            return true
        }
        let began=ProcessInfo.processInfo.systemUptime
        while !cancel(),ProcessInfo.processInfo.systemUptime-began<120 {
            let request=root.appendingPathComponent("keys-request.json")
            if let data=try? Data(contentsOf:request),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let pid=value["pid"] as? Int,let keys=value["keys"] as? [[String:Any]] {
                try? FileManager.default.removeItem(at:request)
                let passed=run(Int32(pid),keys)
                try! JSONSerialization.data(withJSONObject:["passed":passed]).write(to:root.appendingPathComponent("keys-done.json"),options:.atomic)
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        mirror.stop();Thread.sleep(forTimeInterval:0.05)
    }
}
