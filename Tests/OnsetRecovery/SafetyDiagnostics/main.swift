import AppKit
let engine=OnsetRecoveryEngine();let gate=OnsetInputGate(marker:123);engine.gate=gate
let event=CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!
engine.pending=[event];engine.retainedInput=[event];engine.prefixRemainder=[event];engine.postedToGate=3
let args=ProcessInfo.processInfo.arguments
if !args.contains("--diagnose-input") {
    // A disabled trace must not even acquire the gate lock.
    gate.lock.lock();engine.traceSafety(.stop,reason:"PRIVATE_ONSET_SAFETY_PAYLOAD");gate.lock.unlock()
    print("PASS: disabled safety trace does not read gate state")
} else {
    engine.unavailableReason="PRIVATE_ONSET_SAFETY_PAYLOAD"
    engine.traceDeliveryContext(hasSnapshot:false,hasPlanField:true,sameField:false,sameSource:nil)
    engine.traceSafety(.stop,reason:"PRIVATE_ONSET_SAFETY_PAYLOAD")
    engine.log("privacy_check",["text":"PRIVATE_ONSET_SAFETY_PAYLOAD","code":40,"events":[event]])
    gate.fail("observation_stale")
    engine.traceSafety(.stop,reason:"acknowledgment_gate_unavailable")
    engine.acknowledgmentClock={10};engine.acknowledgmentWaitBegan=9.75
    engine.traceSafety(.ackWait)
    let path=args[args.firstIndex(of:"--diagnose-input")!+1]
    let text=try! String(contentsOfFile:path,encoding:.utf8)
    precondition(text.contains("reason=other") && !text.contains("PRIVATE_ONSET_SAFETY_PAYLOAD"))
    precondition(text.contains("reason=acknowledgment_gate_unavailable") && text.contains("gateFailure=observation_stale"))
    precondition(text.contains("pending=1 retained=1 prefix=1 posted=3") && text.contains("waitMs=250"))
    precondition(!text.contains("code=") && !text.contains("events=") && !text.contains("text="))
    precondition(text.contains("readFailure=other") && text.contains("sameSource=unchecked"))
    print("PASS: fixed reasons and counts only; unknown reason and generic payload excluded")
}
