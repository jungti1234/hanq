import Foundation
import Darwin
import CryptoKit

@_silgen_name("hanq_metrics") func readMetrics(_ values:UnsafeMutablePointer<UInt64>)->Int32
func metrics()->[String:UInt64] {
    var values=[UInt64](repeating:0,count:7)
    precondition(readMetrics(&values)==0)
    return Dictionary(uniqueKeysWithValues:zip(["residentBytes","physicalFootprintBytes","kernelAttributedWrittenBytes","peakResidentBytes","userNanoseconds","systemNanoseconds","peakPhysicalFootprintBytes"],values))
}
func emit(_ value:[String:Any]){print(String(data:try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)}
func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:"StreamingTest",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath),fm=FileManager.default
let mode=CommandLine.arguments[1]
let initial=metrics()
let group=DispatchGroup();group.enter()
DispatchQueue(label:"hanq.streaming.validation").async {
    do {
        let snapshot=try DiagnosticReviewSnapshot(directory:root.appendingPathComponent("input"))
        let incident=snapshot.incidents.first{$0.manual}!
        emit(["stage":"listed","memory":metrics()])
        if mode=="load" {
            let document=try incident.originals[0]!.review().document
            emit(["stage":"loaded","memory":metrics(),"sections":document.sections.count])
        }else {
            let environment=DiagnosticReviewEnvironment(appVersion:"fixture",build:"420",macOSVersion:"fixture",modelIdentifier:nil,keyboardLayout:.unknownOrOther,koreanKeyEnabled:true,hanjaKeyEnabled:true,hudEnabled:false,capsLockSwitchEnabled:nil,loginItemState:.unknown,diagnosticsEnabled:true,inputMonitoringEnabled:false,cachedAccessibilityPermission:false,updateRestricted:false)
            let files=try snapshot.files(selected:[incident.id],environment:environment)
            emit(["stage":"prepared","memory":metrics(),"files":files.count,"sourceBytes":files.reduce(0){$0+$1.bytes}])
            if mode=="zip" {
                let archive=try DiagnosticReviewArchive(files:files)
                let output=root.appendingPathComponent("selected.zip")
                try archive.save(to:output)
                emit(["stage":"zipped","memory":metrics(),"zipBytes":archive.bytes])
                let extracted=root.appendingPathComponent("extracted")
                let unzip=Process();unzip.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
                unzip.arguments=["-x","-k",output.path,extracted.path]
                try unzip.run();unzip.waitUntilExit();try require(unzip.terminationStatus==0,"ZIP extraction failed")
                let restored=extracted.appendingPathComponent("HanQ-Diagnostics")
                for file in files {
                    let copied=restored.appendingPathComponent(file.path)
                    let actual=try DiagnosticArchiveIO.scan(copied,maximum:32*1024*1024)
                    // Materialize only one bounded original for an independent
                    // equality check; production preparation does not do this.
                    try autoreleasepool {
                        let original=try file.data
                        try require(actual.bytes==original.count && actual.digest==SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined(),"original bytes differ: "+file.path)
                    }
                }
                var captures:[[String:Any]]=[]
                for original in incident.originals.values {
                    var counts=[Int:Int](),count=0,hash=SHA256()
                    let selection=try DiagnosticArchiveReader.selection(original.filename,in:restored)
                    _ = try selection.visit{frame in
                        count+=1;counts[frame["kind"] as? Int ?? 0,default:0]+=1
                        hash.update(data:try JSONSerialization.data(withJSONObject:frame,options:[.sortedKeys]))
                    }
                    try require(count==selection.header.frameCount,"restored frame count")
                    captures.append(["phase":original.header.phase,"frames":count,"kinds":counts.map{["kind":$0.key,"count":$0.value]},"semanticSHA256":hash.finalize().map{String(format:"%02x",$0)}.joined()])
                }
                var errorIDs=Set<String>(),errorCount=0
                for file in files where DiagnosticCriticalJournal.exportedName(file.path) {
                    let data=try Data(contentsOf:restored.appendingPathComponent(file.path))
                    guard let scanned=DiagnosticCriticalLane.scan(data,visit:{event in
                        if event.failure.stage == .probeLaunch{errorCount+=1;errorIDs.insert(event.run+":"+String(event.sequence))}
                    }),scanned.incomplete==0 else{throw DiagnosticReviewError.invalidArchive}
                }
                try require(errorCount==errorIDs.count,"duplicate important error identities")
                emit(["stage":"restored","memory":metrics(),"filesVerified":files.count,"captures":captures,"importantErrors":errorCount,"uniqueImportantErrors":errorIDs.count])
            }
            withExtendedLifetime(files){}
        }
        withExtendedLifetime(snapshot){}
    }catch{fputs("FAIL streaming: \(error)\n",stderr);exit(1)}
    group.leave()
}
group.wait()
emit(["stage":"complete","initial":initial,"memory":metrics()])
