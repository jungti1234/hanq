import Foundation
import Darwin

let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("hanq-bounded-"+UUID().uuidString,isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
var checks=0
func check(_ condition:@autoclosure ()throws->Bool,_ label:String){
    checks+=1;do{if try condition(){return}}catch{}
    fputs("FAIL bounded: \(label)\n",stderr);exit(1)
}
let suite="hanq.bounded.tests."+UUID().uuidString
let defaults=UserDefaults(suiteName:suite)!
defer{defaults.removePersistentDomain(forName:suite)}
defaults.set(true,forKey:InputIncidentPreferences.key)
defaults.set(true,forKey:InputIncidentPreferences.archiveBeforePruningKey)
func options(_ args:[String])->(directory:URL,enabled:Bool,persistent:Bool,preserve:Bool,bounded:Bool,valid:Bool){
    InputIncidentPreferences.launch(arguments:["HanQ"]+args,defaults:defaults)
}
let wanted=root.appendingPathComponent("new")
let good=options(["--bounded-input-incidents",wanted.path])
check(good.valid && good.bounded && good.enabled && good.persistent && !good.preserve,"bounded explicit persistent root")
check(good.directory==wanted,"bounded exact destination")
for args in [["--bounded-input-incidents"],["--bounded-input-incidents","relative"],
    ["--bounded-input-incidents",wanted.path,"--bounded-input-incidents",wanted.path],
    ["--bounded-input-incidents",wanted.path,"--preserve-input-incidents",wanted.path],
    ["--bounded-input-incidents",wanted.path,"--diagnose-input-incidents",wanted.path],
    ["--bounded-input-incidents="+wanted.path],["--bounded-input-incidents-extra",wanted.path]] {
    check(!options(args).valid,"invalid/mixed mode rejected before shared-root fallback: \(args)")
}
let shared=InputIncidentPreferences.defaultDirectory
for p in [shared,shared.appendingPathComponent("nested"),shared.deletingLastPathComponent(),URL(fileURLWithPath:"/")] {
    check(!options(["--bounded-input-incidents",p.path]).valid,"shared namespace/ancestor rejected")
}
let alias=root.appendingPathComponent("shared-alias")
try fm.createSymbolicLink(at:alias,withDestinationURL:shared.deletingLastPathComponent())
check(!options(["--bounded-input-incidents",alias.appendingPathComponent("InputIncidents").path]).valid,"alias cannot adopt shared logs")
check(!options(["--bounded-input-incidents",shared.path.uppercased()]).valid,"case alias cannot adopt shared logs")
// Empty-home and later-created namespace, without touching the user's home.
let emptyHome=root.appendingPathComponent("empty-home")
try fm.createDirectory(at:emptyHome,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
let absent=emptyHome.appendingPathComponent("Library/Application Support/HanQ Diagnostics")
let dangling=root.appendingPathComponent("dangling-shared")
try fm.createSymbolicLink(at:dangling,withDestinationURL:absent)
func separate(_ p:URL)->Bool{InputIncidentPreferences.boundedNamespaceIsSeparate(p,shared:absent)}
check(!separate(dangling.appendingPathComponent("InputIncidents")),"dangling alias rejected before namespace exists")
check(!fm.fileExists(atPath:absent.path),"preflight creates no shared namespace")
check(separate(emptyHome.appendingPathComponent("unrelated")),"empty home permits unrelated missing destination")
check(separate(emptyHome.appendingPathComponent("Library/Application Support/HanQ Diagnostics-other")),"prefix sibling is not shared namespace")
let relative=root.appendingPathComponent("relative-shared")
try fm.createSymbolicLink(atPath:relative.path,withDestinationPath:"empty-home/Library/Application Support/HanQ Diagnostics")
check(!separate(relative.appendingPathComponent("InputIncidents")),"relative dangling alias rejected")
try fm.createDirectory(at:absent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
check(!separate(dangling.appendingPathComponent("InputIncidents")),"same rejection after target creation")
let cycle=root.appendingPathComponent("cycle")
try fm.createSymbolicLink(at:cycle,withDestinationURL:cycle)
check(!separate(cycle),"cycle fails closed with bounded traversal")
let unrelatedAlias=root.appendingPathComponent("unrelated-alias")
try fm.createSymbolicLink(at:unrelatedAlias,withDestinationURL:emptyHome.appendingPathComponent("unrelated"))
check(separate(unrelatedAlias),"unrelated dangling alias is not misclassified as shared; writer still validates it")
let preserved=options(["--preserve-input-incidents",wanted.path])
check(preserved.valid && preserved.preserve && !preserved.bounded && preserved.persistent,"preserve mode unchanged")
let transient=options(["--diagnose-input-incidents",wanted.path])
check(transient.valid && transient.preserve && !transient.bounded && !transient.persistent,"legacy transient mode unchanged")
let normal=options([])
check(normal.valid && !normal.bounded && !normal.preserve && normal.directory==shared,"normal mode unchanged")
check(defaults.bool(forKey:InputIncidentPreferences.archiveBeforePruningKey),"launch parsing leaves archive preference unchanged")
defaults.set(wanted.path,forKey:InputIncidentPreferences.boundedDirectoryKey)
let configured=options([])
check(configured.valid && configured.bounded && configured.enabled && configured.directory==wanted,"saved route survives a normal launch")
check(!DiagnosticStorageStartup.explicitRequested(arguments:["HanQ"],defaults:defaults),"ordinary configured launch reaches UI instance lock before storage")
check(!DiagnosticStorageStartup.explicitRequested(arguments:["HanQ","--permission-recovery"],defaults:defaults),"ordinary recovery reaches UI lock before storage")
check(DiagnosticStorageStartup.explicitRequested(arguments:["HanQ",DiagnosticStorageStartup.tokenArgument,UUID().uuidString],defaults:defaults),"configured test launch requires actual current-process proof")
check(options(["--permission-recovery"]).bounded && options(["--permission-recovery"]).directory==wanted,"saved route survives permission recovery")
defaults.set(false,forKey:InputIncidentPreferences.key)
check(options([]).valid && options([]).bounded && !options([]).enabled,"saved route respects diagnostics OFF")
check(options(["--bounded-input-incidents",wanted.path]).enabled,"explicit test mode requires collection despite saved OFF")
defaults.set(true,forKey:InputIncidentPreferences.key)
for value in [true,"relative",shared.path] as [Any] {
    defaults.set(value,forKey:InputIncidentPreferences.boundedDirectoryKey)
    check(!options([]).valid,"bad saved route cannot fall back to shared logs")
    check(options(["--preserve-input-incidents",wanted.path]).preserve,"another session's explicit preserve route wins")
    check(!options(["--diagnose-input-incidents",wanted.path]).bounded,"another explicit legacy route wins")
}
defaults.removeObject(forKey:InputIncidentPreferences.boundedDirectoryKey)

let run=UUID().uuidString
func payload(_ id:Int,_ phase:Int,_ manual:Bool=false)->Data {
    try! JSONSerialization.data(withJSONObject:["schema":1,"build":"test","runID":run,
        "incident":id,"phase":phase,"trigger":manual ? 1:2,"padding":String(repeating:"x",count:32)],options:.sortedKeys)
}
func snapshot(_ dir:URL)throws->[String:Data] {
    let paths=try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
    return try Dictionary(uniqueKeysWithValues:paths.map{($0.lastPathComponent,try Data(contentsOf:$0))})
}
func pair(_ store:DiagnosticLogStore,_ id:Int,_ manual:Bool=false){
    check(store.save(payload(id,0,manual),incident:id,phase:0,automatic:!manual) == .saved,"pre save")
    check(store.save(payload(id,1,manual),incident:id,phase:1,automatic:!manual) == .saved,"post save")
}
let old=root.appendingPathComponent("old-investigation")
let investigator=DiagnosticLogStore(directory:old,policy:.investigation,persistentOwnership:true)
check(investigator.verifyReadiness().ready,"old investigation ready")
pair(investigator,1);pair(investigator,2,true)
let oldBytes=try snapshot(old)
let refuse=DiagnosticLogStore(directory:old,policy:.incidentDefault,persistentOwnership:true,requiresBoundedPriorPolicy:true)
check(!refuse.verifyReadiness().ready,"bounded mode refuses unbounded ownership before pruning")
check(refuse.save(payload(3,0),incident:3,phase:0,automatic:true) == .unavailable,"rejected investigation cannot publish a later capture")
check(try snapshot(old)==oldBytes,"rejected investigation retains every filename and byte including metadata")

let invalid=root.appendingPathComponent("invalid-policy")
let transientBounded=root.appendingPathComponent("invalid-transient")
let transientStore=DiagnosticLogStore(directory:transientBounded,policy:.incidentDefault,requiresBoundedPriorPolicy:true)
check(!transientStore.verifyReadiness().ready,"bounded proof requires persistent ownership")
check(transientStore.save(payload(1,0),incident:1,phase:0,automatic:true) == .unavailable,"invalid transient combination cannot publish captures or status")
check(!fm.fileExists(atPath:transientBounded.path),"invalid transient combination opens no directory")
let invalidStore=DiagnosticLogStore(directory:invalid,policy:.investigation,persistentOwnership:true,requiresBoundedPriorPolicy:true)
check(!invalidStore.verifyReadiness().ready,"bounded mode cannot issue readiness for an unbounded policy")
check(!fm.fileExists(atPath:invalid.path),"invalid policy creates no destination")
let archived=root.appendingPathComponent("invalid-archive")
let archiveStore=DiagnosticLogStore(directory:archived,policy:.incidentDefault,persistentOwnership:true,
    archiveDirectory:root.appendingPathComponent("archive"),requiresBoundedPriorPolicy:true)
check(!archiveStore.verifyReadiness().ready,"bounded mode rejects a growing external archive")
check(!fm.fileExists(atPath:archived.path),"archive rejection creates no destination")

let fresh=root.appendingPathComponent("bounded"),policy=DiagnosticLogRetentionPolicy(maximumAutomaticFiles:4,maximumAutomaticBytes:2048,maximumManualBytes:2048)
var bounded:DiagnosticLogStore?=DiagnosticLogStore(directory:fresh,policy:policy,persistentOwnership:true,requiresBoundedPriorPolicy:true)
check(bounded!.verifyReadiness().ready,"fresh bounded writer proves actual write/read")
pair(bounded!,1);pair(bounded!,2,true)
let manual=try snapshot(fresh).filter{$0.key.hasPrefix("incident-2-")}
pair(bounded!,3);pair(bounded!,4)
check(bounded!.usage.files==4 && bounded!.usage.bytes<=2048,"automatic pair rotation respects count and bytes")
check(!(try snapshot(fresh)).keys.contains{$0.hasPrefix("incident-1-")},"only new bounded cohort's oldest automatic pair removed")
for (name,data) in manual{check(try Data(contentsOf:fresh.appendingPathComponent(name))==data,"automatic rotation preserves bounded manual records")}
let firstFiles=try snapshot(fresh).filter{$0.key.hasPrefix("incident-")}
let beforeContender=try snapshot(fresh)
let contender=DiagnosticLogStore(directory:fresh,policy:policy,persistentOwnership:true,requiresBoundedPriorPolicy:true)
check(!contender.verifyReadiness().ready,"a second bounded writer is rejected")
check(contender.save(payload(5,0),incident:5,phase:0,automatic:true) == .unavailable,"rejected writer cannot publish after readiness failure")
check(contender.status.lastFailureStage==3,"rejected writer uses compatible ownership failure stage")
check(try snapshot(fresh)==beforeContender,"rejected writer changes no capture, status or ownership bytes")
bounded=nil
let resumed=DiagnosticLogStore(directory:fresh,policy:policy,persistentOwnership:true,requiresBoundedPriorPolicy:true)
check(resumed.verifyReadiness().ready,"bounded ownership resumes after previous writer closes")
check(try snapshot(fresh).filter{$0.key.hasPrefix("incident-")}==firstFiles,"bounded restart preserves live records")
let beforeOversize=try snapshot(fresh).filter{$0.key.hasPrefix("incident-")}
check(resumed.save(Data(repeating:32,count:2049),incident:5,phase:0,automatic:true) == .limit,"oversize automatic record refused")
check(resumed.save(Data(repeating:32,count:2049),incident:6,phase:0,automatic:false) == .limit,"oversize manual record refused")
check(try snapshot(fresh).filter{$0.key.hasPrefix("incident-")}==beforeOversize,"oversize refusal preserves prior evidence")
check(try snapshot(old)==oldBytes,"new bounded rotations leave old investigation unchanged")
check(resumed.status.maximumAutomaticBytes==2048 && resumed.status.maximumManualBytes==2048,"status reports actual writer bounds")
let receipt=DiagnosticReadinessReceipt.make(token:UUID().uuidString,runID:run,bounded:true)
check(receipt.bounded==true && receipt.pid==getpid(),"current-process receipt proves bounded configuration")
check(DiagnosticReadinessReceipt.make(token:"test",runID:run).bounded==false,"legacy receipt configuration remains unbounded")
print("PASS \(checks) isolated bounded configuration, preservation, rotation, refusal and process-proof checks; no app/keys/TCC")
