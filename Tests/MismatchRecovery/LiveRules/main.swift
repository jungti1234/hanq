import Foundation
var checks=0
func check(_ condition:Bool){checks+=1;if !condition{fputs("FAIL: Caps trial rule \(checks)\n",stderr);exit(1)}}
for first in [15,40,5] {
    check(CapsTrial.followingRoman([first,first,first],first:first)==PhysicalLetterKeys.letters[UInt16(first)]!+PhysicalLetterKeys.letters[UInt16(first)]!)
    check(CapsTrial.followingRoman([first,0,11],first:first)=="ab")
    check(CapsTrial.followingRoman([first,0,45],first:first)=="an")
    check(CapsTrial.followingRoman([first,11,8],first:first)=="bc")
    check(CapsTrial.followingRoman([first,0,51],first:first)==nil)
    check(CapsTrial.followingRoman([first,0,51,11],first:first)==nil)
    check(CapsTrial.followingRoman([first,0,11,11],first:first)==nil)
    check(CapsTrial.followingRoman([first,0],first:first)==nil)
    check(CapsTrial.followingRoman([first,0,123],first:first)==nil)
    check(CapsTrial.followingRoman([11,0,11],first:first)==nil)
}

let trace="mono=1000000000 mismatch.replay_started\nmono=2000000000 mismatch.korean_result_verified"
let physical:[[String:Any]]=[["code":5,"modifiers":256],["code":0,"modifiers":65792],["code":11,"modifiers":65792]]
check(CapsTrial.followingRoman(physical,first:5)=="AB")
check(CapsTrial.followingRoman([["code":5,"modifiers":256],["code":0,"modifiers":65792],["code":11,"modifiers":256]],first:5)=="Ab")
check(CapsTrial.followingRoman([["code":5,"modifiers":256],["code":0,"modifiers":131072],["code":11,"modifiers":256]],first:5)==nil)
check(CapsTrial.followingRoman([["code":5,"modifiers":256],["code":0],["code":11,"modifiers":256]],first:5)==nil)
let events:[[String:Any]]=[["code":15,"replay":false,"time":0.5],["code":15,"replay":true,"time":1.5],["code":15,"replay":true,"time":2.5],["code":15,"replay":true,"time":2.7]]
check(CapsTrial.userEvents(events,trace:trace).compactMap{$0["code"] as? Int}==[15,15,15])
check(CapsTrial.userEvents(events,trace:"mono=1000000000 mismatch.replay_started").count==1)
check(CapsTrial.userEvents(events,trace:"mono=1000000000 mismatch.replay_started\nmono=2000000000 mismatch.abort reasonCode=19").count==3)
let pulse="1 mono=1000000000 pid=7 main.pulse tap=true enabled=true cachedAX=true mismatchEnabled=true mismatchSuspended=false mismatchRecovering=false mismatchTap=true mismatchSwitchTap=true"
check(CapsTrial.monitorReady(pulse,pid:7,now:1_500_000_000))
check(!CapsTrial.monitorReady(pulse,pid:8,now:1_500_000_000))
check(!CapsTrial.monitorReady(pulse,pid:7,now:3_000_000_000))
check(!CapsTrial.monitorReady(pulse,pid:7,now:500_000_000))
check(!CapsTrial.monitorReady("",pid:7,now:1_500_000_000))
for bad in ["mismatchEnabled=false","mismatchSuspended=true","mismatchRecovering=true","mismatchTap=false","mismatchSwitchTap=false"] {
    let key=String(bad.split(separator:"=")[0])
    let good=key+"="+((key=="mismatchSuspended" || key=="mismatchRecovering") ? "false":"true")
    check(!CapsTrial.monitorReady(pulse+"\n"+pulse.replacingOccurrences(of:good,with:bad),pid:7,now:1_500_000_000))
}
let log=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-trace-\(UUID().uuidString)")
defer{try? FileManager.default.removeItem(at:log)}
try Data(repeating:120,count:44*1_048_576).write(to:log)
var cursor=TrialTrace();cursor.begin(log)
check(cursor.offset==44*1_048_576 && cursor.text.isEmpty)
check(cursor.refresh(log)==0 && cursor.valid && cursor.caughtUp)
let handle=try FileHandle(forWritingTo:log);try handle.seekToEnd()
try handle.write(contentsOf:Data("mono=1000000000 main.pulse enabled=true\nmono=1000000000 mismatch.replay_sta".utf8))
check(cursor.refresh(log)<TrialTrace.readLimit && cursor.text.isEmpty)
try handle.write(contentsOf:Data("rted\nmono=2000000000 mismatch.korean_result_verified\n".utf8))
cursor.refresh(log)
check(cursor.text.contains("mismatch.replay_started") && cursor.text.contains("mismatch.korean_result_verified"))
check(CapsTrial.userEvents(events,trace:cursor.text).count==3)
let saved=cursor.text
check(cursor.refresh(log)==0 && cursor.text==saved)
try handle.write(contentsOf:Data(repeating:120,count:2*TrialTrace.readLimit))
check(cursor.refresh(log)==TrialTrace.readLimit && !cursor.caughtUp)
cursor.refresh(log)
check(!cursor.valid) // Oversize unterminated line cannot silently pass.
cursor.begin(log);check(cursor.valid && cursor.text.isEmpty)
try handle.truncate(atOffset:0);cursor.refresh(log);check(!cursor.valid)
try handle.close()
print("PASS: \(checks) Caps/trace rules; bounded incremental reads of a 44 MiB log, split lines, failure closure; no OS keys")
