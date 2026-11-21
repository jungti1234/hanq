import Foundation
import Darwin
var checks=0
func check(_ value:@autoclosure ()->Bool,_ message:String){checks+=1;if !value(){fputs("FAIL: \(message)\n",stderr);exit(1)}}
let fm=FileManager.default,root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
func directory(_ name:String)->URL{let d=root.appendingPathComponent(name);try! fm.createDirectory(at:d,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return d}
func snapshot(_ dir:URL)->[String:Data]{Dictionary(uniqueKeysWithValues:try! fm.contentsOfDirectory(atPath:dir.path).map{($0,try! Data(contentsOf:dir.appendingPathComponent($0)))})}
var time=100000.0
var limits=DiagnosticWriteBudget.Limits()
limits.automaticHour=1_000_000;limits.automaticDay=2_000_000;limits.manualHour=500_000;limits.manualDay=1_000_000
let dir=directory("rotation")
var budget:DiagnosticWriteBudget?=DiagnosticWriteBudget(limits:limits,clock:{time})
var store:DiagnosticLogStore?=DiagnosticLogStore(directory:dir,policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:20_000),persistentOwnership:true,writeBudget:budget)
check(store!.verifyReadiness().ready,"initial readiness")
let payload=Data(repeating:32,count:3000)
var id=0,saved=0
for _ in 0..<100 {id+=1;if store!.savePair(payload,payload,incident:id,automatic:true) == .saved{saved+=1}}
check(saved>0 && saved<100,"sustained flood reaches cumulative allowance")
check(store!.usage.files==4 && store!.usage.bytes==12000,"rotation does not refund writes")
let frozen=snapshot(dir),written=store!.actualWrittenBytes+budget!.actualBytes
for _ in 0..<10000{id+=1;check(store!.savePair(payload,payload,incident:id,automatic:true) == .limit,"suppressed without deferred work")}
check(snapshot(dir)==frozen && store!.actualWrittenBytes+budget!.actualBytes==written,"blocked storm performs zero further writes including metadata")
check(written<=limits.automaticHour,"payload, temporary and ledger logical writes within hour allowance")
check(store!.savePair(payload,payload,incident:id+1,automatic:false) == .saved,"manual credit independent of exhausted automatic allowance");id+=1
store=nil;budget=nil
budget=DiagnosticWriteBudget(limits:limits,clock:{time})
store=DiagnosticLogStore(directory:dir,policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:20_000),persistentOwnership:true,writeBudget:budget)
check(store!.savePair(payload,payload,incident:id+1,automatic:true) == .limit,"restart grants no automatic credit");id+=1
check(store!.savePair(payload,payload,incident:id+1,automatic:false) == .saved,"restart keeps independent manual allowance");id+=1
time-=50000
check(store!.savePair(payload,payload,incident:id+1,automatic:true) == .limit,"clock rollback grants no allowance");id+=1
time=103601
check(store!.savePair(payload,payload,incident:id+1,automatic:true) == .saved,"next hour opens while preserving day accounting");id+=1
for _ in 0..<100{id+=1;_ = store!.savePair(payload,payload,incident:id,automatic:true)}
time+=3601
for _ in 0..<100{id+=1;_ = store!.savePair(payload,payload,incident:id,automatic:true)}
check(budget!.summary["automaticDay"]!<=limits.automaticDay && store!.savePair(payload,payload,incident:id+1,automatic:true) == .limit,"day cap holds across hour renewals");id+=1
time=186401
check(store!.savePair(payload,payload,incident:id+1,automatic:true) == .saved,"next day renews allowance");id+=1
let statusFile=try! fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first{$0.pathExtension=="status"}!
check((try? RecorderStorageDocument.decode(Data(contentsOf:statusFile))) != nil,"strict status decoder accepts budget metadata")
store=nil;budget=nil
try! fm.removeItem(at:dir.appendingPathComponent(".write-budget-v1.ledger"))
let beforeMissing=snapshot(dir)
let missing=DiagnosticLogStore(directory:dir,policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:20_000),persistentOwnership:true,writeBudget:DiagnosticWriteBudget(limits:limits,clock:{time}))
check(missing.savePair(payload,payload,incident:id+1,automatic:true) == .unavailable && snapshot(dir)==beforeMissing,"deleted ledger fails closed, preserves evidence")

// A durable reservation survives a crash before any capture is published.
let crash=directory("crash"),fd=open(crash.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
let one=DiagnosticWriteBudget(limits:limits,clock:{time})
check(one.reserve(800000,automatic:true,event:true,dir:fd),"reserve before simulated crash")
let two=DiagnosticWriteBudget(limits:limits,clock:{time})
check(!two.reserve(800000,automatic:true,event:true,dir:fd),"unspent crash reservation is not refunded")
close(fd)
let damaged=directory("damaged")
try! Data("{".utf8).write(to:damaged.appendingPathComponent(".write-budget-v1.ledger"));try! fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:damaged.appendingPathComponent(".write-budget-v1.ledger").path)
let damagedFD=open(damaged.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
check(!DiagnosticWriteBudget(clock:{time}).reserve(1,automatic:true,event:true,dir:damagedFD),"corrupt ledger is not reset");close(damagedFD)
let failed=directory("failed"),failedFD=open(failed.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
let failure=DiagnosticWriteBudget(clock:{time},writer:{_,_,_ in errno=ENOSPC;return -1})
check(!failure.reserve(10,automatic:true,event:true,dir:failedFD) && failure.persistenceFailures==1,"ENOSPC reservation failure prevents payload writes")
check(!failure.reserve(10,automatic:true,event:true,dir:failedFD) && failure.persistenceFailures==1,"logger/ledger failures do not recurse or retry unboundedly");close(failedFD)

// Explicit bounded compatibility worker: independent trigger, pair, flood, manual, no catch-up.
var tick=100.0
let traceDir=root.appendingPathComponent("trace")
let trace=InputIncidentTrace(secureInput:{false},destination:traceDir,persistentOwnership:true,clock:{tick},boundedStorage:true)
for _ in 0..<4096{trace.context();trace.flush()}
trace.captureForTest(.axDelay);trace.flush()
check(snapshot(traceDir).keys.filter{$0.hasPrefix("incident-")}.count==1,"normal mode publishes durable pre without waiting for post window")
for _ in 0..<3{trace.captureForTest(.axDelay);trace.flush()}
trace.captureForTest(.callbackDelay);trace.flush()
trace.mark();trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
let captures=snapshot(traceDir).filter{$0.key.hasPrefix("incident-")}
check(captures.count==12,"four same-kind events within ten seconds, another kind and manual retain pre/post")
let decoded=captures.values.map{try! RecorderTrace.decode($0)}
check(decoded.allSatisfy{$0.captureBacklog?.deferred.isEmpty == true},"normal mode never queues a deferred burst")
check(decoded.allSatisfy{$0.captureBacklog?.rateSuppressed?.isEmpty == true},"same kind and time no longer cause event suppression")
let sizes=captures.values.map{$0.count}
print("MEASURE 4096-frame capture phase bytes: \(sizes.sorted()); total=\(sizes.reduce(0,+))")
tick=10000;trace.drainCapturesForTest();trace.flush()
check(snapshot(traceDir).filter{$0.key.hasPrefix("incident-")}.count==12,"time advance does not invent deferred requests")
trace.stopAndFlush()
print("PASS \(checks) write budget, restart, failed persistence, paired capture and flood checks; no app/TCC/keys")
