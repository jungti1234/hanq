import AppKit

func runSelectAllBoundaryTests() {
    let field=AXUIElementCreateApplication(12345),en="com.apple.keylayout.ABC"
    func pump(){RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2))}
    func make(_ changeContext:Bool=false)->(MismatchRecoveryEngine,()->String,()->Int) {
        let p=MismatchRecoveryEngine();p.enabled=true;p.recovering=true;p.planElement=field
        p.intendedSource=en;p.testFastContext={true}
        var source=mismatchKoreanID,text="알트탭",selection=NSRange(location:3,length:0),posts=0
        p.testSource={source};p.testSelectSource={s in source=s;if changeContext{text="다른 내용"};return noErr}
        p.testSnapshot={MismatchSnapshot(element:field,text:text,selection:selection)}
        p.testSetRange={_,range in
            probeTestCheck(source==en,"switch before applying full selection")
            selection=range;return .success
        }
        p.testPost={e in
            probeTestCheck(!e.flags.contains(.maskCommand),"never replay Command A as printable input")
            posts+=1
            if e.type == .keyDown {
                let c=MismatchRecoveryPlan.character(UInt16(e.getIntegerValueField(.keyboardEventKeycode)),false)!
                text=(text as NSString).replacingCharacters(in:selection,with:c)
                selection=NSRange(location:selection.location+c.utf16.count,length:0)
            }
        }
        p.ledger=MismatchReplayLedger(before:"알트탭",caret:3)
        func queue(_ code:CGKeyCode,_ down:Bool,_ flags:CGEventFlags,_ source:String) {
            let e=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down)!;e.flags=flags
            p.nextBufferedID+=1;p.bufferedIdentities[ObjectIdentifier(e)]=p.nextBufferedID;p.pendingSources[p.nextBufferedID]=source;p.pending.append(e)
        }
        queue(0,true,.maskCommand,mismatchKoreanID);queue(0,false,.maskCommand,mismatchKoreanID)
        for code:CGKeyCode in [0,37,17,17,0,11,49,0,37]{queue(code,true,[],en);queue(code,false,[],en)}
        return (p,{text},{posts})
    }
    let (normal,text,posts)=make();normal.drain();pump()
    probeTestCheck(text()=="alttab al","select all then switch then English replaces entire composition")
    probeTestCheck(!normal.recovering && !normal.suspended && normal.pending.isEmpty,"transaction finishes without retaining text")
    probeTestCheck(posts()==18,"nine English keys sent once as paired events")
    probeTestCheck(normal.currentSource()==en,"requested English source preserved")
    let (changed,changedText,changedPosts)=make(true);changed.drain();pump()
    probeTestCheck(changed.suspended && changedPosts()==0 && changedText()=="다른 내용","changed context never receives selection or replay")
    let shortcut=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!;shortcut.flags=[.maskCommand,.maskShift]
    probeTestCheck(!MismatchRecoveryEngine.isSelectAll(shortcut),"different shortcut is not treated as Select All")
    print("PASS: queued Select All, source transition, exact English replacement, paired delivery and changed context")
}
