import AppKit
func runShortcutSourceStateTests() {
    let owner=MismatchSourceSwitch();var source="Korean";var selections:[String]=[]
    owner.reset(source)
    func select(_ id:String)->OSStatus{selections.append(id);source=id;return noErr}
    probeTestCheck(owner.request("English",valid:{true},current:{source},select:select)==noErr,"explicit English selection succeeds")
    probeTestCheck(selections==["English"] && source=="English" && !owner.busy,"exact source chosen without synthesized shortcut")
    probeTestCheck(!owner.observe("English"),"delayed owned notification does not become user intent")
    probeTestCheck(owner.observe("Korean"),"external source change is observable")
    probeTestCheck(owner.request("Other",valid:{false},current:{source},select:select) != noErr && selections==["English"],"invalid context never selects")
    probeTestCheck(owner.request("",valid:{true},current:{source},select:select) != noErr,"empty source never cycles")
    probeTestCheck(owner.request("Unavailable",valid:{true},current:{source},select:{_ in -50}) == -50,"source selection failure propagates")
    var time=1.0;source="Korean";owner.now={time};owner.reset("Korean")
    probeTestCheck(owner.request("English",valid:{true},current:{source},select:{_ in noErr})==noErr && owner.unsettled,"asynchronous selection retains one bounded receipt")
    probeTestCheck(!owner.observe("English") && !owner.unsettled,"late requested source is internal")
    owner.reset("Korean");_=owner.request("English",valid:{true},current:{"Korean"},select:{_ in noErr});time+=1
    probeTestCheck(owner.observe("English"),"expired internal receipt cannot hide a later external switch")
    owner.cancel();probeTestCheck(!owner.busy && !owner.unsettled,"cancel carries no synthetic key to release")
    for (flags,letter,number) in [(CGEventFlags(),"a","1"),(.maskShift,"A","!"),(.maskAlphaShift,"A","1"),([.maskShift,.maskAlphaShift],"A","!")] {
        for (code,expected) in [(UInt16(0),letter),(UInt16(18),number)] {
            let shift=MismatchReplayLedger.modelShift(code:code,flags:flags,source:"com.apple.keylayout.ABC")
            var ledger=MismatchReplayLedger(before:"앞🙂뒤",caret:3);ledger.append(source:"com.apple.keylayout.ABC",keys:[(code,shift)])
            probeTestCheck(ledger.insertion==expected,"English Caps/Shift preserves case without shifting punctuation")
        }
        let shift=MismatchReplayLedger.modelShift(code:0,flags:flags,source:mismatchKoreanID)
        probeTestCheck(shift==flags.contains(.maskShift),"Korean layout ignores Caps capitalization")
    }
    print("PASS: 11 explicit source selection, failure and notification ownership checks; no OS key posts")
}
