import Foundation

// Run the production storage-only helper entrypoint; it never checks TCC or posts keys.
DiagnosticStorageStartup.runProbeIfRequested()

// Exercise the production monitor without installing taps or changing TCC.
// The launcher is replaceable so a hung LaunchServices call cannot stall tests.
let mode = CommandLine.arguments.last!
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
let launched = DispatchSemaphore(value: 0)
let terminated = DispatchSemaphore(value: 0)
let lock = NSLock()
var count = 0
var reason: String?
var directories: [URL] = []
let monitor = FreshPermissionMonitor(interval: 0.05, timeout: 0.2, launchProbe: { directory, completion in
    precondition(directory.deletingLastPathComponent().path=="/private/tmp")
    precondition(PrivateProbeDirectory.open(directory,prefix:"hanq-permission-") != nil)
    lock.lock()
    count += 1
    let attempt = count
    directories.append(directory)
    lock.unlock()
    launched.signal()
    if mode == "stalled-launch" {
        Thread.sleep(forTimeInterval: 1)
        return
    }
    if mode == "missing-result" || mode == "stop" { completion(nil); return }
    if mode == "launch-error" {
        completion(NSError(domain: "test", code: 1))
        return
    }
    let result = PermissionProbeResult(
        token: mode == "wrong-token" ? "another-request" : directory.lastPathComponent,
        pid: getpid(), ax: attempt == 1, post: attempt == 1)
    let data = mode == "corrupt-result" ? Data("{".utf8) : try! JSONEncoder().encode(result)
    try! data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    // A valid result wins over a delayed LaunchServices error.
    completion(mode == "result-before-error" ? NSError(domain: "test", code: 2) : nil)
}, terminate: { value in
    lock.lock()
    reason = value
    lock.unlock()
    terminated.signal()
})
monitor.start()
precondition(launched.wait(timeout: .now() + 2) == .success)
if mode == "stop" {
    monitor.stop()
    precondition(terminated.wait(timeout: .now() + 0.5) == .timedOut)
} else {
    precondition(terminated.wait(timeout: .now() + 2) == .success)
    lock.lock()
    let expected: String
    switch mode {
    case "stalled-launch", "missing-result": expected = "probe-timeout"
    case "launch-error": expected = "probe-launch"
    case "wrong-token", "corrupt-result": expected = "invalid-result"
    default:
        expected = "permission-denied"
        precondition(count == 2, "Granted result must continue monitoring")
    }
    precondition(reason == expected, "Expected \(expected), got \(String(describing: reason))")
    lock.unlock()
    monitor.stop()
}
lock.lock()
precondition(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
lock.unlock()
print("PASS: permission monitor \(mode)")
