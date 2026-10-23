import Foundation
import Darwin
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if (try? value()) != true{fputs("FAIL: \(message)\n",stderr);exit(1)}}
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("hanq-export-tests-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
func files(_ dir:URL)->[URL]{((try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? []).filter{$0.lastPathComponent.hasPrefix("incident-")}}
let policy=DiagnosticLogRetentionPolicy(maximumAutomaticFiles:64,maximumAutomaticBytes:100,maximumManualBytes:60)
let dir=root.appendingPathComponent("quotas")
let store=DiagnosticLogStore(directory:dir,policy:policy,persistentOwnership:true)
func pair(_ s:DiagnosticLogStore,_ id:Int,_ automatic:Bool,_ size:Int){for phase in 0...1{check(s.save(Data(repeating:32,count:size),incident:id,phase:phase,automatic:automatic) == .saved,"capture pair saves")}}
pair(store,1,true,20);pair(store,2,false,15);pair(store,3,false,15);pair(store,4,true,20)
check(store.usage.bytes==80 && store.manualUsage.bytes==60,"independent budgets tracked")
pair(store,5,false,15)
check(!files(dir).contains{$0.lastPathComponent.hasPrefix("incident-2-")},"oldest manual pair rotates together")
check(files(dir).filter{$0.lastPathComponent.hasPrefix("incident-1-")}.count==2,"manual rotation preserves automatic pair")
pair(store,6,true,20)
check(!files(dir).contains{$0.lastPathComponent.hasPrefix("incident-1-")},"automatic budget rotates its own oldest pair")
check(files(dir).filter{$0.lastPathComponent.hasPrefix("incident-3-")}.count==2,"automatic rotation preserves manual pair")
check(store.save(Data(repeating:32,count:61),incident:7,phase:0,automatic:false) == .limit,"oversize manual fails without pruning")
check(store.save(Data([32]),incident:7,phase:1,automatic:false) == .retired,"failed manual pre cannot create orphan post")
let restarted=DiagnosticLogStore(directory:dir,policy:policy,persistentOwnership:true)
restarted.prepareOwnership()
check(restarted.manualUsage==store.manualUsage && restarted.usage==store.usage,"both budgets resume after restart")
pair(restarted,8,false,15)
check(restarted.manualUsage.bytes==60 && restarted.usage.bytes==80,"restart rotates manual independently")
let reduced=DiagnosticLogStore(directory:dir,policy:.init(maximumAutomaticFiles:64,maximumAutomaticBytes:40,maximumManualBytes:30),persistentOwnership:true)
reduced.prepareOwnership()
check(reduced.usage.bytes==40 && reduced.manualUsage.bytes==30,"lowered budgets prune whole owned pairs")

// Upgrade a real legacy index without treating arbitrary old files as logs.
let legacyDir=root.appendingPathComponent("legacy")
let legacy=DiagnosticLogStore(directory:legacyDir,policy:.incidentDefault,persistentOwnership:true)
let run=UUID().uuidString
func payload(_ id:Int,_ phase:Int)->Data{Data("{\"schema\":1,\"trigger\":1,\"runID\":\"\(run)\",\"incident\":\(id),\"phase\":\(phase)}".utf8)}
for id in 1...3{for phase in 0...1{check(legacy.save(payload(id,phase),incident:id,phase:phase,automatic:false) == .saved,"legacy fixture")}}
let index=legacyDir.appendingPathComponent(".automatic-ownership-v1.index")
var object=try JSONSerialization.jsonObject(with:Data(contentsOf:index)) as! [String:Any]
object["schema"]=1;object.removeValue(forKey:"manualFiles")
var status=object["status"] as! [String:Any]
for key in ["maximumManualBytes","manualFiles","manualBytes"]{status.removeValue(forKey:key)}
status["maximumAutomaticBytes"]=64*1024*1024;object["status"]=status
try JSONSerialization.data(withJSONObject:object).write(to:index)
let onePair=payload(3,0).count+payload(3,1).count
let upgrade=DiagnosticLogStore(directory:legacyDir,policy:.init(maximumAutomaticFiles:64,maximumAutomaticBytes:32*1024*1024,maximumManualBytes:onePair),persistentOwnership:true)
upgrade.prepareOwnership()
check(upgrade.manualUsage.files==2 && upgrade.manualUsage.bytes==onePair,"verified legacy manuals migrate into bounded retention")
check(files(legacyDir).allSatisfy{$0.lastPathComponent.hasPrefix("incident-3-")},"legacy migration keeps latest whole manual pair")
let protected=DiagnosticLogStore(directory:root.appendingPathComponent("protected"),policy:.investigation,persistentOwnership:true)
for id in 1...40{pair(protected,id,false,20)}
let protectedNext=DiagnosticLogStore(directory:root.appendingPathComponent("protected"),policy:.investigation,persistentOwnership:true)
protectedNext.prepareOwnership();pair(protectedNext,41,true,20)
check(protectedNext.manualUsage.files==80 && protectedNext.status.evictedFiles==0,"investigation records never rotate across rebuild/restart")

// Opt-in backups preserve evicted evidence before unlinking any source.
let backedDir=root.appendingPathComponent("backed")
let archives=root.appendingPathComponent("archives")
let backed=DiagnosticLogStore(directory:backedDir,policy:.init(maximumAutomaticFiles:64,maximumAutomaticBytes:40,maximumManualBytes:40),persistentOwnership:true,archiveDirectory:archives)
pair(backed,1,true,20);pair(backed,2,false,20)
pair(backed,3,true,20);pair(backed,4,false,20)
let archiveFiles=try fm.contentsOfDirectory(at:archives,includingPropertiesForKeys:nil)
let manifests=archiveFiles.filter{$0.lastPathComponent.hasPrefix("manifest-")}
check(manifests.count==2,"both categories archive before rotation")
for manifest in manifests {
    let entries=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [[String:Any]]
    check(entries.count==2,"archive manifest preserves full event pair")
    for entry in entries {
        let data=try Data(contentsOf:archives.appendingPathComponent((entry["sha256"] as! String)+".json"))
        check(data.count==entry["bytes"] as? Int,"archived payload available for later analysis")
    }
}
let deniedArchive=root.appendingPathComponent("denied-archive")
try fm.createDirectory(at:deniedArchive,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:deniedArchive.path)
let refuse=DiagnosticLogStore(directory:root.appendingPathComponent("refuse"),policy:.init(maximumAutomaticFiles:64,maximumAutomaticBytes:40),archiveDirectory:deniedArchive)
pair(refuse,1,true,20)
check(refuse.save(Data(repeating:32,count:20),incident:2,phase:0,automatic:true) == .unavailable,"backup failure stops pruning and new growth")
check(refuse.usage.bytes==40,"failed archive leaves original pair intact")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:deniedArchive.path)

// Actual trace accepts >32 manual requests, while preserving pending-work limits.
let traceDir=root.appendingPathComponent("trace")
let trace=InputIncidentTrace(destination:traceDir,persistentOwnership:true)
for _ in 0..<40{trace.mark();trace.flush();trace.finishCaptureWindowsForTest();trace.flush()}
check(files(traceDir).count==80,"forty manual events produce eighty files without lifetime cap")
let extra=traceDir.appendingPathComponent("unrelated.txt");try Data("private non-log".utf8).write(to:extra)
let desktop=root.appendingPathComponent("Desktop")
try fm.createDirectory(at:desktop,withIntermediateDirectories:false)
func export(_ trace:InputIncidentTrace,_ destination:URL)throws->URL{
    let done=DispatchSemaphore(value:0)
    var result:Result<URL,Error>?
    DiagnosticLogExport.export(trace,to:destination,date:Date(timeIntervalSince1970:1792670400)){result=$0;done.signal()}
    check(done.wait(timeout:.now()+20) == .success,"export finishes asynchronously")
    return try result!.get()
}
// Leave this last manual post pending: export must wait for it.
trace.mark();trace.flush()
let archive=try export(trace,desktop)
check(archive.lastPathComponent.range(of:"^HanQ-Diagnostics-[0-9]{8}-[0-9]{6}\\.zip$",options:.regularExpression) != nil,"English timestamp ZIP filename")
let original=try Data(contentsOf:archive)
let second=try export(trace,desktop)
check(try second.lastPathComponent.hasSuffix("-2.zip") && Data(contentsOf:archive)==original,"same timestamp never overwrites previous export")
let extract=root.appendingPathComponent("extracted")
let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");unzip.arguments=["-x","-k",archive.path,extract.path]
try unzip.run();unzip.waitUntilExit();check(unzip.terminationStatus==0,"ZIP extracts successfully")
let exported=extract.appendingPathComponent("HanQ-Diagnostics")
check(files(exported).count==82,"export includes pending latest before/after pair")
check(!fm.fileExists(atPath:exported.appendingPathComponent("unrelated.txt").path),"export excludes unrelated files and ownership index")
for file in files(exported){check(try Data(contentsOf:file)==Data(contentsOf:traceDir.appendingPathComponent(file.lastPathComponent)),"exported contents match stable source snapshot")}
check(try RecorderStorageDocument.decode(Data(contentsOf:exported.appendingPathComponent("storage-status.json"))).status.valid,"export storage status strict decode")
check(try Data(contentsOf:extra)==Data("private non-log".utf8),"original unrelated evidence unchanged")
trace.stopAndFlush()
let offArchive=try export(trace,desktop)
check(fm.fileExists(atPath:offArchive.path),"existing logs export while collection OFF")
let empty=InputIncidentTrace(destination:root.appendingPathComponent("empty"),initiallyEnabled:false,persistentOwnership:true)
do{_ = try export(empty,desktop);check(false,"empty export must fail")}catch{check(error is DiagnosticLogExport.Failure,"no-log result is explicit")}
do{_ = try export(trace,root.appendingPathComponent("missing/Desktop"));check(false,"unwritable export must fail")}catch{check(true,"destination failure reported")}
check(try fm.contentsOfDirectory(atPath:desktop.path).allSatisfy{!$0.hasPrefix(".")},"no partial Desktop archives remain")
print("PASS \(checks) independent quotas, migration, protected investigations, >32 manual records and asynchronous ZIP export; no global inputs")
