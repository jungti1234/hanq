import Foundation
import Carbon
import CryptoKit
var checks=0
func check(_ test:@autoclosure () throws->Bool,_ message:String){checks+=1;if (try? test()) != true{fputs("FAIL \(message)\n",stderr);exit(1)}}
do {
let fm=FileManager.default
let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("hanq-migration-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
func dir(_ name:String)throws->URL{let u=root.appendingPathComponent(name);try fm.createDirectory(at:u,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return u}
func hashes(_ u:URL)throws->[String:String]{
 var result:[String:String]=[:]
 guard let e=fm.enumerator(at:u,includingPropertiesForKeys:[.isRegularFileKey],options:[]) else{throw DiagnosticLogExport.Failure.unavailable}
 for case let file as URL in e {var info=stat();guard lstat(file.path,&info)==0 else{throw DiagnosticLogExport.Failure.unavailable};if info.st_mode&S_IFMT==S_IFREG{result[String(file.path.dropFirst(u.path.count+1))]=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()}}
 return result
}

let old=try dir("old"),fresh=try dir("fresh")
let suite="HanQMigrationTests-"+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer{defaults.removePersistentDomain(forName:suite)}
defaults.set(old.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
defaults.set(false,forKey:InputIncidentPreferences.key)
var option=InputIncidentPreferences.launch(arguments:["HanQ"],defaults:defaults)
check(option.valid && !option.bounded && !option.preserve && !option.enabled,"ordinary startup chooses shared retention, respects OFF")
check(option.directory==InputIncidentPreferences.defaultDirectory && option.legacy.map(\.path)==[old.path],"previous location remains reachable")
check(defaults.string(forKey:InputIncidentPreferences.boundedDirectoryKey)==old.path,"route lookup cannot commit before readiness")
for args in [["HanQ","--bounded-input-incidents",old.path],["HanQ","--bounded-input-incidents"],["HanQ","--bounded-input-incidents="+old.path],["HanQ","--bounded-input-incidents",old.path,"--preserve-input-incidents",fresh.path]]{check(!InputIncidentPreferences.launch(arguments:args,defaults:defaults).valid,"retired CLI explicitly fails")}
check(InputIncidentPreferences.launch(arguments:["HanQ","--preserve-input-incidents",fresh.path],defaults:defaults).legacy.isEmpty,"explicit investigations isolated from saved source")
defaults.set(old.path.replacingOccurrences(of:"/private/tmp/",with:"/tmp/"),forKey:InputIncidentPreferences.boundedDirectoryKey)
check(InputIncidentPreferences.launch(arguments:["HanQ"],defaults:defaults).legacy.map(\.path)==[old.path],"old system /tmp alias maps to same read-only source")
defaults.set(old.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
let run=UUID().uuidString
let fixture=LegacyFixtureStore(directory:old,policy:.incidentDefault,persistentOwnership:true,requiresBoundedPriorPolicy:true)
for n in 1...3 {for phase in 0...1 {
 let data=try JSONSerialization.data(withJSONObject:["schema":1,"build":"437","runID":run,"incident":n,"phase":phase,"trigger":n==3 ? 1:2,"frames":[["kind":2,"category":2,"sequence":n*2+phase,"milliseconds":n*1000,"durationMicros":1000]]])
 check(fixture.save(data,incident:n,phase:phase,automatic:n != 3) == .saved,"legacy fixture created")
}}
let before=try hashes(old)
let environment=DiagnosticReviewEnvironment(appVersion:"test",build:"migration",macOSVersion:"test",modelIdentifier:"test",keyboardLayout:.twoSet,koreanKeyEnabled:true,hanjaKeyEnabled:true,hudEnabled:false,capsLockSwitchEnabled:false,loginItemState:.notRegistered,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
func verify(_ source:URL,_ name:String)throws {
 let prior=try hashes(source)
 let snapshot=root.appendingPathComponent(name)
 let reader=DiagnosticLogStore(directory:source,policy:.investigation,persistentOwnership:true,readOnly:true)
 check(!reader.verifyReadiness().ready,"read-only store cannot create canary")
 try reader.copyExportSnapshot(to:snapshot,reviewMetadata:true)
 let review=try DiagnosticReviewSnapshot(directory:snapshot)
 check(!review.incidents.isEmpty,"legacy records visible")
 let files=try review.files(selected:Set(review.incidents.prefix(5).map(\.id)),environment:environment)
 check(!files.map(\.readableText).joined().isEmpty,"legacy preview generated")
 let sourceFD=open(source.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
 guard sourceFD>=0 else{throw DiagnosticLogExport.Failure.unavailable}
 defer{close(sourceFD)}
 try DiagnosticCriticalJournal.forEachFile(sourceFD){name,data in
  check(try files.contains{file in guard file.path==name else{return false};return try file.data==data},"every legacy critical journal is retained byte-for-byte in selected export")
 }
 let archive=try DiagnosticReviewArchive(files:files),zip=root.appendingPathComponent(name+".zip")
 try archive.save(to:zip)
 let restored=try dir(name+"-restored"),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");p.arguments=["-x","-k",zip.path,restored.path];try p.run();p.waitUntilExit();check(p.terminationStatus==0,"ZIP restores")
 for file in files {
  check(try Data(contentsOf:restored.appendingPathComponent("HanQ-Diagnostics").appendingPathComponent(file.path))==file.data,"ZIP bytes match reviewed originals")
  if file.path.hasPrefix("incident-"){check(try file.data==Data(contentsOf:source.appendingPathComponent(file.path)),"old capture bytes unchanged")}
 }
 check(try hashes(source)==prior,"all source files including index and budget unchanged")
}
try verify(old,"fixture-review")
InputIncidentPreferences.commitLegacyMigration(defaults:defaults,expected:[fresh])
check(defaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey) != nil,"changed preference cannot be removed")
let trace=InputIncidentTrace(secureInput:{false},destination:fresh,persistentOwnership:true,legacyDirectories:[old],migration:{InputIncidentPreferences.commitLegacyMigration(defaults:defaults,expected:[old])})
trace.flush()
check(defaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey)==nil,"ready new store commits migration")
check(defaults.stringArray(forKey:InputIncidentPreferences.legacyDirectoriesKey)==[old.path],"old location durably registered")
option=InputIncidentPreferences.launch(arguments:["HanQ","--permission-recovery"],defaults:defaults)
check(option.valid && option.legacy.map(\.path)==[old.path] && !option.bounded,"relaunch keeps old read access and new writer")
trace.captureForTest(.manual);trace.flush();trace.finishCaptureWindowsForTest();trace.flush()
check((trace.sharedStatsForTest()?.saved ?? 0)>=2,"new pre and post stored through shared writer")
check(!(try fm.contentsOfDirectory(atPath:fresh.path)).contains{$0.hasPrefix("incident-") || $0==".write-budget-v1.ledger"},"no new legacy captures or budget ledger")
check(try hashes(old)==before,"migration and new writes preserve all old bytes")
let sem=DispatchSemaphore(value:0);var result:Result<Void,Error>?
trace.prepareLegacyExport(index:0,to:root.appendingPathComponent("trace-review")){result=$0;sem.signal()}
check(sem.wait(timeout:.now()+10) == .success,"menu source snapshot completes");try result!.get()
check(try DiagnosticReviewSnapshot(directory:root.appendingPathComponent("trace-review")).incidents.count==3,"menu source exposes all old incidents")
trace.setCollectionEnabled(false);trace.flush()
let unavailable=root.appendingPathComponent("missing-parent/no-folder")
let denied=DiagnosticLogStore(directory:unavailable,policy:.investigation,persistentOwnership:true,readOnly:true)
do{try denied.copyExportSnapshot(to:root.appendingPathComponent("bad"));check(false,"missing old source must report error")}catch{}
check(!fm.fileExists(atPath:unavailable.deletingLastPathComponent().path),"missing old source never created")
let alias=root.appendingPathComponent("alias");try fm.createSymbolicLink(at:alias,withDestinationURL:old)
defaults.set(alias.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
check(!InputIncidentPreferences.launch(arguments:["HanQ"],defaults:defaults).valid,"unsafe alias rejected without mutation")
check(try hashes(old)==before,"invalid migration does not touch originals")
// OFF and failed readiness cannot retire the old write-mode preference.
let offDefaults=UserDefaults(suiteName:suite+"-off")!
defer{offDefaults.removePersistentDomain(forName:suite+"-off")}
offDefaults.set(old.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
let offPath=root.appendingPathComponent("off-new")
let offTrace=InputIncidentTrace(secureInput:{false},destination:offPath,initiallyEnabled:false,persistentOwnership:true,legacyDirectories:[old],migration:{InputIncidentPreferences.commitLegacyMigration(defaults:offDefaults,expected:[old])})
offTrace.flush()
let offExportDone=DispatchSemaphore(value:0);var offExport:Result<Void,Error>?
offTrace.prepareLegacyExport(index:0,to:root.appendingPathComponent("off-legacy-review")){offExport=$0;offExportDone.signal()}
check(offExportDone.wait(timeout:.now()+10) == .success,"previous records export while new collection is OFF")
try offExport!.get()
check(!fm.fileExists(atPath:offPath.path) && offDefaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey) != nil,"OFF does not initialize storage or mutate migration settings")
offTrace.setCollectionEnabled(true);offTrace.flush()
check(offDefaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey)==nil,"enabling collection commits only after readiness")
offTrace.stopAndFlush()
offDefaults.set(old.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
let failurePath=try dir("not-writable");check(chmod(failurePath.path,0o500)==0,"deny only fixture directory")
let failureTrace=InputIncidentTrace(secureInput:{false},destination:failurePath,persistentOwnership:true,legacyDirectories:[old],migration:{InputIncidentPreferences.commitLegacyMigration(defaults:offDefaults,expected:[old])})
failureTrace.flush()
check(offDefaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey) != nil,"failed new storage preserves migration input")
check(chmod(failurePath.path,0o700)==0,"restore fixture")
failureTrace.setCollectionEnabled(false);failureTrace.flush();failureTrace.setCollectionEnabled(true);failureTrace.flush()
let retryDeadline=Date().addingTimeInterval(8)
while offDefaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey) != nil,Date()<retryDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
check(offDefaults.object(forKey:InputIncidentPreferences.boundedDirectoryKey)==nil,"same process migrates after storage recovers")
failureTrace.stopAndFlush()
// Earlier schema variants are read without rewriting their ownership indexes.
for schema in [1,2] {
 let location=try dir("schema-\(schema)")
 let historical=LegacyFixtureStore(directory:location,policy:.incidentDefault,persistentOwnership:true)
 for phase in 0...1 {
  let data=try JSONSerialization.data(withJSONObject:["schema":1,"runID":run,"incident":1,"phase":phase,"trigger":2,"frames":[["kind":2,"category":2,"sequence":phase,"milliseconds":0]]])
  check(historical.save(data,incident:1,phase:phase,automatic:true) == .saved,"historical schema fixture created")
 }
 let index=location.appendingPathComponent(".automatic-ownership-v1.index")
 var document=try JSONSerialization.jsonObject(with:Data(contentsOf:index)) as! [String:Any]
 document["schema"]=schema
 try JSONSerialization.data(withJSONObject:document).write(to:index)
 try verify(location,"schema-\(schema)-review")
}
// A retired accounting ledger is preserved but not required for reading logs.
try Data("damaged historical budget".utf8).write(to:old.appendingPathComponent(".write-budget-v1.ledger"))
try verify(old,"ledger-independent-review")
if let path=ProcessInfo.processInfo.environment["HANQ_LEGACY_READONLY_FIXTURE"]{try verify(URL(fileURLWithPath:path),"preserved-real-log")}
print("PASS \(checks) migration, read-only legacy preview, ZIP restore, shared pre/post checks")

} catch {fputs("FAIL migration: \(error)\n",stderr);exit(1)}
