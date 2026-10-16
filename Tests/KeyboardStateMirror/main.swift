import AppKit
var checks=0
func check(_ ok:Bool,_ name:String){checks+=1;if !ok{fatalError(name)}}
func key(_ type:CGEventType,_ code:UInt16=37)->CGEvent {
 let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:type == .keyDown)!
 e.type=type;return e
}
let mirror=KeyboardStateMirror();mirror.beginTesting()
for type:CGEventType in [.keyDown,.keyUp,.flagsChanged] {
 let e=key(type);e.flags = .maskShift
 let raw=mirror.preserve(type,e,process:{e.flags=[];return nil})!
 let state=raw.takeRetainedValue()
 check(state !== e,"suppressed edge uses a fresh state-only record")
 check(state.getIntegerValueField(.eventSourceUserData)==mirror.marker && state.flags == .maskShift,"raw flags and private boundary marker")
 check(mirror.receive(type,state)==nil,"state-only edge never reaches an app")
}
let other=KeyboardStateMirror()
let marked=key(.keyUp);marked.setIntegerValueField(.eventSourceUserData,value:other.marker)
var called=false
check(mirror.preserve(.keyUp,marked,process:{called=true;return nil}) != nil && !called,"other boundary producers bypass all input consumers")
check(mirror.receive(.keyUp,marked) != nil,"one producer cannot consume another producer's state receipt")
let normal=key(.keyDown)
check(mirror.preserve(.keyDown,normal,process:{Unmanaged.passUnretained(normal)}) != nil && normal.getIntegerValueField(.eventSourceUserData)==0,"normal key remains unchanged")
mirror.stop();called=false
check(mirror.preserve(.keyDown,normal,process:{called=true;return nil}) != nil && !called,"stopped boundary cannot run a consuming handler")
print("PASS: \(checks) keyboard state boundary ownership, flags and teardown assertions; no OS posts")

for tag:Int64 in [0x4852000100000001,0x4851455600000001] {
 let original=key(.keyDown);original.setIntegerValueField(.eventSourceUserData,value:tag)
 let receipt=original.copy()!;var seen:Int64=0
 mirror.diagnosticBoundary={_,event,consumed in check(!consumed,"ordinary provenance is never consumed");seen=event.getIntegerValueField(.eventSourceUserData)}
 check(mirror.receive(.keyDown,original)?.takeUnretainedValue() === original,"ordinary original passed once")
 check(seen==tag,"observer sees identity before boundary cleanup; source metadata is verified live")
 check(receipt.getIntegerValueField(.eventSourceUserData)==tag,"async gate receipt retains its own identity")
}
mirror.diagnosticBoundary=nil
for tag:Int64 in [0x12345678,0x48414E5100000001,0x4851535749544348] {
 let e=key(.keyDown);e.setIntegerValueField(.eventSourceUserData,value:tag)
 check(mirror.receive(.keyDown,e) != nil && e.getIntegerValueField(.eventSourceUserData)==tag,"unrelated producer/repair tags are untouched")
}

var posted=PostedKeys()
posted.record(56,down:true,modifier:true);posted.record(37,down:true);posted.record(37,down:true)
check(posted.takeReleases()==[PostedKeys.Key(code:37,modifier:false),PostedKeys.Key(code:56,modifier:true)],"interrupted producer releases letter before its modifier once")
check(posted.takeReleases().isEmpty,"cleanup cannot release a press twice")
posted.record(37,down:true);posted.record(37,down:false)
check(posted.takeReleases().isEmpty,"successful pair cannot produce an extra cleanup release")
print("PASS: \(checks) total including interrupted test-producer ownership")
