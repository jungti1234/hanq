import AppKit
var checks=0
func check(_ value:Bool,_ name:String){if !value{FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8));exit(1)};checks+=1}
func event(_ code:UInt16=13,_ down:Bool=true)->CGEvent{CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!}
let g=OnsetInputGate(marker:99);g.beat()
check(g.receive(.keyDown,event()) != nil,"idle passes input")
check(g.begin(),"hold begins")
for i in 0..<100 {check(g.receive(i%2==0 ? .keyDown:.keyUp,event(UInt16(i%40),i%2==0)) == nil,"held")}
check(!g.finishIfEmpty(),"cannot release before collecting keys")
let held=g.take();check(held.count==100,"all retained")
check(held.enumerated().allSatisfy{Int($0.element.getIntegerValueField(.keyboardEventKeycode))==$0.offset%40},"ordered")
check(g.finishIfEmpty(),"atomic empty release")
check(g.receive(.keyDown,event()) != nil,"released input passes")
let stale=OnsetInputGate(marker:99);stale.beat();_ = stale.begin();_ = stale.receive(.keyDown,event())
stale.heartbeat=0
let start=ProcessInfo.processInfo.systemUptime
check(stale.receive(.keyDown,event()) != nil,"stale observer passes input")
check(ProcessInfo.processInfo.systemUptime-start<0.02,"no observer wait")
check(!stale.healthy() && stale.take().count==1,"stale stops and retains old key")
for type in [CGEventType.tapDisabledByTimeout,.tapDisabledByUserInput]{let x=OnsetInputGate(marker:99);x.beat();check(x.receive(type,event()) != nil,"disable passes");check(!x.healthy(),"disable is terminal")}
let limit=OnsetInputGate(marker:99);limit.beat();_ = limit.begin();limit.holdUntil=1
check(limit.receive(.keyDown,event()) != nil && !limit.healthy(),"deadline passes input")
let shortcut=OnsetInputGate(marker:99);shortcut.beat();_ = shortcut.begin();let command=event();command.flags = .maskCommand
check(shortcut.receive(.keyDown,command) != nil && !shortcut.healthy(),"shortcut passes and stops")
let stopped=OnsetInputGate(marker:99);stopped.beat();_ = stopped.begin();stopped.stop()
check(stopped.receive(.keyDown,event()) != nil,"revocation stop passes input")
let contention=OnsetInputGate(marker:99);contention.beat();contention.lock.lock()
check(contention.receive(.keyDown,event()) != nil,"lock timeout passes input")
contention.lock.unlock()
// Hold from a worker, then release promptly while receive waits: both real input
// and replay acknowledgments must survive ordinary cross-thread contention.
for isReplay in [false,true] {
    let transient=OnsetInputGate(marker:99);transient.beat();_ = transient.begin()
    let acquired=DispatchSemaphore(value:0)
    let worker=Thread {
        transient.lock.lock();acquired.signal()
        Thread.sleep(forTimeInterval:0.0002)
        transient.lock.unlock()
    }
    worker.start();acquired.wait()
    let e=event();if isReplay{e.setIntegerValueField(.eventSourceUserData,value:99)}
    let result=transient.receive(.keyDown,e)
    check(transient.healthy(),"brief contention preserves gate")
    check(isReplay ? result != nil:result == nil,"brief contention preserves routing")
    check(isReplay ? transient.seenCount()==1:transient.take().count==1,"brief contention loses neither held key nor acknowledgment")
}
var timedOut=false
contention.failed={reason in timedOut = reason=="gate_lock_timeout"}
RunLoop.current.run(until:Date().addingTimeInterval(0.01))
check(timedOut && !contention.healthy(),"timeout still stops gate")
let synthetic=OnsetInputGate(marker:99);synthetic.beat();_ = synthetic.begin();let own=event();own.setIntegerValueField(.eventSourceUserData,value:99)
check(synthetic.receive(.keyDown,own) != nil && synthetic.take().isEmpty,"own replay not captured")
check(synthetic.seenCount()==1,"synthetic crossing counted before release")
check(synthetic.receive(.keyUp,own) != nil && synthetic.seenCount()==2,"each synthetic crossing acknowledged")
// Expiration of an untouched first key must not tear down future observation.
func reserved()->OnsetInputGate {
    let gate=OnsetInputGate(marker:99);gate.beat();gate.configureEarly(true)
    let key=event(15);key.flags=[]
    check(gate.receive(.keyDown,key) != nil,"initial down passes")
    check(gate.reservation() != nil,"initial reservation exists")
    return gate
}
for polling in [false,true] {
    let gate=reserved();let up=event(15,false);up.flags=[]
    check(gate.receive(.keyUp,up) != nil && gate.take().isEmpty,"first release passes exactly once")
    gate.heartbeat=0
    if polling{gate.poll()}else{check(gate.receive(.keyDown,event(40)) != nil,"expiry event passes")}
    check(gate.healthy() && gate.reservation()==nil,"empty expiry preserves tap")
    gate.configureEarly(true)
    check(gate.receive(.keyDown,event(15)) != nil && gate.reservation()==nil,"cannot rearm before main acknowledgment")
    check(gate.takeEarlyExpiration() && !gate.takeEarlyExpiration(),"expiry consumed once")
    gate.beat();gate.configureEarly(true);_ = gate.receive(.keyDown,event(15))
    check(gate.reservation() != nil,"next input can reserve immediately")
}
let deadline=reserved();deadline.holdUntil=1;deadline.poll()
check(deadline.healthy() && deadline.takeEarlyExpiration(),"empty reservation deadline preserves observation")
let queued=reserved();queued.held=[event(40)];queued.heartbeat=0;queued.poll()
check(!queued.healthy() && queued.take().count==1 && !queued.takeEarlyExpiration(),"queued originals keep terminal safety")
let claimed=reserved();check(claimed.claimEarly(),"repair claim succeeds");claimed.heartbeat=0;claimed.poll()
check(!claimed.healthy() && !claimed.takeEarlyExpiration(),"claimed repair keeps terminal safety even empty")
let repeated=reserved();check(repeated.claimEarly(),"claim before repeat");_ = repeated.receive(.keyDown,event(15));_ = repeated.take()
check(repeated.receive(.keyUp,event(15,false))==nil,"release cannot overtake engine-side repeated down")
let ordered=reserved();check(ordered.claimEarly(),"claim before ordered queue");_ = ordered.receive(.keyDown,event(40))
check(ordered.receive(.keyUp,event(15,false))==nil,"first release cannot overtake queued input")
print("PASS \(checks) input gate checks; no event tap installed, no keys posted")
