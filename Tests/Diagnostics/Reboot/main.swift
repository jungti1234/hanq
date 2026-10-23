import Foundation
import Darwin

var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if (try? value()) != true{fputs("FAIL: \(message)\n",stderr);exit(1)}}
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("hanq-reboot-"+UUID().uuidString)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer{try? fm.removeItem(at:root)}
let policy=DiagnosticLogRetentionPolicy(maximumAutomaticFiles:4,maximumAutomaticBytes:100,maximumManualBytes:80)
let indexName=".automatic-ownership-v1.index"
func index(_ dir:URL)throws->[String:Any]{try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent(indexName))) as! [String:Any]}
func edit(_ dir:URL,_ change:(inout [String:Any])->Void)throws{
    var value=try index(dir);change(&value)
    try JSONSerialization.data(withJSONObject:value).write(to:dir.appendingPathComponent(indexName))
}
func capture(_ store:DiagnosticLogStore,_ id:Int,_ automatic:Bool){
    for phase in 0...1{check(store.save(Data(repeating:32,count:20),incident:id,phase:phase,automatic:automatic) == .saved,"pair saves")}
}
func fixture(_ name:String,parent:URL=root)throws->URL{
    let dir=parent.appendingPathComponent(name),store=DiagnosticLogStore(directory:dir,policy:policy,persistentOwnership:true)
    capture(store,1,true);capture(store,2,false);return dir
}
func remount(_ dir:URL)throws{
    try edit(dir){v in
        v["bootUUID"]=UUID().uuidString;v["device"]=(v["device"] as! Int64)+17
        for key in ["files","manualFiles"] {
            v[key]=(v[key] as! [[String:Any]]).map{entry in var r=entry;r["device"]=(r["device"] as! Int64)+17;r["ctime"]=(r["ctime"] as! Int64)+1;return r}
        }
        var r=v["statusFile"] as! [String:Any];r["device"]=(r["device"] as! Int64)+17;r["ctime"]=(r["ctime"] as! Int64)+1;v["statusFile"]=r
    }
}
func refuses(_ dir:URL,_ message:String){
    let store=DiagnosticLogStore(directory:dir,policy:policy,persistentOwnership:true)
    check(store.save(Data([32]),incident:10,phase:0,automatic:false) == .unavailable,message)
    check(store.status.lastFailureStage==3,"ownership refusal remains explicit")
    check(store.legacyArchive==nil,"new-format failures never archive/reset the store")
}
let reboot=try fixture("reboot")
try remount(reboot)
let resumed=DiagnosticLogStore(directory:reboot,policy:policy,persistentOwnership:true)
resumed.prepareOwnership()
check(resumed.usage.bytes==40 && resumed.manualUsage.bytes==40,"volume/inode/birth/hash resume both budgets after device and ctime changes")
check(resumed.status.saved==4 && resumed.lastCaptureIncident==2,"reboot resumes counters and event seed")
capture(resumed,3,true);capture(resumed,4,false);capture(resumed,5,true);capture(resumed,6,false)
check(resumed.usage.bytes==80 && resumed.manualUsage.bytes==80,"reboot preserves independent quotas")
check(resumed.status.evictedGroups==2 && resumed.status.evictedFiles==4,"reboot retains oldest-pair rotation")
check(try (index(reboot)["schema"] as? Int)==3,"resumed writes schema3")
let again=DiagnosticLogStore(directory:reboot,policy:policy,persistentOwnership:true)
again.prepareOwnership();check(again.status.saved==12 && again.usage==resumed.usage,"same-boot app relaunch also resumes")
let exported=root.appendingPathComponent("resumed-export")
try again.copyExportSnapshot(to:exported)
let exportedNames=try fm.contentsOfDirectory(atPath:exported.path).filter{$0.hasPrefix("incident-")}
check(exportedNames.count==8,"reboot-restored records remain exportable")
for name in exportedNames{check(try Data(contentsOf:exported.appendingPathComponent(name))==Data(contentsOf:reboot.appendingPathComponent(name)),"resumed export bytes match")}

let wrongVolume=try fixture("volume");try remount(wrongVolume)
try edit(wrongVolume){$0["volumeUUID"]=UUID().uuidString};refuses(wrongVolume,"other volume UUID rejected")
let wrongDirectory=try fixture("directory");try remount(wrongDirectory)
try edit(wrongDirectory){$0["inode"]=(($0["inode"] as! UInt64)+1)};refuses(wrongDirectory,"other directory inode rejected")
let reusedDirectory=try fixture("directory-birth");try remount(reusedDirectory)
try edit(reusedDirectory){$0["birth"]=(($0["birth"] as! Int64)+1)};refuses(reusedDirectory,"reused directory inode with other creation time rejected")
let sameBoot=try fixture("same-boot");try edit(sameBoot){$0["device"]=(($0["device"] as! Int64)+1)}
refuses(sameBoot,"device mismatch within same boot is not excused")
let wrongFile=try fixture("file-birth");try remount(wrongFile)
try edit(wrongFile){v in var r=v["files"] as! [[String:Any]];r[0]["birth"]=(r[0]["birth"] as! Int64)+1;v["files"]=r}
refuses(wrongFile,"reused file inode with other creation time rejected")
let badHash=try fixture("hash");try remount(badHash)
try edit(badHash){v in var r=v["files"] as! [[String:Any]];r[0]["digest"]=String(repeating:"0",count:64);v["files"]=r}
refuses(badHash,"content fingerprint mismatch rejected")
let badStatus=try fixture("status-hash");try remount(badStatus)
try edit(badStatus){v in var r=v["statusFile"] as! [String:Any];r["digest"]=String(repeating:"0",count:64);v["statusFile"]=r}
refuses(badStatus,"status fingerprint mismatch rejected")
let missing=try fixture("missing-identity");try remount(missing)
try edit(missing){$0.removeValue(forKey:"bootUUID")};refuses(missing,"missing durable identity rejected")

// Edit bytes in place and restore nanosecond mtime, preserving inode and birth.
let altered=try fixture("in-place");try remount(altered)
let row=(try index(altered)["files"] as! [[String:Any]])[0]
let path=altered.appendingPathComponent(row["name"] as! String)
var before=stat();check(lstat(path.path,&before)==0,"tamper fixture stat")
let fd=open(path.path,O_WRONLY|O_NOFOLLOW);check(fd>=0,"tamper fixture open")
var byte:UInt8=33;check(write(fd,&byte,1)==1,"same-size in-place edit")
var times=[before.st_atimespec,before.st_mtimespec]
check(futimens(fd,&times)==0,"restore exact mtime");close(fd)
refuses(altered,"same-size same-inode same-mtime changed bytes rejected after boot")
check(try Data(contentsOf:path).first==33,"tampered evidence never overwritten")

// A strictly verified same-boot legacy store upgrades without moving evidence.
let upgrade=try fixture("legacy-same-boot")
try edit(upgrade){$0["schema"]=2}
let upgraded=DiagnosticLogStore(directory:upgrade,policy:policy,persistentOwnership:true)
upgraded.prepareOwnership()
check(upgraded.status.saved==4 && upgraded.legacyArchive==nil,"verified legacy schema2 upgrades in place")
check(try index(upgrade)["schema"] as? Int==3,"legacy upgrade writes stable identity")

// A legacy remount cannot prove ownership; preserve the complete namespace,
// including unindexed historical manual data and unrelated failure companions.
for schema in 1...2 {
    let legacy=try fixture("legacy-remount-\(schema)")
    let extra=legacy.appendingPathComponent("prior-investigation.txt")
    try Data("retained evidence".utf8).write(to:extra)
    try edit(legacy){v in
        v["schema"]=schema;v["device"]=(v["device"] as! Int64)+17
        for key in ["files","manualFiles"] {v[key]=(v[key] as! [[String:Any]]).map{entry in var r=entry;r["device"]=(r["device"] as! Int64)+17;r["ctime"]=(r["ctime"] as! Int64)+1;return r}}
        var r=v["statusFile"] as! [String:Any];r["device"]=(r["device"] as! Int64)+17;v["statusFile"]=r
        if schema==1{v.removeValue(forKey:"manualFiles")}
    }
    let old=try fm.contentsOfDirectory(at:legacy,includingPropertiesForKeys:nil).map{($0.lastPathComponent,try Data(contentsOf:$0))}
    let recovered=DiagnosticLogStore(directory:legacy,policy:policy,persistentOwnership:true)
    recovered.prepareOwnership()
    check(recovered.legacyArchive != nil,"legacy remount archived as opaque preserved directory")
    for (name,bytes) in old{check(try Data(contentsOf:recovered.legacyArchive!.appendingPathComponent(name))==bytes,"every legacy byte preserved")}
    check(recovered.usage.files==0 && recovered.manualUsage.files==0,"unproven legacy files never adopted for pruning")
    capture(recovered,1,false);capture(recovered,2,true)
    check(recovered.status.saved==4 && recovered.status.evictedFiles==0,"new bounded store accepts both categories")
    let restarted=DiagnosticLogStore(directory:legacy,policy:policy,persistentOwnership:true)
    restarted.prepareOwnership();check(restarted.status.saved==4,"recovered namespace resumes after relaunch")
}

// A different file/inode or unsafe archive destination is never hidden by reset.
let replaced=try fixture("legacy-replaced");try edit(replaced){v in
    v["schema"]=2;v["device"]=(v["device"] as! Int64)+17
    for key in ["files","manualFiles"]{v[key]=(v[key] as! [[String:Any]]).map{e in var r=e;r["device"]=(r["device"] as! Int64)+17;return r}}
    var r=v["statusFile"] as! [String:Any];r["device"]=(r["device"] as! Int64)+17;v["statusFile"]=r
}
let target=(try index(replaced)["files"] as! [[String:Any]])[0]["name"] as! String
try fm.removeItem(at:replaced.appendingPathComponent(target));try Data(repeating:32,count:20).write(to:replaced.appendingPathComponent(target))
refuses(replaced,"changed legacy file blocks archival recovery")
for symlink in [false,true] {
    let parent=root.appendingPathComponent("archive-refusal-\(symlink)")
    try fm.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let blocked=try fixture("store",parent:parent)
    try remount(blocked);try edit(blocked){$0["schema"]=2}
    let archive=parent.appendingPathComponent("InvestigationArchives")
    if symlink{try fm.createSymbolicLink(at:archive,withDestinationURL:root)}
    else{try Data("existing evidence".utf8).write(to:archive)}
    let snapshot=try fm.contentsOfDirectory(at:blocked,includingPropertiesForKeys:nil).map{($0.lastPathComponent,try Data(contentsOf:$0))}
    refuses(blocked,"unsafe archive path blocks recovery without changing original namespace")
    for (name,bytes) in snapshot{check(try Data(contentsOf:blocked.appendingPathComponent(name))==bytes,"archive failure preserves every original byte")}
}
print("PASS \(checks) stable reboot identity, hashes, independent quotas, legacy preservation and tamper refusal; no OS input/reboot")
