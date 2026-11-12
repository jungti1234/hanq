import Foundation
import Darwin

let root=FileManager.default.temporaryDirectory.appendingPathComponent("hanq-storage-checks-"+UUID().uuidString,isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? FileManager.default.removeItem(at:root)}
var checks=0,failures=0
func check(_ value:Bool,_ name:String){checks+=1;if !value{failures+=1;print("FAIL",name)}}
func folder(_ name:String,_ mode:Int=0o700)throws->URL {
    let p=root.appendingPathComponent(name,isDirectory:true)
    try FileManager.default.createDirectory(at:p,withIntermediateDirectories:false,attributes:[.posixPermissions:mode]);return p
}
func store(_ url:URL)->DiagnosticLogStore{DiagnosticLogStore(directory:url,policy:.investigation,persistentOwnership:true)}
let parent=try folder("parent",0o755),directory=parent.appendingPathComponent("incidents",isDirectory:true)
let rejected=store(directory)
check(!rejected.verifyReadiness().ready,"755 parent rejected before any input")
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:parent.path)
check(!rejected.verifyReadiness().ready,"changing permissions cannot rehabilitate failed ownership in place")
let fresh=store(parent.appendingPathComponent("fresh",isDirectory:true))
check(fresh.verifyReadiness().ready,"fresh700 store proves actual write and read")
check(fresh.verifyReadiness().ready,"readiness canary leaves no collision")
check(fresh.status.attempts==0 && fresh.status.saved==0,"readiness is not a fabricated incident")

let receiptDirectory=parent.appendingPathComponent("receipt",isDirectory:true),receiptStore=store(receiptDirectory)
let token=UUID().uuidString,name=DiagnosticReadinessReceipt.name(token)
let data=try JSONEncoder().encode(DiagnosticReadinessReceipt.make(token:token,runID:UUID().uuidString))
check(receiptStore.verifyReadiness(receipt:data,name:name).ready,"retained current-process receipt written and reopened")
let receipt=receiptDirectory.appendingPathComponent(name)
check(try Data(contentsOf:receipt)==data,"receipt bytes equal producer bytes")
let attrs=try FileManager.default.attributesOfItem(atPath:receipt.path)
check((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600,"receipt owner-only")
check(!receiptStore.verifyReadiness(receipt:data,name:name).ready,"an existing receipt cannot be overwritten")
check(try Data(contentsOf:receipt)==data,"collision keeps original receipt")
receiptStore.withdrawReadiness()
check(!FileManager.default.fileExists(atPath:receipt.path),"collection disable withdraws receipt")
check(!receiptStore.readiness.ready,"withdrawn readiness cannot start a test")
check(receiptStore.verifyReadiness(receipt:data,name:name).ready,"fresh receipt can be issued after explicit withdrawal")
check(receiptStore.save(Data("{}".utf8),incident:1,phase:0,automatic:false) == .saved,"export fixture saves a separate real incident file")
let exported=parent.appendingPathComponent("export-without-technical-receipt",isDirectory:true)
try receiptStore.copyExportSnapshot(to:exported)
check(!(try FileManager.default.contentsOfDirectory(atPath:exported.path)).contains{$0.hasPrefix(".preflight-") || $0.hasPrefix(".storage-check-")},"technical process proof and canary never enter diagnostic export")
_ = receiptStore.save(Data("{}".utf8),incident:0,phase:0,automatic:false)
check(!receiptStore.readiness.ready,"a later save failure invalidates readiness")
check(!FileManager.default.fileExists(atPath:receipt.path),"later failure removes this store's proof")

let untrusted=try folder("untrusted"),foreign=untrusted.appendingPathComponent("incidents",isDirectory:true)
try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
check(!store(foreign).verifyReadiness().ready,"world-readable child rejected")
let roParent=try folder("read-only-parent",0o500)
check(!store(roParent.appendingPathComponent("incidents",isDirectory:true)).verifyReadiness().ready,"real mkdir/write failure rejected")
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:roParent.path)

let linkParent=try folder("link-parent"),outside=try folder("outside")
let symbolicDestination=linkParent.appendingPathComponent("incidents",isDirectory:true)
try FileManager.default.createSymbolicLink(at:symbolicDestination,withDestinationURL:outside)
check(!store(symbolicDestination).verifyReadiness().ready,"symlink destination rejected")
check((try FileManager.default.contentsOfDirectory(atPath:outside.path)).isEmpty,"no write through symlink")

let damagedParent=try folder("damaged-parent"),damaged=damagedParent.appendingPathComponent("incidents",isDirectory:true)
let first=store(damaged);check(first.verifyReadiness().ready,"valid initial ownership")
let index=damaged.appendingPathComponent(".automatic-ownership-v1.index")
try Data("broken".utf8).write(to:index)
check(!store(damaged).verifyReadiness().ready,"corrupt ownership is never silently adopted")
check(try Data(contentsOf:index)==Data("broken".utf8),"corrupt evidence is preserved")

let traceParent=try folder("trace-parent"),trace=InputIncidentTrace(secureInput:{false},destination:traceParent.appendingPathComponent("incidents",isDirectory:true),persistentOwnership:true,retention:.investigation)
check(trace.waitForStorageReadiness().ready,"real trace initialization completes before readiness")
let published=DispatchSemaphore(value:0)
trace.observeStorage{published.signal()}
trace.mark()
check(published.wait(timeout:.now()+3) == .success,"manual save completion notifies UI")
check((try FileManager.default.contentsOfDirectory(atPath:traceParent.appendingPathComponent("incidents").path)).contains{$0.hasPrefix("incident-") && $0.hasSuffix(".json")},"UI completion is sent after an actual incident exists")
trace.stopAndFlush()
#if HANQ_DIAGNOSTIC_TESTING
let automaticParent=try folder("automatic-status-failure"),automaticDirectory=automaticParent.appendingPathComponent("incidents",isDirectory:true)
var automaticTime=0.0
let automaticTrace=InputIncidentTrace(secureInput:{false},destination:automaticDirectory,persistentOwnership:true,clock:{automaticTime},retention:.investigation)
check(automaticTrace.waitForStorageReadiness().ready,"automatic store begins with actual writable storage")
let automaticPublished=DispatchSemaphore(value:0)
automaticTrace.observeStorage{automaticPublished.signal()}
automaticTrace.captureForTest(.callbackDelay);automaticTrace.flush()
check(automaticPublished.wait(timeout:.now()) == .success,"initial automatic save notifies export state")
automaticTrace.finishCaptureWindowsForTest();automaticTrace.flush()
while automaticPublished.wait(timeout:.now()) == .success {}
let statusName=try FileManager.default.contentsOfDirectory(atPath:automaticDirectory.path).first{$0.hasPrefix(".storage-") && $0.hasSuffix(".status")}!
let statusURL=automaticDirectory.appendingPathComponent(statusName)
try Data("unowned replacement".utf8).write(to:statusURL,options:.atomic)
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:statusURL.path)
automaticTime=20
automaticTrace.captureForTest(.callbackDelay);automaticTrace.flush()
check(automaticPublished.wait(timeout:.now()) == .success,"status-only failure notifies UI even when capture result remains saved")
let healthPublished=DispatchSemaphore(value:0)
var automaticHealth:DiagnosticStorageHealth?
automaticTrace.storageHealth{automaticHealth=$0;healthPublished.signal()}
let receivedHealth=healthPublished.wait(timeout:.now()+1) == .success
check(receivedHealth && automaticHealth?.readiness.ready==false && (automaticHealth?.missingWrites ?? 0)>0,"actual status write failure revokes readiness and is visible")
automaticTrace.stopAndFlush()
#endif
let badTraceParent=try folder("bad-trace-parent",0o755)
let badTrace=InputIncidentTrace(secureInput:{false},destination:badTraceParent.appendingPathComponent("incidents",isDirectory:true),persistentOwnership:true,retention:.investigation)
check(!badTrace.waitForStorageReadiness().ready,"trace cannot report ready from configuration alone")
check(DiagnosticStorageHealth(readiness:.notChecked,missingWrites:0).menuMessage==nil,"unrequested check is not a false error")
check(DiagnosticStorageHealth(readiness:.unavailable,missingWrites:0).menuMessage != nil,"storage failure has a visible explanation")
check(DiagnosticStorageHealth(readiness:.ready,missingWrites:3).menuMessage?.contains("3")==true,"storage error count stays visible")
print("\(failures==0 ? "PASS":"FAIL") \(checks) actual diagnostic storage readiness checks; no UI/keys/taps")
exit(failures==0 ? 0:1)
