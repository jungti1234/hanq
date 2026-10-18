import Foundation
import Darwin

var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;do{if try value(){return}}catch{};fputs("FAIL: \(message)\n",stderr);exit(1)}
let fm=FileManager.default
let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hanq-retention-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
func files(_ url:URL)->[URL]{((try? fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}}
func bytes(_ n:Int)->Data{Data(repeating:0x20,count:n)}
func group(_ store:DiagnosticLogStore,_ id:Int,_ size:Int){
    check(store.save(bytes(size),incident:id,phase:0,automatic:true) == .saved,"pre saves")
    check(store.save(bytes(size),incident:id,phase:1,automatic:true) == .saved,"post saves")
}
let directory=root.appendingPathComponent("count")
try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let old=directory.appendingPathComponent("incident-1-0-old.json")
try bytes(1000).write(to:old)
let store=DiagnosticLogStore(directory:directory,policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:1000))
check(store.save(bytes(2000),incident:1,phase:0,automatic:false) == .saved,"manual ignores automatic limits")
let manual=files(directory).first{$0.lastPathComponent != old.lastPathComponent}!
let manualData=try Data(contentsOf:manual)
group(store,2,20);group(store,3,20);group(store,4,20)
check(store.usage == .init(files:4,bytes:80),"file limit rotates whole pre/post groups")
check(files(directory).filter{$0.lastPathComponent.hasPrefix("incident-2-")}.isEmpty,"oldest group removed together")
check(try Data(contentsOf:old)==bytes(1000),"pre-existing incident-shaped files preserved")
check(try Data(contentsOf:manual)==manualData,"manual file unchanged")
check(store.save(bytes(20),incident:2,phase:1,automatic:true) == .retired,"late post cannot resurrect evicted group")
check(files(directory).count==6,"protected files excluded from automatic count")
for file in files(directory) where file.lastPathComponent != old.lastPathComponent {
    let mode=(try fm.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue
    check(mode==0o600,"published captures are owner-only: \(file.lastPathComponent) mode=\(mode)")
}
check(!files(directory).contains{$0.lastPathComponent.hasPrefix(".partial-")},"no partial publication")
let byteDir=root.appendingPathComponent("bytes")
let byteStore=DiagnosticLogStore(directory:byteDir,policy:.init(maximumAutomaticFiles:100,maximumAutomaticBytes:100))
group(byteStore,1,40);group(byteStore,2,30)
check(byteStore.usage == .init(files:2,bytes:60),"byte limit independently rotates oldest group")
check(byteStore.save(bytes(101),incident:3,phase:0,automatic:true) == .limit,"oversize pre refused before pruning")
check(byteStore.save(bytes(1),incident:3,phase:1,automatic:true) == .retired,"failed pre cannot publish orphan post")
check(byteStore.usage == .init(files:2,bytes:60),"oversize preserves earlier evidence")
check(byteStore.save(bytes(71),incident:2,phase:1,automatic:true) == .retired,"duplicate post refused")
let one=DiagnosticLogStore(directory:root.appendingPathComponent("one"),policy:.init(maximumAutomaticFiles:1,maximumAutomaticBytes:100))
check(one.save(bytes(40),incident:1,phase:0,automatic:true) == .saved,"single-file policy keeps immediate pre evidence")
check(one.save(bytes(40),incident:1,phase:1,automatic:true) == .limit,"post cannot exceed group count limit")
check(one.save(bytes(40),incident:2,phase:0,automatic:true) == .saved,"incomplete old group rotates")
let changedDir=root.appendingPathComponent("changed")
let changed=DiagnosticLogStore(directory:changedDir,policy:.init(maximumAutomaticFiles:2,maximumAutomaticBytes:100))
group(changed,1,20)
let victim=files(changedDir).first!
try fm.removeItem(at:victim);try bytes(21).write(to:victim)
check(changed.save(bytes(20),incident:2,phase:0,automatic:true) == .unavailable,"replaced old file refuses pruning and new publication")
check(try Data(contentsOf:victim)==bytes(21),"replacement not deleted")
check(files(changedDir).count==2,"prune failure cannot grow automatic files")
check(changed.save(bytes(10),incident:3,phase:0,automatic:false) == .saved,"manual remains independent after automatic prune refusal")
let linkDir=root.appendingPathComponent("link")
try fm.createSymbolicLink(at:linkDir,withDestinationURL:directory)
let linked=DiagnosticLogStore(directory:linkDir,policy:.incidentDefault)
check(linked.save(bytes(5),incident:1,phase:0,automatic:true) == .unavailable,"symlink directory refused")
let originalDir=root.appendingPathComponent("original")
let identity=DiagnosticLogStore(directory:originalDir,policy:.incidentDefault)
check(identity.save(bytes(5),incident:1,phase:0,automatic:true) == .saved,"directory identity bound on first save")
try fm.moveItem(at:originalDir,to:root.appendingPathComponent("moved"))
try fm.createDirectory(at:originalDir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
check(identity.save(bytes(5),incident:2,phase:0,automatic:true) == .unavailable,"same path replacement not adopted")
check(files(originalDir).isEmpty,"replacement directory untouched")
let restarted=DiagnosticLogStore(directory:byteDir,policy:.init(maximumAutomaticFiles:1,maximumAutomaticBytes:10))
let previousNames=Set(files(byteDir).map{$0.lastPathComponent})
check(restarted.save(bytes(5),incident:1,phase:0,automatic:true) == .saved,"restart begins a new ownership cohort")
check(previousNames.isSubset(of:Set(files(byteDir).map{$0.lastPathComponent})),"restart protects every pre-existing automatic file")
let delayedDir=root.appendingPathComponent("delayed")
let delayed=DiagnosticLogStore(directory:delayedDir,policy:.init(maximumAutomaticFiles:2,maximumAutomaticBytes:100))
check(delayed.save(bytes(20),incident:1,phase:0,automatic:true) == .saved,"first pre saves")
check(delayed.save(bytes(20),incident:2,phase:0,automatic:true) == .saved,"newer pre saves")
check(delayed.save(bytes(20),incident:1,phase:1,automatic:true) == .limit,"late older post never evicts newer pre")
check(delayed.save(bytes(81),incident:2,phase:1,automatic:true) == .limit,"post cannot grow its group beyond byte budget")
check(delayed.usage == .init(files:2,bytes:40),"rejected post preserves both pre files")
try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:delayedDir.path)
check(delayed.save(bytes(20),incident:3,phase:0,automatic:true) == .unavailable,"unwritable destination cannot prune earlier evidence")
try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:delayedDir.path)
check(delayed.usage == .init(files:2,bytes:40),"write failure preserves tracked usage")
check(delayed.save(bytes(20),incident:4,phase:0,automatic:true) == .saved,"later automatic capture resumes after transient failure")

// Exercise the actual trigger/encoder/writer path beyond the old lifetime cap.
// Advancing the test clock keeps the ten-second throttle deterministic; delayed
// post frames use an explicit close when advancing the virtual clock.
// Real delayed-post timing is covered by the preservation and storage tests.
var time=100.0
let traceDir=root.appendingPathComponent("trace")
let trace=InputIncidentTrace(destination:traceDir,clock:{time},retention:.init(maximumAutomaticFiles:6,maximumAutomaticBytes:1_000_000))
trace.mark();trace.flush()
let protected=files(traceDir).first!
let protectedData=try Data(contentsOf:protected)
for _ in 0..<45 {time+=11;trace.finishCaptureWindowsForTest();trace.flush();trace.sourceBoundary(.retained,queued:1,awaitingOnset:0);trace.flush()}
check(files(traceDir).contains{$0.lastPathComponent.hasPrefix("incident-46-0-")},"automatic captures continue after 32 incidents")
let beforeThrottle=files(traceDir).count
trace.sourceBoundary(.retained,queued:1,awaitingOnset:0);trace.flush()
check(files(traceDir).count==beforeThrottle,"automatic throttle unchanged")
Thread.sleep(forTimeInterval:1.2);trace.flush()
let jsons=files(traceDir)
let objects=try jsons.map{try JSONSerialization.jsonObject(with:Data(contentsOf:$0)) as! [String:Any]}
let auto=objects.filter{($0["trigger"] as? Int) != 1}
check(auto.count<=6,"actual encoder stays within file count after delayed posts")
check(auto.allSatisfy{($0["incident"] as! Int)>=41},"retired delayed post never republishes old evidence")
check(try Data(contentsOf:protected)==protectedData,"manual pre preserved through long-running rotation")
check(objects.filter{($0["trigger"] as? Int)==1}.count==2,"manual post survives automatic rotation")
check(jsons.allSatisfy{$0.pathExtension=="json"},"only complete JSON remains")
print("PASS \(checks) rotation, bytes, groups, protected/manual files, failure safety and >32 automatic captures; no OS keys")
