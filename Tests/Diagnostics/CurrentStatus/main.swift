import Foundation
import Darwin

var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ text:String){checks+=1;if (try? value()) != true{fputs("FAIL: \(text)\n",stderr);exit(1)}}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
func settle(){RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
func wait(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(8);while !predicate() && Date()<deadline{settle()};check(predicate(),"asynchronous state completes")}
func health(_ trace:InputIncidentTrace)->DiagnosticStorageHealth{var result:DiagnosticStorageHealth?;trace.storageHealth{result=$0};trace.flush();return result!}
final class Writer {
    private let lock=NSLock();private var failure:Int32=0;private var count=0
    func fail(_ active:Bool,code:Int32=ENOSPC){lock.lock();failure=active ? code:0;lock.unlock()}
    var calls:Int{lock.lock();defer{lock.unlock()};return count}
    func write(_ fd:Int32,_ p:UnsafeRawPointer?,_ n:Int)->Int{lock.lock();defer{lock.unlock()};count+=1;if failure != 0{errno=failure;return -1};return Darwin.write(fd,p,n)}
}
let writer=Writer(),source=root.appendingPathComponent("source")
try fm.createDirectory(at:source,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let journal=DiagnosticCriticalJournal(directory:source)
OperationalDiagnostics.shared.installJournal(journal)
let trace=InputIncidentTrace(secureInput:{false},destination:source,sharedWriter:writer.write)
trace.flush()
check(health(trace).menuMessage==nil,"healthy startup has no menu warning")
check(health(trace).manualCaptureAvailable,"healthy startup accepts a manual record")
var keyboardSamples=0
trace.keyboardSample={_,_ in keyboardSamples+=1;return nil}
let callsBeforeHealth=writer.calls
for _ in 0..<50{_ = health(trace)}
check(keyboardSamples==0 && writer.calls==callsBeforeHealth,"availability reads neither sample keyboard nor write probes")
check(DiagnosticStorageHealth(readiness:.unavailable,missingWrites:11,collectionEnabled:false,pendingWrites:true).menuMessage != nil,"OFF still reports a currently failing queued write")
check(DiagnosticStorageHealth(readiness:.ready,missingWrites:11,suppressedWrites:9).menuMessage==nil,"past omission counters remain history, not current outage")
var observed:[Bool]=[]
trace.observeStorage{trace.storageHealth{h in DispatchQueue.main.async{observed.append(h.menuMessage != nil)}}}
var outcomes:[DiagnosticManualCapture.Status]=[]
trace.mark{outcomes.append($0)};trace.flush();settle()
check(outcomes.isEmpty,"pre alone never reports manual success")
writer.fail(true);trace.finishCaptureWindowsForTest();trace.flush();settle()
check(outcomes == [.waiting],"failed post tells user pending retry, not saved or lost")
check(health(trace).menuMessage != nil,"current ENOSPC appears in menu")
check(health(trace).manualCaptureAvailable,"a current disk error alone does not disable a new manual record")
check(health(trace).menuMessage=="진단 기록을 저장할 공간이 부족합니다\n공간을 확보해 주세요 · 자동 재시도 중","space warning has cause and actual retry in two lines")
check(health(trace).activeIssues.first?.retry == .automatic,"scheduled writer reports real retry state")
check(journal.flush(timeout:5),"important error journal flushes")
let errors=try DiagnosticCriticalJournal.laneDirectories.filter{$0.contains("Errors")}.flatMap{lane in
    try fm.contentsOfDirectory(at:source.appendingPathComponent(lane),includingPropertiesForKeys:nil).filter{$0.pathExtension=="jsonl"}
}
check(!errors.isEmpty,"actual injected failure has an important error file")
let originalErrors=try errors.map{try Data(contentsOf:$0)}
let exported=root.appendingPathComponent("pending-export")
var exportResult:Result<Void,Error>?
trace.prepareExport(to:exported,reviewMetadata:true){exportResult=$0}
wait{exportResult != nil};try exportResult!.get()
check(health(trace).menuMessage != nil,"opening export cannot clear a failed pending write")
let snapshot=try DiagnosticReviewSnapshot(directory:exported)
let environment=DiagnosticReviewEnvironment(appVersion:"0",build:"test",macOSVersion:"test",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:false,hanjaKeyEnabled:false,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
let files=try snapshot.files(selected:Set(snapshot.incidents.map(\.id)),environment:environment)
let partial=try DiagnosticReviewArchive(files:files)
check(partial.warningMessage?.contains("메모리에서 복사")==true && snapshot.incidents.allSatisfy(\.complete),"pending post is rescued and paired with the unchanged pre")
check(files[0].readableText.contains("포함 범위 안내"),"same limitations are in exported summary")
let pendingState=try JSONDecoder().decode(DiagnosticStorageIssueSnapshot.self,from:Data(contentsOf:exported.appendingPathComponent("storage-issues.json")))
check(pendingState.isValid && pendingState.issues.contains{$0.component == .detail && $0.retry == .automatic},"export records the writer's actual scheduled retry")
check(partial.warningMessage?.contains("자동으로 다시 시도")==true && files[0].readableText.contains("재시도 상태는 바뀌지"),"memory export keeps the original writer's retry status")
let legacyURL=root.appendingPathComponent("legacy-pending-export")
try fm.copyItem(at:exported,to:legacyURL);try fm.removeItem(at:legacyURL.appendingPathComponent("storage-issues.json"))
try fm.removeItem(at:legacyURL.appendingPathComponent("pending-export.json"))
for capture in snapshot.pendingExport!.captures{try fm.removeItem(at:legacyURL.appendingPathComponent(capture.file))}
let legacy=try DiagnosticReviewSnapshot(directory:legacyURL)
let legacyWarning=try DiagnosticReviewArchive(files:legacy.files(selected:Set(legacy.incidents.map(\.id)),environment:environment)).warningMessage
check(legacyWarning?.contains("상태를 확인할 수 없습니다")==true && legacyWarning?.contains("자동으로 다시 시도하고")==false,"older snapshots never invent an automatic retry from pending bytes")
writer.fail(false)
wait{outcomes.last == .saved && observed.last == false}
let recovered=health(trace)
check(recovered.menuMessage==nil && recovered.missingWrites>0,"timer recovery hides active warning but retains failure count")
check(trace.sharedStatsForTest()?.pendingBytes==0,"both manual phases really finish before success")
check(try Data(contentsOf:exported.appendingPathComponent("storage-issues.json"))==files.first{$0.path=="storage-issues.json"}!.data,"an older export remains an immutable snapshot when live storage recovers")
check(journal.flush(timeout:5),"recovery facts flush")
check(try errors.map{try Data(contentsOf:$0)}==originalErrors,"recovery never erases or rewrites important error history")
let written=writer.calls
RunLoop.current.run(until:Date().addingTimeInterval(2.1))
check(writer.calls==written,"healthy retry timer adds no probe writes")
let completeURL=root.appendingPathComponent("complete-export")
exportResult=nil;trace.prepareExport(to:completeURL,reviewMetadata:true){exportResult=$0};wait{exportResult != nil};try exportResult!.get()
let complete=try DiagnosticReviewSnapshot(directory:completeURL)
let completeFiles=try complete.files(selected:Set(complete.incidents.map(\.id)),environment:environment)
check(try DiagnosticReviewArchive(files:completeFiles).warningMessage==nil,"historical retry count is not an export omission")
for original in errors {
    let name=String(original.lastPathComponent.dropFirst())
    let file=completeFiles.first{$0.path==name}!
    check(try file.data==Data(contentsOf:original),"important original bytes exported after warning disappears")
}
let recoveredArchive=try DiagnosticReviewArchive(files:completeFiles),saved=root.appendingPathComponent("recovered.zip")
try recoveredArchive.save(to:saved)
let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");unzip.arguments=["-x","-k",saved.path,root.appendingPathComponent("restored").path];try unzip.run();unzip.waitUntilExit();check(unzip.terminationStatus==0,"ZIP restores")
for file in completeFiles{check(try Data(contentsOf:root.appendingPathComponent("restored/HanQ-Diagnostics/"+file.path))==file.data,"ZIP preserves each selected original and important error")}

// Partial raw error bytes remain exportable and must be called out explicitly.
let criticalName=completeFiles.first{$0.path.hasPrefix("critical-errors-")}!.path
let copy=completeURL.appendingPathComponent(criticalName)
let handle=try FileHandle(forWritingTo:copy);try handle.seekToEnd();try handle.write(contentsOf:Data("{incomplete".utf8));try handle.close()
let damaged=try DiagnosticReviewSnapshot(directory:completeURL)
let damagedFiles=try damaged.files(selected:Set(damaged.incidents.map(\.id)),environment:environment)
check(try DiagnosticReviewArchive(files:damagedFiles).warningMessage?.contains("불완전")==true,"truncated critical row produces an export warning")
check(try damagedFiles.first{$0.path==criticalName}!.data==Data(contentsOf:copy),"truncated original is not silently cleaned")

var cancelled:[DiagnosticManualCapture.Status]=[]
trace.mark{cancelled.append($0)};trace.flush();trace.setCollectionEnabled(false);trace.flush();settle()
check(cancelled == [.incomplete],"OFF during manual post window reports incomplete")
check(health(trace).menuMessage==nil,"OFF is not a current collection failure")
check(!health(trace).manualCaptureAvailable,"OFF cannot accept a new manual record")
var disabled:[DiagnosticManualCapture.Status]=[];trace.mark{disabled.append($0)};settle()
check(disabled == [.unavailable],"disabled manual action does not silently succeed")
trace.stopAndFlush()

var admission:[DiagnosticManualCapture.Status]=[]
let busy=InputIncidentTrace(secureInput:{false},destination:nil,writer:{_ in})
for _ in 0..<4{busy.mark{admission.append($0)}};busy.flush();settle()
check(!health(busy).manualCaptureAvailable,"four active windows disable new manual admission")
busy.mark{admission.append($0)};busy.flush();settle()
check(admission == [.incomplete],"fifth concurrent manual request reports bounded admission failure")
busy.finishCaptureWindowsForTest();busy.flush();settle()
check(admission.filter{$0 == .saved}.count==4,"accepted manual requests complete independently")
check(health(busy).manualCaptureAvailable,"closing windows restores manual admission")
busy.stopAndFlush()

// Reserve the open post windows as well as the next request's two phases.
// A user may mark again during a disk outage without losing earlier requests.
let boundedRoot=root.appendingPathComponent("bounded-admission")
try fm.createDirectory(at:boundedRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let boundedWriter=Writer()
let boundedJournal=DiagnosticCriticalJournal(directory:boundedRoot)
OperationalDiagnostics.shared.installJournal(boundedJournal)
let bounded=InputIncidentTrace(secureInput:{false},destination:boundedRoot,sharedWriter:boundedWriter.write)
bounded.flush();boundedWriter.fail(true)
var boundedOutcomes:[[DiagnosticManualCapture.Status]]=[[],[]]
bounded.mark{boundedOutcomes[0].append($0)};bounded.flush();settle()
check(health(bounded).manualCaptureAvailable,"one pending request leaves space for another pre/post pair")
bounded.mark{boundedOutcomes[1].append($0)};bounded.flush();settle()
check(!health(bounded).manualCaptureAvailable,"pending phases and open posts together block another request")
bounded.finishCaptureWindowsForTest();bounded.flush();settle()
check(boundedOutcomes.allSatisfy{$0 == [.waiting]},"both accepted records wait without a rejected post")
check(bounded.sharedStatsForTest()?.rejected==0,"capacity check reserves enough queue slots for both accepted posts")
var boundedHealth:DiagnosticStorageHealth?
bounded.observeStorage{bounded.storageHealth{value in DispatchQueue.main.async{boundedHealth=value}}}
boundedWriter.fail(false)
wait{boundedOutcomes.allSatisfy{$0.last == .saved} && boundedHealth?.manualCaptureAvailable==true && boundedHealth?.menuMessage==nil}
check(bounded.sharedStatsForTest()?.saved==4 && bounded.sharedStatsForTest()?.pendingBytes==0,"automatic retry completes all four phases without another manual action")
check(bounded.sharedStatsForTest()?.failures ?? 0 > 0,"automatic recovery retains failed attempt history")
var reservation=bounded.reserveManualMemoryForTest(8*1024*1024)
check(reservation != nil && !health(bounded).manualCaptureAvailable,"full manual memory budget disables admission independently of disk health")
boundedHealth=nil;reservation=nil
wait{boundedHealth?.manualCaptureAvailable==true}
check(health(bounded).menuMessage==nil,"temporary capacity exhaustion does not invent a disk warning")
check(boundedJournal.flush(timeout:5),"bounded retry error evidence is saved")
bounded.stopAndFlush()
// The independent important-error writer can fail even while details work.
let criticalRoot=root.appendingPathComponent("critical-failure")
try fm.createDirectory(at:criticalRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let criticalWriter=Writer();criticalWriter.fail(true)
let failedJournal=DiagnosticCriticalJournal(directory:criticalRoot,writer:criticalWriter.write)
OperationalDiagnostics.shared.installJournal(failedJournal)
let journalTrace=InputIncidentTrace(secureInput:{false},destination:criticalRoot)
journalTrace.flush()
failedJournal.record(.posix(.probeLaunch,EIO))
check(!failedJournal.flush(timeout:0.05),"important error writer fails independently")
check(health(journalTrace).menuMessage != nil,"important error storage failure reaches current menu")
check(health(journalTrace).manualCaptureAvailable,"independent critical writer failure does not disable available detailed capture")
journalTrace.setCollectionEnabled(false);journalTrace.flush();settle()
check(health(journalTrace).menuMessage != nil,"OFF does not hide an active important error write failure")
let pendingCritical=root.appendingPathComponent("critical-pending-export")
var criticalExport:Result<Void,Error>?
journalTrace.prepareExport(to:pendingCritical,reviewMetadata:true){criticalExport=$0}
wait{criticalExport != nil};try criticalExport!.get()
let criticalSnapshot=try DiagnosticReviewSnapshot(directory:pendingCritical)
check(criticalSnapshot.hasRecords,"pending critical status remains reviewable without a detailed capture")
let criticalFiles=try criticalSnapshot.files(selected:[],environment:environment)
let criticalArchive=try DiagnosticReviewArchive(files:criticalFiles)
check(criticalArchive.warningMessage?.contains("메모리에 남아 있던 사건 기록")==true,"export discloses and includes unwritten important errors")
let memoryEvents=try criticalFiles.filter{$0.path.hasPrefix("critical-memory-")}.flatMap{DiagnosticCriticalJournal.decode(try $0.data)!.events}
check(memoryEvents.contains{$0.failure == .posix(.probeLaunch,EIO)},"pending important error has exact domain, code and event identity in export")
check(criticalFiles.contains{$0.path=="critical-storage-status.json"},"pending critical status accompanies the ZIP")
var criticalRecovered=false
journalTrace.observeStorage{journalTrace.storageHealth{h in DispatchQueue.main.async{if h.menuMessage==nil{criticalRecovered=true}}}}
criticalWriter.fail(false)
wait{criticalRecovered && failedJournal.status().pendingErrors==0}
check(failedJournal.status().writeFailures>0,"critical recovery retains attempted failure history")
check(health(journalTrace).menuMessage==nil,"critical recovery clears the menu while OFF")
journalTrace.stopAndFlush()

// No payload is needed to recover an initialization failure, but a read-only
// directory check alone is not sufficient evidence of recovery.
let idleWriter=Writer();idleWriter.fail(true);var retryClock=0.0
let idle=DiagnosticSharedStore(directory:root.appendingPathComponent("idle-recovery"),retryClock:{retryClock},writer:idleWriter.write)
check(!idle.prepare() && idle.stats.lastFailure != nil,"initial owner write failure is current")
let stalledCalls=idleWriter.calls
check(!idle.prepare() && idleWriter.calls==stalledCalls,"prepare obeys retry backoff")
idleWriter.fail(false);retryClock=61
check(idle.drain() && idle.hasVerifiedWrite && idle.stats.lastFailure==nil,"idle recovery requires actual successful canary write/read")
let quietCalls=idleWriter.calls
for _ in 0..<100{_ = idle.drain()}
check(idleWriter.calls==quietCalls,"healthy idle recovery introduces no recurring writes")

// A retryable failure may later turn into a non-recoverable writer error.
let blockedWriter=Writer(),blockedRoot=root.appendingPathComponent("blocked-retry")
try fm.createDirectory(at:blockedRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let blockedTrace=InputIncidentTrace(secureInput:{false},destination:blockedRoot,sharedWriter:blockedWriter.write)
blockedTrace.flush()
var blockedResults:[DiagnosticManualCapture.Status]=[]
blockedTrace.mark{blockedResults.append($0)};blockedTrace.flush();settle()
blockedWriter.fail(true);blockedTrace.finishCaptureWindowsForTest();blockedTrace.flush();settle()
check(blockedResults == [.waiting],"retryable manual failure initially waits")
blockedWriter.fail(true,code:EINVAL)
wait{blockedResults.last == .incomplete}
check(!blockedResults.contains(.saved),"a later permanent failure never reports manual success")
check(health(blockedTrace).menuMessage != nil && (blockedTrace.sharedStatsForTest()?.pendingBytes ?? 0)>0,"blocked evidence remains queued with an active storage warning")
check(!health(blockedTrace).manualCaptureAvailable,"permanently unsafe store cannot accept a new manual capture")
check(health(blockedTrace).activeIssues.first?.retry == .stopped,"permanent writer failure reports stopped, not automatic")
check(health(blockedTrace).notice?.needsDetails==true && health(blockedTrace).problemSummary?.action.contains("피드백")==true && !health(blockedTrace).detailMessage.contains("전후 상세 기록"),"stopped failure offers feedback, with no redundant single-path heading")
let blockedCalls=blockedWriter.calls
RunLoop.current.run(until:Date().addingTimeInterval(2.1))
check(blockedWriter.calls==blockedCalls,"reported stopped writer does not secretly keep retrying")
let blockedExport=root.appendingPathComponent("blocked-export")
exportResult=nil;blockedTrace.prepareExport(to:blockedExport,reviewMetadata:true){exportResult=$0};wait{exportResult != nil};try exportResult!.get()
let blockedSnapshot=try DiagnosticReviewSnapshot(directory:blockedExport)
let blockedFiles=try blockedSnapshot.files(selected:Set(blockedSnapshot.incidents.map(\.id)),environment:environment)
let blockedArchive=try DiagnosticReviewArchive(files:blockedFiles)
check(blockedArchive.warningMessage?.contains("자동 재시도가 중단")==true && blockedArchive.warningMessage?.contains("잠시 후 창")==false,"actual stopped writer's export cannot promise a later retry")
check(blockedSnapshot.incidents.allSatisfy(\.complete) && blockedFiles[0].readableText.contains("자동 재시도가 중단"),"stopped writer's memory is exported without promising resumed storage")
let blockedZip=root.appendingPathComponent("blocked.zip");try blockedArchive.save(to:blockedZip)
let blockedUnzip=Process();blockedUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");blockedUnzip.arguments=["-x","-k",blockedZip.path,root.appendingPathComponent("blocked-restored").path];try blockedUnzip.run();blockedUnzip.waitUntilExit()
check(blockedUnzip.terminationStatus==0,"stopped-state ZIP restores")
for file in blockedFiles{check(try Data(contentsOf:root.appendingPathComponent("blocked-restored/HanQ-Diagnostics/"+file.path))==file.data,"stopped export keeps originals, retry status and summary byte-for-byte")}
blockedTrace.stopAndFlush()

// Cause classification must not manufacture scheduling from an error code.
let cases:[(Int32,DiagnosticStorageIssue.Cause)]=[(ENOSPC,.space),(EDQUOT,.space),(EACCES,.permission),(EPERM,.permission),(EROFS,.readOnly),(ENOENT,.missing),(EBUSY,.busy),(EIO,.io),(EMFILE,.resources),(ENOMEM,.resources),(EINVAL,.unknown)]
for (code,cause) in cases {
    let issue=DiagnosticStorageIssue(component:.detail,failure:.posix(.storageWrite,code),retry:.unknown)
    let value=DiagnosticStorageHealth(readiness:.unavailable,missingWrites:0,issues:[issue])
    check(issue.cause==cause,"POSIX cause \(code) classified")
    check(value.notice?.message.split(separator:"\n").count==2 && value.notice?.detail.contains("미확인")==true,"unobserved retry never inferred from errno \(code)")
}
let cocoaSpace=DiagnosticStorageIssue(component:.detail,failure:.capture(NSError(domain:NSCocoaErrorDomain,code:NSFileWriteOutOfSpaceError),stage:.storageWrite),retry:.automatic)
check(cocoaSpace.cause == .space,"Cocoa no-space without nested errno is classified")
let unknown=DiagnosticStorageIssue(component:.detail,failure:.capture(NSError(domain:"test",code:17,userInfo:[NSLocalizedDescriptionKey:"DO-NOT-DISPLAY-PRIVATE-PATH"]),stage:.storageWrite),retry:.automatic)
check(!DiagnosticStorageHealth(readiness:.unavailable,missingWrites:0,issues:[unknown]).detailMessage.contains("DO-NOT-DISPLAY"),"raw NSError descriptions never reach the user detail")

// Independent journal lanes can have different causes and retry outcomes.
final class LaneWriter {
    let lock=NSLock();var errors:Int32=ENOSPC
    func setErrors(_ code:Int32){lock.lock();errors=code;lock.unlock()}
    func write(_ fd:Int32,_ p:UnsafeRawPointer?,_ n:Int)->Int {
        var name=[CChar](repeating:0,count:Int(MAXPATHLEN));precondition(fcntl(fd,F_GETPATH,&name)==0)
        let path=String(cString:name)
        lock.lock();let code=path.contains("CriticalErrors-v3") ? errors:(path.contains("CriticalObservations-v3") ? EINVAL:0);lock.unlock()
        if code != 0{errno=code;return -1};return Darwin.write(fd,p,n)
    }
}
let laneWriter=LaneWriter(),mixedRoot=root.appendingPathComponent("mixed-lanes")
try fm.createDirectory(at:mixedRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let mixedJournal=DiagnosticCriticalJournal(directory:mixedRoot,writer:laneWriter.write)
OperationalDiagnostics.shared.installJournal(mixedJournal)
let mixedTrace=InputIncidentTrace(secureInput:{false},destination:mixedRoot);mixedTrace.flush()
mixedJournal.record(.posix(.probeLaunch,EIO));mixedJournal.record(.policy(.incidentTrigger,1),observation:true)
_ = mixedJournal.flush(timeout:1)
let mixedHealth=health(mixedTrace)
check(mixedHealth.activeIssues.contains{$0.component == .criticalErrors && $0.retry == .automatic},"error lane keeps automatic retry")
check(mixedHealth.activeIssues.contains{$0.component == .observations && $0.retry == .stopped},"observation lane exposes its independent permanent stop")
check(mixedHealth.notice?.detail.contains("일부")==true && mixedHealth.notice?.needsDetails==true,"mixed failures never promise every lane retries")
check(mixedHealth.problemSummary?.retry.contains("중요 오류 기록: 자동으로")==true && mixedHealth.problemSummary?.retry.contains("사건 관측 기록: 자동 재시도가 중단")==true,"compact summary names each lane when retry states differ")
let mixedExport=root.appendingPathComponent("mixed-export")
exportResult=nil;mixedTrace.prepareExport(to:mixedExport,reviewMetadata:true){exportResult=$0};wait{exportResult != nil};try exportResult!.get()
let mixedSnapshot=try DiagnosticReviewSnapshot(directory:mixedExport)
let mixedFiles=try mixedSnapshot.files(selected:Set(mixedSnapshot.incidents.map(\.id)),environment:environment)
let mixedWarnings=try DiagnosticReviewArchive(files:mixedFiles).warningMessage ?? ""
check(mixedWarnings.contains("중요 오류 기록: 자동으로 다시 시도"),"export preserves independent error lane retries")
check(mixedWarnings.contains("사건 관측 기록: 자동 재시도가 중단"),"export preserves independently stopped observation lane")
check(mixedSnapshot.pendingExport?.journalFiles.values.reduce(0,+) ?? 0 >= 2,"both independently failed lanes supply memory copies")
var changedCause=false
mixedTrace.observeStorage{mixedTrace.storageHealth{value in DispatchQueue.main.async{changedCause=value.activeIssues.contains{$0.component == .criticalErrors && $0.cause == .io}}}}
laneWriter.setErrors(EIO)
wait{changedCause}
laneWriter.setErrors(0)
wait{mixedJournal.status().pendingErrors==0}
let remaining=health(mixedTrace)
check(remaining.activeIssues.count==1 && remaining.activeIssues.first?.component == .observations && remaining.notice != nil,"one recovered lane cannot hide another lane's active failure")
check(mixedJournal.status().writeFailures>0,"changing warning cause retains cumulative failure history")
mixedTrace.stopAndFlush()

// A real denied initialization records its preparation-stage cause.
let denied=root.appendingPathComponent("denied-preflight")
try fm.createDirectory(at:denied,withIntermediateDirectories:false,attributes:[.posixPermissions:0o500])
let deniedStore=DiagnosticLogStore(directory:denied,policy:.incidentDefault)
check(!deniedStore.verifyReadiness().ready && deniedStore.lastStorageFailure?.underlyingPOSIX==Int(EACCES),"actual denied preparation preserves the OS failure")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:denied.path)
check(deniedStore.verifyReadiness().ready && deniedStore.lastStorageFailure==nil,"successful preparation clears only the active failure")

// Preparation still retries independently when the detailed writer has stopped.
// Do not hide it merely because another storage issue already exists.
let initialDenied=root.appendingPathComponent("denied-startup")
try fm.createDirectory(at:initialDenied,withIntermediateDirectories:false,attributes:[.posixPermissions:0o500])
let initialDeniedTrace=InputIncidentTrace(secureInput:{false},destination:initialDenied)
initialDeniedTrace.flush()
let initialDeniedHealth=health(initialDeniedTrace)
check(initialDeniedHealth.activeIssues.contains{$0.component == .detail && $0.retry == .automatic},"denied startup keeps the recoverable detail retry")
check(initialDeniedHealth.activeIssues.contains{$0.component == .readiness && $0.retry == .automatic},"denied startup also exposes the independently scheduled preparation retry")
check(initialDeniedHealth.notice?.detail.contains("일부") != true,"both recoverable paths report automatic retries")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:initialDenied.path)
wait{health(initialDeniedTrace).activeIssues.isEmpty}
check(health(initialDeniedTrace).manualCaptureAvailable,"restored startup permissions recover both paths without relaunch")
initialDeniedTrace.stopAndFlush()

// A persistent ownership guard is different: a timer invocation cannot retry
// past its permanent stop. Keep the original cause while reporting that stop.
let ownershipDenied=root.appendingPathComponent("denied-ownership")
try fm.createDirectory(at:ownershipDenied,withIntermediateDirectories:false,attributes:[.posixPermissions:0o500])
let ownershipTrace=InputIncidentTrace(secureInput:{false},destination:ownershipDenied,persistentOwnership:true)
ownershipTrace.flush()
let ownershipHealth=health(ownershipTrace)
print("Ownership diagnostic fixture:", ownershipHealth.detailMessage.replacingOccurrences(of:"\n",with:" | "))
check(ownershipHealth.activeIssues.contains{$0.component == .readiness && $0.retry == .automatic && $0.cause == .permission},"permission failure while opening ownership metadata remains recoverable")
RunLoop.current.run(until:Date().addingTimeInterval(2.1))
check(health(ownershipTrace).activeIssues.contains{$0.component == .readiness && $0.retry == .automatic && $0.cause == .permission},"backoff retains the access failure's actual cause")
check(health(ownershipTrace).notice?.detail.contains("일부") != true,"all stopped stores never imply a partial automatic retry")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:ownershipDenied.path)
wait{health(ownershipTrace).activeIssues.isEmpty}
check(health(ownershipTrace).manualCaptureAvailable,"persistent ownership store safely initializes after access is restored")
ownershipTrace.stopAndFlush()

// Unknown and unscheduled states stay distinct, and invalid status metadata is
// rejected before the reviewer can display a misleading retry promise.
for retry in [DiagnosticStorageIssue.Retry.notScheduled,.unknown] {
    let issue=DiagnosticStorageIssue(component:.detail,failure:.posix(.storageWrite,EIO),retry:retry)
    let value=DiagnosticStorageHealth(readiness:.unavailable,missingWrites:0,issues:[issue])
    check(value.problemSummary?.action.contains("잠시 기다려")==false,"non-automatic issue never tells the user to just wait")
    let state=DiagnosticStorageIssueSnapshot(issues:[issue])
    check(state.exportAdvice(for:[.detail]).contains(retry == .unknown ? "확인할 수 없습니다":"예약되어 있지 않습니다"),"export keeps unknown and unscheduled states distinct")
}
let duplicate=DiagnosticStorageIssueSnapshot(issues:[cocoaSpace,cocoaSpace])
check(!duplicate.isValid,"duplicate components cannot claim conflicting retry states")
try JSONEncoder().encode(duplicate).write(to:legacyURL.appendingPathComponent("storage-issues.json"))
try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:legacyURL.appendingPathComponent("storage-issues.json").path)
do{_ = try DiagnosticReviewSnapshot(directory:legacyURL);check(false,"invalid retry status must be rejected")}catch{check(true,"invalid retry status is rejected")}

print("PASS \(checks) current warning, manual completion/retry/cancel, export omissions and exact error/ZIP preservation; synthetic I/O failures, no input hooks")
