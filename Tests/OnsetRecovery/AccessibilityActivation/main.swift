import AppKit
var count=0
func check(_ value:Bool,_ message:String){count+=1;precondition(value,message)}
let app=NSRunningApplication.current
let appAX=AXUIElementCreateApplication(getpid())
func engine()->OnsetRecoveryEngine {
    let e=OnsetRecoveryEngine();e.target=app;e.ax=appAX;e.enabled=true
    e.testAccessibilityReady={true};e.testAccessibilityTarget={getpid()};e.accessibilityClock={0}
    e.focusAccess.read={_ in nil};e.focusAccess.frontmostPID={getpid()}
    e.testAccessibilityRequest={_,_ in preconditionFailure("unconfigured test cannot write actual AX")}
    return e
}
let e=engine();var writes:[String]=[];var now=0.0;var exposed=false
e.accessibilityClock={now};e.testAccessibilityRequest={_,name in
    writes.append(name)
    if now>=1{exposed=true;return .success}
    return .cannotComplete
}
e.focusAccess.read={_ in exposed ? appAX:nil}
check(e.focusedElement(appAX,pid:getpid())==nil && writes.isEmpty,"keyboard/snapshot focus failure never performs activation writes")
e.serviceFocusAccessibility()
check(writes.count==2 && !exposed && !e.recovering && e.pending.isEmpty,"failed first request leaves ordinary input untouched")
now=0.5;e.serviceFocusAccessibility();check(writes.count==2,"retry waits for next interval")
now=1;e.serviceFocusAccessibility();check(writes.count==4 && exposed,"second idle request can restore an app that rejected the first")
check(e.focusedElement(appAX,pid:getpid()) != nil,"only normal focus read confirms restored exposure")
now=100;e.serviceFocusAccessibility();check(writes.count==4,"restored focus stops requests")
exposed=false;_ = e.focusedElement(appAX,pid:getpid());e.serviceFocusAccessibility()
check(writes.count==6,"same-session later loss is recoverable")

let disabled:[(String,(OnsetRecoveryEngine)->Void)]=[
    ("disabled",{$0.enabled=false}),("repair",{$0.recovering=true}),
    ("context wait",{$0.waitingForContext=true}),("replay",{$0.replayStarted=true}),
    ("pending",{$0.pending=[CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!]}),
    ("retained",{$0.retainedInput=[CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!]}),
    ("prefix",{$0.prefixRemainder=[CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!]}),
    ("unconfirmed post",{$0.postedToGate=1}),
    ("acknowledgment",{$0.unacknowledgedPosts=[(sequence:1,time:0)]}),
    ("manual edit",{$0.canBeginRepair={false}}),
    ("permission or secure input",{$0.testAccessibilityReady={false}}),
    ("different focus owner",{$0.focusAccess.frontmostPID={getpid()+1}}),
    ("missing app root",{$0.ax=nil}),("missing target",{$0.target=nil;$0.testAccessibilityTarget=nil}),
    ("invalid target",{$0.testAccessibilityTarget={-1}})
]
for (name,disable) in disabled {
    let x=engine();var requests=0;x.testAccessibilityRequest={_,_ in requests+=1;return .success}
    _ = x.focusedElement(appAX,pid:getpid());disable(x);x.serviceFocusAccessibility()
    check(requests==0,"\(name) must not change the target application's accessibility")
}
let switched=engine();var switchWrites=0;var pid:pid_t?=getpid()
switched.focusAccess.frontmostPID={pid};switched.testAccessibilityRequest={_,_ in switchWrites+=1;pid=getpid()+1;return .success}
_ = switched.focusedElement(appAX,pid:getpid());switched.serviceFocusAccessibility()
check(switchWrites==1,"focus change during first request prevents the second write")
let revoked=engine();var trusted=true;var revokedWrites=0
revoked.testAccessibilityReady={trusted};revoked.testAccessibilityRequest={_,_ in revokedWrites+=1;trusted=false;return .apiDisabled}
_ = revoked.focusedElement(appAX,pid:getpid());revoked.serviceFocusAccessibility()
check(revokedWrites==1,"permission loss between activation attributes stops immediately")
let reserved=engine();let gate=OnsetInputGate(marker:reserved.marker);gate.beat();gate.configureEarly(true);reserved.gate=gate
let key=CGEvent(keyboardEventSource:nil,virtualKey:15,keyDown:true)!;_ = gate.receive(.keyDown,key)
check(gate.reservation() != nil,"fixture has a live first-key reservation")
var reservedWrites=0;reserved.testAccessibilityRequest={_,_ in reservedWrites+=1;return .success}
_ = reserved.focusedElement(appAX,pid:getpid());reserved.serviceFocusAccessibility()
check(reservedWrites==0,"reserved first key cannot be delayed by accessibility writes")
gate.stop()
let beganEdit=engine();var editWrites=0
beganEdit.testAccessibilityRequest={_,_ in editWrites+=1;beganEdit.recovering=true;return .success}
_ = beganEdit.focusedElement(appAX,pid:getpid());beganEdit.serviceFocusAccessibility()
check(editWrites==1,"a transaction starting during activation prevents any following write")
let healthy=engine();var extraFocusReads=0
healthy.focusAccess.read={_ in extraFocusReads+=1;return nil}
healthy.serviceFocusAccessibility()
check(extraFocusReads==0,"healthy observations add no AX focus query or gate work")
print("PASS \(count) production idle activation integration checks; all AX writes injected; no OS keys posted")
