import AppKit
import Carbon
@main struct Sender {
    static func main() {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),source=CGEventSource(stateID:.privateState)!
        let mirror=KeyboardStateMirror.shared
        guard CGPreflightPostEventAccess(),mirror.start() else{exit(2)}
        var receiver:NSRunningApplication?
        let began=ProcessInfo.processInfo.systemUptime
        func safe(_ app:NSRunningApplication)->Bool {
            CFRunLoopRunInMode(.defaultMode,0.001,false)
            return !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier && !IsSecureEventInputEnabled() && CGPreflightPostEventAccess() && mirror.ready
        }
        while !FileManager.default.fileExists(atPath:root.appendingPathComponent("quit").path),ProcessInfo.processInfo.systemUptime-began<60 {
            let path=root.appendingPathComponent("request.json")
            if let d=try? Data(contentsOf:path),let request=try? JSONSerialization.jsonObject(with:d) as? [String:Any],let pid=request["pid"] as? Int,let keys=request["keys"] as? [[String:Any]] {
                try? FileManager.default.removeItem(at:path)
                if receiver==nil {receiver=NSRunningApplication(processIdentifier:pid_t(pid))}
                var passed=false
                if let app=receiver,app.processIdentifier==pid_t(pid),app.bundleIdentifier=="taek.in.hanq.hanja-command-fixture" {
                    var held=PostedKeys()
                    func run()->Bool {
                        defer {
                            for key in held.takeReleases() {
                                if let e=CGEvent(keyboardEventSource:source,virtualKey:key.code,keyDown:false) {
                                    if key.modifier{e.type = .flagsChanged};e.flags=[];mirror.releasePosted(e,to:app.isTerminated ? nil:app.processIdentifier)
                                }
                            }
                        }
                        for item in keys {
                            guard let raw=item["code"] as? Int,(0...127).contains(raw),let command=item["rightCommand"] as? Bool else{return false}
                            let shift=item["shift"] as? Bool == true,chord=item["commandChord"] as? Bool == true
                            let code=UInt16(raw)
                            for down in [true,false] {
                                guard safe(app),let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:down) else{return false}
                                if command || code==61{event.type = .flagsChanged}
                                event.flags=down ? (command ? CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10):(code==61 ? CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue|0x40):[])):[]
                                if shift{event.flags = .maskShift}
                                if chord{event.flags=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x08)}
                                if down{held.record(code,down:true,modifier:command || code==61)}
                                event.post(tap:.cghidEventTap)
                                if !down{held.record(code,down:false)}
                                Thread.sleep(forTimeInterval:0.02)
                            }
                            Thread.sleep(forTimeInterval:item["gap"] as? Double ?? 0.04)
                        }
                        return true
                    }
                    passed=run()
                }
                do {try JSONSerialization.data(withJSONObject:["passed":passed]).write(to:root.appendingPathComponent("done.json"),options:.atomic)}catch{fputs("sender output failure\n",stderr);exit(1)}
            }
            Thread.sleep(forTimeInterval:0.005)
        }
        mirror.stop();Thread.sleep(forTimeInterval:0.05)
    }
}
