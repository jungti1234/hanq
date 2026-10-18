import Foundation

var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}

// Use the real monotonic clock and hold the metadata lock until the decision
// worker has actually failed try-lock. The input-side call must return first.
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),attempted=DispatchSemaphore(value:0)
let counterLock=NSLock();var clockCalls=0
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,clock:{
    if Thread.current.name=="hold-real-wait"{Thread.current.name="held-real-wait";entered.signal();release.wait()}
    return ProcessInfo.processInfo.systemUptime
},decisionClock:{
    counterLock.lock();clockCalls+=1;let call=clockCalls;counterLock.unlock()
    if call==3{attempted.signal()}
    return DispatchTime.now().uptimeNanoseconds
},writer:{captures.append($0)})
trace.decision(.handoff,.handoffUninitialized);trace.flush()
counterLock.lock();clockCalls=0;counterLock.unlock()
Thread{trace.withLockedMetadataForTest{entered.signal();release.wait()};done.signal()}.start()
check(entered.wait(timeout:.now()+2) == .success,"metadata lock held")
let callerBegan=DispatchTime.now().uptimeNanoseconds
trace.decision(.handoff,.handoffUninitialized)
check(DispatchTime.now().uptimeNanoseconds-callerBegan<100_000_000,"input caller does not wait for metadata lock")
check(attempted.wait(timeout:.now()+2) == .success,"worker actually failed try-lock")
trace.decision(.handoff,.handoffUninitialized) // Queued behind the waiting worker.
Thread.sleep(forTimeInterval:0.04)
release.signal();check(done.wait(timeout:.now()+2) == .success,"metadata lock released")
trace.flush();trace.mark();trace.flush()
let capture=captures[0]
let frames=capture.frames.filter{$0.kind == .detectionDecision}
// A heavily scheduled host may delay the third duplicate past the product's
// 50ms preservation threshold. It must then be retained, not called a failure.
check((2...3).contains(frames.count),"contended duplicate retained with bounded third repeat")
if frames.count==3 {
    let extra=frames[2].decisionTiming!
    check(extra.queueMicros>=50_000 || extra.clipped,"extra duplicate is retained only for significant queue delay")
}
check(frames[0].decisionTiming?.contended==false && frames[0].decisionTiming?.lockWaitMicros==0,"initial uncontended observation explicitly reports zero lock wait")
let waited=frames[1].decisionTiming!
check(waited.contended && waited.lockWaitMicros>=20_000 && !waited.clipped,"real held-lock elapsed time is measured")
let stats=capture.decisionDelivery.waits[244]!
check(stats.processed==3 && stats.contended==1,"cumulative stats include coalesced repeated calls")
check(stats.totalLockWaitMicros==waited.lockWaitMicros && stats.maxLockWaitMicros==waited.lockWaitMicros,"cumulative total/max match the one actual wait")
check(stats.maxQueueMicros>=20_000,"queue delay behind the waiting worker is separate from lock wait")
let decoded=try! RecorderTrace.decode(JSONEncoder().encode(capture))
check(decoded.frames.filter{$0.decisionTiming?.contended==true}.count==1,"real timed capture accepted by strict collector")
check(decoded.decisionDelivery?.waits?["244"]?.processed==3,"timing aggregates survive sanitized collection")

// Inject a monotonic clock to verify exact conversion, clipping and the
// distinction between dispatch delay and lock acquisition elapsed time.
func controlled(_ values:[UInt64],contend:Bool)->InputIncidentTrace.Capture {
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),attempted=DispatchSemaphore(value:0)
    let clockLock=NSLock();var call=0;var result:[InputIncidentTrace.Capture]=[]
    let trace=InputIncidentTrace(destination:nil,clock:{
        if Thread.current.name=="hold-controlled-wait"{Thread.current.name="held-controlled-wait";entered.signal();release.wait()}
        return ProcessInfo.processInfo.systemUptime
    },decisionClock:{
        clockLock.lock();let index=call;call+=1;clockLock.unlock()
        if index==2{attempted.signal()}
        return values[min(index,values.count-1)]
    },writer:{result.append($0)})
    if contend {
        Thread{trace.withLockedMetadataForTest{entered.signal();release.wait()};done.signal()}.start()
        check(entered.wait(timeout:.now()+2) == .success,"controlled lock held")
    }
    trace.decision(.repair,.repairBlocked)
    if contend {
        check(attempted.wait(timeout:.now()+2) == .success,"controlled worker entered blocking acquisition")
        release.signal();check(done.wait(timeout:.now()+2) == .success,"controlled lock released")
    }
    trace.flush();trace.mark();trace.flush();return result[0]
}
let exact=controlled([1_000_000_000,1_010_000_000,1_011_000_000,1_051_000_000],contend:true)
let exactTiming=exact.frames.first{$0.kind == .detectionDecision}!.decisionTiming!
check(exactTiming.queueMicros==10_000 && exactTiming.lockWaitMicros==40_000 && exactTiming.contended && !exactTiming.clipped,"queue10ms and lock40ms remain distinct")
check(exact.decisionDelivery.waits[268]?.totalLockWaitMicros==40_000,"exact duration reaches per-reason aggregate")
let clipped=controlled([1_000_000_000,63_000_000_000,64_000_000_000,125_000_000_000],contend:true)
let clippedTiming=clipped.frames.first{$0.kind == .detectionDecision}!.decisionTiming!
check(clippedTiming.queueMicros==60_000_000 && clippedTiming.lockWaitMicros==60_000_000 && clippedTiming.clipped,"long timing values explicitly mark60s clipping")
check(clipped.decisionDelivery.waits[268]?.clipped==1,"clipped observation counted cumulatively")
let free=controlled([1_000_000_000,1_005_000_000],contend:false)
let freeTiming=free.frames.first{$0.kind == .detectionDecision}!.decisionTiming!
check(freeTiming.queueMicros==5000 && freeTiming.lockWaitMicros==0 && !freeTiming.contended,"queue-only latency is never classified as lock contention")
check(free.decisionDelivery.waits[268]?.contended==0,"uncontended aggregate stays zero")
for data in [exact,clipped,free] {
    check((try? RecorderTrace.decode(JSONEncoder().encode(data))) != nil,"controlled timing data remains collector-compatible")
}
// Repeated idle reasons must retain significant queue-only latency and clipping,
// even when no try-lock failed. Exact threshold and a short repeat are distinct.
let queueTimes:[UInt64]=[1_000_000_000,1_000_000_000,1_000_000_000,1_049_999_000,1_000_000_000,1_050_000_000,1_000_000_000,61_000_000_000,1_000_000_000,61_000_001_000]
var queueIndex=0,queueCaptures:[InputIncidentTrace.Capture]=[]
let queueTrace=InputIncidentTrace(destination:nil,decisionClock:{let result=queueTimes[min(queueIndex,queueTimes.count-1)];queueIndex+=1;return result},writer:{queueCaptures.append($0)})
for _ in 0..<5{queueTrace.decision(.sample,.noCandidate);queueTrace.flush()}
queueTrace.mark();queueTrace.flush()
let queueFrames=queueCaptures[0].frames.filter{$0.kind == .detectionDecision}
check(queueFrames.count==4,"only a short duplicate is suppressed")
check(queueFrames.map{$0.decisionTiming!.queueMicros} == [0,50_000,60_000_000,60_000_000],"queue-only repeated reasons survive exact50ms threshold and60s cap")
check(queueFrames.allSatisfy{!$0.decisionTiming!.contended && $0.decisionTiming!.lockWaitMicros==0},"queue-only repeats never manufacture a lock wait")
check(queueFrames.last!.decisionTiming!.clipped && !queueFrames[2].decisionTiming!.clipped,"exact60s and over-limit are distinguished")
let queueStats=queueCaptures[0].decisionDelivery.waits[76]!
check(queueCaptures[0].decisionDelivery.coalesced?[76]==1,"short repeated decision suppression explicitly counted by site/reason")
check(queueStats.processed==5 && queueStats.contended==0 && queueStats.clipped==1,"suppressed/retained repeats remain counted once")
check((try? RecorderTrace.decode(JSONEncoder().encode(queueCaptures[0]))) != nil,"queue-only retained reasons remain strict-compatible")
print("PASS \(checks) real/injected timing, actual try-lock failure, nonblocking caller, coalesced repeat aggregates, queue/lock separation, clipping and strict collector checks; no AX/keys")
print("MEASURED lockWaitMicros=\(waited.lockWaitMicros) maximumQueueMicros=\(stats.maxQueueMicros) processed=\(stats.processed) contended=\(stats.contended)")
