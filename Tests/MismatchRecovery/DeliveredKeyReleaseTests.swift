import AppKit

func runDeliveredKeyReleaseTests() {
    let field=AXUIElementCreateApplication(12345)
    func make()->MismatchRecoveryEngine {
        let p=MismatchRecoveryEngine();p.enabled=true;p.recovering=true;p.planElement=field
        p.testSnapshot={nil};p.testFastContext={true}
        p.recoveryDeadline=ProcessInfo.processInfo.systemUptime+2.5
        p.deliveredHeldKeys=[2];p.heldKeys=[2]
        return p
    }
    func event(_ code:CGKeyCode,_ down:Bool)->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!
        e.flags=[];return e
    }
    let original=make(),up=event(2,false)
    probeTestCheck(original.event(.keyUp,up) != nil,"release already-delivered d immediately")
    probeTestCheck(original.pending.isEmpty && original.deliveredHeldKeys.isEmpty && original.heldKeys.isEmpty,"no delayed duplicate release")
    let queued=make()
    probeTestCheck(queued.event(.keyDown,event(40,true))==nil,"new vowel remains ordered in queue")
    probeTestCheck(queued.event(.keyUp,event(40,false))==nil,"queued vowel release stays with its down")
    probeTestCheck(queued.event(.keyUp,event(2,false)) != nil,"original d release passes even behind queued vowel")
    probeTestCheck(queued.pending.count==2,"original release is not appended to typing queue")
    let repeated=make(),repeatDown=event(2,true)
    repeatDown.setIntegerValueField(.keyboardEventAutorepeat,value:1)
    probeTestCheck(repeated.event(.keyDown,repeatDown)==nil,"repeat stays in input order")
    probeTestCheck(repeated.event(.keyUp,event(2,false)) != nil,"original held key is released now")
    probeTestCheck(repeated.pending.count==2 && repeated.pending.last?.type == .keyUp,"queued repeat has its own paired later release")
    repeated.closeSession()
    probeTestCheck(repeated.deliveredHeldKeys.isEmpty,"teardown clears original hold tracking")
    print("PASS: 10 delivered-key release checks; original release passes during AX wait, queued down/up pairs preserved")
}
