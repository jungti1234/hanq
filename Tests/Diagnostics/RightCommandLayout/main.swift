import AppKit
import Carbon

func check(_ passed: @autoclosure () throws -> Bool, _ message: String) {
    guard (try? passed()) == true else { fputs("FAIL \(message)\n", stderr); exit(1) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let store = root.appendingPathComponent("store")
try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
let abc = "com.apple.keylayout.ABC", korean = KoreanKeyboardLayout.twoSetID
let translated = KoreanKeyboardLayout.translationIDs[korean]!
let origin: UInt64 = 100_000_000_000
var now = origin, selected = abc, effectiveLayout = abc, secure = false
var layoutReads = 0, missedReads = 0
let trace = InputIncidentTrace(secureInput: { secure }, destination: store, persistentOwnership: true,
                               clock: { Double(now) / 1e9 })
trace.flush()
let tracker = RightCommandLayoutDiagnostics(trace: trace, clock: { now }, secure: { secure }, read: {
    layoutReads += 1
    return (selected, effectiveLayout, nil, selected)
})
let barrier = SourceSwitchBarrier()
barrier.incidentTrace = trace
barrier.recordDiagnosticSwitchRequest = tracker.requested
barrier.observeSwitchCommit = { target, stamp, _ in tracker.confirmed(target, at: stamp); return nil }
barrier.now = { Double(now) / 1e9 }
barrier.read = { nil }
barrier.readForOutsideSwitch = { (nil, nil) }
barrier.readFocus = { nil }
barrier.frontPID = { 89_001 }
barrier.frontWindow = { _ in nil }
barrier.source = { selected }
var legacyLayoutChecks = 0
barrier.initialLayout = { _ in legacyLayoutChecks += 1; return .conflicting }
let selector = SelectionPreservingSourceSwitch()
selector.currentSource = { selected }
selector.selectSource = { selected = $0; return noErr }
selector.allowed = { true }
selector.focus = { nil }
let engine = MismatchRecoveryEngine()
engine.incidentTrace = trace
engine.enabled = true
engine.locked = AXUIElementCreateApplication(89_001)
engine.testSource = { selected }
engine.testSnapshot = { missedReads += 1; return nil }
engine.diagnosticFirstKey = { type, event, stamp in tracker.firstKey(type, event, at: stamp) }
engine.testSetRange = { _, _ in fatalError("diagnostics edited the selection") }
engine.testPostAtTap = { _, _ in fatalError("diagnostics replayed an event") }

func key(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = [], tag: Int64 = 0) -> CGEvent {
    let source = CGEventSource(stateID: .privateState)!
    source.userData = tag
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
    event.timestamp = now
    event.flags = flags
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    return event
}

// Same direct fallback used by the app when it cannot establish an editable field.
check(!barrier.request(korean, at: now, rightCommand: true, recordWindow: { _ in }), "unreadable switch uses direct fallback")
check(selector.select(korean) == noErr && selected == korean, "fallback selected two-set")
barrier.didSwitchWithoutField(korean, at: now)
check(layoutReads == 1, "commit-time read occurs before the first key")
let schedule = [707, 772, 852, 904, 1000, 1084, 1179, 1321, 1553]
// Letter positions are synthetic. Only the spacing and the space key matter here.
let codes: [CGKeyCode] = [0, 1, 7, 2, 49, 14, 4, 15, 12]
effectiveLayout = translated
for (offset, code) in zip(schedule, codes) {
    now = origin + UInt64(offset) * 1_000_000
    for down in [true, false] {
        let event = key(code, down: down)
        check(engine.captureEventOrigin(event.type, event, at: now) != nil, "HID origin captured")
        tracker.firstKey(event.type, event, at: engine.originalTimestamp(event.type, event))
        check(!barrier.receive(event.type, event), "normal delivery through switch barrier")
        barrier.observeBeforeOnset(event.type, event, waiting: false)
        check(engine.event(event.type, event) != nil, "original key passed without a field")
    }
    trace.flush()
}
check(layoutReads == 2 && missedReads >= 9 && legacyLayoutChecks == 0 && !engine.recovering,
      "exactly two diagnostic reads outside the recovery window")
now = origin + 6_294_000_000
trace.mark()
trace.flush()
trace.finishCaptureWindowsForTest()
trace.flush()
let shared = store.appendingPathComponent(DiagnosticSharedStore.directoryName)
let files = try FileManager.default.contentsOfDirectory(atPath: shared.path).filter(DiagnosticSharedStore.validName)
let manualPre = try files.first {
    let h = try DiagnosticSharedStore.readHeader(shared.appendingPathComponent($0)).0
    return h.role != 1 && h.trigger == 1 && h.phase == 0
}!
let data = try DiagnosticArchiveReader.normalized(manualPre, in: shared)
let saved = try RecorderTrace.decode(data)
check(saved.rightCommandLayouts?.count == 1, "strict recorder decodes one switch from the shared manual capture")
let row = saved.rightCommandLayouts![0]
check(row.id == 1 && row.target == .twoSet && row.outcome == .firstKey, "two reads share the transition identity")
check(row.commit.selected == .twoSet && row.commit.layout == .abc && row.commit.overrideLayout == .none &&
      row.commit.selectedAfter == .twoSet, "commit preserves selected two-set with ABC layout")
let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
func decodable(_ object: [String: Any]) -> Bool {
    guard let bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
    return (try? RecorderTrace.decode(bytes)) != nil
}
var older = original
older.removeValue(forKey: "rightCommandLayouts")
check(decodable(older), "older captures without paired observations are accepted")
let originalRow = (original["rightCommandLayouts"] as! [[String: Any]])[0]
for invalid in [["input": "private"], ["layout": 10], ["selected": true], ["eventMicros": row.commit.observedMicros - 1]] as [[String: Any]] {
    var edited = originalRow
    edited["firstKey"] = (edited["firstKey"] as! [String: Any]).merging(invalid) { _, new in new }
    check(!decodable(original.merging(["rightCommandLayouts": [edited]]) { _, new in new }), "malformed first-key evidence rejected")
}
let first = row.firstKey!
check(first.selected == .twoSet && first.layout == .twoSet && first.overrideLayout == .none &&
      first.selectedAfter == .twoSet, "first key independently sees translated two-set")
check(first.eventMicros == first.observedMicros && first.observedMicros - row.commit.observedMicros == 707_000,
      "first key sampled 707 ms after commit")
check(saved.frames.filter {
    $0.kind == 8 && $0.edge == InputIncidentTrace.DecisionSite.event.rawValue &&
    $0.category == InputIncidentTrace.DecisionReason.snapshotUnavailable.rawValue
}.count == 9, "all nine key-down decisions report snapshot unavailable")
let exported = root.appendingPathComponent("export")
let completed = DispatchSemaphore(value: 0)
var exportOK = false
trace.prepareExport(to: exported, reviewMetadata: true) { result in
    if case .success = result { exportOK = true }
    completed.signal()
}
check(completed.wait(timeout: .now() + 10) == .success && exportOK, "manual capture export")
let review = try DiagnosticReviewSnapshot(directory: exported)
let incident = review.incidents.first { $0.originals[0]?.filename == manualPre }!
let fields = try incident.originals[0]!.review().document.sections.flatMap(\.fields)
check(fields.contains { $0.label == "우측 Command #1" && $0.value.contains("배열 ABC") &&
    $0.value.contains("첫 키 +707.0ms") && $0.value.contains("배열 두벌식") }, "Korean incident preview displays both readings")
try Data((manualPre + "\n").utf8).write(to: root.appendingPathComponent("manual-name"))
print("PASS manual shared capture #1: commit selected=two-set/layout=ABC; first key +707000us selected=two-set/layout=two-set; nine unreadable downs and nine ups passed; strict recorder and preview")

// A normal, readable editor uses the asynchronous barrier confirmation.
let editor = ReturnEditor(left: "", right: "")
var extraCaptures: [InputIncidentTrace.Capture] = []
let extra = InputIncidentTrace(secureInput: { secure }, destination: nil, clock: { Double(now) / 1e9 },
                               writer: { extraCaptures.append($0) })
var extraReads = 0
let monitor = RightCommandLayoutDiagnostics(trace: extra, clock: { now }, secure: { secure }, read: {
    extraReads += 1
    return (editor.selected, "test.private.custom-id", nil, "unknown")
})
editor.barrier.recordDiagnosticSwitchRequest = monitor.requested
editor.barrier.observeSwitchCommit = { target, stamp, _ in monitor.confirmed(target, at: stamp); return nil }
editor.time = Double(now) / 1e9 - 0.02
editor.change(abc)
check(extraReads == 1, "readable editor commit sampled exactly once (reads \(extraReads))")
now += 90_000_000_000
let ordinary = key(15)
func observe(_ event: CGEvent) { monitor.firstKey(event.type, event, at: event.timestamp) }
observe(key(15, down: false))
check(extraReads == 1, "release ignored")
observe(key(123))
check(extraReads == 1, "navigation ignored")
observe(key(15, flags: .maskCommand))
check(extraReads == 1, "shortcut ignored")
let repeatKey = key(15)
repeatKey.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
observe(repeatKey)
check(extraReads == 1, "repeat ignored")
let replay = key(15, tag: SyntheticInputMarker.manualEdit)
check(replay.getIntegerValueField(.eventSourceUserData) == SyntheticInputMarker.manualEdit, "fixture carries replay tag")
observe(replay)
check(extraReads == 1, "replay ignored")
observe(key(15, tag: SourceSwitchBarrier.marker))
check(extraReads == 1, "switch-barrier replay ignored")
let stale = key(15)
stale.timestamp = origin
observe(stale)
check(extraReads == 1, "release, navigation, shortcut, repeat, replay and late pre-switch events are ignored")
observe(ordinary)
observe(ordinary)
check(extraReads == 2, "first unmodified key alone consumes delayed main-tap fallback")
func toggle(_ id: String, right: Bool = true) {
    now += 1_000_000
    monitor.requested(id, at: now, rightCommand: right)
    monitor.confirmed(id, at: now)
}
toggle(korean)
toggle(abc)
monitor.sourceChanged(to: korean)
observe(key(15))
toggle(abc, right: false)
observe(key(15))
secure = true
toggle(korean)
observe(key(15))
secure = false
check(extraReads == 4, "new right-Command or external source change supersedes; other initiators and secure events add no read")
extra.mark()
extra.flush()
let history = extraCaptures[0].rightCommandLayouts!
check(history.map(\.outcome) == [.firstKey, .superseded, .superseded], "each superseded transition retains its own commit only")
check(history[0].firstKey!.observedMicros - history[0].commit.observedMicros == 90_000_000 &&
      history[0].firstKey!.layout == .other && history[0].firstKey!.selectedAfter == .unavailable,
      "90-second gap, unrecognized layout and unavailable selected-after preserved explicitly")
check(!(String(data: try JSONEncoder().encode(extraCaptures[0]), encoding: .utf8) ?? "").contains("test.private"),
      "custom source ID never exported")
func collection(_ enabled: Bool) {
    var done = false
    extra.setCollectionEnabled(enabled) { done = true }
    let end = Date().addingTimeInterval(5)
    while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    check(done && extra.enabled == enabled, "collection change completed")
}
toggle(korean)
collection(false)
observe(key(15))
toggle(abc)
collection(true)
observe(key(15))
check(extraReads == 5, "disabled interval and re-enabling cannot attach a key to an older switch")
for _ in 0...DiagnosticSwitchLayout.limit { toggle(korean); observe(key(15)); extra.flush() }
extra.mark()
extra.flush()
let recent = extraCaptures.last!.rightCommandLayouts!
check(recent.count == DiagnosticSwitchLayout.limit && recent.allSatisfy { $0.outcome == .firstKey } &&
      recent.first!.id == recent.last!.id - DiagnosticSwitchLayout.limit + 1, "manual history keeps the latest sixteen complete records")
print("PASS readable-field and main-tap fallback; 90-second gap, key filtering, superseded transitions, privacy, opt-out and bounded history")

// A committed transition is exportable while waiting. A later capture can
// attach the key even if both system layout readings still conflict.
var beforeAndAfter: [InputIncidentTrace.Capture] = []
let pairedTrace = InputIncidentTrace(secureInput: { false }, destination: nil,
    clock: { Double(now) / 1e9 }, writer: { beforeAndAfter.append($0) })
var reads = 0
let paired = RightCommandLayoutDiagnostics(trace: pairedTrace, clock: { now }, secure: { false }, read: {
    reads += 1
    return (korean, abc, "com.apple.keylayout.US", korean)
})
paired.requested(korean, at: now, rightCommand: true)
paired.confirmed(abc, at: now)
paired.firstKey(.keyDown, key(15), at: now)
check(reads == 0, "wrong or unconfirmed target provides no sample")
paired.confirmed(korean, at: now)
pairedTrace.mark()
pairedTrace.flush()
let beforeKey = beforeAndAfter[0].rightCommandLayouts!.last!
check(beforeKey.outcome == .unobserved && beforeKey.firstKey == nil, "manual mark before first key contains only commit")
now += 707_000_000
paired.firstKey(.keyDown, key(15), at: now)
pairedTrace.finishCaptureWindowsForTest()
pairedTrace.flush()
let afterKey = beforeAndAfter.last!.rightCommandLayouts!.last!
check(reads == 2 && beforeKey.id == afterKey.id && beforeKey.commit == afterKey.commit &&
      afterKey.firstKey?.layout == .abc && afterKey.firstKey?.overrideLayout == .us &&
      afterKey.outcome == .firstKey, "same transition and ABC layout persisted in both halves of a manual capture")
print("PASS ongoing switch, unchanged conflicting layout, mismatched confirmation, old captures and malformed evidence")

// Activation and diagnostics must describe the very same commit. A second
// read here could turn an ABC conflict into an apparently normal transition.
now += 1_000_000
paired.requested(korean, at: now, rightCommand: true)
paired.confirmed(korean, at: now, reading: (now, (korean, abc, nil, korean)))
let commitTime = now
now += 5_000_000
paired.firstKey(.keyDown, key(15), at: now)
pairedTrace.mark()
pairedTrace.flush()
let sharedCommit = beforeAndAfter.last!.rightCommandLayouts!.last!
check(reads == 3 && sharedCommit.commit.readMicros == Int(commitTime/1000) &&
      sharedCommit.commit.layout == .abc && sharedCommit.commit.overrideLayout == .none &&
      sharedCommit.firstKey?.overrideLayout == .us, "shared commit sample and independent first-key sample")

// A user switch queued during a repair confirms on its own source boundary.
// An intervening menu selection must end the association before a following key.
do {
    let recovery = ReturnEditor(left: "", right: "")
    let engine = recovery.engine
    var seen: [InputIncidentTrace.Capture] = []
    let records = InputIncidentTrace(secureInput: { false }, destination: nil, writer: { seen.append($0) })
    let observer = RightCommandLayoutDiagnostics(trace: records, clock: { now }, secure: { false }, read: {
        (recovery.selected, abc, nil, recovery.selected)
    })
    engine.diagnosticSwitchRequested = observer.requested
    engine.diagnosticSwitchConfirmed = { observer.confirmed($0, at: $1) }
    engine.recovering = true
    engine.intendedSource = abc
    engine.recoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
    engine.userToggleDuringRecovery(at: now)
    engine.drain(verifiedSnapshot: recovery.snapshot())
    now += 707_000_000
    observer.firstKey(.keyDown, key(15), at: now)
    records.flush()
    engine.recovering = true
    engine.intendedSource = abc
    engine.recoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
    engine.userToggleDuringRecovery(at: now)
    engine.drain(verifiedSnapshot: recovery.snapshot())
    engine.recovering = true
    now += 1_000_000
    engine.setUserSourceIntent(abc, at: now)
    observer.firstKey(.keyDown, key(15), at: now)
    records.mark()
    records.flush()
    check(seen[0].rightCommandLayouts?.map(\.outcome) == [.firstKey, .superseded],
          "recovery-owned switches have separate boundaries including a subsequent external selection")
    print("PASS recovery-owned right Command and intervening external source intent")
}

for (rightCommand, conflict) in [(true, true), (true, false), (false, true)] {
    let editor = ReturnEditor(left: "rk", right: "")
    let engine = editor.engine
    var inspections = 0, selections = [String]()
    engine.inspectRecoverySwitchLayout = { target, stamp in
        check(target == korean && stamp == now, "inspect only the confirmed Korean transition")
        inspections += 1
        return conflict
    }
    engine.testSelectSource = { target in
        selections.append(target)
        editor.selected = target
        return noErr
    }
    engine.recoveryLayoutReady = { target in editor.selected == target }
    engine.recovering = true
    engine.intendedSource = abc
    engine.recoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
    now += 1_000_000
    engine.setUserSourceIntent(korean, at:now, rightCommand:rightCommand)
    engine.drain(verifiedSnapshot: editor.snapshot())
    let expected = rightCommand && conflict ? [abc, korean] : []
    check(selections == expected && inspections == (rightCommand ? 1 : 0),
          "recovery owner selects immediately and once before any first key")
    engine.drain(verifiedSnapshot: editor.snapshot())
    check(selections == expected && !engine.recovering && editor.body == "rk" &&
          editor.range == NSRange(location:2, length:0) && editor.writes.isEmpty,
          "recovery owner keeps draft and caret across the verified return")
}
print("PASS shared diagnostic/activation sample and recovery-owned pre-key round trip")
