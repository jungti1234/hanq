import Foundation
import Darwin
import CryptoKit
import Compression

setbuf(stdout,nil)
var checks=0
func check(_ value:@autoclosure ()throws->Bool,_ message:String){checks+=1;if (try? value()) != true{fputs("FAIL streaming storage: \(message)\n",stderr);exit(1)}}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
func directory(_ name:String)->URL{let url=root.appendingPathComponent(name);try! fm.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return url}
func frame(_ n:Int,_ ms:Int)->InputIncidentTrace.Frame{.init(sequence:n,milliseconds:ms,lane:.main,kind:.context,event:0,edge:0,category:0,inputOrigin:0,consumed:false,durationMicros:0,count:0,selected:false,field:0,decisionTiming:nil,observationTiming:nil)}
func raw(_ result:DiagnosticPayloadStream.Result)->Data {
    let input=result.chunks.reduce(into:Data()){$0.append($1)}
    if !result.compressed{return input}
    var output=Data(count:result.rawBytes)
    let count=output.withUnsafeMutableBytes{dst in input.withUnsafeBytes{src in compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,dst.count,src.bindMemory(to:UInt8.self).baseAddress!,src.count,nil,COMPRESSION_ZLIB)}}
    check(count==result.rawBytes,"existing decoder accepts streamed zlib");return output
}
let special=String(repeating:"fixture/\"\\\u{0}\n\t한글😀",count:7000)
let metadata:DiagnosticJSON = .object(["schema":.integer(1),"build":.string("420"),"payload":.string(special),"values":.array([.null,.bool(true),.bool(false),.integer(Int64.min),.integer(Int64.max),.real(0.125)])])
let changes=[DiagnosticJSON.Change(path:[],value:metadata),.init(path:["payload"],value:nil),.init(path:["payload"],value:.null)]
let small=try! (1...100).map{try DiagnosticPackedFrame(frame($0,$0))}
for tuple in [([],[],[]), (DiagnosticPackedCodec.shared.fields,small,changes)] as [([String],[DiagnosticPackedFrame],[DiagnosticJSON.Change])] {
    let result=try! DiagnosticPayloadStream.encode(fields:tuple.0,frames:tuple.1,changes:tuple.2)
    check(result.chunks.allSatisfy{$0.count<=64*1024},"bounded output chunks")
    let streamed=raw(result)
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    let old=try! encoder.encode(DiagnosticSharedStore.Payload(fields:tuple.0,frames:tuple.1,changes:tuple.2))
    check(try (JSONSerialization.jsonObject(with:streamed) as! NSDictionary).isEqual(to:JSONSerialization.jsonObject(with:old) as! [AnyHashable:Any]),"reference JSON payload values match across Unicode, escaping, null and integer bounds")
}
let packets=try! (1...65536).map{try DiagnosticPackedFrame(frame($0,($0-1)*60000/65536))}
let run=UUID().uuidString,live=directory("live")
let store=DiagnosticSharedStore(directory:live,preserve:true)
let base:DiagnosticJSON = .object(["schema":.integer(1),"build":.string("420"),"coverage":.object(["frames":.integer(65536),"requestedFromMilliseconds":.integer(0),"requestedThroughMilliseconds":.integer(60000)])])
func input(_ frames:[DiagnosticPackedFrame],_ phase:Int,_ incident:Int=1)->DiagnosticSharedStore.Input{
    var metadata=base
    if phase==1{try! metadata.apply([.init(path:["coverage","requestedFromMilliseconds"],value:.integer(60001)),.init(path:["coverage","requestedThroughMilliseconds"],value:.integer(63000))])}
    return .init(metadata:metadata,frames:frames,run:run,incident:incident,phase:phase,trigger:1,milliseconds:100_000_000+Int64(phase*3000))
}
check(store.submit(input(packets,0)),"maximum 65536 pre frames stored")
let post=try! (1...65536).map{try DiagnosticPackedFrame(frame(65536+$0,60000+$0*3000/65536))}
check(store.submit(input(post,1)),"dense complete three-second post stored")
check(store.stats.saved==2 && store.stats.suppliedFrames==131072,"both phases complete")
for name in try! fm.contentsOfDirectory(atPath:store.directory.path).filter(DiagnosticSharedStore.validName) {
    let selection=try! DiagnosticArchiveReader.selection(name,in:store.directory)
    if selection.header.role==1{continue}
    var n=0
    _ = try! selection.visit{value in
        n+=1;check(value["sequence"] as? Int==n+selection.header.phase*65536,"all maximum frames preserve order")
    }
    check(n==65536,"phase has exactly 65536 frames")
}
// Leave this large fixture for separate, fresh-process preview/ZIP measurement.
let snapshot=directory("maximum-input")
try! store.copySnapshot(into:snapshot)
let journal=DiagnosticCriticalJournal(directory:live)
let important=OperationalFailure.posix(.probeLaunch,ENOSPC)
for _ in 0..<50{for _ in 0..<64{journal.record(important)};check(journal.flush(timeout:5),"important error batch flushed")}
let liveFD=open(live.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
try! DiagnosticCriticalJournal.forEachFile(liveFD){name,data in
    let file=snapshot.appendingPathComponent(name);try data.write(to:file)
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
}
close(liveFD)
for (name,value) in [("review-dates.json","{}"),("storage-status.json","{\"schema\":1,\"status\":{}}")] {
    let p=snapshot.appendingPathComponent(name);try! Data(value.utf8).write(to:p);try! fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:p.path)
}
var blocked=true,total=0,retry=100.0
let partial=DiagnosticSharedStore(directory:directory("partial"),preserve:true,retryClock:{retry},writer:{fd,p,n in
    if blocked,total>=100000{errno=ENOSPC;return -1}
    let count=Darwin.write(fd,p,blocked ? min(n,100000-total):n)
    if count>0{total+=count};return count
})
check(!partial.submit(input(packets,0)),"failure occurs after multiple header/output chunks")
check(partial.stats.lastFailure?.underlyingPOSIX==Int(ENOSPC) && partial.stats.pendingBytes>0,"partial cause and pending bytes retained")
let written=partial.stats.writtenBytes
for _ in 0..<100{_ = partial.drain()}
check(partial.stats.writtenBytes==written,"backoff adds no writes")
let pendingSnapshot=directory("pending-input")
let pendingInfo=try! partial.copyReviewSnapshot(into:pendingSnapshot,request:DiagnosticSnapshotRequest())
for (name,value) in [("review-dates.json",Data("{}".utf8)),("storage-status.json",Data("{\"schema\":1,\"status\":{}}".utf8)),("pending-export.json",try! JSONEncoder().encode(pendingInfo))]{
    try! DiagnosticSharedStore.writeExport(value,to:pendingSnapshot.appendingPathComponent(name))
}
check(pendingInfo.captures.count==1 && partial.stats.writtenBytes==written,"maximum pending memory export adds no source writes")
var rescuedFrames=0
_ = try! DiagnosticArchiveReader.selection(pendingInfo.captures[0].file,in:pendingSnapshot).visit{value in rescuedFrames+=1;check(value["sequence"] as? Int==rescuedFrames,"memory export exact sequence")}
check(rescuedFrames==65536 && partial.stats.pendingBytes>0,"maximum memory copy preserves all frames and original retry queue")
blocked=false;retry+=61
check(partial.drain() && partial.stats.saved==1 && partial.stats.pendingBytes==0,"retry resumes across chunk boundary")
let name=try! fm.contentsOfDirectory(atPath:partial.directory.path).first{DiagnosticSharedStore.validName($0) && (try? DiagnosticSharedStore.readHeader(partial.directory.appendingPathComponent($0)).0.role) != 1}!
var restored=0
_ = try! DiagnosticArchiveReader.selection(name,in:partial.directory).visit{value in restored+=1;check(value["sequence"] as? Int==restored,"retry exact sequence")}
check(restored==65536,"retry restores all frames")
let file=partial.directory.appendingPathComponent(name)
let original=try! DiagnosticArchiveIO.scan(file,maximum:16*1024*1024)
let copy=root.appendingPathComponent("cancelled-copy")
var calls=0
do{try DiagnosticArchiveIO.copy(file,to:copy,bytes:original.bytes,digest:original.digest,check:{calls+=1;if calls==4{throw DiagnosticReviewError.invalidArchive}});check(false,"cancel copy")}
catch{check(!fm.fileExists(atPath:copy.path),"cancelled copy removes incomplete output")}
check(try DiagnosticArchiveIO.scan(file,maximum:16*1024*1024).digest==original.digest,"cancelled copy preserves source")
let tampered=root.appendingPathComponent("tampered-source")
try! fm.copyItem(at:file,to:tampered)
let fd=open(tampered.path,O_WRONLY|O_NOFOLLOW);var byte:UInt8=0
check(pwrite(fd,&byte,1,0)==1,"tamper fixture");close(fd)
do{try DiagnosticArchiveIO.copy(tampered,to:copy,bytes:original.bytes,digest:original.digest);check(false,"changed source")}
catch{check(!fm.fileExists(atPath:copy.path),"digest mismatch never publishes a changed file")}
let oversized:DiagnosticJSON = .string(String(repeating:"x",count:17*1024*1024))
do{_ = try DiagnosticPayloadStream.encode(fields:[],frames:[],changes:[.init(path:[],value:oversized)]);check(false,"oversized payload")}
catch{check(true,"oversized raw payload rejected before disk spooling")}
print("MEASURE maximum fixture: \(store.stats.writtenBytes) bytes; \(store.stats.writeCalls) writes; \(snapshot.path)")
print("PASS: streaming storage \(checks) checks (maximum windows, exact frames, bounded chunks, partial recovery, cancellation, compatibility)")
