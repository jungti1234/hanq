import Foundation
import Darwin

var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if (try? value()) != true{fputs("FAIL: \(message)\n",stderr);exit(1)}}
let fm=FileManager.default
let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-persistence-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
func files(_ url:URL)->[URL]{((try? fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}}
func payload(_ automatic:Bool)->Data{Data("{\"schema\":1,\"trigger\":\(automatic ? 2:1)}".utf8)}
func group(_ store:DiagnosticLogStore,_ id:Int){
    check(store.save(payload(true),incident:id,phase:0,automatic:true) == .saved,"persistent pre saves")
    check(store.save(payload(true),incident:id,phase:1,automatic:true) == .saved,"persistent post saves")
}
let suite="hanq.persistence.tests."+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer{defaults.removePersistentDomain(forName:suite)}
let arguments=["HanQ"]
check(!InputIncidentPreferences.launch(arguments:arguments,defaults:defaults).enabled,"fresh installation defaults OFF")
defaults.set(true,forKey:InputIncidentPreferences.key)
let saved=InputIncidentPreferences.launch(arguments:arguments,defaults:UserDefaults(suiteName:suite)!)
check(saved.enabled && saved.persistent && saved.directory==InputIncidentPreferences.defaultDirectory,"saved ON resumes without launch arguments")
let cli=InputIncidentPreferences.launch(arguments:["HanQ","--diagnose-input-incidents",root.path],defaults:defaults)
check(cli.enabled && !cli.persistent && cli.directory.path==root.path,"developer CLI uses isolated legacy ownership")
check(cli.preserve,"developer investigation logs are exempt from normal rotation")
let preserved=InputIncidentPreferences.launch(arguments:["HanQ","--preserve-input-incidents",root.path],defaults:defaults)
check(preserved.enabled && preserved.persistent && preserved.preserve,"explicit permanent investigation directory resumes without deletion")
check(InputIncidentPreferences.launch(arguments:["HanQ","--diagnose-input-incidents","--other"],defaults:defaults).persistent,"invalid CLI falls back to saved preference")
defaults.set(false,forKey:InputIncidentPreferences.key)
check(!InputIncidentPreferences.launch(arguments:arguments,defaults:UserDefaults(suiteName:suite)!).enabled,"saved OFF also resumes")
check(InputIncidentPreferences.launch(arguments:["HanQ","--diagnose-input-incidents",root.path],defaults:defaults).enabled && !defaults.bool(forKey:InputIncidentPreferences.key),"CLI override never changes saved preference")

let directory=root.appendingPathComponent("cohort")
let policy=DiagnosticLogRetentionPolicy(maximumAutomaticFiles:4,maximumAutomaticBytes:1000)
let first=DiagnosticLogStore(directory:directory,policy:policy,persistentOwnership:true)
group(first,1)
check(first.save(payload(false),incident:2,phase:0,automatic:false) == .saved,"manual saves beside managed automatic files")
let manual=files(directory).first{$0.lastPathComponent.hasPrefix("incident-2-")}!
let manualData=try Data(contentsOf:manual)
group(first,3)
let statusNames=try fm.contentsOfDirectory(atPath:directory.path).filter{$0.hasSuffix(".status")}
let second=DiagnosticLogStore(directory:directory,policy:policy,persistentOwnership:true)
second.prepareOwnership()
check(second.lastCaptureIncident==3 && second.usage.files==4,"restart restores capture seed and owned budget")
check(second.status.saved==5,"completed storage counters resume")
group(second,4)
check(second.usage.files==4 && !files(directory).contains{$0.lastPathComponent.hasPrefix("incident-1-")},"restart rotates oldest owned pair within original file limit")
check(try Data(contentsOf:manual)==manualData,"manual survives restart rotation")
check(try fm.contentsOfDirectory(atPath:directory.path).filter{$0.hasSuffix(".status")}==statusNames,"restart reuses one bounded status companion")
let third=DiagnosticLogStore(directory:directory,policy:policy,persistentOwnership:true)
third.prepareOwnership()
check(third.status.saved==7 && third.status.evictedGroups==1 && third.usage==second.usage,"counters and usage survive a second restart")
let index=directory.appendingPathComponent(".automatic-ownership-v1.index")
check(try Data(contentsOf:index).count<=128*1024,"ownership metadata bounded")
check((try fm.attributesOfItem(atPath:index.path)[.posixPermissions] as! NSNumber).intValue==0o600,"ownership metadata private")
let byteDirectory=root.appendingPathComponent("bytes")
let bytePolicy=DiagnosticLogRetentionPolicy(maximumAutomaticFiles:100,maximumAutomaticBytes:100)
let byteFirst=DiagnosticLogStore(directory:byteDirectory,policy:bytePolicy,persistentOwnership:true)
group(byteFirst,1);group(byteFirst,2)
let byteNext=DiagnosticLogStore(directory:byteDirectory,policy:bytePolicy,persistentOwnership:true)
group(byteNext,3)
check(byteNext.usage.bytes<=100 && byteNext.status.evictedGroups>0,"byte budget resumes independently of count")

// Ambiguous evidence is preserved and cannot authorize a growing new cohort.
let orphanDir=root.appendingPathComponent("orphan")
let original=DiagnosticLogStore(directory:orphanDir,policy:policy,persistentOwnership:true)
group(original,1)
let orphan=orphanDir.appendingPathComponent("incident-2-0-"+UUID().uuidString+".json")
try payload(true).write(to:orphan);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:orphan.path)
let orphanNext=DiagnosticLogStore(directory:orphanDir,policy:policy,persistentOwnership:true)
check(orphanNext.save(payload(true),incident:3,phase:0,automatic:true) == .unavailable,"interrupted unindexed automatic publication refuses further growth")
check(try Data(contentsOf:orphan)==payload(true),"orphan evidence never deleted")
check(orphanNext.save(payload(false),incident:4,phase:0,automatic:false) == .unavailable,"manual also refuses unbounded publication when ownership cannot resume")
let lostDir=root.appendingPathComponent("lost")
let lostFirst=DiagnosticLogStore(directory:lostDir,policy:policy,persistentOwnership:true)
group(lostFirst,1)
let lostFiles=files(lostDir)
try fm.removeItem(at:lostDir.appendingPathComponent(".automatic-ownership-v1.index"))
let lostNext=DiagnosticLogStore(directory:lostDir,policy:policy,persistentOwnership:true)
check(lostNext.save(payload(true),incident:2,phase:0,automatic:true) == .unavailable,"lost index never adopts historical logs")
check(lostFiles.allSatisfy{fm.fileExists(atPath:$0.path)},"lost metadata preserves all earlier captures")
let changedDir=root.appendingPathComponent("changed")
let changedFirst=DiagnosticLogStore(directory:changedDir,policy:policy,persistentOwnership:true)
group(changedFirst,1)
let changed=files(changedDir).first!
try payload(false).write(to:changed)
let changedNext=DiagnosticLogStore(directory:changedDir,policy:policy,persistentOwnership:true)
check(changedNext.save(payload(true),incident:2,phase:0,automatic:true) == .unavailable,"changed owned capture refuses adoption and pruning")
check(try Data(contentsOf:changed)==payload(false),"changed file preserved")
let corruptDir=root.appendingPathComponent("corrupt")
let corruptFirst=DiagnosticLogStore(directory:corruptDir,policy:policy,persistentOwnership:true)
corruptFirst.prepareOwnership()
let corruptIndex=corruptDir.appendingPathComponent(".automatic-ownership-v1.index")
var object=try JSONSerialization.jsonObject(with:Data(contentsOf:corruptIndex)) as! [String:Any]
var status=object["status"] as! [String:Any]
for key in ["attempts","saved","limited","retired","unavailable","encodingFailures"]{status[key]=Int.max}
object["status"]=status
try JSONSerialization.data(withJSONObject:object).write(to:corruptIndex)
let corruptNext=DiagnosticLogStore(directory:corruptDir,policy:policy,persistentOwnership:true)
check(corruptNext.save(payload(true),incident:1,phase:0,automatic:true) == .unavailable,"hostile counter sums fail without integer overflow")
let linkedDir=root.appendingPathComponent("linked")
try fm.createSymbolicLink(at:linkedDir,withDestinationURL:directory)
let linked=DiagnosticLogStore(directory:linkedDir,policy:policy,persistentOwnership:true)
check(linked.save(payload(true),incident:5,phase:0,automatic:true) == .unavailable,"persistent namespace rejects symlink")

// Both companion writes can fail on one attempt; the public counter counts
// affected attempts, not metadata files, so it remains bounded by attempts.
let failedDir=root.appendingPathComponent("metadata-failure")
let failed=DiagnosticLogStore(directory:failedDir,policy:policy,persistentOwnership:true)
failed.prepareOwnership()
try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:failedDir.path)
let failedResult=failed.save(payload(true),incident:1,phase:0,automatic:true)
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:failedDir.path)
check(failedResult == .unavailable,"unwritable persistent storage refuses capture")
check(failed.status.statusWriteFailures==1 && failed.status.attempts==1,"one attempt never double-counts status and ownership failures")
let unindexedStatusDir=root.appendingPathComponent("unindexed-status")
let unindexedStatus=DiagnosticLogStore(directory:unindexedStatusDir,policy:policy,persistentOwnership:true)
unindexedStatus.prepareOwnership()
let initialIndex=try JSONSerialization.jsonObject(with:Data(contentsOf:unindexedStatusDir.appendingPathComponent(".automatic-ownership-v1.index"))) as! [String:Any]
let unindexedStatusPath=unindexedStatusDir.appendingPathComponent(initialIndex["statusName"] as! String)
try Data("{}".utf8).write(to:unindexedStatusPath)
try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:unindexedStatusPath.path)
let unexpected=DiagnosticLogStore(directory:unindexedStatusDir,policy:policy,persistentOwnership:true)
check(unexpected.save(payload(true),incident:1,phase:0,automatic:true) == .unavailable,"unindexed status publication refuses ambiguous resume")
check(try Data(contentsOf:unindexedStatusPath)==Data("{}".utf8),"unindexed status evidence remains untouched")

func toggle(_ trace:InputIncidentTrace,_ active:Bool){
    var finished=false
    trace.setCollectionEnabled(active){finished=true}
    let deadline=Date().addingTimeInterval(5)
    while !finished && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    check(finished && trace.enabled==active,"runtime toggle completes")
    trace.flush()
}
var captures:[InputIncidentTrace.Capture]=[]
let trace=InputIncidentTrace(destination:nil,initiallyEnabled:false,writer:{captures.append($0)})
trace.state(.mismatch,.buffered,pending:11);trace.mark();trace.flush()
check(captures.isEmpty && trace.beginRead(.mismatchAX)==nil,"OFF observes and writes nothing")
toggle(trace,true)
trace.state(.mismatch,.buffered,pending:22);trace.mark();trace.flush()
check(captures.count==1 && captures[0].frames.contains{$0.kind == .state && $0.count==22},"live ON starts full trace without process restart")
let oldSpan=trace.beginRead(.mismatchAX)
trace.flush()
toggle(trace,false)
trace.endRead(.mismatchAX,oldSpan);trace.flush()
let count=captures.count
Thread.sleep(forTimeInterval:1.1);trace.flush()
check(captures.count==count,"OFF cancels outstanding delayed post capture")
toggle(trace,true)
trace.endRead(.mismatchAX,oldSpan)
trace.state(.mismatch,.buffered,pending:33);trace.mark();trace.flush()
let fresh=captures.last!
check(UUID(uuidString:fresh.runID) != nil && fresh.runID==captures[0].runID,"one anonymous run identity survives live toggles")
check(!fresh.frames.contains{$0.kind == .read || ($0.kind == .state && $0.count==22)},"new generation excludes previous AX span and buffered frames")
check(fresh.frames.contains{$0.kind == .state && $0.count==33},"new generation records new state")
let newSpan=trace.beginRead(.mismatchAX);trace.endRead(.mismatchAX,newSpan);trace.flush()
check(newSpan != nil,"old span returns its reservation after OFF")
toggle(trace,false)
let offDir=root.appendingPathComponent("disabled")
let off=InputIncidentTrace(destination:offDir,initiallyEnabled:false,persistentOwnership:true)
off.mark();off.flush()
check(!fm.fileExists(atPath:offDir.path),"disabled startup does not create storage")
toggle(off,true);off.mark();off.flush()
let savedFiles=files(offDir),savedData=try savedFiles.map{try Data(contentsOf:$0)}
toggle(off,false)
check(try savedFiles.map{try Data(contentsOf:$0)}==savedData,"OFF preserves existing disk evidence")
let previousRun=(try JSONSerialization.jsonObject(with:Data(contentsOf:savedFiles[0])) as! [String:Any])["runID"] as! String
let resumed=InputIncidentTrace(destination:offDir,persistentOwnership:true)
resumed.mark();resumed.flush()
check(files(offDir).contains{$0.lastPathComponent.hasPrefix("incident-2-0-")},"new trace instance advances persistent capture identity")
let newFile=files(offDir).first{$0.lastPathComponent.hasPrefix("incident-2-0-")}!
let newRun=(try JSONSerialization.jsonObject(with:Data(contentsOf:newFile)) as! [String:Any])["runID"] as! String
check(newRun != previousRun,"restarted trace never shares event/sequence identity with previous run")

resumed.stopAndFlush()
let beforeShutdown=files(offDir)
Thread.sleep(forTimeInterval:1.1);resumed.flush()
check(!resumed.enabled && files(offDir).count==beforeShutdown.count,"normal termination cancels late posts and drains current storage transaction")

let locked=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
DispatchQueue.global().async{trace.withLockedMetadataForTest{locked.signal();release.wait()};done.signal()}
locked.wait()
let began=DispatchTime.now().uptimeNanoseconds
trace.setCollectionEnabled(true)
trace.state(.mismatch,.buffered,pending:44)
let elapsed=DispatchTime.now().uptimeNanoseconds-began
check(elapsed<50_000_000,"settings and input-side observation never wait for diagnostic metadata lock")
release.signal();done.wait();trace.flush()
print("PASS \(checks) persisted ON/OFF, live generations, restart count/byte rotation, manual preservation and fail-safe ownership; no OS keys")
