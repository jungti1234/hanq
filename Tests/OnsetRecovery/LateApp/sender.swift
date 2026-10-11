import AppKit
import Carbon
let root=URL(fileURLWithPath:CommandLine.arguments[1])
print("sender post permission",CGPreflightPostEventAccess());fflush(stdout)
guard CGPreflightPostEventAccess() else{exit(2)}
let began=ProcessInfo.processInfo.systemUptime
while ProcessInfo.processInfo.systemUptime-began<120 {
    let request=root.appendingPathComponent("keys-request.json")
    if let data=try? Data(contentsOf:request),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let pid=value["pid"] as? Int,let keys=value["keys"] as? [[String:Any]]{
        try? FileManager.default.removeItem(at:request);var passed=true
        let source=CGEventSource(stateID:.privateState)!
        for item in keys {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier==Int32(pid),!IsSecureEventInputEnabled(),let code=item["code"] as? Int,let shift=item["shift"] as? Bool else{passed=false;break}
            if shift{let e=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:true)!;e.type = .flagsChanged;e.flags = .maskShift;e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.008)}
            for down in [true,false]{
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier==Int32(pid) else{passed=false;break}
                let e=CGEvent(keyboardEventSource:source,virtualKey:UInt16(code),keyDown:down)!;e.flags=shift ? .maskShift:[];e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.008)
            }
            if shift{let e=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:false)!;e.type = .flagsChanged;e.flags=[];e.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.008)}
            if !passed{break};Thread.sleep(forTimeInterval:0.03)
        }
        try! JSONSerialization.data(withJSONObject:["passed":passed]).write(to:root.appendingPathComponent("keys-done.json"),options:.atomic)
    }
    Thread.sleep(forTimeInterval:0.01)
}
