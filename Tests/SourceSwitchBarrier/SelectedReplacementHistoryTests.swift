import AppKit
import Carbon

// AppDelegate ordering with injected editor/source/transport. A timed-out
// layout guard may clear its transport history; detector history must still
// cover the original selection replacement when AX catches up in a batch.
func runSelectedReplacementBarrierTests(){
    let ko=KoreanKeyboardLayout.twoSetID,en="com.apple.keylayout.ABC"
    let field=AXUIElementCreateApplication(900001),window=AXUIElementCreateApplication(900002)
    let codes:[UInt16]=[15,40,1,40]
    func event(_ c:UInt16,_ time:Double,_ down:Bool)->CGEvent {
        let e=CGEvent(keyboardEventSource:nil,virtualKey:c,keyDown:down)!
        e.flags=[];e.timestamp=UInt64(time*1_000_000_000);return e
    }
    for conflict in [true,false] {for stale in [true,false] {
        var body="ABCDEF",selection=NSRange(location:0,length:6),source=en
        var time=ProcessInfo.processInfo.systemUptime-2.0,stages:[String]=[]
        let b=SourceSwitchBarrier(),e=MismatchRecoveryEngine()
        b.now={time};b.source={source};b.select={source=$0;return noErr}
        b.read={.init(field:field,text:body,selection:selection)};b.readFocus={field};b.fieldWindow={_ in window}
        b.initialLayout={conflict ? .conflicting:.ready}
        b.applySelection={_,_ in check(false,"unexpected barrier selection write");return false}
        b.retained={_ in check(false,"unexpected barrier retained input")};b.trace={stages.append($0)}
        e.enabled=true;e.lastSource=ko;e.locked=field
        e.testSnapshot={.init(element:field,text:body,selection:selection)}
        e.testSource={ko};e.testFastContext={true};e.canBeginRepair={false}
        e.testPost={_ in check(false,"unexpected detector OS post")}
        e.testPostAtTap={_,_ in check(false,"unexpected detector tap post")}
        e.testSetRange={_,_ in check(false,"unexpected detector AX write");return .failure}
        e.testSelectSource={_ in check(false,"unexpected detector source selection");return -50}
        e.verifiedDeliveryHistory={s,prior in b.verifiedTwoSetHistory(s,after:0,allowPrior:prior)}
        func afterMain(_ key:CGEvent){
            b.observeBeforeOnset(key.type,key,waiting:false)
            check(e.event(key.type,key) != nil,"combined selected replacement passes original event")
        }
        b.send={key in
            check(!b.receive(key.type,key),"barrier's own copy bypasses queue")
            afterMain(key)
        }
        check(b.request(ko,at:UInt64(time*1_000_000_000)),"selected source request accepted")
        b.step();b.step();check(source==ko && !b.busy,"source selected before first letter")
        time+=0.151
        for (i,c) in codes.enumerated(){
            if i>0 && (!stale || i==3){body=String("rksk".prefix(i));selection=NSRange(location:i,length:0)}
            let key=event(c,time,true)
            if b.receive(.keyDown,key){
                check(conflict && i==0,"only the initial guard owns a press")
                time+=0.087;b.step()
            }else{afterMain(key)}
            check(e.plan?.codes.count==i+1,"every key survives conflict=\(conflict) stale=\(stale)")
            check(e.plan?.before=="" && e.plan?.caret==0,"original replacement boundary never becomes an ASCII prefix")
            let up=event(c,time+0.001,false)
            if !b.receive(.keyUp,up){afterMain(up)}
            time+=0.10
        }
        body="rksk";selection=NSRange(location:4,length:0)
        check(e.plan?.replayRoman=="rksk" && e.plan?.matches(text:body,selection:selection)==true,"entire batch is eligible after exact output appears")
        check(stages.contains("initial_original_resumed")==conflict,"layout-conflict fallback was exercised")
        check(!e.recovering && e.pending.isEmpty && e.retained.isEmpty,"read-only regression never owns repair input")
        b.fail("test_end")
    }}
    print("PASS: all four layout-conflict / delayed-selection combinations preserve the whole replacement")
}
