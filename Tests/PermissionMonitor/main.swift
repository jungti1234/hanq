import Foundation

// Run the production storage-only helper entrypoint; it never checks TCC or posts keys.
if let i=CommandLine.arguments.firstIndex(of:"--fixture-probe") {
    let directory=URL(fileURLWithPath:CommandLine.arguments[i+1])
    let result=PermissionProbeResult(token:directory.lastPathComponent,pid:getpid(),ax:true,post:true)
    do{try PermissionProbeChannel.send(JSONEncoder().encode(result),to:directory);exit(0)}catch{exit(74)}
}
DiagnosticStorageStartup.runProbeIfRequested()

// Exercise the production monitor without installing taps or changing TCC.
// The launcher is replaceable so a hung LaunchServices call cannot stall tests.
let mode = CommandLine.arguments.last!
if mode == "errors" {
    let secret="private-path-or-input-must-not-appear"
    let wrapped=NSError(domain:NSCocoaErrorDomain,code:640,userInfo:[NSLocalizedDescriptionKey:secret,
        NSUnderlyingErrorKey:NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC),userInfo:[NSFilePathErrorKey:secret])])
    let failure=OperationalFailure.capture(wrapped,stage:.probeWrite)
    precondition(failure.domain == .cocoa && failure.code==640 && failure.underlyingPOSIX==Int(ENOSPC))
    precondition(!String(data:try! JSONEncoder().encode(failure),encoding:.utf8)!.contains(secret))
    for code in [ENOSPC,EACCES,EIO,ENOENT] {
        let result=OperationalIO.writeAll(Data([1,2,3]),to:-1,stage:.probeWrite,write:{_,_,_ in errno=code;return -1})
        precondition(result == .posix(.probeWrite,code))
    }
    var calls=0,received:[UInt8]=[]
    precondition(OperationalIO.writeAll(Data([1,2,3,4]),to:-1,stage:.probeWrite,write:{_,bytes,count in
        calls+=1
        if calls==1{errno=EINTR;return -1}
        received.append(bytes!.load(as:UInt8.self));return min(1,count)
    }) == nil)
    precondition(received == [1,2,3,4] && calls==5)
    precondition(OperationalIO.writeAll(Data([1]),to:-1,stage:.probeWrite,write:{_,_,_ in 0}) == .policy(.probeWrite,1))
    var now:UInt64=1,emissions:[OperationalDiagnostics.Entry]=[]
    let recorder=OperationalDiagnostics(clock:{now},sink:{emissions.append($0)})
    for _ in 0..<10000{recorder.record(failure)}
    precondition(emissions.count==10000 && recorder.snapshot().entries[0].count==10000)
    now+=30_000_000_000;recorder.record(failure)
    precondition(emissions.count==10001 && emissions.last!.count==10001)
    for i in 0..<100{recorder.record(.policy(.probeToken,i))}
    precondition(recorder.snapshot().entries.count==64 && recorder.snapshot().evicted==37 && emissions.count==10101)
    let url=PrivateProbeDirectory.root.appendingPathComponent("hanq-permission-"+UUID().uuidString)
    try! FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let workspace=PrivateProbeDirectory.open(url,prefix:"hanq-permission-")!
    let original=workspace.publishFailure(Data([1,2]),write:{_,_,_ in errno=ENOSPC;return -1})
    precondition(original == .posix(.probeWrite,ENOSPC))
    precondition(try! FileManager.default.contentsOfDirectory(atPath:url.path).isEmpty)
    precondition(workspace.publish(Data([1,2])))
    precondition(workspace.publishFailure(Data([3])) == .posix(.probePublish,EEXIST))
    let invalidStore=DiagnosticLogStore(directory:url.appendingPathComponent("result.json"),policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:1024))
    errno=EIO // A policy rejection must not reuse an unrelated syscall's errno.
    precondition(invalidStore.save(Data([1]),incident:1,phase:0,automatic:true) == .unavailable)
    precondition(OperationalDiagnostics.shared.snapshot().entries.contains{$0.failure == .policy(.storagePrepare,2)})
    let missingStore=DiagnosticLogStore(directory:url.appendingPathComponent("missing/sub"),policy:.init(maximumAutomaticFiles:4,maximumAutomaticBytes:1024))
    precondition(missingStore.save(Data([1]),incident:1,phase:0,automatic:true) == .unavailable)
    precondition(OperationalDiagnostics.shared.snapshot().entries.contains{$0.failure == .posix(.storagePrepare,ENOENT)})
    try! FileManager.default.removeItem(at:url)
    print("PASS: operational causes, privacy, short writes, EINTR, cleanup and aggregation")
    exit(0)
}
if mode == "workspace" {
    let fm=FileManager.default
    var owned:[URL]=[]
    func directory(_ prefix:String="hanq-permission-")->URL {
        let url=PrivateProbeDirectory.root.appendingPathComponent(prefix+UUID().uuidString)
        try! fm.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        owned.append(url);return url
    }
    defer{for url in owned{try? fm.removeItem(at:url)}}
    var checks=0
    func check(_ value:Bool){precondition(value);checks+=1}
    for prefix in ["hanq-permission-","hanq-storage-"] {
        let url=directory(prefix)
        let workspace=PrivateProbeDirectory.open(url,prefix:prefix)!
        let data=Data("{\"fixture\":true}".utf8)
        check(workspace.publish(data))
        check(try! Data(contentsOf:url.appendingPathComponent("result.json"))==data)
        check((try! fm.attributesOfItem(atPath:url.appendingPathComponent("result.json").path)[.posixPermissions] as! NSNumber).intValue==0o600)
        check(!workspace.publish(Data("changed".utf8)))
        check(try! Data(contentsOf:url.appendingPathComponent("result.json"))==data)
        check(PrivateProbeDirectory.open(url,prefix:prefix=="hanq-permission-" ? "hanq-storage-":"hanq-permission-")==nil)
    }
    let broad=directory()
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:broad.path)
    check(PrivateProbeDirectory.open(broad,prefix:"hanq-permission-")==nil)
    let normal=directory(), link=PrivateProbeDirectory.root.appendingPathComponent("hanq-permission-"+UUID().uuidString)
    try! fm.createSymbolicLink(at:link,withDestinationURL:normal);owned.append(link)
    check(PrivateProbeDirectory.open(link,prefix:"hanq-permission-")==nil)
    let protectedLink=PrivateProbeDirectory.root.appendingPathComponent("hanq-storage-"+UUID().uuidString)
    try! fm.createSymbolicLink(at:protectedLink,withDestinationURL:URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Documents"));owned.append(protectedLink)
    check(PrivateProbeDirectory.open(protectedLink,prefix:"hanq-storage-")==nil)
    let nested=normal.appendingPathComponent("hanq-permission-nested")
    try! fm.createDirectory(at:nested,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    check(PrivateProbeDirectory.open(nested,prefix:"hanq-permission-")==nil)
    check(PrivateProbeDirectory.open(directory("unrelated-"),prefix:"unrelated-")==nil)
    check(PrivateProbeDirectory.open(PrivateProbeDirectory.root.appendingPathComponent("hanq-permission-missing-"+UUID().uuidString),prefix:"hanq-permission-")==nil)
    let replaced=directory(), opened=PrivateProbeDirectory.open(replaced,prefix:"hanq-permission-")!
    let moved=replaced.appendingPathExtension("moved")
    try! fm.moveItem(at:replaced,to:moved);owned.append(moved)
    try! fm.createDirectory(at:replaced,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    check(!opened.publish(Data("stale".utf8)))
    check(!fm.fileExists(atPath:moved.appendingPathComponent("result.json").path))
    check(!fm.fileExists(atPath:replaced.appendingPathComponent("result.json").path))
    let changed=directory(), handle=PrivateProbeDirectory.open(changed,prefix:"hanq-permission-")!
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:changed.path)
    check(!handle.publish(Data("unsafe".utf8)))
    let resultLink=directory(), sentinel=normal.appendingPathComponent("sentinel")
    try! Data("keep".utf8).write(to:sentinel)
    try! fm.createSymbolicLink(at:resultLink.appendingPathComponent("result.json"),withDestinationURL:sentinel)
    check(!PrivateProbeDirectory.open(resultLink,prefix:"hanq-permission-")!.publish(Data("overwrite".utf8)))
    check(try! Data(contentsOf:sentinel)==Data("keep".utf8))
    check(!PrivateProbeDirectory.open(normal,prefix:"hanq-permission-")!.publish(Data(repeating:0,count:8193)))
    print("PASS: private probe workspace \(checks) checks")
    for url in owned{try? fm.removeItem(at:url)}
    exit(0)
}
let launched=DispatchSemaphore(value:0),changed=DispatchSemaphore(value:0),terminated=DispatchSemaphore(value:0)
let lock=NSLock()
var count=0,grants=0,errors:[OperationalFailure]=[],reason:String?,directories:[URL]=[]
var children:[Process]=[]
let gate=FreshPermissionGate()
let first=gate.block(),later=gate.block()
precondition(!gate.restore(first) && !gate.allowsInput && gate.restore(later) && gate.allowsInput)
// Real process startup and Security verification use the production deadline.
// Only injected error paths shorten it to keep the fixture bounded and fast.
let probeTimeout:TimeInterval=["process","foreign-signature"].contains(mode) ? 2:0.4
let monitor=FreshPermissionMonitor(interval:0.05,timeout:probeTimeout,retryBase:0.05,launchProbe:{directory,completion in
    precondition(PrivateProbeDirectory.open(directory,prefix:"hanq-permission-") != nil)
    lock.lock();count+=1;let attempt=count;directories.append(directory);lock.unlock();launched.signal()
    if mode=="stalled-launch"{Thread.sleep(forTimeInterval:1);return}
    if mode=="missing-result" || mode=="stop" || (mode=="recover" && attempt==1){completion(nil);return}
    if mode=="launch-error"{completion(NSError(domain:NSOSStatusErrorDomain,code:-10810));return}
    if mode=="process" || mode=="foreign-signature" {
        let path=mode=="process" ? CommandLine.arguments[0]:FileManager.default.currentDirectoryPath+"/foreign-probe"
        let child=Process();child.executableURL=URL(fileURLWithPath:path);child.currentDirectoryURL=directory
        child.arguments=["--fixture-probe",directory.path];try! child.run()
        lock.lock();children.append(child);lock.unlock();completion(nil);return
    }
    let result=PermissionProbeResult(token:mode=="wrong-token" ? "another-request":directory.lastPathComponent,
        pid:mode=="wrong-pid" ? getpid()+1:getpid(),ax:(mode=="recover" || mode=="no-file") ? true:attempt==1,
        post:(mode=="recover" || mode=="no-file") ? true:attempt==1)
    let data=mode=="corrupt-result" ? Data("{".utf8):try! JSONEncoder().encode(result)
    if mode=="no-file" {
        let file=directory.appendingPathComponent("result.json")
        try! Data("read-only-sentinel".utf8).write(to:file);try! FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:file.path)
    }
    do{try PermissionProbeChannel.send(data,to:directory,timeout:0.35)}catch{completion(error);return}
    completion(mode=="result-before-error" ? NSError(domain:"test",code:2):nil)
},changed:{update in
    lock.lock()
    switch update {
    case .unavailable(let error):errors.append(error);gate.block()
    case .granted:grants+=1;_ = gate.restore(gate.generation)
    }
    lock.unlock();changed.signal()
},terminate:{value in lock.lock();reason=value;lock.unlock();terminated.signal()})
monitor.start()
precondition(launched.wait(timeout:.now()+2) == .success)
if mode=="stop" {
    monitor.stop();precondition(changed.wait(timeout:.now()+0.6) == .timedOut)
}else if ["revoked","result-before-error"].contains(mode) {
    precondition(terminated.wait(timeout:.now()+3) == .success)
    lock.lock();precondition(reason=="permission-denied" && count==2 && errors.isEmpty);lock.unlock()
}else {
    precondition(changed.wait(timeout:.now()+3) == .success)
    if mode=="recover"{precondition(changed.wait(timeout:.now()+3) == .success)}
    lock.lock()
    switch mode {
    case "no-file","process":precondition(grants>=1 && errors.isEmpty)
    case "foreign-signature":precondition(errors.first?.stage == .transport && errors.first?.domain == .osStatus && grants==0,"foreign response: grants=\(grants) failures=\(errors)")
    case "recover":precondition(!errors.isEmpty && grants>=1 && gate.allowsInput)
    case "missing-result","stalled-launch":precondition(errors.first?.stage == .probeTimeout && !gate.allowsInput)
    case "launch-error":precondition(errors.first?.stage == .probeLaunch && errors.first?.code == -10810)
    case "wrong-token":precondition(errors.first?.stage == .probeToken)
    case "wrong-pid":precondition(errors.first?.stage == .transport && errors.first?.code==8)
    case "corrupt-result":precondition(errors.first?.stage == .probeDecode)
    default:preconditionFailure("unknown mode")
    }
    precondition(reason==nil);lock.unlock()
    if mode=="stalled-launch" {
        Thread.sleep(forTimeInterval:0.3)
        lock.lock();precondition(count==1,"hung launch must not enqueue repeated launch work");lock.unlock()
    }
}
monitor.stop();Thread.sleep(forTimeInterval:0.1)
lock.lock()
precondition(directories.allSatisfy{!FileManager.default.fileExists(atPath:$0.path)})
let processes=children
lock.unlock()
for child in processes{child.waitUntilExit();precondition(child.terminationStatus == (mode=="foreign-signature" ? 74:0))}
print("PASS: permission monitor \(mode), PID \(getpid()) retained for operational errors")
