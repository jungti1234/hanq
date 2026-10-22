import AppKit
import Carbon

struct OwnedSourceDecision {
    static func allows(receiverAlive:Bool,pathMatches:Bool,bundleMatches:Bool,frontMatches:Bool,
                       focusMatches:Bool,secureOff:Bool,axTrusted:Bool,age:Double)->Bool {
        receiverAlive && pathMatches && bundleMatches && frontMatches && focusMatches &&
            secureOff && axTrusted && age>=0 && age<=1
    }
    static func withFreshAXRetry(probe:()->(allowed:Bool,transientAX:Bool),pause:()->Void)->Bool {
        let first=probe()
        if first.allowed{return true}
        guard first.transientAX else{return false}
        pause()
        // The second probe must repeat every ownership/safety/age condition.
        // No cached focus proof, extra time allowance or third attempt.
        return probe().allowed
    }
}

#if !OWNED_SOURCE_CONTROL_TESTING
@main enum OwnedInputSourceControl {
    static func main(){
        guard CommandLine.arguments.count==4 else{exit(2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),bundle=CommandLine.arguments[2]
        let executable=URL(fileURLWithPath:CommandLine.arguments[3]).resolvingSymlinksInPath().path
        func write(_ name:String,_ value:[String:Any]){
            if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]){try? data.write(to:root.appendingPathComponent(name),options:.atomic)}
        }
        func id(_ source:TISInputSource)->String {
            guard let pointer=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return ""}
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        let original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),originalID=original.map(id) ?? ""
        var identity:LongProductIdentity?,receiverPID:pid_t?,enabled=Set<String>(),needsCleanup=false,seen=Set<String>()
        var mutations=0,denied=0,focusRetries=0,probeOmitted=0
        var failedProbes:[[String:Any]]=[],failedCommands:[[String:Any]]=[],lastProbe:[String:Any]=[:]
        func allowed(_ pid:pid_t,_ began:Double)->Bool {
            func probe()->(allowed:Bool,transientAX:Bool){
            CFRunLoopRunInMode(.defaultMode,0.00001,false)
            let app=NSRunningApplication(processIdentifier:pid)
            let pathMatches=app?.executableURL?.resolvingSymlinksInPath().path==executable
            if identity==nil,pathMatches,app?.bundleIdentifier==bundle {identity=LongProductIdentity(pid:Int(pid),path:executable);receiverPID=pid}
            let trusted=AXIsProcessTrusted()
            var focusFailure=0,focusStatus:Int32=0
            let focusMatches=ownedInputFocusMatches(pid,onFailure:{focusFailure=$0;focusStatus=$1})
            let receiverMatches=pid==receiverPID,alive=identity?.alive==true,bundleMatches=app?.bundleIdentifier==bundle
            let frontMatches=NSWorkspace.shared.frontmostApplication?.processIdentifier==pid,secureOff = !IsSecureEventInputEnabled()
            let age=ProcessInfo.processInfo.systemUptime-began
            let allOther=receiverMatches && OwnedSourceDecision.allows(receiverAlive:alive,pathMatches:pathMatches,
                bundleMatches:bundleMatches,frontMatches:frontMatches,focusMatches:true,secureOff:secureOff,axTrusted:trusted,age:age)
            let result=allOther && focusMatches
            lastProbe=["receiverMatches":receiverMatches,"receiverAlive":alive,"pathMatches":pathMatches,
                "bundleMatches":bundleMatches,"frontMatches":frontMatches,"focusMatches":focusMatches,
                "secureOff":secureOff,"axTrusted":trusted,"focusFailure":focusFailure,"focusAXStatus":Int(focusStatus),
                "ageMicros":age.isFinite ? Int(max(-1_000_000,min(60_000_000,age*1_000_000))):(-1),"allowed":result]
            if !result {
                if failedProbes.count<16{failedProbes.append(lastProbe)}else{probeOmitted+=1}
            }
            return (result,allOther && focusFailure==5 && focusStatus==AXError.cannotComplete.rawValue)
            }
            return OwnedSourceDecision.withFreshAXRetry(probe:probe,pause:{focusRetries+=1;Thread.sleep(forTimeInterval:0.01)})
        }
        let trusted=AXIsProcessTrusted()
        write("source-control-ready.json",["ax":trusted,"postsKeys":false,"pid":getpid(),"originalSource":originalID])
        guard trusted else{exit(2)}
        let deadline=ProcessInfo.processInfo.systemUptime+1200
        while ProcessInfo.processInfo.systemUptime<deadline {
            if let identity,!identity.alive{break}
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("quit").path),identity==nil{break}
            let path=root.appendingPathComponent("source-control-request.json")
            if let attributes=try? FileManager.default.attributesOfItem(atPath:path.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               (attributes[.ownerAccountID] as? NSNumber)?.uint32Value==getuid(),
               ((attributes[.size] as? NSNumber)?.intValue ?? Int.max)<=8192,
               let data=try? Data(contentsOf:path),let request=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                try? FileManager.default.removeItem(at:path)
                let nonce=request["nonce"] as? String ?? "",operation=request["operation"] as? String ?? ""
                let sourceID=request["sourceID"] as? String ?? "",pid=pid_t(request["pid"] as? Int ?? 0)
                let began=request["uptime"] as? Double ?? 0
                var status:OSStatus = -1
                let eligible=UUID(uuidString:nonce) != nil && !seen.contains(nonce) && seen.count<512
                if eligible && allowed(pid,began) {
                    seen.insert(nonce)
                    if operation=="check" {status=noErr}
                    else if sourceID==originalID || sourceID=="com.apple.keylayout.ABC" || sourceID.hasPrefix("com.apple.inputmethod.Korean.") {
                        let list=TISCreateInputSourceList([kTISPropertyInputSourceID as String:sourceID] as CFDictionary,true)?.takeRetainedValue() as? [TISInputSource]
                        if let source=list?.first,allowed(pid,began) {
                            switch operation {
                            case "select":status=TISSelectInputSource(source)
                            case "enable":
                                let wasEnabled=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled).map{CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue())} ?? true
                                status=TISEnableInputSource(source);if status==noErr && !wasEnabled{enabled.insert(sourceID)}
                            case "disable":
                                if enabled.contains(sourceID){status=TISDisableInputSource(source);if status==noErr{enabled.remove(sourceID)}}
                                else if let pointer=TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled),!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()){status=noErr}
                            default:break
                            }
                            if status==noErr {
                                mutations+=1
                                let current=TISCopyCurrentKeyboardInputSource().map{id($0.takeRetainedValue())} ?? ""
                                needsCleanup=current != originalID || !enabled.isEmpty
                            }
                        }
                    }
                }
                if status != noErr {
                    denied+=1
                    if failedCommands.count<16 {
                        failedCommands.append(["operation":["check":0,"select":1,"enable":2,"disable":3][operation] ?? -1,
                            "status":Int(status),"guardEvaluated":eligible,"guardProbe":eligible ? lastProbe:[:]])
                    }
                }
                write("source-control-response.json",["nonce":nonce,"status":Int(status)])
                write("source-control-status.json",["needsCleanup":needsCleanup,"mutations":mutations,"denied":denied,"postsKeys":false,"originalSource":originalID,"enabledByTest":Array(enabled).sorted(),"focusRetries":focusRetries,"lastGuardProbe":lastProbe,"failedGuardProbes":failedProbes,"guardProbesOmitted":probeOmitted,"failedCommands":failedCommands])
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        write("source-control-ended.json",["needsCleanup":needsCleanup,"mutations":mutations,"denied":denied,"postsKeys":false,"restoredAutomaticallyOutsideOwnedFocus":false])
    }
}
#endif
