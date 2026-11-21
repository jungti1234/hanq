import Foundation
import Darwin
var checks=0
func check(_ test:@autoclosure () throws ->Bool,_ title:String) {
    checks+=1;if (try? test()) != true {fputs("FAIL durability: \(title)\n",stderr);exit(1)}
}
let fm=FileManager.default,root=URL(fileURLWithPath:fm.currentDirectoryPath)
func dir(_ name:String)->URL {let d=root.appendingPathComponent(name);try! fm.createDirectory(at:d,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return d}
func files(_ d:URL)->[String:Data] {
    let paths=(fm.enumerator(at:d,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []).filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true && !$0.lastPathComponent.contains("writer")}
    return Dictionary(uniqueKeysWithValues:paths.map{(String($0.path.dropFirst(d.path.count+1)),try! Data(contentsOf:$0))})
}
func records(_ d:URL)throws ->[DiagnosticCriticalJournal.Event] {
    let fd=open(d.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);defer{close(fd)}
    return try DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []}
}
let cause=OperationalFailure.posix(.probeLaunch,ENOSPC)
if CommandLine.arguments.contains("--kill-child") {
    let d=dir("source")
    let journal=DiagnosticCriticalJournal(directory:d)
    OperationalDiagnostics.shared.installJournal(journal)
    let trace=InputIncidentTrace(secureInput:{false},destination:d,persistentOwnership:true)
    trace.context();trace.captureForTest(.boundaryInterrupted);trace.flush()
    OperationalDiagnostics.shared.record(cause)
    check(journal.flush(timeout:3),"child critical record durable")
    check(files(d).keys.filter{$0.hasSuffix(".hqdiag") && (try? DiagnosticSharedStore.readHeader(d.appendingPathComponent($0)).0.role) != 1}.count==1,"child has pre before post deadline")
    FileHandle.standardOutput.write(Data("READY\n".utf8))
    Thread.sleep(forTimeInterval:20);exit(99)
}
if CommandLine.arguments.contains("--exit-child") {
    let d=dir("source"),journal=DiagnosticCriticalJournal(directory:d)
    OperationalDiagnostics.shared.installJournal(journal)
    OperationalDiagnostics.shared.record(cause)
    PermissionRecovery().exitAfterPermissionLoss()
}
// Failed/partial ledger writes consume credit; retries are paced and identity
// checked, with no reset/refund on eventual success or subsequent relaunch.
var tick=100.0,fail=true,calls=0
let ledgerDir=dir("ledger"),fd=open(ledgerDir.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
let budget=DiagnosticWriteBudget(clock:{100000},retryClock:{tick},writer:{fd,p,n in
    calls+=1
    if fail {if calls==1{return Darwin.write(fd,p,min(7,n))};errno=ENOSPC;return -1}
    return Darwin.write(fd,p,n)
})
check(!budget.reserve(500,automatic:true,event:true,dir:fd),"partial ledger ENOSPC blocks payload")
let charged=budget.summary["automaticHour"]!,attempts=calls
for _ in 0..<10000{_ = budget.reserve(500,automatic:true,event:true,dir:fd)}
check(calls==attempts && budget.persistenceFailures==1,"10k requests do not retry inside backoff")
fail=false;tick+=1
check(budget.reserve(500,automatic:true,event:true,dir:fd),"ledger automatically recovers")
check(budget.summary["automaticHour"]==charged*2 && budget.lastFailure==nil,"failed reservation remains charged and error clears")
let reopened=DiagnosticWriteBudget(clock:{100000})
check(reopened.reserve(500,automatic:true,event:true,dir:fd) && reopened.summary["automaticHour"]==charged*3,"relaunch keeps all committed credits")
close(fd)
// Payload and ownership-index failures recover using the still-owned objects.
for mode in ["payload","index","initial-ledger"] {
    tick=100;var broken=false,writeCalls=0
    let d=dir(mode)
    let accounting=DiagnosticWriteBudget(retryClock:{tick},writer:{fd,p,n in
        if mode=="initial-ledger" && broken{errno=ENOSPC;return -1};return Darwin.write(fd,p,n)
    })
    let store=DiagnosticLogStore(directory:d,policy:.incidentDefault,persistentOwnership:true,writeBudget:accounting,retryClock:{tick},writer:{fd,p,n in
        writeCalls+=1
        let text=String(data:Data(bytes:p!,count:n),encoding:.utf8) ?? ""
        if broken && ((mode=="payload" && text=="payload") || (mode=="index" && text.contains("writeBudgetRequired"))) {errno=ENOSPC;return -1}
        return Darwin.write(fd,p,n)
    })
    if mode=="initial-ledger"{broken=true}
    let ready=store.verifyReadiness()
    check(ready.ready == (mode != "initial-ledger"),"\(mode) initial readiness")
    broken=true
    check(store.save(Data("payload".utf8),incident:1,phase:0,automatic:true) != .saved || mode=="index","\(mode) injected storage failure observed")
    check(!store.readiness.ready,"\(mode) failure withdraws readiness")
    let before=writeCalls
    for _ in 0..<100{_ = store.save(Data("payload".utf8),incident:2,phase:0,automatic:true)}
    check(writeCalls==before,"\(mode) retry storm does not write")
    broken=false;tick+=61
    check(store.save(Data("payload".utf8),incident:3,phase:0,automatic:true) == .saved,"\(mode) same-process recovery")
    check(store.readiness.ready,"\(mode) successful write restores readiness")
}
// Ordinary detail quotas cannot stop new minimal occurrences. Repeated
// failures are different events, not a 30-second/10-second aggregate.
let emergency=dir("critical")
var small=DiagnosticWriteBudget.Limits();small.automaticHour=5000;small.automaticDay=5000
let ordinary=DiagnosticLogStore(directory:emergency,policy:.incidentDefault,persistentOwnership:true,writeBudget:DiagnosticWriteBudget(limits:small))
_ = ordinary.verifyReadiness()
check(ordinary.save(Data(repeating:32,count:4096),incident:1,phase:0,automatic:true) != .saved,"ordinary budget exhausted")
let journal=DiagnosticCriticalJournal(directory:emergency)
for batch in 0..<50 {
    for code in 0..<64{journal.record(code<2 ? .policy(.probeLaunch,batch*64+code):cause)}
    check(journal.flush(timeout:3),"minimum events continue after detailed quota, batch \(batch)")
}
let events=try! records(emergency)
check(events.count==3200 && Set(events.map{$0.run+":"+String($0.sequence)}).count==3200,"all 3200 separate occurrences retain unique IDs")
check(events.filter{$0.failure==cause}.count==3100,"same cause in same second is not discarded or reduced to a counter")
check(journal.status().writtenBytes<2*1024*1024,"3200 minimum records use less than 2MiB logical writes")
print("MEASURE 3200 minimum occurrences: \(journal.status().writtenBytes) logical bytes; detail quota already exhausted")
// Bounded retention evicts OLD segments, never stops NEW occurrence recording.
let rotationDir=dir("critical-rotation"),rotation=DiagnosticCriticalJournal(directory:rotationDir,segmentBytes:4096)
for i in 0..<100{rotation.record(.policy(.probeLaunch,i));check(rotation.flush(timeout:3),"rotation event \(i) remains writable")}
let retained=try! records(rotationDir)
check(rotation.status().rotations>1 && retained.count==100 && retained.contains{$0.failure.code==99},"size rolls preserve all still-retained occurrences")
check(files(rotationDir).filter{$0.key.hasSuffix(".jsonl")}.count>2,"age retention can use more than two segments")
// A partial append resumes its suffix after ENOSPC, without duplicating events.
var bad=true,criticalClock=100.0,criticalWrites=0
let retryDir=dir("critical-retry"),retry=DiagnosticCriticalJournal(directory:retryDir,clock:{criticalClock},writer:{fd,p,n in
    criticalWrites+=1
    if bad {if criticalWrites==1{return Darwin.write(fd,p,min(7,n))};errno=ENOSPC;return -1}
    return Darwin.write(fd,p,n)
})
retry.record(cause);check(!retry.flush(timeout:3),"critical partial ENOSPC is not success")
let priorWrites=criticalWrites
for _ in 0..<100{retry.record(cause)}
check(!retry.flush(timeout:3) && criticalWrites==priorWrites,"critical retry backoff holds")
bad=false;criticalClock+=61
check(retry.flush(timeout:3) && (try! records(retryDir)).count==101,"restored storage saves all 101 separate occurrences exactly once")
// A stalled kernel write cannot extend the waiting safety path indefinitely.
let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
var slowFirst=true
let slow=DiagnosticCriticalJournal(directory:dir("blocked"),writer:{fd,p,n in if slowFirst{slowFirst=false;entered.signal();release.wait()};return Darwin.write(fd,p,n)})
slow.record(cause);check(entered.wait(timeout:.now()+3) == .success,"blocked writer entered")
let began=ProcessInfo.processInfo.systemUptime
check(!slow.flush(timeout:0.05) && ProcessInfo.processInfo.systemUptime-began<0.2,"terminal wait is bounded even with blocked storage")
release.signal();check(slow.flush(timeout:3),"released writer completes later")
// Observation backlogs cannot occupy the slots reserved for real failures.
let held=DispatchSemaphore(value:0),continueWrite=DispatchSemaphore(value:0)
var firstWrite=true
let reserveDir=dir("reserved-slots"),reserved=DiagnosticCriticalJournal(directory:reserveDir,writer:{fd,p,n in
    if firstWrite{firstWrite=false;held.signal();continueWrite.wait()};return Darwin.write(fd,p,n)
})
reserved.record(.policy(.incidentTrigger,8),observation:true)
check(held.wait(timeout:.now()+3) == .success,"observation writer held")
for _ in 0..<300{reserved.record(.policy(.incidentTrigger,8),observation:true)}
for _ in 0..<20{reserved.record(cause)}
check(reserved.status().droppedObservations>0 && reserved.status().pendingErrors<=20 && reserved.status().droppedErrors==0,"observation flood cannot consume error slots")
continueWrite.signal();_ = reserved.flush(timeout:3)
check((try! records(reserveDir)).filter{$0.failure==cause}.count==20,"all real errors survive observation overload")
// Minimum-only records are reviewable and included unchanged in the archive.
let reviewDir=dir("review-source"),reviewJournal=DiagnosticCriticalJournal(directory:reviewDir)
reviewJournal.record(cause);check(reviewJournal.flush(timeout:3),"minimum-only fixture saved")
let reviewStore=DiagnosticLogStore(directory:reviewDir,policy:.incidentDefault,persistentOwnership:true)
check(reviewStore.verifyReadiness().ready,"minimum-only store ownership")
let export=root.appendingPathComponent("export")
try! reviewStore.copyExportSnapshot(to:export,reviewMetadata:true)
let review=try! DiagnosticReviewSnapshot(directory:export)
check(review.incidents.isEmpty && review.hasRecords && review.critical != nil,"review supports minimum-only evidence")
let environment=DiagnosticReviewEnvironment(appVersion:"0",build:"test",macOSVersion:"test",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:false,hanjaKeyEnabled:false,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:false,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
let exportFiles=try! review.files(selected:[],environment:environment)
let criticalFile=exportFiles.first{DiagnosticCriticalJournal.exportedName($0.path)}!
let original=files(reviewDir).first{$0.key.hasSuffix("."+criticalFile.path)}!.value
check(try criticalFile.data==original,"minimum original bytes preserved by review/export")
let linkDir=dir("critical-link"),sentinel=root.appendingPathComponent("sentinel")
try! Data("preserve".utf8).write(to:sentinel)
try! fm.createSymbolicLink(at:linkDir.appendingPathComponent(DiagnosticCriticalJournal.laneDirectories[0]),withDestinationURL:sentinel)
let linked=DiagnosticCriticalJournal(directory:linkDir)
linked.record(cause);check(!linked.flush(timeout:3),"critical symlink is refused")
check(try! Data(contentsOf:sentinel)==Data("preserve".utf8),"foreign symlink target unchanged")
// Turning detailed input observation OFF must not turn off failure evidence.
let offDir=dir("details-off"),offJournal=DiagnosticCriticalJournal(directory:offDir)
OperationalDiagnostics.shared.installJournal(offJournal)
let offTrace=InputIncidentTrace(secureInput:{false},destination:offDir,initiallyEnabled:false,persistentOwnership:true)
offTrace.recoveryFailure(rollback:true,site:"attemptRollback",reason:"rollback_text_changed")
offTrace.recoveryFailure(rollback:true,site:"attemptRollback",reason:"rollback_text_changed")
offTrace.flush();check(offJournal.flush(timeout:3),"failure minimums persist with details OFF")
let offEvents=(try! records(offDir)).filter{$0.failure.stage == .recoveryFailure}
check(offEvents.count==2 && offEvents.allSatisfy{$0.context==nil},"two separate failures retained without collecting disabled input context")
let corruptDir=dir("corrupt-header"),corruptFile=corruptDir.appendingPathComponent(DiagnosticCriticalJournal.filenames[0])
let corruptBytes=Data("{\"schema\":2,\"generation\":9223372036854775807}\n".utf8)
try! corruptBytes.write(to:corruptFile);try! fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:corruptFile.path)
let corruptJournal=DiagnosticCriticalJournal(directory:corruptDir)
corruptJournal.record(cause)
check(corruptJournal.flush(timeout:3),"a corrupt legacy file does not block the independent new error lane")
check(try! Data(contentsOf:corruptFile)==corruptBytes,"corrupt journal evidence remains unchanged")
// A crash-truncated tail remains as explicit incomplete evidence; new lines work.
let tailDir=dir("truncated-tail")
let header=try! JSONEncoder().encode(DiagnosticCriticalJournal.Header(schema:2,generation:1))
let tail=tailDir.appendingPathComponent(DiagnosticCriticalJournal.filenames[0])
try! (header+Data("\n{\"run\":\"unfinished".utf8)).write(to:tail)
try! fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:tail.path)
let tailJournal=DiagnosticCriticalJournal(directory:tailDir)
tailJournal.record(cause);check(tailJournal.flush(timeout:3),"new record follows a preserved partial tail")
let decoded=DiagnosticCriticalJournal.decode(try! Data(contentsOf:tail))!
check(decoded.incomplete==1 && decoded.events.isEmpty && (try! records(tailDir)).count==1,"legacy partial bytes preserved and new occurrence is separate")
// The real trace continues minimum records after the detailed event quota;
// skipped post phases must not keep spending ledger/status/index credit.
let quotaDir=root.appendingPathComponent("trace-quota"),quotaJournal=DiagnosticCriticalJournal(directory:quotaDir)
OperationalDiagnostics.shared.installJournal(quotaJournal)
let quotaTrace=InputIncidentTrace(secureInput:{false},destination:quotaDir,persistentOwnership:true,capacity:1,clock:{100.0})
quotaTrace.flush()
for _ in 0..<48{quotaTrace.captureForTest(.axDelay);quotaTrace.flush();quotaTrace.finishCaptureWindowsForTest();quotaTrace.flush()}
check(quotaJournal.flush(timeout:10),"first 48 trace events acknowledged")
let detailedBefore=files(quotaDir).filter{!$0.key.hasPrefix(".critical")}
for _ in 0..<100{quotaTrace.captureForTest(.axDelay);quotaTrace.flush();quotaTrace.finishCaptureWindowsForTest();quotaTrace.flush()}
check(quotaJournal.flush(timeout:10),"minimums continue after 48-event cap")
check(files(quotaDir).keys.filter{$0.hasSuffix(".hqdiag") && (try? DiagnosticSharedStore.readHeader(quotaDir.appendingPathComponent($0)).0.role) != 1}.count==296,"all 148 incidents keep both detailed phases without hourly count cutoff")
let quotaEvents=try! records(quotaDir)
let requested=quotaEvents.filter{$0.failure.stage == .incidentTrigger && $0.context?.trace==quotaEvents.first{$0.failure.stage == .incidentTrigger}?.context?.trace}
check(requested.count==148 && Set(requested.compactMap{$0.context?.requestID}).count==148,"148 same-time requests have distinct incident coordinates")
check(quotaEvents.filter{$0.failure.stage == .captureDisposition && $0.failure.code==1}.count==296,"each pre and post success has a linked disposition")
quotaTrace.stopAndFlush()
// Both writers may first open the same root concurrently. EEXIST from mkdir
// is revalidated as a private directory, not latched as a permanent failure.
for i in 0..<40 {
    let directory=root.appendingPathComponent("first-use-\(i)")
    let j=DiagnosticCriticalJournal(directory:directory)
    let store=DiagnosticLogStore(directory:directory,policy:.incidentDefault,persistentOwnership:true,writeBudget:DiagnosticWriteBudget())
    j.record(cause)
    check(store.verifyReadiness().ready,"concurrent first-use detail writer \(i)")
    check(j.flush(timeout:3),"concurrent first-use minimum writer \(i)")
}
// Real process death, not an in-process simulated callback. No TCC/UI/input.
for mode in ["--kill-child","--exit-child"] {
    let childDir=dir(mode.dropFirst(2).description),process=Process(),pipe=Pipe()
    process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=[mode]
    process.currentDirectoryURL=childDir;process.standardOutput=pipe
    try! process.run()
    if mode=="--kill-child" {
        let ready=pipe.fileHandleForReading.availableData
        check(String(data:ready,encoding:.utf8)?.contains("READY")==true,"child acknowledged durable pre before kill")
        kill(process.processIdentifier,SIGKILL)
    }
    process.waitUntilExit()
    let source=childDir.appendingPathComponent("source")
    if mode=="--kill-child" {
        check(process.terminationReason == .uncaughtSignal && process.terminationStatus==SIGKILL,"child actually SIGKILLed")
        let names=files(source).keys.filter{$0.hasSuffix(".hqdiag") && (try? DiagnosticSharedStore.readHeader(source.appendingPathComponent($0)).0.role) != 1}
        check(names.count==1 && (try! DiagnosticSharedStore.readHeader(source.appendingPathComponent(names.first!))).0.phase==0,"pre survives SIGKILL before post window")
        let resumed=DiagnosticSharedStore(directory:source)
        check(resumed.prepare(),"durable shared pre can be reopened after crash")
        check((try! records(source)).contains{$0.failure==cause},"critical cause survives SIGKILL")
    }else {
        check(process.terminationStatus==72,"real permission-loss exit code unchanged")
        check((try! records(source)).contains{$0.failure.stage == .termination && $0.failure.code==72},"terminal reason saved before _exit")
    }
}
print("PASS \(checks) durability, transient recovery, critical evidence, bounded exit and real subprocess death checks; no app/TCC/keys")
