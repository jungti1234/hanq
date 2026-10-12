import AppKit
import Carbon
let root=URL(fileURLWithPath:CommandLine.arguments[1]),mirror=KeyboardStateMirror.shared
guard CGPreflightPostEventAccess(),mirror.start() else{exit(2)}
func pump(_ seconds:Double){let end=Date().addingTimeInterval(seconds);while Date()<end{CFRunLoopRunInMode(.defaultMode,0.005,false)}}
func startActor(_ role:String)->NSRunningApplication {
    let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/open")
    task.arguments=["-n",root.appendingPathComponent(role+".app").path,"--args",root.path,role,String(getpid())]
    try! task.run();task.waitUntilExit()
    let ready=root.appendingPathComponent("ready-"+role+".json")
    for _ in 0..<100{if FileManager.default.fileExists(atPath:ready.path){break};pump(0.02)}
    let value=try! JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:Int]
    return NSRunningApplication(processIdentifier:Int32(value["pid"]!))!
}
let appB=startActor("B"),appA=startActor("A")
func activate(_ app:NSRunningApplication){app.activate(options:[]);for _ in 0..<50{if NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier{return};pump(0.005)}}
func state()->[String:Bool]{["HID_L":CGEventSource.keyState(.hidSystemState,key:37),"session_L":CGEventSource.keyState(.combinedSessionState,key:37),"HID_shift":CGEventSource.keyState(.hidSystemState,key:56),"session_shift":CGEventSource.keyState(.combinedSessionState,key:56)]}
func edges(_ role:String)->[[String:Int64]]{(try? JSONDecoder().decode([[String:Int64]].self,from:Data(contentsOf:root.appendingPathComponent("edges-"+role+".json")))) ?? []}
let source=CGEventSource(stateID:.privateState)!,routing=InputDeliveryOrigin()
var rootPresses=PostedKeys()
routing.beginTesting()
var mode="none",switchOnPress=false,interruptPID:pid_t=0,interruptKind=""
var rows:[[String:Any]]=[],failure="",trace:[[String:Any]]=[],ownTags:Set<Int64>=[]
routing.send={e,pid in trace.append(["stage":"direct","pid":pid,"type":e.type.rawValue]);e.postToPid(pid)}
func watched(_ e:CGEvent)->Bool{(e.getIntegerValueField(.eventSourceUnixProcessID)==Int64(getpid()) || ownTags.contains(e.getIntegerValueField(.eventSourceUserData))) && [37,56].contains(e.getIntegerValueField(.keyboardEventKeycode))}
let mask:CGEventMask=[CGEventType.keyDown,.keyUp,.flagsChanged].reduce(0){$0 | (1 << $1.rawValue)}
let hid=CGEvent.tapCreate(tap:.cghidEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,e,_ in
    routing.forgetMirroredRelease(type,e)
    if watched(e) {
        if mode=="route" {trace.append(["stage":"HID","type":type.rawValue,"front":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,"target":e.getIntegerValueField(.eventTargetUnixProcessID),"device":e.getIntegerValueField(CGEventField(rawValue:87)!),"source":e.getIntegerValueField(.eventSourceUnixProcessID),"tag":e.getIntegerValueField(.eventSourceUserData)])}
        if mode=="HID" {return mirror.preserve(type,e){nil}}
        if mode=="route" {let result=mirror.preserve(type,e){routing.receive(type,e)};if InputDeliveryOrigin.isMarker(e.getIntegerValueField(.eventSourceUserData)){ownTags.insert(e.getIntegerValueField(.eventSourceUserData))};return result}
    }
    return Unmanaged.passUnretained(e)
},userInfo:nil)!
let session=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{_,type,e,_ in
    if watched(e) {
        if mode=="session" {return mirror.preserve(type,e){nil}}
        if mode=="route" {
            return mirror.preserve(type,e){
                let origin=routing.take(type,e)
                trace.append(["stage":"session","type":type.rawValue,"origin":origin?.pid ?? -1,"front":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,"tag":e.getIntegerValueField(.eventSourceUserData),"device":e.getIntegerValueField(CGEventField(rawValue:87)!),"repeat":e.getIntegerValueField(.keyboardEventAutorepeat)])
                if type == .keyDown,switchOnPress{switchOnPress=false;activate(appB)}
                return routing.forwardIfMoved(e,origin:origin) ? nil:Unmanaged.passUnretained(e)
            }
        }
    }
    if interruptPID>0,type == .keyDown,e.getIntegerValueField(.keyboardEventKeycode)==37,
       e.getIntegerValueField(.eventSourceUnixProcessID)==Int64(interruptPID) {
        // The actual sender's pause makes interruption occur after the owned
        // receiver acknowledged down, not inside WindowServer delivery.
    }
    return Unmanaged.passUnretained(e)
},userInfo:nil)!
let taps=[hid,session],sources=taps.map{CFMachPortCreateRunLoopSource(nil,$0,0)!}
for (tap,run) in zip(taps,sources){CFRunLoopAddSource(CFRunLoopGetCurrent(),run,.defaultMode);CGEvent.tapEnable(tap:tap,enable:true)}
func edge(_ down:Bool,_ repeatKey:Bool=false)->Bool {
    guard let front=NSWorkspace.shared.frontmostApplication?.processIdentifier,
          [appA.processIdentifier,appB.processIdentifier].contains(front),!IsSecureEventInputEnabled(),
          let e=CGEvent(keyboardEventSource:source,virtualKey:37,keyDown:down) else{return false}
    e.flags=[];e.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(front))
    e.setIntegerValueField(.eventSourceUnixProcessID,value:Int64(getpid()))
    if repeatKey{e.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
    rootPresses.record(37,down:down)
    e.post(tap:.cghidEventTap);pump(0.15);return true
}
for condition in ["HID","session","route"] {
    activate(appA);mode=condition;switchOnPress=condition=="route"
    let beforeA=edges("A").count,beforeB=edges("B").count
    guard state().values.allSatisfy({!$0}) else{failure="unexpected held baseline";break}
    let first=edge(true),pressedState=state()
    let sent=first && (condition != "route" || edge(true,true)) && edge(false)
    var modifierSent=true
    if condition != "route" {
        for down in [true,false] {
            guard let e=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:down) else{modifierSent=false;break}
            e.type = .flagsChanged;e.flags=down ? CGEventFlags(rawValue:CGEventFlags.maskShift.rawValue|2):[]
            e.setIntegerValueField(.eventSourceUnixProcessID,value:Int64(getpid()))
            rootPresses.record(56,down:down,modifier:true)
            e.post(tap:.cghidEventTap);pump(0.1)
            if down && (state()["HID_shift"] != true || state()["session_shift"] != true){modifierSent=false}
        }
    }
    pump(0.05)
    let receivedA=Array(edges("A").dropFirst(beforeA)),receivedB=Array(edges("B").dropFirst(beforeB))
    let expected:[Int64]=condition=="route" ? [10,10,11]:[]
    let pass=sent && modifierSent && pressedState["HID_L"] == true && pressedState["session_L"] == true && receivedA.map{$0["type"]!}==expected && receivedB.isEmpty && state().values.allSatisfy({!$0})
    rows.append(["case":condition,"pass":pass,"A":receivedA,"B":receivedB,"pressedState":pressedState,"state":state()])
    if !pass{failure="edge or state verification failed";break}
}
mode="none"
// Establish how Quartz delivers a targeted modifier notification independently
// of the state boundary. This is deliberately not a typing event.
if failure.isEmpty {
    activate(appA)
    let a=edges("A").count,b=edges("B").count
    let down=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:true)!
    down.type = .flagsChanged;down.flags=CGEventFlags(rawValue:CGEventFlags.maskShift.rawValue|2)
    rootPresses.record(56,down:true,modifier:true)
    down.post(tap:.cghidEventTap);pump(0.1)
    let letterDown=CGEvent(keyboardEventSource:source,virtualKey:37,keyDown:true)!
    rootPresses.record(37,down:true)
    letterDown.flags=down.flags;letterDown.post(tap:.cghidEventTap);pump(0.1);activate(appB)
    let letterUp=CGEvent(keyboardEventSource:source,virtualKey:37,keyDown:false)!
    letterUp.flags=down.flags;letterUp.postToPid(appA.processIdentifier);pump(0.01)
    let up=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:false)!
    up.type = .flagsChanged;up.flags=[]
    up.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(appA.processIdentifier))
    up.postToPid(appA.processIdentifier);pump(0.1)
    let directState=state(),received=Array(edges("A").dropFirst(a)),other=Array(edges("B").dropFirst(b))
    mirror.releasePosted(letterUp,to:nil);mirror.releasePosted(up,to:nil);pump(0.1)
    _=rootPresses.takeReleases()
    let pass=received.map{$0["type"]!} == [12,10,11,12] && other.isEmpty && directState.values.allSatisfy({$0}) && state().values.allSatisfy({!$0})
    rows.append(["case":"targeted-releases-retain-global-state","pass":pass,"A":received,"B":other,"directState":directState,"state":state()])
    if !pass { failure="direct/global state comparison failed" }
}
if failure.isEmpty {
    for kind in ["signal","focus"] {
        activate(appA)
        let sender=Process();sender.executableURL=root.appendingPathComponent("actual-sender");sender.arguments=[root.path,"--pause-after-letter"]
        try! sender.run();interruptPID=sender.processIdentifier;interruptKind=kind
        try! JSONEncoder().encode([getpid(),interruptPID]).write(to:root.appendingPathComponent("producers.json"))
        pump(0.1);let a=edges("A").count,b=edges("B").count
        try! JSONSerialization.data(withJSONObject:["pid":appA.processIdentifier,"keys":[["code":37,"shift":true]]]).write(to:root.appendingPathComponent("keys-request.json"),options:.atomic)
        for _ in 0..<150{if edges("A").dropFirst(a).contains(where:{$0["code"]==37 && $0["type"]==10}){break};pump(0.005)}
        if kind=="signal" {sender.terminate()} else {activate(appB);try! Data().write(to:root.appendingPathComponent("continue"))}
        for _ in 0..<200{if FileManager.default.fileExists(atPath:root.appendingPathComponent("keys-done.json").path){break};pump(0.01)}
        if sender.isRunning{sender.terminate()}
        while sender.isRunning{pump(0.01)}
        pump(0.1);interruptPID=0
        let received=Array(edges("A").dropFirst(a)),other=Array(edges("B").dropFirst(b))
        let letters=received.filter{$0["code"]==37}.map{$0["type"]!}
        let shifts=received.filter{$0["code"]==56}.map{$0["type"]!}
        let pass=letters==[10,11] && shifts==[12,12] && other.isEmpty && state().values.allSatisfy({!$0})
        rows.append(["case":"producer-"+kind,"pass":pass,"A":received,"B":other,"state":state()])
        try? FileManager.default.removeItem(at:root.appendingPathComponent("keys-done.json"))
        try? FileManager.default.removeItem(at:root.appendingPathComponent("continue"))
        if !pass{failure="interrupted producer verification failed";break}
    }
}
for (tap,run) in zip(taps,sources){CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap);CFRunLoopRemoveSource(CFRunLoopGetCurrent(),run,.defaultMode)}
// Cleanup only the fixed test key if an assertion failed, never unrelated input.
for key in rootPresses.takeReleases() {
    if let up=CGEvent(keyboardEventSource:source,virtualKey:key.code,keyDown:false){
        if key.modifier {up.type = .flagsChanged};up.flags=[]
        mirror.releasePosted(up,to:appA.isTerminated ? nil:appA.processIdentifier);pump(0.1)
    }
}
try! JSONSerialization.data(withJSONObject:["passed":failure.isEmpty,"failure":failure,"cases":rows,"trace":trace],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("results.json"))
try! Data().write(to:root.appendingPathComponent("quit"));pump(0.1);routing.stop();mirror.stop()
print(failure.isEmpty ? "PASS: 6 native state/receiver/interruption cases":"FAIL: "+failure)
exit(failure.isEmpty ? 0:1)
