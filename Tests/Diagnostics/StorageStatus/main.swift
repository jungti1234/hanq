import Foundation
import Darwin
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if !(try! value()){fputs("FAIL: \(message)\n",stderr);exit(1)}}
let fm=FileManager.default
let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-storage-status-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
func names(_ dir:URL)->[URL]{(try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? []}
func statuses(_ dir:URL)->[URL]{names(dir).filter{$0.pathExtension=="status"}}
func document(_ dir:URL)throws->RecorderStorageDocument {try RecorderStorageDocument.decode(Data(contentsOf:statuses(dir).first!))}
func bytes(_ n:Int)->Data{Data(repeating:32,count:n)}
let dir=root.appendingPathComponent("rotation")
try fm.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let protected=dir.appendingPathComponent("existing.json");try bytes(123).write(to:protected)
let store=DiagnosticLogStore(directory:dir,policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:100))
check(store.status.attempts==0,"new store reports no prior writes")
check(store.save(bytes(150),incident:1,phase:0,automatic:false) == .saved,"manual capture independent of budget")
for id in 2...4 {for phase in 0...1{check(store.save(bytes(20),incident:id,phase:phase,automatic:true) == .saved,"automatic capture saves through rotation")}}
let current=try document(dir).status
check(current.valid && current.attempts==7 && current.saved==7,"current attempt appears in bounded companion")
check(current.evictedGroups==1 && current.evictedFiles==2 && current.evictedBytes==40,"actual oldest pair deletion counted")
check(current.automaticFiles==4 && current.automaticBytes==80,"status usage matches policy/store")
check(current.lastResult==1 && current.lastIncident==4 && current.lastPhase==1 && current.lastAutomatic,"last outcome has fixed coordinates")
check(current.lastWriteMicros<=current.maxWriteMicros && current.statusWriteFailures==0,"write duration and companion errors distinguished")
check(statuses(dir).count==1,"one companion per running store")
let statusPath=statuses(dir).first!,statusData=try Data(contentsOf:statusPath)
check(statusData.count<=16*1024,"companion bounded independently of captures")
check((try fm.attributesOfItem(atPath:statusPath.path)[.posixPermissions] as! NSNumber).intValue==0o600,"status owner-only")
check(try Data(contentsOf:protected)==bytes(123),"old file untouched")
check(store.save(bytes(101),incident:5,phase:0,automatic:true) == .limit,"oversize failure has outcome")
check(try document(dir).status.limited==1 && document(dir).status.lastResult==2,"failed capture still updates companion")
check(store.save(bytes(1),incident:5,phase:1,automatic:true) == .retired,"late post has distinct outcome")
check(try document(dir).status.retired==1 && document(dir).status.lastResult==3,"retired recorded independently")
store.encodingFailed(incident:6,phase:0,automatic:true)
check(try document(dir).status.encodingFailures==1 && document(dir).status.lastFailureStage==6,"encoding failure survives without a capture")
let owned=names(dir).first{$0.lastPathComponent.hasPrefix("incident-3-")}!
try fm.removeItem(at:owned);try bytes(21).write(to:owned)
check(store.save(bytes(20),incident:7,phase:0,automatic:true) == .unavailable,"changed owned file refuses pruning")
check(try document(dir).status.unavailable==1 && document(dir).status.lastFailureStage==3,"ownership failure distinguished from byte limit")
check(try Data(contentsOf:owned)==bytes(21),"externally replaced file retained")
let replacement=bytes(3);try fm.removeItem(at:statusPath);try replacement.write(to:statusPath)
check(store.save(bytes(1),incident:8,phase:0,automatic:false) == .saved,"companion refusal does not stop manual evidence")
check(store.status.statusWriteFailures==1,"companion failure counted in memory")
check(try Data(contentsOf:statusPath)==replacement,"changed companion never overwritten")
let recoveredDir=root.appendingPathComponent("recovery")
let recovered=DiagnosticLogStore(directory:recoveredDir,policy:.incidentDefault)
check(recovered.save(bytes(2),incident:1,phase:0,automatic:true) == .saved,"recovery initial capture")
try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:recoveredDir.path)
check(recovered.save(bytes(2),incident:2,phase:0,automatic:true) == .unavailable,"unwritable disk failure")
check(recovered.status.lastFailureStage==4 && recovered.status.lastErrno != 0 && recovered.status.statusWriteFailures==1,"publication errno and unwritable status failure counted")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:recoveredDir.path)
check(recovered.save(bytes(2),incident:3,phase:0,automatic:true) == .saved,"later capture resumes")
check(try document(recoveredDir).status.unavailable==1 && document(recoveredDir).status.statusWriteFailures==1,"next good companion includes disk failures")
check(try document(recoveredDir).status.lastFailureStage==0 && document(recoveredDir).status.lastErrno==0,"success clears last failure details")
let restarted=DiagnosticLogStore(directory:recoveredDir,policy:.incidentDefault)
let previous=try Data(contentsOf:statuses(recoveredDir).first!)
check(restarted.save(bytes(2),incident:1,phase:0,automatic:true) == .saved,"new store starts distinct status cohort")
let previousStatusPreserved=try statuses(recoveredDir).contains{try Data(contentsOf:$0)==previous}
check(statuses(recoveredDir).count==2 && previousStatusPreserved,"prior run status preserved")
// Actual trace headers report only prior completed writes, never their own save.
var time=100.0
let traceDir=root.appendingPathComponent("trace")
let trace=InputIncidentTrace(destination:traceDir,clock:{time},retention:.init(maximumAutomaticFiles:2,maximumAutomaticBytes:1_000_000))
trace.captureForTest(.axDelay);trace.flush()
let pre=names(traceDir).first{$0.pathExtension=="json"}!
let preData=try Data(contentsOf:pre)
let preValue=try RecorderTrace.decode(preData)
check(preValue.storageBeforeWrite?.attempts==0,"first capture explicitly reports prior state")
check(try document(traceDir).status.attempts==1,"companion includes the current write")
let postDeadline=ProcessInfo.processInfo.systemUptime+4
while ProcessInfo.processInfo.systemUptime<postDeadline {
 trace.flush()
 if (try? document(traceDir).status.attempts)==2{break}
 Thread.sleep(forTimeInterval:0.05)
}
trace.flush()
let post=names(traceDir).first{$0.lastPathComponent.hasPrefix("incident-1-1-")}!
check(try RecorderTrace.decode(Data(contentsOf:post)).storageBeforeWrite?.attempts==1,"post header includes completed pre save")
check(try document(traceDir).status.attempts==2 && document(traceDir).status.automaticFiles==2,"current companion and disk count match")
time+=11;trace.captureForTest(.axDelay);trace.flush()
check(try document(traceDir).status.evictedFiles==2 && document(traceDir).status.evictedGroups==1,"real trigger/encoder/writer exposes pair rotation")
// Strict collector retains the latest status separately from new input evidence.
let collected=root.appendingPathComponent("collected")
let session=try RecorderSession(source:traceDir,outputRoot:collected,product:[:])
try session.finish(scenario:"ordinary")
check(session.storageStatuses==1 && session.copied==0,"baseline status collected as cumulative state, not new observations")
let copy=try fm.contentsOfDirectory(at:session.directory,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("storage-")}!
check(try RecorderStorageDocument.decode(Data(contentsOf:copy)).status.evictedFiles==2,"sanitized status survives collector")
var object=try JSONSerialization.jsonObject(with:statusData) as! [String:Any]
var payload=object["status"] as! [String:Any]
let invalids:[(String,Any)]=[("text","PRIVATE"),("saved",-1),("attempts",true),("lastResult",9),("lastFailureStage",7),("automaticBytes",101),("lastAutomatic",1),("lastWriteMicros",60_000_001),("statusWriteFailures",8)]
for (key,value) in invalids {
 var edited=payload;edited[key]=value;var doc=object;doc["status"]=edited
 check((try? RecorderStorageDocument.decode(JSONSerialization.data(withJSONObject:doc)))==nil,"strict status rejects invalid/unknown payload: \(key)")
}
var traceObject=try JSONSerialization.jsonObject(with:preData) as! [String:Any]
payload["text"]="PRIVATE";traceObject["storageBeforeWrite"]=payload
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:traceObject)))==nil,"capture rejects unknown storage payload")
print("PASS \(checks) actual rotation/failures/usage/write time, prior/current state, bounded protected status, recovery and strict collection; no OS keys")
