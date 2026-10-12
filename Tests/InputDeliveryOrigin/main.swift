import AppKit

var checks=0
var targets:[ObjectIdentifier:pid_t]=[:]
func check(_ condition:@autoclosure ()->Bool,_ message:String){checks+=1;if !condition(){fatalError(message)}}
func event(_ type:CGEventType = .keyDown,code:UInt16=15,pid:pid_t=100,tag:Int64=0)->CGEvent {
 let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:type == .keyDown)!
 e.type=type;e.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid));if tag != 0 {e.setIntegerValueField(.eventSourceUserData,value:tag)};targets[ObjectIdentifier(e)]=pid;return e
}
let routing=InputDeliveryOrigin();var front:pid_t?=100;var time=10.0;var sent:[(Int64,pid_t,CGEventType)]=[]
routing.targetPID={targets[ObjectIdentifier($0)]};routing.frontPID={front};routing.now={time};routing.canSend={true};routing.send={sent.append(($0.getIntegerValueField(.keyboardEventKeycode),$1,$0.type))};routing.recipientLifetime={_ in {true}};routing.beginTesting()
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
// A forwarded press still belongs to its receiver after the OS chooses the
// newly focused app for its release. Do not mix a PID down with a normal up.
do {
 let b=InputDeliveryOrigin();var focused:pid_t?=100;var posts:[(pid_t,CGEventType)]=[];var alive=true
 b.frontPID={focused};b.targetPID={targets[ObjectIdentifier($0)]};b.canSend={true}
 b.recipientLifetime={_ in {alive}};b.send={posts.append(($1,$0.type))};b.beginTesting()
 let down=event(code:37);b.capture(.keyDown,down);let press=b.take(.keyDown,down);focused=200
 check(b.forwardIfMoved(down,origin:press),"forwarded down establishes release ownership")
 let repeatKey=event(code:37,pid:200);repeatKey.setIntegerValueField(.keyboardEventAutorepeat,value:1)
 b.capture(.keyDown,repeatKey)
 check(b.forwardIfMoved(repeatKey,origin:b.take(.keyDown,repeatKey)),"repeat stays with original receiver")
 let up=event(.keyUp,code:37,pid:200);b.capture(.keyUp,up)
 check(b.forwardIfMoved(up,origin:b.take(.keyUp,up)),"release follows receiver without a second focus change")
 check(posts.map{$0.0}==[100,100,100] && posts.map{$0.1}==[.keyDown,.keyDown,.keyUp],"one receiver and exact edge order")
 let normal=event(code:37,pid:200);b.capture(.keyDown,normal)
 check(!b.forwardIfMoved(normal,origin:b.take(.keyDown,normal)),"released key cannot retain old receiver")
 focused=100;let deadDown=event(code:8);b.capture(.keyDown,deadDown);let origin=b.take(.keyDown,deadDown);focused=200
 check(b.forwardIfMoved(deadDown,origin:origin),"second forwarded press")
 alive=false;let deadUp=event(.keyUp,code:8,pid:200);b.capture(.keyUp,deadUp)
 check(!b.forwardIfMoved(deadUp,origin:b.take(.keyUp,deadUp)),"terminated recipient never authorizes PID reuse")
 b.stop()
}
do {
 let b=InputDeliveryOrigin();var focused:pid_t?=100;var posts:[CGEventType]=[]
 b.frontPID={focused};b.targetPID={targets[ObjectIdentifier($0)]};b.canSend={true};b.recipientLifetime={_ in {true}}
 b.send={e,pid in check(pid==100,"HID release stays with prior receiver");posts.append(e.type)};b.beginTesting()
 let down=event(code:37);b.capture(.keyDown,down);let origin=b.take(.keyDown,down);focused=200
 check(b.forwardIfMoved(down,origin:origin),"establish HID release owner")
 let up=event(.keyUp,code:37,pid:200)
 check(b.receive(.keyUp,up)==nil && posts==[.keyDown,.keyUp],"release is resolved before any later input consumer")
 focused=100;let again=event(code:37);b.capture(.keyDown,again);let o=b.take(.keyDown,again);focused=200
 check(b.forwardIfMoved(again,origin:o),"establish cleanup owner")
 let cleanup=event(.keyUp,code:37,pid:200,tag:KeyboardStateMirror().marker)
 b.forgetMirroredRelease(.keyUp,cleanup)
 let fresh=event(code:37,pid:200);b.capture(.keyDown,fresh)
 check(!b.forwardIfMoved(fresh,origin:b.take(.keyDown,fresh)),"producer cleanup cannot leave a stale recipient for the next press")
 b.stop()
}
for marker:Int64 in [0x454F5448,0x48414E5100000001,0x4851535749544348,123] {
 let e=event(tag:marker);routing.capture(.keyDown,e)
 check(e.getIntegerValueField(.eventSourceUserData)==marker && routing.take(.keyDown,e)==nil,"do not wrap another producer")
}
do {
 let b=InputDeliveryOrigin();var focused:pid_t?=100;var destinations:[pid_t]=[]
 b.frontPID={focused};b.targetPID={targets[ObjectIdentifier($0)]};b.canSend={true};b.recipientLifetime={_ in {true}}
 b.send={_,pid in destinations.append(pid)};b.beginTesting()
 let device=CGEventField(rawValue:87)!
 let down=event(code:37);down.setIntegerValueField(device,value:11)
 b.capture(.keyDown,down);let origin=b.take(.keyDown,down);focused=200
 check(b.forwardIfMoved(down,origin:origin),"device-specific press owns its original receiver")
 let tag=down.getIntegerValueField(.eventSourceUserData)
 func repeated(_ code:UInt16=37,_ deviceID:Int64=11)->CGEvent {
  let e=event(code:code,pid:200,tag:tag);e.setIntegerValueField(device,value:deviceID)
  e.setIntegerValueField(.keyboardEventAutorepeat,value:1);return e
 }
 check(b.take(.keyDown,repeated())?.pid==100,"repeat can reuse only its own still-held provenance")
 check(b.take(.keyDown,repeated(8))==nil,"changed repeat key cannot borrow held provenance")
 check(b.take(.keyDown,repeated(37,22))==nil,"another device cannot borrow held repeat provenance")
 let otherSource=repeated();otherSource.setIntegerValueField(.eventSourceUnixProcessID,value:999999)
 check(b.take(.keyDown,otherSource)==nil,"another producer cannot borrow held repeat provenance")
 let otherUp=event(.keyUp,code:37,pid:200);otherUp.setIntegerValueField(device,value:22)
 check(b.receive(.keyUp,otherUp) != nil && destinations==[100],"other device release stays on normal pipeline")
 let ownUp=event(.keyUp,code:37,pid:200);ownUp.setIntegerValueField(device,value:11)
 check(b.receive(.keyUp,ownUp)==nil && destinations==[100,100],"matching device release retains original receiver")
 check(b.take(.keyDown,repeated())==nil,"release removes repeat alias")
 b.stop()
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
