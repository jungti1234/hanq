import Foundation
import Darwin

let args = CommandLine.arguments
if args.count > 1, args[1] == "--reader" || args[1] == "--reader-list" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let result = HanjaDictionaryReader.candidates(String(data:data,encoding:.utf8) ?? "",
        system:URL(fileURLWithPath:args[2]),user:URL(fileURLWithPath:args[3]))
    FileHandle.standardOutput.write(args[1] == "--reader-list" ? try! JSONEncoder().encode(result) : Data(result.status.rawValue.utf8));exit(0)
}
if args.count > 1, args[1].hasPrefix("--fake-") {
    if args[1] == "--fake-crash" { raise(SIGABRT);exit(1) }
    _ = FileHandle.standardInput.readDataToEndOfFile()
    if args[1] == "--fake-timeout" { sleep(4);exit(0) }
    if args[1] == "--fake-failure" { exit(1) }
    FileHandle.standardOutput.write(Data(String(args[1].dropFirst(7)).utf8));exit(0)
}
HanjaCandidates.runProbeIfRequested()

let root=URL(fileURLWithPath:args[1]), maker=URL(fileURLWithPath:args[2])
let executable=URL(fileURLWithPath:args[0])
var checks=0
func check(_ result:Bool,_ name:String){guard result else{fatalError(name)};checks += 1}
func fixture(_ name:String,_ key:String,_ value:String,invalid:Bool=false)->URL{
    let url=root.appendingPathComponent(name)
    let process=Process();process.executableURL=maker
    process.arguments=[url.path,key,value,invalid ? "invalid":"normal"]
    try! process.run();process.waitUntilExit();check(process.terminationStatus==0,"fixture creation")
    return url
}
func lookup(_ text:String,system:URL=HanjaCandidates.systemDictionary,user:URL)->HanjaCandidateAvailability{
    HanjaCandidates.probe(text,executable:executable,arguments:["--reader",system.path,user.path])
}
let absent=root.appendingPathComponent("absent")
check(lookup("가나다",user:absent) == .none,"missing user dictionary is a successful empty lookup")
check(lookup("한국",user:absent) == .available,"real system candidates preserved")
check(lookup("학교",user:absent) == .available,"another real system word preserved")
check(lookup("한",user:absent) == .available,"single syllable candidates preserved")
let userOnly=fixture("user-only","가나다","假那多")
check(lookup("가나다",user:userOnly) == .available,"user-only candidates prevent suppression")
check(lookup("없는후보확인",user:userOnly) == .none,"successful misses in both dictionaries suppress")
let originalOnly=fixture("original-only","가나다","가나다")
check(lookup("가나다",user:originalOnly) == .none,"only unchanged Hangul does not open candidates")
let custom=fixture("custom-output","가나다","사용자 지정 문구")
check(lookup("가나다",user:custom) == .available,"custom user conversion is preserved even without ideographs")
let malformed=fixture("malformed","가나다","假那多",invalid:true)
check(lookup("가나다",user:malformed) == .unknown,"unrecognized user record falls back")
check(lookup("가나다",system:absent,user:userOnly) == .unknown,"missing system dictionary falls back")
let corrupt=root.appendingPathComponent("corrupt")
try! FileManager.default.createDirectory(at:corrupt.appendingPathComponent("Contents"),withIntermediateDirectories:true)
try! Data("invalid".utf8).write(to:corrupt.appendingPathComponent("Contents/Info.plist"))
check(lookup("가나다",user:corrupt) == .unknown,"corrupt user dictionary falls back")
check(lookup("한국",user:corrupt) == .unknown,"even a system hit preserves fallback on user failure")
let inaccessible=fixture("inaccessible","가나다","假那多")
let index=inaccessible.appendingPathComponent("Contents/Keyword.index")
try! FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:index.path)
check(lookup("가나다",user:inaccessible) == .unknown,"unreadable user data falls back")
try! FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:index.path)
func contents(_ url: URL) -> [String: Data] {
    var result = [String: Data]()
    for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])! {
        if (try! file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[file.path] = try! Data(contentsOf: file)
        }
    }
    return result
}
let before = contents(userOnly)
_ = lookup("가나다",user:userOnly)
check(contents(userOnly) == before,"lookup does not rewrite any user dictionary file")
func list(_ text: String, user: URL) -> HanjaCandidateResult {
    HanjaCandidates.probeCandidates(text, executable: executable,
        arguments: ["--reader-list", HanjaCandidates.systemDictionary.path, user.path])
}
let registered = list("가나다", user: userOnly)
check(registered.status == .available && registered.candidates == ["假那多"], "user-only candidate list excludes original")
let systemList = list("한국", user: absent)
check(systemList.status == .available && systemList.candidates.count == 2
    && !systemList.candidates.contains("한국"), "actual Apple dictionary candidates without synthetic original")
check(list("가나다", user: originalOnly).status == .none, "source-only list is empty")
check(list("가나다", user: corrupt).status == .unknown, "list lookup failure preserves native fallback")
check(list("가나다", user: custom).candidates == ["사용자 지정 문구"], "custom registered conversion retained")
for reply in ["{\"status\":\"none\",\"candidates\":[]}", "{\"status\":\"unknown\",\"candidates\":[]}"] {
    check(HanjaCandidates.probeCandidates("가나다", executable: executable,
        arguments: ["--fake-" + reply]).candidates.isEmpty, "bounded list reply")
}
for reply in ["garbage", "{\"status\":\"available\",\"candidates\":[]}",
              "{\"status\":\"none\",\"candidates\":[\"假那多\"]}",
              "{\"status\":\"available\",\"candidates\":[\"가나다\"]}",
              "{\"status\":\"available\",\"candidates\":[\"\"]}"] {
    check(HanjaCandidates.probeCandidates("가나다", executable: executable,
        arguments: ["--fake-" + reply]).status == .unknown, "invalid or source-only list replies fall back")
}
check(HanjaCandidates.probeCandidates("가나다", executable: executable, timeout: 0.08,
    arguments: ["--fake-timeout"]).status == .unknown, "list timeout falls back")
for state in [HanjaCandidateAvailability.available,.none,.unknown]{
    check(HanjaCandidates.probe("가나다",executable:executable,arguments:["--fake-"+state.rawValue]) == state,"child response policy")
    check(state.shouldRequestCandidates == (state != .none),"only confirmed empty response suppresses")
}
for mode in ["--fake-garbage","--fake-none\n","--fake-failure","--fake-crash","--fake-timeout"]{
    check(HanjaCandidates.probe("가나다",executable:executable,timeout:0.08,arguments:[mode]) == .unknown,"failed child falls back")
}
check(HanjaCandidates.probe("가나다",executable:absent) == .unknown,"launch failure falls back")
for text in ["", "abc", "ㄱ", "한 글", String(repeating:"가",count:65)]{
    check(HanjaCandidates.probe(text,executable:executable) == .unknown,"unsupported target falls back")
}
let started=ProcessInfo.processInfo.systemUptime
_ = HanjaCandidates.probe("가나다",executable:executable,timeout:0.08,arguments:["--fake-timeout"])
check(ProcessInfo.processInfo.systemUptime-started<0.5,"child timeout is bounded")
print("PASS: \(checks) Hanja candidate checks; system dictionary and isolated user fixtures; no input keys posted")
