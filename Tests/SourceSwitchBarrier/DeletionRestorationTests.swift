import AppKit

func runDeletionRestorationTests() {
    // Several committed source intervals must stay outside the split search.
    // All observations and side effects are injected; no editor is touched.
    for scenario in ["split", "prefix", "style", "repeat", "body", "suffix", "caret", "selection", "field", "source", "unreadable", "shortcut", "unverified", "canonical"] {
        let b=SourceSwitchBarrier()
        var source=ko,focused=field,available=true
        var replay=MismatchReplayLedger(before:"앞🙂 뒤",caret:4)
        replay.append(source:en,keys:[(0,false),(49,false)])
        replay.append(source:ko,keys:[(1,false),(40,false)])
        replay.append(source:en,keys:[(11,false),(49,false)])
        let simple=["prefix","canonical"].contains(scenario)
        let codes:[UInt16]=simple ? [15,40,1]:[15,46,3,38,0,2,37,15,38]
        replay.append(source:ko,keys:codes.map{($0,false)})
        var text=replay.text,range=replay.selection
        check(text=="앞🙂 a 나b "+(simple ? "간":"그럼이거")+"뒤","multi-source restoration fixture has known text")
        b.now={100};b.source={source};b.readFocus={focused}
        b.read={available ? .init(field:focused,text:text,selection:range):nil}
        b.incidentTrace=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{_ in check(false,"restoration fixture never writes diagnostics")})
        b.send={_ in check(false,"restoration never posts keys")}
        b.select={_ in check(false,"restoration never switches sources");return -50}
        b.applySelection={_,_ in check(false,"restoration never writes selection");return false}
        b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:text,selection:range))
        if scenario=="unverified" {text="changed";range=NSRange(location:7,length:0)}
        b.observe(.keyDown,key(51,scenario=="shortcut" ? .maskAlternate:[]))
        text="앞🙂 a 나b "+(simple ? "가":"그럼이ㄱ")+"뒤"
        range=NSRange(location:text.utf16.count-1,length:0)
        if scenario=="repeat" {
            b.observe(.keyDown,key(51));text="앞🙂 a 나b 그럼이뒤";range=NSRange(location:text.utf16.count-1,length:0)
            b.observe(.keyDown,key(15));text="앞🙂 a 나b 그럼이ㄱ뒤";range=NSRange(location:text.utf16.count-1,length:0)
        }
        if scenario=="style" {text=text.replacingOccurrences(of:"a 나b ",with:"A\u{00a0}나B\u{00a0}")}
        if scenario=="body" {text=text.replacingOccurrences(of:"앞",with:"옆")}
        if scenario=="suffix" {text=text.replacingOccurrences(of:"뒤",with:"끝")}
        if scenario=="caret" {range.location-=1}
        if scenario=="selection" {range.length=1}
        if scenario=="field" {focused=other}
        if scenario=="source" {source=en}
        if scenario=="unreadable" {available=false}
        if scenario=="canonical" {text=text.replacingOccurrences(of:"가",with:"\u{1100}\u{1161}");range.location+=1}
        let before=text,selection=range,code:UInt16=simple ? 1:38
        b.observe(.keyDown,key(code))
        if ["split","prefix","style","repeat"].contains(scenario) {
            check(b.expected?.0=="앞🙂 a 나b "+(simple ? "간":"그럼이거")+"뒤","restoration preserves observed split and committed intervals: \(scenario)")
            check(b.expected?.1==NSRange(location:b.expected!.0.utf16.count-1,length:0),"restored caret remains before original suffix: \(scenario)")
        } else if scenario=="unreadable" {
            check(b.expected==nil,"unreadable snapshot cannot reuse deletion history")
        } else {
            let inserted=source==en ? "j":(simple ? "ㄴ":"ㅓ")
            let fresh=(before as NSString).replacingCharacters(in:selection,with:inserted)
            check(b.expected?.0==fresh,"failed restoration uses actual body and selection: \(scenario)")
            check(b.expected?.1==NSRange(location:selection.location+inserted.utf16.count,length:0),"failed restoration does not retain old caret: \(scenario)")
        }
        check(!b.busy,"deletion observation owns no input transaction: \(scenario)")
        b.fail("test_cleanup")
    }
}
