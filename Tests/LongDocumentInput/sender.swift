import AppKit
import Carbon

// Guarded fixed-case HID sender. A request can bind only the one owned fixture
// process. Cancel/focus/secure-input failures release only this sender's keys.
@main struct LongSender {
    static func main() {
        guard CommandLine.arguments.count==2 else{exit(2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),mirror=KeyboardStateMirror.shared
        guard CGPreflightPostEventAccess(),mirror.start() else{exit(2)}
        let source=CGEventSource(stateID:.privateState)!
        let productRecord=(try? JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("product.json"))) as? [String:Any])
        let product:LongProductIdentity? = {
            guard let pid=productRecord?["main_pid"] as? Int,let app=productRecord?["app"] as? [String:Any],let path=app["path"] as? String else{return nil}
            return LongProductIdentity(pid:pid,path:path+"/Contents/MacOS/HanQ")
        }()
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("product.json").path),product==nil{exit(2)}
        var receiver:NSRunningApplication?,signals:[DispatchSourceSignal]=[]
        let lock=NSLock();var stopped=false
        func cancelled()->Bool {lock.lock();defer{lock.unlock()};return stopped}
        for number in [SIGINT,SIGTERM] {
            signal(number,SIG_IGN);let s=DispatchSource.makeSignalSource(signal:number,queue:.global())
            s.setEventHandler{lock.lock();stopped=true;lock.unlock()};s.resume();signals.append(s)
        }
        func safe(_ app:NSRunningApplication)->Bool {
            CFRunLoopRunInMode(.defaultMode,0.00001,false)
            let productAlive=product?.alive ?? true
            let checks=["notCancelled":!cancelled(),"noQuit":!FileManager.default.fileExists(atPath:root.appendingPathComponent("quit").path),"productAlive":productAlive,"mirrorReady":mirror.ready,"receiverAlive":!app.isTerminated,"frontMatches":NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier,"keyboardFocusMatches":ownedInputFocusMatches(app.processIdentifier),"secureInputOff":!IsSecureEventInputEnabled(),"postAllowed":CGPreflightPostEventAccess()]
            if checks.values.contains(false),let data=try? JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]){try? data.write(to:root.appendingPathComponent("sender-guard.json"),options:.atomic)}
            return checks.values.allSatisfy{$0}
        }
        func run(_ request:[String:Any])->[String:Any] {
            guard let pid=request["pid"] as? Int,let keys=request["keys"] as? [[String:Any]],let gap=request["gap"] as? Double,(0.004...0.1).contains(gap),keys.count<=1500 else{return ["passed":false,"reason":"invalid_request"]}
            if receiver==nil{receiver=NSRunningApplication(processIdentifier:pid_t(pid))}
            guard let app=receiver,app.processIdentifier==pid_t(pid),app.bundleIdentifier=="taek.in.hanq.long-document-fixture" else{return ["passed":false,"reason":"owned_identity"]}
            var held=PostedKeys(),times:[Double]=[],downCount=0,upCount=0,lastPostedDown=0.0
            defer {
                for key in held.takeReleases() {
                    if let e=CGEvent(keyboardEventSource:source,virtualKey:key.code,keyDown:false){if key.modifier{e.type = .flagsChanged};e.flags=[];mirror.releasePosted(e,to:app.isTerminated ? nil:app.processIdentifier)}
                }
            }
            func edge(_ code:Int,_ down:Bool,_ flags:CGEventFlags,_ modifier:Bool=false)->Bool {
                guard safe(app),(0...127).contains(code),let e=CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(code),keyDown:down) else{return false}
                if modifier{e.type = .flagsChanged};e.flags=flags
                // CGEvent defaults keyCode 51 to U+0008. Match real macOS
                // backward delete (U+007F), as the existing native probes do.
                if code==51 {var character:UniChar=0x7f;e.keyboardSetUnicodeString(stringLength:1,unicodeString:&character)}
                if down{held.record(UInt16(code),down:true,modifier:modifier)}
                let postedAt=ProcessInfo.processInfo.systemUptime
                e.post(tap:.cghidEventTap)
                if down{lastPostedDown=postedAt}
                if !down{held.record(UInt16(code),down:false)}
                if !modifier{if down{downCount+=1}else{upCount+=1}}
                return true
            }
            var next=ProcessInfo.processInfo.systemUptime
            for key in keys {
                guard let code=key["code"] as? Int,let shift=key["shift"] as? Bool,let command=key["command"] as? Bool,let rc=key["rightCommand"] as? Bool,let ro=key["rightOption"] as? Bool else{return ["passed":false,"reason":"invalid_key"]}
                let now=ProcessInfo.processInfo.systemUptime;if now<next{Thread.sleep(forTimeInterval:next-now)}
                var flags:CGEventFlags=[]
                if shift{flags=CGEventFlags(rawValue:CGEventFlags.maskShift.rawValue|0x02);guard edge(56,true,flags,true) else{return ["passed":false,"reason":"shift_guard"]}}
                if command{flags.formUnion(CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x08));guard edge(55,true,flags,true) else{return ["passed":false,"reason":"command_guard"]}}
                if rc{flags=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)}
                if ro{flags=CGEventFlags(rawValue:CGEventFlags.maskAlternate.rawValue|0x40)}
                guard edge(code,true,flags,rc || ro) else{return ["passed":false,"reason":"down_guard"]}
                times.append(lastPostedDown)
                Thread.sleep(forTimeInterval:0.002)
                guard edge(code,false,(rc || ro) ? []:flags,rc || ro) else{return ["passed":false,"reason":"up_guard"]}
                if command{guard edge(55,false,shift ? CGEventFlags(rawValue:CGEventFlags.maskShift.rawValue|0x02):[],true) else{return ["passed":false,"reason":"command_release"]}}
                if shift{guard edge(56,false,[],true) else{return ["passed":false,"reason":"shift_release"]}}
                next=max(next+(key["gap"] as? Double ?? gap),ProcessInfo.processInfo.systemUptime)
            }
            let intervals=zip(times,times.dropFirst()).map{($1-$0)*1000}.sorted()
            func percentile(_ n:Double)->Double {intervals.isEmpty ? 0:intervals[min(intervals.count-1,Int(Double(intervals.count-1)*n))]}
            let maximumGap:Double=intervals.last ?? 0.0
            return ["passed":true,"plannedKeys":keys.count,"postedDowns":downCount,"postedUps":upCount,"nominalGapMs":gap*1000,"downIntervalsMs":intervals,"downSequenceUptime":times,"p50GapMs":percentile(0.5),"p95GapMs":percentile(0.95),"maxGapMs":maximumGap,"finishedUptime":ProcessInfo.processInfo.systemUptime]
        }
        let began=ProcessInfo.processInfo.systemUptime
        while !cancelled(),!FileManager.default.fileExists(atPath:root.appendingPathComponent("quit").path),ProcessInfo.processInfo.systemUptime-began<1200 {
            let request=root.appendingPathComponent("request.json")
            if let data=try? Data(contentsOf:request),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                try? FileManager.default.removeItem(at:request)
                let result=run(value)
                guard JSONSerialization.isValidJSONObject(result) else{exit(3)}
                if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]){try? data.write(to:root.appendingPathComponent("done.json"),options:.atomic)}
            }
            Thread.sleep(forTimeInterval:0.002)
        }
        mirror.stop();Thread.sleep(forTimeInterval:0.05)
    }
}
