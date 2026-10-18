import Foundation
import ApplicationServices
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
func code(_ op:Int,_ lane:Int,_ detail:Int=0)->Int {((op-1)*8+lane-1)*32+detail}
let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
event.timestamp=123456789
var measured:[String:Int]=[:]
for operation in 1...10 {
    let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),attempted=DispatchSemaphore(value:0)
    let clockLock=NSLock();var calls=0;var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,observationClock:{
        clockLock.lock();calls+=1;let n=calls;clockLock.unlock()
        if n==3{attempted.signal()}
        return DispatchTime.now().uptimeNanoseconds
    },writer:{captures.append($0)})
    var span:InputIncidentTrace.ReadSpan?
    if operation==3{span=trace.beginRead(.mismatchAX);trace.flush()}
    if operation==4{trace.shape(.mismatchAX,identity:1,count:3,selected:false,editing:false);trace.flush()}
    clockLock.lock();calls=0;clockLock.unlock()
    Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
    check(held.wait(timeout:.now()+2) == .success,"metadata held for operation \(operation)")
    let began=ProcessInfo.processInfo.systemUptime
    let key:Int
    switch operation {
    case 1:trace.event(.mismatch,.keyDown,event,consumed:true,duration:0.003);key=code(1,4,5)
    case 2:span=trace.beginRead(.mismatchAX);key=code(2,7)
    case 3:trace.endRead(.mismatchAX,span);key=code(3,7)
    case 4:trace.shape(.mismatchAX,identity:1,count:3,selected:false,editing:false);key=code(4,7)
    case 5:trace.state(.mismatch,.retained,pending:7);key=code(5,4,4)
    case 6:trace.context();key=code(6,2)
    case 7:trace.sourceBoundary(.waiting,queued:4,awaitingOnset:2);key=code(7,8,1)
    case 8:trace.mark();key=code(8,2)
    case 9:trace.start();key=code(9,2)
    default:trace.captureForTest(.manual);key=code(10,2,1)
    }
    check(ProcessInfo.processInfo.systemUptime-began<0.1,"caller returns before metadata release \(operation)")
    check(attempted.wait(timeout:.now()+2) == .success,"actual first try-lock failure reached \(operation)")
    Thread.sleep(forTimeInterval:0.025)
    release.signal();check(done.wait(timeout:.now()+2) == .success,"metadata released \(operation)")
    if operation==2{trace.endRead(.mismatchAX,span)}
    trace.flush();trace.mark();trace.flush()
    let capture=captures.last!,stats=capture.observationDelivery.waits[key]!
    check(stats.contended>=1 && stats.maxLockWaitMicros>=20_000,"per-kind actual wait measured \(operation)")
    let timings=captures.flatMap{$0.frames}.compactMap{$0.observationTiming}.filter{$0.contended}
    if operation==10{check(captures.contains{$0.captureTiming.contended && $0.captureTiming.lockWaitMicros>=20_000},"pre capture has individual acquisition timing")}
    else{check(timings.contains{$0.lockWaitMicros==stats.maxLockWaitMicros},"individual frame retains measured wait \(operation)")}
    if operation==4{check(capture.frames.filter{$0.kind == .shape}.count==2,"contended unchanged shape still has individual timing")}
    if operation==9{check(capture.frames.contains{$0.kind == .observationWait && $0.category==9},"contended timer has typed wait frame")}
    check((try? RecorderTrace.decode(JSONEncoder().encode(capture))) != nil,"strict collector decodes operation \(operation)")
    if operation==10{check(captures.contains{$0.frames.contains{$0.kind == .observationWait && $0.category==10}},"important capture wait also survives in bounded history")}
    measured[String(operation)]=stats.maxLockWaitMicros
}
// Post capture is a separate writer acquisition after the 1s boundary.
do {
    let phase0=DispatchSemaphore(value:0),phase1=DispatchSemaphore(value:0),held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),attempted=DispatchSemaphore(value:0)
    let guardLock=NSLock();var calls=0;var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,observationClock:{guardLock.lock();calls+=1;let n=calls;guardLock.unlock();if n==3{attempted.signal()};return DispatchTime.now().uptimeNanoseconds},writer:{c in captures.append(c);(c.phase==0 ? phase0:phase1).signal()})
    trace.captureForTest(.manual);check(phase0.wait(timeout:.now()+2) == .success,"pre capture written")
    guardLock.lock();calls=0;guardLock.unlock()
    Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
    check(held.wait(timeout:.now()+2) == .success,"post capture metadata held")
    check(attempted.wait(timeout:.now()+3) == .success,"post capture try-lock actually failed")
    Thread.sleep(forTimeInterval:0.025);release.signal();check(done.wait(timeout:.now()+2) == .success,"post lock released")
    check(phase1.wait(timeout:.now()+2) == .success,"post capture written")
    let post=captures.first{$0.phase==1}!
    check(post.captureTiming.contended && post.captureTiming.lockWaitMicros>=20_000,"post individual timing measured")
    check(post.observationDelivery.waits[code(10,2,25)]?.contended==1,"post stats have separate fixed phase code")
    check((try? RecorderTrace.decode(JSONEncoder().encode(post))) != nil,"post metadata strict decode")
    measured["post"]=post.captureTiming.lockWaitMicros
}
func controlled(_ values:[UInt64],contend:Bool)->InputIncidentTrace.Capture {
    let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),attempted=DispatchSemaphore(value:0)
    let guardLock=NSLock();var call=0;var captures:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,observationClock:{guardLock.lock();let n=call;call+=1;guardLock.unlock();if n==2{attempted.signal()};return values[min(n,values.count-1)]},writer:{captures.append($0)})
    if contend {Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start();check(held.wait(timeout:.now()+2) == .success,"controlled lock held")}
    trace.state(.mismatch,.buffered,pending:2)
    if contend {check(attempted.wait(timeout:.now()+2) == .success,"controlled try failure");release.signal();check(done.wait(timeout:.now()+2) == .success,"controlled release")}
    trace.flush();trace.mark();trace.flush();return captures.last!
}
let exact=controlled([1_000_000_000,1_010_000_000,1_011_000_000,1_051_000_000],contend:true)
let timing=exact.frames.first{$0.kind == .state}!.observationTiming!
check(timing.contended && timing.queueMicros==10000 && timing.lockWaitMicros==40000,"queue10ms/actual lock40ms are distinct")
check(exact.observationDelivery.waits[code(5,4,8)]?.totalLockWaitMicros==40000,"exact aggregate sum")
let free=controlled([1_000_000_000,1_005_000_000],contend:false).frames.first{$0.kind == .state}!.observationTiming!
check(!free.contended && free.lockWaitMicros==0 && free.queueMicros==5000,"queue-only wait is not lock contention")
let clipped=controlled([1_000_000_000,63_000_000_000,64_000_000_000,125_000_000_000],contend:true)
let cap=clipped.frames.first{$0.kind == .state}!.observationTiming!
check(cap.clipped && cap.queueMicros==60_000_000 && cap.lockWaitMicros==60_000_000,"60s clipping explicit")
check(clipped.observationDelivery.waits[code(5,4,8)]?.clipped==1,"clipping aggregate")
let sub=controlled([1_000_000_000,1_000_000_000,1_000_001_000,1_000_001_999],contend:true).frames.first{$0.kind == .state}!.observationTiming!
check(sub.contended && sub.lockWaitMicros==0,"sub-microsecond contention stays marked")
let reversed=controlled([2_000_000_000,1_000_000_000],contend:false).frames.first{$0.kind == .state}!.observationTiming!
check(reversed.queueMicros==0 && reversed.lockWaitMicros==0,"reversed injected monotonic delta cannot underflow")
let boundary=controlled([1_000_000_000,61_000_000_000],contend:false).frames.first{$0.kind == .state}!.observationTiming!
check(boundary.queueMicros==60_000_000 && !boundary.clipped,"exact60s boundary is not marked clipped")
for c in [exact,clipped]{check((try? RecorderTrace.decode(JSONEncoder().encode(c))) != nil,"controlled timing strict decode")}
if let path=CommandLine.arguments.dropFirst().first{try! JSONEncoder().encode(exact).write(to:URL(fileURLWithPath:path))}
print("PASS \(checks) actual waits across all10 observation/capture operations and post phase, nonblocking callers, individual/aggregate consistency, suppressed shape/timer, injected timing and clipping; no AX/global keys")
print("MEASURED lock waits us: \(measured)")
