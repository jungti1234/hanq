import AppKit
var checks=0
func check(_ value:Bool,_ name:String){if !value{FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8));exit(1)};checks+=1}
func event(_ code:UInt16=13,_ down:Bool=true)->CGEvent{CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!}
let g=InputGate(marker:99);g.beat()
check(g.receive(.keyDown,event()) != nil,"idle passes input")
check(g.begin(),"hold begins")
for i in 0..<100 {check(g.receive(i%2==0 ? .keyDown:.keyUp,event(UInt16(i%40),i%2==0)) == nil,"held")}
check(!g.finishIfEmpty(),"cannot release before collecting keys")
let held=g.take();check(held.count==100,"all retained")
check(held.enumerated().allSatisfy{Int($0.element.getIntegerValueField(.keyboardEventKeycode))==$0.offset%40},"ordered")
check(g.finishIfEmpty(),"atomic empty release")
check(g.receive(.keyDown,event()) != nil,"released input passes")
let stale=InputGate(marker:99);stale.beat();_ = stale.begin();_ = stale.receive(.keyDown,event())
stale.heartbeat=0
let start=ProcessInfo.processInfo.systemUptime
check(stale.receive(.keyDown,event()) != nil,"stale observer passes input")
check(ProcessInfo.processInfo.systemUptime-start<0.02,"no observer wait")
check(!stale.healthy() && stale.take().count==1,"stale stops and retains old key")
for type in [CGEventType.tapDisabledByTimeout,.tapDisabledByUserInput]{let x=InputGate(marker:99);x.beat();check(x.receive(type,event()) != nil,"disable passes");check(!x.healthy(),"disable is terminal")}
let limit=InputGate(marker:99);limit.beat();_ = limit.begin();limit.holdUntil=1
check(limit.receive(.keyDown,event()) != nil && !limit.healthy(),"deadline passes input")
let shortcut=InputGate(marker:99);shortcut.beat();_ = shortcut.begin();let command=event();command.flags = .maskCommand
check(shortcut.receive(.keyDown,command) != nil && !shortcut.healthy(),"shortcut passes and stops")
let stopped=InputGate(marker:99);stopped.beat();_ = stopped.begin();stopped.stop()
check(stopped.receive(.keyDown,event()) != nil,"revocation stop passes input")
let contention=InputGate(marker:99);contention.beat();contention.lock.lock()
check(contention.receive(.keyDown,event()) != nil,"lock timeout passes input")
contention.lock.unlock()
// Hold from a worker, then release promptly while receive waits: both real input
// and replay acknowledgments must survive ordinary cross-thread contention.
for isReplay in [false,true] {
    let transient=InputGate(marker:99);transient.beat();_ = transient.begin()
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
let synthetic=InputGate(marker:99);synthetic.beat();_ = synthetic.begin();let own=event();own.setIntegerValueField(.eventSourceUserData,value:99)
check(synthetic.receive(.keyDown,own) != nil && synthetic.take().isEmpty,"own replay not captured")
check(synthetic.seenCount()==1,"synthetic crossing counted before release")
check(synthetic.receive(.keyUp,own) != nil && synthetic.seenCount()==2,"each synthetic crossing acknowledged")
print("PASS \(checks) input gate checks; no event tap installed, no keys posted")
