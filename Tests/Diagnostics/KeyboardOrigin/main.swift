import Foundation
import CoreGraphics

typealias Press = KeyboardOriginComparison.Press
let times: [UInt64] = [100_000, 201_007, 201_055, 295_000]
let presses = times.enumerated().map {
    Press(time: $0.element, sequence: $0.offset + 1, repeated: $0.offset == 2, processReported: $0.offset == 2)
}
func compare(_ times: [UInt64], at now: UInt64 = 600_000) -> [InputIncidentTrace.KeyboardBurst] {
    var window = KeyboardDeviceWindow()
    window.reset(.ready, at: 0)
    for t in times { window.observe(t, now: t + 100) }
    return KeyboardOriginComparison.compare(presses, device: window, now: now)
}
let equal = compare(times)
precondition(equal.count == 3 && equal[1].deviceDown == 2 && equal[1].quartzDown == 2 && equal[1].outcome == 1)
let excess = compare([times[0], times[1], times[3]])[1]
precondition(excess.deviceDown == 1 && excess.quartzDown == 2 && excess.outcome == 2 && excess.firstSequence == 2)
precondition(excess.repeatDown == 1 && excess.reportedProcessDown == 1)
precondition(compare([]).allSatisfy { $0.outcome == 0 })
precondition(compare([times[0], times[1]])[1].outcome == 0)
precondition(compare([times[0], times[1], times[3]], at: 305_000)[1].outcome == 0)
precondition(compare(times + [205_000])[1].outcome == 0)
precondition(compare(times, at: 61_000_000).isEmpty)
var window = KeyboardDeviceWindow()
window.observe(1, now: 2)
precondition(window.downs.isEmpty)
window.reset(.ready, at: 0)
for i in 1...513 { window.observe(UInt64(i), now: UInt64(i)) }
precondition(window.downs.isEmpty && window.since == 513)
window.observe(520, now: 530)
window.observe(521, now: 200_000)
precondition(window.downs.isEmpty && window.since == 200_000)
window.reset(.interrupted, at: 201_000)
precondition(KeyboardOriginComparison.compare(presses, device: window, now: 600_000).isEmpty)

// Use local, unposted CGEvents to exercise manual capture and the strict readers.
var clock = 100.0
var captures: [InputIncidentTrace.Capture] = []
let trace = InputIncidentTrace(secureInput: { false }, destination: nil, clock: { clock }, writer: { captures.append($0) })
trace.keyboardSample = { frames, _ in
    guard let row = frames.first(where: { $0.eventEvidence?.keyClass == 2 }) else {
        return .init(status: 1, bursts: [])
    }
    return .init(status: 1, bursts: [.init(firstSequence: row.sequence, deviceDown: 1, quartzDown: 2,
                                           repeatDown: 1, reportedProcessDown: 1, outcome: 2)])
}
for i in 0..<2 {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
    e.timestamp = UInt64(100_000_000_000 + 50_000 * i)
    e.setIntegerValueField(.keyboardEventAutorepeat, value: Int64(i))
    e.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(123456789 * i))
    clock = 100.001 + 0.00005 * Double(i)
    trace.event(.hid, .keyDown, e)
}
trace.flush()
clock += 0.4
trace.mark()
trace.flush()
let capture = captures.first!
var dev = KeyboardDeviceWindow()
dev.reset(.ready, at: 99_000_000)
dev.observe(100_000_000, now: 100_000_080)
dev.observe(100_000_050, now: 100_000_090)
let mapped = KeyboardOriginDiagnostics.compareFrames(capture.frames, origin: capture.clockOriginMicros!, window: dev, now: 100_400_000)
precondition(mapped.status == 1 && mapped.bursts.count == 1 && mapped.bursts[0].outcome == 1)
precondition(mapped.bursts[0].repeatDown == 1 && mapped.bursts[0].reportedProcessDown == 1)
let bytes = try JSONEncoder().encode(capture)
_ = try RecorderTrace.decode(bytes)
precondition(!String(decoding: bytes, as: UTF8.self).contains("123456789"))
var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
let original = object["keyboardOrigin"] as! [String: Any]
for bad: [String: Any] in [original.merging(["keyCode": 0]) { _, v in v },
                             ["status": 2, "bursts": original["bursts"]!]] {
    object["keyboardOrigin"] = bad
    precondition((try? RecorderTrace.decode(JSONSerialization.data(withJSONObject: object))) == nil)
}
object.removeValue(forKey: "keyboardOrigin")
_ = try RecorderTrace.decode(JSONSerialization.data(withJSONObject: object))
try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
trace.stopAndFlush()
print("PASS keyboard-origin counts, ambiguous coverage, retention, strict manual capture and privacy")
