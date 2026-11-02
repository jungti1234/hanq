import AppKit
import Carbon

func runNativeObservationTests() {
    for selected in [false,true] {
        for next:CGKeyCode in [0,15,51] {
            let b=SourceSwitchBarrier()
            var range=NSRange(location:2,length:0),clock=0.0,posts=0,writes=0,retained=0
            b.source={ko};b.now={clock}
            b.read={.init(field:field,text:"그럼",selection:range)}
            b.send={_ in posts+=1};b.applySelection={_,_ in writes+=1;return true}
            b.retained={retained += $0.count}
            let all=key(0,.maskCommand)
            check(!b.receive(.keyDown,all),"original Cmd+A passes once")
            b.observe(.keyDown,all)
            let release=key(0,.maskCommand);release.type = .keyUp
            check(!b.receive(.keyUp,release),"original shortcut release passes")
            b.observe(.keyUp,release)
            if selected{range=NSRange(location:0,length:2)}
            b.step()
            check(!b.busy,"native composition commit/selection never owns subsequent input")
            let down=key(next,next==0 ? .maskCommand:[])
            check(!b.receive(.keyDown,down),"next Cmd+A, letter or Backspace passes before selection acknowledgment")
            b.observe(.keyDown,down)
            let up=down.copy()!;up.type = .keyUp
            check(!b.receive(.keyUp,up),"following release passes without retained pair")
            b.observe(.keyUp,up)
            clock=1.1;b.step()
            check(posts==0 && writes==0 && retained==0 && !b.busy,"native observation never replays, edits or retains")
        }
    }
    do {
        let b=SourceSwitchBarrier();var text="그럼",range=NSRange(location:2,length:0)
        b.source={ko};b.read={.init(field:field,text:text,selection:range)}
        for _ in 0..<3 {
            let all=key(0,.maskCommand)
            check(!b.receive(.keyDown,all),"repeated native shortcut is not quarantined")
            b.observe(.keyDown,all)
            let up=all.copy()!;up.type = .keyUp
            check(!b.receive(.keyUp,up),"repeated shortcut release remains paired")
            b.observe(.keyUp,up);b.step()
        }
        range=NSRange(location:0,length:2);b.step()
        let deletion=key(51)
        check(!b.receive(.keyDown,deletion),"delete after actual full selection passes")
        b.observe(.keyDown,deletion)
        text="";range=NSRange(location:0,length:0)
        let next=key(15)
        check(!b.receive(.keyDown,next),"retyping after native deletion passes")
        b.observe(.keyDown,next)
        check(b.expected?.0=="ㄱ","new input is anchored to actual empty editor, not stale selected text")
        b.fail("test_end")
    }
    for readable in [false,true] {
        let b=SourceSwitchBarrier();var available=true
        b.source={ko};b.read={available ? .init(field:field,text:"그럼",selection:NSRange(location:2,length:0)):nil}
        b.observe(.keyDown,key(0,.maskCommand));available=readable;b.step()
        let shift=key(56,.maskShift);shift.type = .flagsChanged
        check(!b.receive(.flagsChanged,shift),"native wait does not retain an ordinary modifier")
        b.observe(.flagsChanged,shift)
        let next=key(15,.maskShift)
        check(!b.receive(.keyDown,next),"native wait never captures shifted typing even with missing AX")
        b.observe(.keyDown,next)
        check(!b.busy && b.diagnosticCounts.queued==0,"uncertain native observation leaves the input path open")
        b.fail("test_end")
    }
    do {
        let b=SourceSwitchBarrier();var source=ko,range=NSRange(location:2,length:0),switches=0
        b.source={source};b.read={.init(field:field,text:"그럼",selection:range)}
        b.select={source=$0;switches+=1;return noErr}
        b.observe(.keyDown,key(0,.maskCommand));b.step()
        check(!b.busy && b.request(en),"only an actual source request takes ownership")
        b.step();check(b.busy && switches==0,"source switch still waits for its preceding selection boundary")
        range=NSRange(location:0,length:2);b.step();b.step()
        check(switches==1 && source==en && !b.busy,"verified source switch preserves native full selection")
        b.fail("test_end")
    }
}
