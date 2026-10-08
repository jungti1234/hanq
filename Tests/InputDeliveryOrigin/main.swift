import AppKit

var checks=0
var targets:[ObjectIdentifier:pid_t]=[:]
func check(_ condition:@autoclosure ()->Bool,_ message:String){checks+=1;if !condition(){fatalError(message)}}
func event(_ type:CGEventType = .keyDown,code:UInt16=15,pid:pid_t=100,tag:Int64=0)->CGEvent {
 let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:type == .keyDown)!
 e.type=type;e.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid));if tag != 0 {e.setIntegerValueField(.eventSourceUserData,value:tag)};targets[ObjectIdentifier(e)]=pid;return e
}
let routing=InputDeliveryOrigin();var front:pid_t?=100;var time=10.0;var sent:[(Int64,pid_t,CGEventType)]=[]
routing.targetPID={targets[ObjectIdentifier($0)]};routing.frontPID={front};routing.now={time};routing.canSend={true};routing.send={sent.append(($0.getIntegerValueField(.keyboardEventKeycode),$1,$0.type))};routing.beginTesting()
let first=event();routing.capture(.keyDown,first);let tag=first.getIntegerValueField(.eventSourceUserData)
check(InputDeliveryOrigin.isMarker(tag),"captured original input")
first.timestamp=999 // Quartz changes this during the exact build-130 reproduction.
let original=routing.take(.keyDown,first)
check(original?.pid==100,"retimestamp keeps original recipient")
check(routing.take(.keyDown,first)==nil,"origin consumed once")
check(!routing.forwardIfMoved(first,origin:original),"same app keeps the normal input pipeline")
front=200
check(routing.forwardIfMoved(first,origin:original),"moved app forwards original once")
check(sent.count==1 && sent[0].1==100,"never sends to new app")
check(!routing.forwardIfMoved(first,origin:original) && sent.count==1,"no duplicate post with consumed origin")
check(InputDeliveryOrigin.isMarker(first.getIntegerValueField(.eventSourceUserData)),"preserve provenance without a repair marker")
front=100
for type:CGEventType in [.keyDown,.keyUp] {
 for code:UInt16 in [15,40,1] {
  let e=event(type,code:code);routing.capture(type,e);let origin=routing.take(type,e);front=200
  check(routing.forwardIfMoved(e,origin:origin),"preserve both key edges")
  front=100
 }
}
check(sent.map{$0.0}==[15,15,40,1,15,40,1],"ordered, no inserted text or synthesized replacement")
let panel=event(pid:300);routing.capture(.keyDown,panel)
check(panel.getIntegerValueField(.eventSourceUserData)==0,"nonactivating panel uses existing focus handling")
for marker:Int64 in [0x454F5448,0x48414E5100000001,0x4851535749544348,123] {
 let e=event(tag:marker);routing.capture(.keyDown,e)
 check(e.getIntegerValueField(.eventSourceUserData)==marker && routing.take(.keyDown,e)==nil,"do not wrap another producer")
}
let changed=event();routing.capture(.keyDown,changed);changed.setIntegerValueField(.keyboardEventKeycode,value:0)
check(routing.take(.keyDown,changed)==nil,"changed key cannot borrow recipient")
let expired=event();routing.capture(.keyDown,expired);time+=3
check(routing.take(.keyDown,expired)==nil,"bounded stale origin")
let stopped=event();routing.capture(.keyDown,stopped);let beforeStop=routing.take(.keyDown,stopped);routing.stop();front=200
check(!routing.forwardIfMoved(stopped,origin:beforeStop),"teardown forbids later direct dispatch")
let old=InputDeliveryOrigin();old.targetPID={targets[ObjectIdentifier($0)]};old.frontPID={100};old.canSend={true};old.beginTesting();let e=event();old.capture(.keyDown,e)
let new=InputDeliveryOrigin();new.beginTesting()
check(new.take(.keyDown,e)==nil,"old session does not authorize new session")
print("PASS: \(checks) original-recipient guards; no global taps or real key posts")
