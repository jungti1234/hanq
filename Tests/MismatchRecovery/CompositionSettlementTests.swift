import AppKit
import Carbon

// Engine-only regressions for the two boundaries seen in the Edge report.
// No OS key posting, AX writes, source selection or simulated IME key loss.
func runCompositionSettlementTests(){
    let ko=mismatchKoreanID,field=AXUIElementCreateApplication(12345)
    var checks=0
    func check(_ value:Bool,_ message:String){checks+=1;probeTestCheck(value,message)}
    func pump(_ seconds:Double){RunLoop.current.run(until:Date().addingTimeInterval(seconds))}
    func candidate(_ roman:String="dks")->MismatchRecoveryPlan {
        var p=MismatchRecoveryPlan(before:"아",caret:1,sourceID:ko)
        for letter in roman {
            let code=PhysicalLetterKeys.letters.first{$0.value==String(letter)}!.key
            probeTestCheck(p.append(code:code,shift:false))
        }
        return p
    }
    func detection()->MismatchRecoveryEngine {
        let p=MismatchRecoveryEngine(detectionOnly:true)
        p.enabled=true;p.locked=field;p.planElement=field;p.lastSource=ko;p.testSource={ko}
        p.plan=candidate();p.planStart=ProcessInfo.processInfo.systemUptime
        p.testPost={_ in probeTestCheck(false,"detection posted an OS key")}
        p.testSelectSource={_ in probeTestCheck(false,"detection selected a source");return noErr}
        return p
    }
    let partial=MismatchSnapshot(element:field,text:"아아ㄴ",selection:NSRange(location:3,length:0))
    let normal=MismatchSnapshot(element:field,text:"아안",selection:NSRange(location:2,length:0))
    // The old detector immediately starts even when the final original S is
    // still held. A transient partial frame is not a settled composition.
    let held=detection();held.heldKeys=[1]
    held.consumeIdleSnapshot(partial);pump(0.025);held.consumeIdleSnapshot(partial)
    check(held.detectionCount==0 && held.plan != nil,"interrupted composition stays observational while a printable key is held")
    held.heldKeys=[];held.consumeIdleSnapshot(normal);pump(0.025);held.consumeIdleSnapshot(normal)
    check(held.detectionCount==0,"normal composition settling before release is never repaired")

    let persistent=detection()
    persistent.consumeIdleSnapshot(partial)
    check(persistent.detectionCount==0,"one unheld partial frame is not stable proof")
    pump(0.025);persistent.consumeIdleSnapshot(partial)
    check(persistent.detectionCount==1,"persistent complete split still reaches the original repair detector")

    for reason in ["key","missing","text","caret","field","source"] {
        let p=detection();p.consumeIdleSnapshot(partial);pump(0.025)
        switch reason {
        case "key":p.detectionRevision+=1
        case "missing":p.consumeIdleSnapshot(nil)
        case "text":p.consumeIdleSnapshot(normal)
        case "caret":p.consumeIdleSnapshot(.init(element:field,text:partial.text,selection:NSRange(location:2,length:0)))
        case "field":p.consumeIdleSnapshot(.init(element:AXUIElementCreateApplication(67890),text:partial.text,selection:partial.selection));p.locked=field;p.planElement=field;p.plan=candidate();p.planStart=ProcessInfo.processInfo.systemUptime
        default:p.sourceChanged("com.apple.keylayout.ABC",normal);p.plan=candidate();p.lastSource=ko
        }
        p.consumeIdleSnapshot(partial)
        check(p.detectionCount==0,"\(reason) invalidates the prior settlement observation")
    }
    let roman=detection();roman.plan=candidate("dk");roman.heldKeys=[40]
    roman.consumeIdleSnapshot(.init(element:field,text:"아dk",selection:NSRange(location:3,length:0)))
    check(roman.detectionCount==1,"literal Roman mismatch retains its existing immediate detection")
    for asynchronous in [false,true] {
        let p=detection(),evidence=MismatchSourceEvidence()
        var source=ko,clock=100.0
        evidence.now={clock};evidence.request(ko,at:200);evidence.didCommit(ko,at:200);evidence.observe(ko)
        p.sourceEvidence=evidence;p.testSource={source}
        p.consumeIdleSnapshot(partial)
        source="com.apple.keylayout.ABC"
        if asynchronous{p.consumeIdleSnapshot(partial)}else{p.sample(synchronous:true)}
        source=ko;clock+=0.01;evidence.observe(ko)
        pump(0.025);p.consumeIdleSnapshot(partial)
        check(p.detectionCount==0,"a deferred \(asynchronous ? "reply":"poll") cannot bridge the interrupted observation")
        pump(0.025);p.consumeIdleSnapshot(partial)
        check(p.detectionCount==1,"fresh stable observations after source confirmation still recover")
    }
    print("PASS \(checks) composition settlement boundaries; no OS keys/AX/source changes")
}
