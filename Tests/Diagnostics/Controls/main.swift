import AppKit
import Carbon
var checks=0
func check(_ v:@autoclosure ()->Bool,_ why:String){checks+=1;if !v(){fputs("FAIL: \(why)\n",stderr);exit(1)}}
let trace=InputIncidentTrace(secureInput:{false},destination:nil,capacity:4096,writer:{captures.append($0)})
var captures:[InputIncidentTrace.Capture]=[]
func event(_ flags:CGEventFlags=[],key:CGKeyCode=54,tag:Int64=0)->CGEvent {
 let e=CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true)!;e.type = .flagsChanged;e.flags=flags;e.timestamp=UInt64(100000+checks)*1000;e.setIntegerValueField(.eventSourceUserData,value:tag);return e
}
let right=CGEventFlags(rawValue:CGEventFlags.maskCommand.rawValue|0x10)
let two=InputSourceSnapshot(id:"private-korean-id",name:"private name",languages:["ko"])
let abc=InputSourceSnapshot(id:"private-english-id",name:"private name",languages:["en"])
func resolution(_ current:InputSourceSnapshot?,_ readable:Bool=true,_ sources:[InputSourceSnapshot]=[two,abc])->KoreanEnglishSwitch.Resolution{
 KoreanEnglishSwitch.resolution(current:current,readable:readable,sources:sources,rememberedKorean:two.id,rememberedEnglish:abc.id)
}
check(resolution(nil).status==1,"missing current distinct")
check(resolution(two,false,[]).status==2,"list lookup failure distinct")
check(resolution(two,true,[]).status==3,"readable empty destinations distinct")
check(resolution(two).target==abc.id && resolution(two).targetClass==2,"Korean selects English")
check(resolution(abc).target==two.id && resolution(abc).targetClass==1,"English selects Korean")
var filter=CommandFilter()
func run(_ flags:CGEventFlags,_ accept:Bool,_ expected:Int) {
 let e=event(flags);var c=InputIncidentControl.begin(trace,.flagsChanged,e)!
 let before=filter.diagnosticState,r=filter.process(type:.flagsChanged,key:54,flags:e.flags,acceptNewPress:accept)
 c.filter(before:before,after:filter.diagnosticState,flags:e.flags,accepted:accept,edge:r.edge,consumed:r.consume,matching:true)
 check(c.filterReason==expected,"real filter reason \(expected)")
 let q=resolution(two);c.query(site:1,status:q.status,current:q.currentClass,target:q.targetClass,available:q.availableCount,korean:q.koreanCount,english:q.englishCount,began:ProcessInfo.processInfo.systemUptime)
 c.route=(r.consume ? InputIncidentControl.Route.filterConsumed:.passed).rawValue
 e.flags=r.flags // diagnostic must retain incoming flags before mutation
 trace.control(.main,.flagsChanged,e,c,consumed:r.consume)
}
run(right,false,5);run(right,true,4);run([],true,3);run(.maskCommand,true,3);run(right,true,1);run(right,true,4);run([],false,2)
check(InputIncidentControl.begin(trace,.keyDown,event([],key:0))==nil,"ordinary letters have no control payload")
let hid=MismatchSwitchGate(accepts:{false},switched:{_ in});hid.incidentTrace=trace
_ = hid.receive(.flagsChanged,event(right,tag:123))
_ = hid.receive(.flagsChanged,event(right))
let accepted=MismatchSwitchGate(accepts:{true},switched:{_ in});accepted.incidentTrace=trace
check(accepted.receive(.flagsChanged,event(right))==nil,"HID accepts/consumes own press")
check(accepted.receive(.flagsChanged,event([]))==nil,"HID drains release")
for condition in [0,1,2,3,4,5,6] {
 let gate=OnsetInputGate(marker:0x48414E5100000001);gate.incidentTrace=trace
 var e=event([])
 switch condition {
 case 1:gate.stop()
 case 2:gate.heartbeat=0;gate.holdUntil=ProcessInfo.processInfo.systemUptime+1
 case 3:gate.beat();gate.holdUntil=ProcessInfo.processInfo.systemUptime-0.01
 case 4:gate.beat();_ = gate.begin();e=event(right)
 case 5:gate.beat();_ = gate.begin()
 case 6:e=event([],tag:gate.marker)
 default:break
 }
 _ = gate.receive(.flagsChanged,e)
}
// Exercise the gate's existing bounded lock failure; diagnostic work is after
// that lock, never inside it.
let lockedGate=OnsetInputGate(marker:0x48414E5100000002);lockedGate.incidentTrace=trace
let gateHeld=DispatchSemaphore(value:0),gateRelease=DispatchSemaphore(value:0),gateDone=DispatchSemaphore(value:0)
Thread{lockedGate.lock.lock();gateHeld.signal();gateRelease.wait();lockedGate.lock.unlock();gateDone.signal()}.start()
_ = gateHeld.wait(timeout:.now()+2)
check(lockedGate.receive(.flagsChanged,event(right)) != nil,"onset lock timeout still passes input")
gateRelease.signal();_ = gateDone.wait(timeout:.now()+2)
trace.flush();trace.mark();trace.flush()
let actualRows=captures.last!.frames.filter{$0.kind == .controlDecision}
for route in [16,17,18,19,20,21,22,24,28,29,6] {check(actualRows.contains{$0.category==route},"actual gate route represented \(route)")}
// Every fixed route survives the typed codec; this is schema coverage, not a
// claim that each main-app early return was reproduced on a physical keyboard.
for reason in 1...30 {var c=InputIncidentControl();c.route=reason;trace.control(.main,.flagsChanged,nil,c)}
var chained=InputIncidentControl();chained.role=1
chained.query(site:2,status:1,current:0,began:ProcessInfo.processInfo.systemUptime)
chained.query(site:1,status:4,current:1,target:2,available:2,korean:1,english:1,began:ProcessInfo.processInfo.systemUptime)
check(chained.priorQuery?.site==2 && chained.priorQuery?.status==1 && chained.queryStatus==4,"external and legacy reads both retained")
trace.control(.main,.flagsChanged,event(right),chained)
trace.flush();trace.mark();trace.flush()
var cap=captures.last!
let rows=cap.frames.filter{$0.kind == .controlDecision}
check(rows.contains{$0.controlEvidence?.incomingFlags==6 && $0.controlEvidence?.filterFlags==6 && $0.controlEvidence?.filterEdge==1},"incoming flags retained despite mutation")
for route in [16,17,18,20,21,22,24,28,29,6] {check(rows.contains{$0.category==route},"control route represented \(route)")}
let encoded=try JSONEncoder().encode(cap)
check((try? RecorderTrace.decode(encoded)) != nil,"strict collector reads controls and new counter codes")
let encodedText=String(data:encoded,encoding:.utf8)!
check(!encodedText.contains("private-") && !encodedText.contains("keyCode") && !encodedText.contains("sourceID"),"raw source and key data absent")
var object=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
let index=(object["frames"] as! [[String:Any]]).firstIndex{$0["kind"] as? Int==11}!
for (key,bad) in [("text","private" as Any),("rawFlags",123 as Any),("queryStatus",6 as Any),("filterBefore",4 as Any),("role",true as Any)] {
 var altered=object;var frames=altered["frames"] as! [[String:Any]];var evidence=frames[index]["controlEvidence"] as! [String:Any];evidence[key]=bad;frames[index]["controlEvidence"]=evidence;altered["frames"]=frames
 check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:altered)))==nil,"reject unknown/private/invalid control \(key)")
}
var badChain=object;var chainedFrames=badChain["frames"] as! [[String:Any]]
let chainedIndex=chainedFrames.firstIndex{($0["controlEvidence"] as? [String:Any])?["priorQuery"] != nil}!
var chainedEvidence=chainedFrames[chainedIndex]["controlEvidence"] as! [String:Any]
var rawQuery=chainedEvidence["priorQuery"] as! [String:Any];rawQuery["sourceID"]="private"
chainedEvidence["priorQuery"]=rawQuery;chainedFrames[chainedIndex]["controlEvidence"]=chainedEvidence;badChain["frames"]=chainedFrames
check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject:badChain)))==nil,"nested query rejects raw source")
let held=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
Thread{trace.withLockedMetadataForTest{held.signal();release.wait()};done.signal()}.start()
check(held.wait(timeout:.now()+2) == .success,"hold metadata lock")
var c=InputIncidentControl();c.role=1;c.route=14
let began=ProcessInfo.processInfo.systemUptime
trace.control(.main,.flagsChanged,event(right),c,consumed:true)
check(ProcessInfo.processInfo.systemUptime-began<0.05,"control caller does not wait for diagnostic lock")
Thread.sleep(forTimeInterval:0.06);release.signal();_ = done.wait(timeout:.now()+2)
trace.flush();trace.mark();trace.flush();cap=captures.last!
check(cap.frames.contains{$0.kind == .controlDecision && ($0.observationTiming?.contended == true || ($0.observationTiming?.queueMicros ?? 0)>=50000)},"important wait retained")
// Saturate the actual bounded metadata lane while its worker cannot progress.
let small=InputIncidentTrace(secureInput:{false},destination:nil,observationCapacity:4,writer:{overflowCaptures.append($0)})
var overflowCaptures:[InputIncidentTrace.Capture]=[]
let held2=DispatchSemaphore(value:0),release2=DispatchSemaphore(value:0),done2=DispatchSemaphore(value:0)
Thread{small.withLockedMetadataForTest{held2.signal();release2.wait()};done2.signal()}.start();_ = held2.wait(timeout:.now()+2)
let floodStart=ProcessInfo.processInfo.systemUptime
for _ in 0..<40{small.control(.main,.flagsChanged,nil,c)}
check(ProcessInfo.processInfo.systemUptime-floodStart<0.05,"queue overflow is nonblocking")
release2.signal();_ = done2.wait(timeout:.now()+2);small.flush();small.mark();small.flush()
let overflow=overflowCaptures.last!
check((overflow.observationDelivery.overflow[((6-1)*8+2-1)*32+9] ?? 0)>0,"overflow identifies main/right Command control")
check((try? RecorderTrace.decode(JSONEncoder().encode(overflow))) != nil,"overflow strict decode")
let off=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{_ in})
check(InputIncidentControl.begin(off,.flagsChanged,event(right))==nil,"OFF skips control probe")
// Isolate receipt from all control-decision producers, including intentional early returns.
var secured = false
var receiptCaptures: [InputIncidentTrace.Capture] = []
let receiptTrace = InputIncidentTrace(secureInput: { secured }, destination: nil, writer: { receiptCaptures.append($0) })
let roles: [(CGKeyCode, Int)] = [(56,1), (60,1), (54,2), (61,3)]
let secret = Array("TEST-INPUT-MUST-STAY-PRIVATE".utf16)
var receiptTimestamp: UInt64 = 50_000_000
func receiptEvent(_ key: CGKeyCode, _ type: CGEventType) -> CGEvent {
    let e = event([.maskCommand, .maskAlternate, .maskShift], key: key)
    receiptTimestamp += 10_000
    e.type = type
    e.timestamp = receiptTimestamp
    e.keyboardSetUnicodeString(stringLength: secret.count, unicodeString: secret)
    return e
}
for (key, _) in roles {
    let change = receiptEvent(key, .flagsChanged)
    receiptTrace.modifierArrived(.switchHID, .flagsChanged, change)
    receiptTrace.modifierArrived(.main, .flagsChanged, change)
    for type in [CGEventType.keyDown, .keyUp] {
        let e = receiptEvent(key, type)
        receiptTrace.modifierArrived(.recipientHID, type, e)
        receiptTrace.modifierArrived(.switchHID, type, e)
        receiptTrace.modifierArrived(.main, type, e)
    }
}
// Two different, incomplete paths must remain distinguishable without assuming delivery or loss.
receiptTrace.modifierArrived(.switchHID, .flagsChanged, receiptEvent(54, .flagsChanged))
receiptTrace.modifierArrived(.main, .flagsChanged, receiptEvent(61, .flagsChanged))
for key in [CGKeyCode(0),12,49,55,57,58,59,62] {
    for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
        receiptTrace.modifierArrived(.main, type, receiptEvent(key, type))
    }
}
receiptTrace.modifierArrived(.main, .leftMouseDown, receiptEvent(54,.leftMouseDown))
secured = true
for (key, _) in roles {
    receiptTrace.modifierArrived(.main, .flagsChanged, receiptEvent(key,.flagsChanged))
}
secured = false
receiptTrace.flush()
check(receiptCaptures.isEmpty, "modifier receipts alone do not request captures")
receiptTrace.mark(); receiptTrace.flush()
let receipts = receiptCaptures.last!
let arrived = receipts.frames.filter { $0.kind == .modifierArrival }
check(arrived.count == 34 && receipts.frames.allSatisfy { $0.controlEvidence == nil }, "only permitted receipts without any dedicated records")
let groups = Dictionary(grouping: arrived, by: { $0.event })
check(groups.count == 14 && groups.keys.allSatisfy { $0 > 0 }, "same input correlated across taps")
for (role, count) in [(1,16),(2,9),(3,9)] {
    check(arrived.filter { $0.category == role }.count == count, "role counts with both Shifts unified")
}
check(groups.values.filter { $0.count == 2 }.allSatisfy { $0.map(\.modifierStage) == [.switchHID, .main] && $0.allSatisfy { $0.edge == 3 } }, "flagsChanged kept as a transition")
check(groups.values.filter { $0.count == 3 }.allSatisfy { $0.map(\.modifierStage) == [.recipientHID, .switchHID, .main] && [1,2].contains($0[0].edge) }, "down and up have all observed receipts")
check(arrived.suffix(2).map(\.modifierStage) == [.switchHID, .main] && arrived.suffix(2).map(\.category) == [2,3] &&
      Set(arrived.suffix(2).map(\.event)).count == 2, "HID-only Command and main-only Option tracked independently")
let receiptData = try JSONEncoder().encode(receipts)
check((try? RecorderTrace.decode(receiptData)) != nil, "strict decoder accepts modifier arrivals")
let receiptObject = try JSONSerialization.jsonObject(with: receiptData) as! [String:Any]
let receiptRows = receiptObject["frames"] as! [[String:Any]]
let firstReceipt = receiptRows.firstIndex { $0["kind"] as? Int == 16 }!
let allowed = Set(["sequence","milliseconds","lane","kind","event","edge","category","inputOrigin","consumed","durationMicros","count","selected","field","observationTiming","modifierStage"])
check(receiptRows.filter { $0["kind"] as? Int == 16 }.allSatisfy { Set($0.keys) == allowed }, "exact scalar receipt fields")
check(!String(decoding: receiptData, as: UTF8.self).contains("TEST-INPUT"), "Unicode payload absent")
for (field, value) in [("text", "private" as Any), ("rawFlags", 9 as Any), ("keyCode", 54 as Any), ("category", 4 as Any), ("modifierStage", 9 as Any), ("modifierStage", 1 as Any)] {
    var invalid = receiptObject, frames = receiptRows
    frames[firstReceipt][field] = value
    invalid["frames"] = frames
    check((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject: invalid))) == nil, "reject invalid arrival field \(field)")
}
var sameTimeCaptures: [InputIncidentTrace.Capture] = []
let sameTime = InputIncidentTrace(secureInput: { false }, destination: nil, writer: { sameTimeCaptures.append($0) })
for (key, _) in [(CGKeyCode(60),1),(54,2),(61,3)] {
    let e = receiptEvent(key, .flagsChanged)
    e.timestamp = 123456000
    sameTime.modifierArrived(.switchHID, .flagsChanged, e)
    sameTime.modifierArrived(.main, .flagsChanged, e)
    if let decision = InputIncidentControl.begin(sameTime, .flagsChanged, e) {
        sameTime.control(.main, .flagsChanged, e, decision)
    }
}
let mirrorSource = CGEventSource(stateID: .privateState)!
let mirrorTag = Int64(bitPattern: 0x48414B5300000001)
mirrorSource.userData = mirrorTag
let mirrored = CGEvent(keyboardEventSource: mirrorSource, virtualKey: 61, keyDown: true)!
mirrored.type = .flagsChanged
mirrored.setIntegerValueField(.eventSourceUserData, value: mirrorTag)
check(mirrored.getIntegerValueField(.eventSourceUserData) == mirrorTag, "fixture uses the product mirror source tag")
sameTime.modifierArrived(.main, .flagsChanged, mirrored)
sameTime.flush(); sameTime.mark(); sameTime.flush()
let atSameTime = sameTimeCaptures.last!.frames.filter { $0.kind == .modifierArrival }
check(Set(atSameTime.filter { $0.inputOrigin == 1 }.map(\.event)).count == 3, "different untagged modifier roles at exactly the same OS timestamp stay distinct: \(atSameTime.map { [$0.category, $0.event, $0.inputOrigin] })")
for decision in sameTimeCaptures.last!.frames.filter({ $0.kind == .controlDecision }) {
    check(atSameTime.filter { $0.event == decision.event && $0.category == decision.edge + 1 }.count == 2, "dedicated decision links to both arrivals of the same modifier")
}
check(atSameTime.last?.inputOrigin == 3, "mirror copy remains separately classified")
// The HID switch gate tags the original only after its entry observation.
// Quartz can deliver the very same tagged event using another timestamp.
var retimedCaptures: [InputIncidentTrace.Capture] = []
let retimedTrace = InputIncidentTrace(secureInput: { false }, destination: nil, writer: { retimedCaptures.append($0) })
let routing = MismatchRecoveryEngine()
let testGate = MismatchSwitchGate(accepts: { false }, switched: { _ in })
testGate.incidentTrace = retimedTrace
testGate.forwarded = { type, event, stamp, receipt in
    routing.captureEventOrigin(type, event, at: stamp, shiftArrival: receipt)
}
let keyboardSource = CGEventSource(stateID: .privateState)!
var forwardedShifts: [CGEvent] = []
for index in 0..<8 {
    let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: index.isMultiple(of: 2) ? 56 : 60, keyDown: true)!
    event.type = .flagsChanged
    event.timestamp = UInt64(1_000_000 + index * 10_000)
    event.flags = index.isMultiple(of: 2) ? .maskShift : []
    let flags = event.flags
    let receipt = retimedTrace.modifierArrived(.switchHID, .flagsChanged, event)
    check(testGate.receiveHID(.flagsChanged, event, shiftArrival: receipt)?.takeUnretainedValue() === event && event.flags == flags, "Shift is forwarded unchanged by the filter")
    check(event.getIntegerValueField(.eventSourceUserData) != 0, "existing input route supplied a tag")
    forwardedShifts.append(event)
}
for (index, event) in forwardedShifts.enumerated().reversed() {
    event.timestamp = UInt64(80_000_000 + index * 50_000)
    retimedTrace.modifierArrived(.main, .flagsChanged, event, from: routing.diagnosticShiftArrival(.flagsChanged, event))
    retimedTrace.event(.boundary, .flagsChanged, event)
}
retimedTrace.flush(); retimedTrace.mark(); retimedTrace.flush()
let retainedRows = retimedCaptures.last!.frames
let hidIDs = retainedRows.filter { $0.modifierStage == .switchHID }.map(\.event)
let mainIDs = retainedRows.filter { $0.modifierStage == .main }.map(\.event)
let endIDs = retainedRows.filter { $0.kind == .event && $0.lane == .boundary }.map(\.event)
let linkedShifts = zip(hidIDs, mainIDs.reversed()).filter { $0 == $1 }.count
print("Retimed Shift receipts: HID \(hidIDs.count), main \(mainIDs.count), linked \(linkedShifts)/8")
check(linkedShifts == 8 && Set(hidIDs).count == 8 && mainIDs == endIDs, "all retimed Shift edges reach their own downstream event")

// Four overlapping Shift edges with identical timestamps. Drop one origin and
// feed the main callback in reverse order to forbid FIFO/time-based guesses.
var collisionCaptures: [InputIncidentTrace.Capture] = []
let collisionTrace = InputIncidentTrace(secureInput: { false }, destination: nil, writer: { collisionCaptures.append($0) })
var overlapping: [CGEvent] = []
for index in 0..<4 {
    let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: index.isMultiple(of: 2) ? 56 : 60, keyDown: true)!
    event.type = .flagsChanged
    event.timestamp = 40_000_000
    let receipt = collisionTrace.modifierArrived(.switchHID, .flagsChanged, event)
    let token = routing.captureEventOrigin(.flagsChanged, event, shiftArrival: receipt)!
    if index == 2 { routing.discardEventOrigin(token) }
    overlapping.append(event)
}
for event in overlapping.reversed() {
    collisionTrace.modifierArrived(.main, .flagsChanged, event, from: routing.diagnosticShiftArrival(.flagsChanged, event))
}
collisionTrace.flush(); collisionTrace.mark(); collisionTrace.flush()
let collisions = collisionCaptures.last!.frames.filter { $0.kind == .modifierArrival }
let allHID = collisions.filter { $0.modifierStage == .switchHID }.map(\.event)
let correspondingMain = Array(collisions.filter { $0.modifierStage == .main }.map(\.event).reversed())
check(Set(allHID).count == 4 && Set(correspondingMain).count == 4, "same-time Shift edges remain distinct in both callbacks")
check([0, 1, 3].allSatisfy { allHID[$0] == correspondingMain[$0] } && !allHID.contains(correspondingMain[2]), "missing origin is reported independently, surviving origins match")
var lookups = 0
func countedLookup() -> InputIncidentTrace.ShiftArrival? { lookups += 1; return nil }
secured = true
receiptTrace.modifierArrived(.main, .flagsChanged, receiptEvent(56, .flagsChanged), from: countedLookup())
secured = false
for key in [CGKeyCode(0), 54, 61] {
    receiptTrace.modifierArrived(.main, .keyDown, receiptEvent(key, .keyDown), from: countedLookup())
}
check(lookups == 0, "secure input, characters and unrelated modifiers never request Shift origins")

var busyCaptures: [InputIncidentTrace.Capture] = []
let busy = InputIncidentTrace(secureInput: { false }, destination: nil, observationCapacity: 4, writer: { busyCaptures.append($0) })
let busyHeld = DispatchSemaphore(value: 0), busyRelease = DispatchSemaphore(value: 0)
Thread { busy.withLockedMetadataForTest { busyHeld.signal(); busyRelease.wait() } }.start()
check(busyHeld.wait(timeout: .now() + 2) == .success, "hold bounded input queue")
let busyOption = receiptEvent(61, .flagsChanged)
for _ in 0..<16 { busy.modifierArrived(.main, .flagsChanged, busyOption) }
busyRelease.signal(); busy.flush(); busy.mark(); busy.flush()
let busyCapture = busyCaptures.last!
let overflowKey = 32 + 8 + InputIncidentTrace.ModifierRole.rightOption.rawValue
check(busyCapture.observationDelivery.overflow[overflowKey] == 14 &&
      busyCapture.frames.filter { $0.kind == .modifierArrival }.count == 2,
      "bounded queue counts omitted Option arrivals without claiming delivery")
var offSecureChecks = 0
let disabled = InputIncidentTrace(secureInput: { offSecureChecks += 1; return false }, destination: nil, initiallyEnabled: false, writer: { _ in })
for (key, _) in roles { disabled.modifierArrived(.main, .flagsChanged, receiptEvent(key,.flagsChanged)) }
check(offSecureChecks == 0, "disabled trace exits before sampling")
if CommandLine.arguments.count > 2 { try receiptData.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
let out=CommandLine.arguments.dropFirst().first.map{URL(fileURLWithPath:$0)}
if let out{try encoded.write(to:out)}
print("PASS \(checks) control diagnostics checks; no global posts, physical keys or actual TIS queries")
