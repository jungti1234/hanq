import Foundation
import Darwin

setbuf(stdout,nil)
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if (try? value()) != true{fputs("FAIL pending recovery: \(message)\n",stderr);exit(1)};print("PASS \(message)")}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
func directory(_ name:String)->URL{let u=root.appendingPathComponent(name);try! fm.createDirectory(at:u,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return u}
func frame(_ n:Int)->InputIncidentTrace.Frame{.init(sequence:n,milliseconds:n,lane:.main,kind:.context,event:0,edge:0,category:0,inputOrigin:0,consumed:false,durationMicros:0,count:0,selected:false,field:0,decisionTiming:nil,observationTiming:nil)}
let packets=try (1...100).map{try DiagnosticPackedFrame(frame($0))},run=UUID().uuidString
let environment=DiagnosticReviewEnvironment(appVersion:"0",build:"433",macOSVersion:"test",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:false,hanjaKeyEnabled:false,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
func exported(_ store:DiagnosticSharedStore,_ name:String)throws->DiagnosticReviewSnapshot {
 let dest=directory(name),pending=try store.copyReviewSnapshot(into:dest,request:DiagnosticSnapshotRequest())
 try DiagnosticSharedStore.writeExport(try JSONEncoder().encode(pending),to:dest.appendingPathComponent("pending-export.json"))
 try DiagnosticSharedStore.writeExport(Data("{}".utf8),to:dest.appendingPathComponent("review-dates.json"))
 try DiagnosticSharedStore.writeExport(Data("{\"schema\":1,\"status\":{}}".utf8),to:dest.appendingPathComponent("storage-status.json"))
 return try DiagnosticReviewSnapshot(directory:dest)
}
func input(_ incident:Int,_ phase:Int=0)->DiagnosticSharedStore.Input{.init(metadata:.object(["schema":.integer(1),"build":.string("433")]),frames:packets,run:run,incident:incident,phase:phase,trigger:1,milliseconds:1000000)}
func names(_ u:URL)->[String]{(try! fm.contentsOfDirectory(atPath:u.path)).filter{DiagnosticSharedStore.validName($0) && (try? DiagnosticSharedStore.readHeader(u.appendingPathComponent($0)).0.role) != 1}}
for code in [EACCES,EPERM,EROFS] {
 var fail=false,clock=100.0,calls=0
 let store=DiagnosticSharedStore(directory:directory("retry-\(code)"),preserve:true,retryClock:{clock},writer:{fd,p,n in calls+=1;if fail{errno=code;return -1};return Darwin.write(fd,p,n)})
 check(store.submit(input(1)),"baseline before recoverable error \(code)")
 let originals=try names(store.directory).map{try Data(contentsOf:store.directory.appendingPathComponent($0))}
 fail=true;check(!store.submit(input(2)),"capture queues at error \(code)")
 check(store.canRetry && store.storageIssue(retryScheduled:true)?.retry == .automatic,"actual retry remains scheduled \(code)")
 let before=calls;for _ in 0..<100{_ = store.drain()};check(calls==before,"backoff avoids repeated writes \(code)")
 fail=false;clock+=61
 check(store.drain() && store.stats.pendingBytes==0 && store.stats.saved==2,"same writer drains after recovery \(code)")
 check(store.stats.lastFailure==nil && store.stats.failures==1,"current error clears and failure history remains \(code)")
 for name in names(store.directory){check(try DiagnosticSharedStore.expand(name,in:store.directory).frames.map(\.sequence)==Array(1...100),"recovered frames retain full order")}
 check(try names(store.directory).map{try Data(contentsOf:store.directory.appendingPathComponent($0))}.contains(originals[0]),"published baseline remains byte-identical")
 let healthyCalls=calls;for _ in 0..<100{_ = store.drain()};check(calls==healthyCalls,"no healthy-state probe writes \(code)")
}
// Real filesystem permission denial, not just an injected write errno.
var deniedClock=100.0
let denied=DiagnosticSharedStore(directory:directory("actual-denied"),preserve:true,retryClock:{deniedClock})
check(denied.submit(input(1)),"real permission fixture stores pre")
check(chmod(denied.directory.path,0)==0,"only owned test directory is denied")
check(!denied.submit(input(1,1)) && denied.stats.lastFailure?.underlyingPOSIX==Int(EACCES),"real EACCES leaves the post pending")
let deniedSnapshot=try exported(denied,"denied-memory-copy")
check(deniedSnapshot.incidents.count==1 && deniedSnapshot.incidents[0].originals[1] != nil && deniedSnapshot.incidents[0].originals[0]==nil,"unreadable disk does not prevent exporting the pending post")
check(deniedSnapshot.pendingExport?.unavailableSources == ["shared"],"unreadable original is explicitly marked, never claimed included")
let rescuedName=deniedSnapshot.incidents[0].originals[1]!.filename
check(try DiagnosticSharedStore.expand(rescuedName,in:deniedSnapshot.directory).frames.map(\.sequence)==Array(1...100),"memory rescue restores exact packed frame order")
check(denied.stats.pendingBytes>0 && denied.stats.saved==1 && denied.stats.lastFailure != nil,"successful export neither clears original failure nor drains pending input")
check(chmod(denied.directory.path,0o700)==0,"owned test directory permission restored")
deniedClock+=61
check(denied.drain() && denied.stats.saved==2 && denied.stats.pendingBytes==0,"same process saves both phases after chmod recovery")
let healthy=try exported(denied,"healthy-copy")
let healthyFiles=try healthy.files(selected:Set(healthy.incidents.map(\.id)),environment:environment)
let healthyRows=DiagnosticReviewPreviewRow.make(healthyFiles)
check(healthyFiles.contains{$0.path=="pending-export.json" && $0.archiveOnly},"empty pending metadata remains in ZIP without a visible warning row")
check(!healthyRows.contains{if case .file(let file)=$0{return file.path=="pending-export.json"};return false},"healthy export hides empty memory-copy notice")
let dependencies=healthyFiles.filter(\.sharedDependency)
check(!dependencies.isEmpty,"shared original dependencies exist")
let groups=healthyRows.filter{!$0.filenames.isEmpty}
check(groups.count==1 && Set(groups[0].filenames)==Set(dependencies.map(\.path)),"all shared originals appear in exactly one preview group")
check(!groups[0].document().readableText.contains(".hqdiag") && groups[0].document(showFilenames:true).readableText.contains(dependencies[0].path),"dependency filenames are collapsed until requested")
let rescuedFiles=try deniedSnapshot.files(selected:Set(deniedSnapshot.incidents.map(\.id)),environment:environment)
let rescuedNotice=rescuedFiles.first{$0.path=="pending-export.json"}!
check(!rescuedNotice.archiveOnly && rescuedNotice.readableText.contains("이번 ZIP에 포함했습니다") && rescuedNotice.readableText.contains("확인할 수 없습니다"),"real memory rescue explains inclusion without inventing retry state")
check(rescuedFiles[0].readableText.contains("읽을 수 없어") && rescuedNotice.readableText.contains("빠진 자료"),"unavailable source warning survives grouping and conditional notices")
// A filesystem problem must never erase the ownership/tampering guard.
for replaceDirectory in [false,true] {
 var fail=false,clock=100.0
 let path=directory(replaceDirectory ? "replacement":"tamper")
 let store=DiagnosticSharedStore(directory:path,preserve:true,retryClock:{clock},writer:{fd,p,n in if fail{errno=EACCES;return -1};return Darwin.write(fd,p,n)})
 check(store.submit(input(1)),"unsafe recovery fixture stores baseline")
 fail=true;check(!store.submit(input(2)),"unsafe recovery fixture queues a capture")
 if replaceDirectory {
  try fm.moveItem(at:store.directory,to:path.appendingPathComponent("original-preserved"))
  try fm.createDirectory(at:store.directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
 }else{
  let file=store.directory.appendingPathComponent(names(store.directory)[0]);let h=try FileHandle(forWritingTo:file);try h.seekToEnd();try h.write(contentsOf:Data([0]));try h.close()
 }
 fail=false;clock+=61
 check(!store.drain() && !store.canRetry,"replacement or mutation remains blocked \(replaceDirectory)")
 check(store.stats.lastFailure?.domain == .policy && store.stats.pendingBytes>0 && store.stats.saved==1,"unsafe recovery retains queued evidence and reports policy failure")
 let rescue=try exported(store,replaceDirectory ? "replacement-export":"tamper-export")
 check(rescue.incidents.count==1 && rescue.incidents[0].number==2,"unsafe original is excluded while owned memory remains exportable")
 check(!store.canRetry && store.stats.pendingBytes>0,"export cannot bypass stopped ownership guard")
}
// More than five pending incidents must have an explicit all-pending route;
// ordinary user selection retains its existing five-incident limit.
var floodFail=false
let flood=DiagnosticSharedStore(directory:directory("pending-many"),preserve:true,writer:{fd,p,n in if floodFail{errno=ENOSPC;return -1};return Darwin.write(fd,p,n)})
check(flood.prepare(),"many-pending store prepared")
floodFail=true
for i in 1...8{let value=DiagnosticSharedStore.Input(metadata:.object(["schema":.integer(1)]),frames:packets,run:run,incident:i,phase:0,trigger:2,milliseconds:1000000);_ = flood.submit(value)}
let many=try exported(flood,"many-copy"),ids=Set(many.incidents.map(\.id))
check(many.incidents.count==8 && many.pendingIncidentIDs==ids,"all eight pending incidents are listed")
do{_ = try many.files(selected:ids,environment:environment);check(false,"ordinary selection rejects eight")}
catch DiagnosticReviewError.tooManySelections{check(true,"ordinary selection retains five-record limit")}
let files=try many.files(selected:ids,environment:environment,allPending:true),archive=try DiagnosticReviewArchive(files:files)
let exportedZip=root.appendingPathComponent("pending-all.zip");try archive.save(to:exportedZip)
let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");unzip.arguments=["-x","-k",exportedZip.path,root.appendingPathComponent("pending-restored").path];try unzip.run();unzip.waitUntilExit()
check(unzip.terminationStatus==0,"all-pending ZIP restores")
for file in files{check(try Data(contentsOf:root.appendingPathComponent("pending-restored/HanQ-Diagnostics/"+file.path))==file.data,"all-pending ZIP byte match \(file.path)")}
for incident in many.incidents {check(try DiagnosticSharedStore.expand(incident.originals[0]!.filename,in:root.appendingPathComponent("pending-restored/HanQ-Diagnostics")).frames.map(\.sequence)==Array(1...100),"ZIP decodes every pending capture")}
check(flood.stats.saved==0 && flood.stats.pendingBytes>0,"ZIP export leaves automatic retry queue intact")
for retry in [DiagnosticStorageIssue.Retry.automatic,.stopped,.notScheduled,.unknown] {
 let retryDirectory=root.appendingPathComponent("retry-copy-\(retry.rawValue)")
 try fm.copyItem(at:many.directory,to:retryDirectory)
 let issue=DiagnosticStorageIssue(component:.detail,failure:.posix(.storageWrite,ENOSPC),retry:retry)
 try JSONEncoder().encode(DiagnosticStorageIssueSnapshot(issues:[issue])).write(to:retryDirectory.appendingPathComponent("storage-issues.json"))
 try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:retryDirectory.appendingPathComponent("storage-issues.json").path)
 let reviewed=try DiagnosticReviewSnapshot(directory:retryDirectory)
 let selectedFiles=try reviewed.files(selected:ids,environment:environment,allPending:true)
 let notice=selectedFiles.first{$0.path=="pending-export.json"}!
 check(!notice.archiveOnly && notice.readableText.contains(retry.message),"pending-copy notice uses actual retry state \(retry)")
 if retry != .automatic {check(!notice.readableText.contains(DiagnosticStorageIssue.Retry.automatic.message),"stopped or unknown retry never promises automatic saving")}
}
for code in [Int(EACCES),Int(EPERM),Int(EROFS)]{check(!DiagnosticWriteBudget.transient(.policy(.storageOwnership,code)),"policy numbers cannot become retryable errno \(code)")}
// Another record waiting in memory must not label a saved selection as rescued.
var selectionFails=false
let selectionStore=DiagnosticSharedStore(directory:directory("selection-pending"),preserve:true,writer:{fd,p,n in if selectionFails{errno=ENOSPC;return -1};return Darwin.write(fd,p,n)})
check(selectionStore.submit(input(1)),"selection fixture stores first record")
selectionFails=true;check(!selectionStore.submit(input(2)),"selection fixture queues different record")
let selectionSnapshot=try exported(selectionStore,"selection-copy")
let savedID=selectionSnapshot.incidents.first{$0.number==1}!.id
let savedSelection=try selectionSnapshot.files(selected:[savedID],environment:environment)
check(savedSelection.first{$0.path=="pending-export.json"}!.archiveOnly,"unselected memory capture does not create a rescue notice")
check(!savedSelection[0].readableText.contains("이번 ZIP에 포함했습니다"),"saved selection never claims an unrelated memory copy")
// A journal-only rescue reports that journal's retry state, not a different
// detail writer which happens to be stopped at the same time.
let journal=DiagnosticCriticalJournal(directory:directory("journal-pending"),writer:{_,_,_ in errno=ENOSPC;return -1})
journal.record(.posix(.probeLaunch,EIO));_ = journal.flush(timeout:2)
let journalCopy=directory("journal-copy")
var journalPending=DiagnosticPendingExport()
for (name,data,count) in try journal.pendingExport(){try DiagnosticSharedStore.writeExport(data,to:journalCopy.appendingPathComponent(name));journalPending.journalFiles[name]=count}
check(journalPending.journalFiles.values.reduce(0,+)==1,"one important error enters memory rescue")
try DiagnosticSharedStore.writeExport(try JSONEncoder().encode(journalPending),to:journalCopy.appendingPathComponent("pending-export.json"))
try DiagnosticSharedStore.writeExport(Data("{}".utf8),to:journalCopy.appendingPathComponent("review-dates.json"))
try DiagnosticSharedStore.writeExport(Data("{\"schema\":1,\"status\":{}}".utf8),to:journalCopy.appendingPathComponent("storage-status.json"))
let journalIssues=DiagnosticStorageIssueSnapshot(issues:[.init(component:.criticalErrors,failure:.posix(.storageWrite,ENOSPC),retry:.automatic),.init(component:.detail,failure:.policy(.storageOwnership,1),retry:.stopped)])
try DiagnosticSharedStore.writeExport(try JSONEncoder().encode(journalIssues),to:journalCopy.appendingPathComponent("storage-issues.json"))
let journalSnapshot=try DiagnosticReviewSnapshot(directory:journalCopy)
let journalFiles=try journalSnapshot.files(selected:[],environment:environment)
let journalNotice=journalFiles.first{$0.path=="pending-export.json"}!
check(journalNotice.readableText.contains(DiagnosticStorageIssue.Retry.automatic.message) && !journalNotice.readableText.contains(DiagnosticStorageIssue.Retry.stopped.message),"journal-only rescue shows only its actual retry state")
let rescuedJournal=journalFiles.first{journalPending.journalFiles[$0.path] != nil}!
check(try DiagnosticCriticalJournal.decode(rescuedJournal.data)?.events.count==1,"important error original remains included with the notice")
func wait(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(5);while !predicate() && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))};check(predicate(),"asynchronous completion")}
let emptyQuit=DiagnosticQuitState(detailPhases:0,errors:0,observations:0),pendingQuit=DiagnosticQuitState(detailPhases:2,errors:1,observations:1)
for choice in [DiagnosticQuitCoordinator.Choice.cancel,.export,.discard] {
 var replies:[Bool]=[],resumed=0,exports=0,prompts=0
 let coordinator=DiagnosticQuitCoordinator(prepare:{$0(pendingQuit)},resume:{resumed+=1},decide:{state,reply in prompts+=1;check(state==pendingQuit,"quit dialog receives actual counts");reply(choice)},exportPending:{exports+=1})
 check(coordinator.request{replies.append($0)},"first termination request starts")
 check(!coordinator.request{_ in check(false,"duplicate reply")},"duplicate termination cannot start a second save or dialog")
 wait{!replies.isEmpty}
 check(prompts==1 && replies==[choice == .discard],"only explicit discard permits termination")
 check(resumed==(choice == .discard ? 0:1) && exports==(choice == .export ? 1:0),"cancel/export restores collection and export does not imply exit")
}
var late:((DiagnosticQuitState)->Void)?,timeoutReplies:[Bool]=[],unknownPrompt=false
let timeoutQuit=DiagnosticQuitCoordinator(prepare:{late=$0},resume:{},decide:{state,reply in unknownPrompt=state==nil;reply(.cancel)},exportPending:{})
_ = timeoutQuit.request(timeout:0.03){timeoutReplies.append($0)};wait{!timeoutReplies.isEmpty}
late?(emptyQuit);RunLoop.current.run(until:Date().addingTimeInterval(0.05))
check(unknownPrompt && timeoutReplies == [false],"stalled writer is unknown and late completion cannot undo cancel")
var cleanReplies:[Bool]=[]
let cleanQuit=DiagnosticQuitCoordinator(prepare:{$0(emptyQuit)},resume:{check(false,"unexpected resume")},decide:{_,_ in check(false,"healthy quit must not warn")},exportPending:{})
_ = cleanQuit.request{cleanReplies.append($0)};wait{!cleanReplies.isEmpty};check(cleanReplies == [true],"healthy final save permits normal quit without a prompt")
let quitRoot=directory("quit-trace")
final class QuitWriter {
 let lock=NSLock();var fail=false
 func set(_ value:Bool){lock.lock();fail=value;lock.unlock()}
 func write(_ fd:Int32,_ p:UnsafeRawPointer?,_ n:Int)->Int{lock.lock();defer{lock.unlock()};if fail{errno=ENOSPC;return -1};return Darwin.write(fd,p,n)}
}
let quitWriter=QuitWriter(),quitJournal=DiagnosticCriticalJournal(directory:quitRoot)
OperationalDiagnostics.shared.installJournal(quitJournal)
let quitTrace=InputIncidentTrace(secureInput:{false},destination:quitRoot,sharedWriter:quitWriter.write)
quitTrace.flush();quitTrace.mark();quitTrace.flush();quitWriter.set(true)
var quitState:DiagnosticQuitState?
quitTrace.prepareForQuit{quitState=$0};wait{quitState != nil}
check(quitState!.detailPhases==1 && quitTrace.sharedStatsForTest()?.saved==1,"quit preparation closes and attempts the pending post")
let submittedAtQuit=quitTrace.sharedStatsForTest()!.submitted
quitTrace.mark();quitTrace.flush()
check(quitTrace.sharedStatsForTest()!.submitted==submittedAtQuit,"quit decision freezes new capture admission, without clearing existing queue")
quitTrace.cancelQuitPreparation();quitWriter.set(false)
quitTrace.mark();quitTrace.flush();check(quitTrace.sharedStatsForTest()!.submitted>submittedAtQuit,"cancel resumes new capture admission")
quitState=nil;quitTrace.prepareForQuit{quitState=$0};wait{quitState != nil}
check(quitState!.detailPhases==0 && quitTrace.sharedStatsForTest()!.saved==4,"final retry bypasses backoff once and saves both complete records")
quitTrace.stopAfterQuitPreparation()
print("Pending recovery checks: \(checks)")
