import Foundation
import Darwin
@_silgen_name("hanq_metrics") func readMetrics(_ values:UnsafeMutablePointer<UInt64>)->Int32
func metrics()->[String:UInt64]{var v=[UInt64](repeating:0,count:7);let status=readMetrics(&v);guard status==0 else{return ["unavailable":UInt64(bitPattern:Int64(status))]};return Dictionary(uniqueKeysWithValues:zip(["residentBytes","physicalFootprintBytes","kernelAttributedWrittenBytes","peakResidentBytes","userNanoseconds","systemNanoseconds","peakPhysicalFootprintBytes"],v))}
func emit(_ value:[String:Any]){let data=try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);FileHandle.standardOutput.write(data+Data([10]))}
let mode=CommandLine.arguments[1],root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let initial=metrics(),start=ProcessInfo.processInfo.systemUptime
var rows=0,bytes=0,peak=initial
func sample(){let value=metrics();for(k,v)in value{peak[k]=max(peak[k] ?? 0,v)}}
if mode=="writer" {
    struct Fixture:Decodable{let metadata:DiagnosticJSON,frames:[InputIncidentTrace.Frame],run:String,incident:Int,phase:Int,trigger:Int,milliseconds:Int64}
    var wall=100000.0
    let store=DiagnosticSharedStore(directory:root.appendingPathComponent("output"),preserve:true,clock:{wall})
    while let line=readLine(){autoreleasepool{
        do {
            let data=Data(line.utf8),fixture=try JSONDecoder().decode(Fixture.self,from:data)
            let packets=try fixture.frames.map(DiagnosticPackedFrame.init)
            wall=Double(fixture.milliseconds)/1000
            guard store.submit(.init(metadata:fixture.metadata,frames:packets,run:fixture.run,incident:fixture.incident,phase:fixture.phase,trigger:fixture.trigger,milliseconds:fixture.milliseconds)) else{throw DiagnosticPackedError.invalid}
            rows+=fixture.frames.count;bytes+=data.count
            if store.stats.saved%100==0 {sample();emit(["progressCaptures":store.stats.saved,"logicalBytes":store.stats.writtenBytes])}
        }catch{fputs("writer replay failed: \(error)\n",stderr);exit(1)}
    }}
    sample()
    let stats=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(store.stats))
    emit(["mode":mode,"initial":initial,"final":metrics(),"peakSamples":peak,"rows":rows,"inputBytes":bytes,"seconds":ProcessInfo.processInfo.systemUptime-start,"stats":stats])
}else {
    let capacity=mode=="legacy4096" ? 4096:21524
    var old:[InputIncidentTrace.Frame?]=mode.hasPrefix("legacy") || mode=="inline60" ? Array(repeating:nil,count:capacity):[]
    let history=mode=="packed" ? DiagnosticFrameHistory(capacity:65536):nil
    var traceTime=0.0
    let faultLock=NSLock();var fault=false
    let journal=mode=="outage" ? DiagnosticCriticalJournal(directory:root.appendingPathComponent("critical")):nil
    if let journal{OperationalDiagnostics.shared.installJournal(journal)}
    let trace=["trace","outage"].contains(mode) ? InputIncidentTrace(secureInput:{false},destination:root.appendingPathComponent("trace"),clock:{traceTime},sharedWriter:{fd,p,n in
        faultLock.lock();let fail=fault;faultLock.unlock()
        if fail{errno=ENOSPC;return -1};return Darwin.write(fd,p,n)
    }):nil
    trace?.flush()
    let allocated=metrics()
    var rawBytes=0,maximumPacket=0,roundtrips=0
    while let line=readLine(){autoreleasepool{
        do {
            let data=Data(line.utf8),frame=try JSONDecoder().decode(InputIncidentTrace.Frame.self,from:data)
            if let history{history[rows%65536]=frame;history.trim(now:frame.milliseconds)}
            if let trace{traceTime=Double(frame.milliseconds)/1000;trace.replayFrameForTest(frame)}
            if !old.isEmpty{old[rows%capacity]=frame}
            if mode=="roundtrip" {
                let packed=try DiagnosticPackedFrame(frame)
                let original=try JSONSerialization.jsonObject(with:data) as! NSDictionary
                let decoded=try DiagnosticPackedCodec.object(packed.data,fields:DiagnosticPackedCodec.shared.fields) as! NSDictionary
                guard original.isEqual(to:decoded as! [AnyHashable:Any]) else{throw DiagnosticPackedError.invalid}
                rawBytes+=packed.data.count;maximumPacket=max(maximumPacket,packed.data.count);roundtrips+=1
            }
            rows+=1;bytes+=data.count
            if rows%1000==0{sample()}
        }catch{fputs("frame replay failed at \(rows): \(error)\n",stderr);exit(1)}
    }}
    let beforeCapture=metrics()
    var outage:[String:Any]=[:]
    if mode=="outage",let trace,let journal {
        faultLock.lock();fault=true;faultLock.unlock()
        let cause=OperationalFailure.posix(.probeLaunch,ENOSPC)
        for i in 0..<256 {
            trace.captureForTest(.axDelay);trace.flush()
            journal.record(cause)
            if i%32==0{guard journal.flush(timeout:5) else{exit(2)}}
        }
        trace.captureForTest(.manual);trace.flush();sample()
        let memory=trace.captureMemoryForTest()
        outage=["duringFault":metrics(),"automaticCharged":memory.automatic,"manualCharged":memory.manual,"peakAutomaticCharged":memory.peakAutomatic,"peakManualCharged":memory.peakManual]
        guard memory.automatic<=8*1024*1024,memory.manual<=8*1024*1024,memory.manual>0,journal.flush(timeout:5) else{exit(3)}
        faultLock.lock();fault=false;faultLock.unlock()
        trace.finishCaptureWindowsForTest();trace.flush()
        for _ in 0..<160{if trace.sharedStatsForTest()?.pendingBytes==0{break};Thread.sleep(forTimeInterval:0.05);trace.flush()}
        guard let stats=trace.sharedStatsForTest(),stats.pendingBytes==0,stats.lastFailure==nil else{exit(4)}
        outage["recoveredStats"]=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(stats))
        let after=trace.captureMemoryForTest();outage["automaticChargedAfter"]=after.automatic;outage["manualChargedAfter"]=after.manual
        guard after.automatic==0,after.manual==0,journal.flush(timeout:5) else{exit(5)}
        let fd=open(root.appendingPathComponent("critical").path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        let events=try! DiagnosticCriticalJournal.readFiles(fd).flatMap{DiagnosticCriticalJournal.decode($0.1)?.events ?? []};close(fd)
        let count=events.filter{$0.failure==cause}.count
        outage["importantErrorsRetained"]=count
        outage["triggerFacts"]=events.filter{$0.failure.stage == .incidentTrigger}.count
        outage["admissionRefusals"]=events.filter{$0.failure.stage == .captureDisposition && $0.failure.code==6}.count
        guard count==256 else{exit(6)}
    }
    if let trace,mode != "outage" {
        trace.captureForTest(.axDelay);trace.flush();trace.captureForTest(.manual);trace.flush()
        trace.finishCaptureWindowsForTest();trace.flush()
    }
    sample()
    let retained=history?.retainedCount ?? old.compactMap{$0}.count
    emit(["mode":mode,"outage":outage,"initial":initial,"allocated":allocated,"beforeCapture":beforeCapture,"final":metrics(),"peakSamples":peak,"rows":rows,"inputBytes":bytes,"seconds":ProcessInfo.processInfo.systemUptime-start,"retained":retained,"accountedBytes":trace?.historyBytesForTest() ?? history?.accountedBytes ?? old.count*MemoryLayout<InputIncidentTrace.Frame?>.stride,"packedPayloadBytes":rawBytes,"maximumPacketBytes":maximumPacket,"roundtripEqual":roundtrips])
    trace?.stopAndFlush();withExtendedLifetime(old){};withExtendedLifetime(history){}
}
