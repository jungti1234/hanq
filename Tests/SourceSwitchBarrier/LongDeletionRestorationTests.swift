import AppKit

func runLongDeletionRestorationTests() {
    // 125 observed keys, including earlier source intervals. The long prefix
    // remains document text and must never become the repair target.
    let context=String(repeating:"한",count:428)+"🙂 e\u{0301} "
    let repeated=String(repeating:"가",count:55)
    let codes:[UInt16]=Array(repeating:[UInt16(15),40],count:55).flatMap{$0}+[15,46,3,38,0,2,37,15,38]
    for scenario in ["split","repeat","body","suffix","caret","selection","field","source","unreadable","shortcut"] {
        let b=SourceSwitchBarrier();var selected=ko,focused=field,readable=true
        var replay=MismatchReplayLedger(before:context+"뒤",caret:context.utf16.count)
        replay.append(source:en,keys:[(0,false),(49,false)])
        replay.append(source:ko,keys:[(1,false),(40,false)])
        replay.append(source:en,keys:[(11,false),(49,false)])
        replay.append(source:ko,keys:codes.map{($0,false)})
        let fixed=context+"a 나b "+repeated
        var text=replay.text,range=replay.selection
        check(text==fixed+"그럼이거뒤","long deletion starts from independently known text")
        b.source={selected};b.readFocus={focused};b.now={100}
        b.read={readable ? .init(field:focused,text:text,selection:range):nil}
        b.incidentTrace=InputIncidentTrace(secureInput:{false},destination:nil,initiallyEnabled:false,writer:{_ in check(false,"long deletion never writes diagnostics")})
        b.send={_ in check(false,"long deletion never posts keys")}
        b.select={_ in check(false,"long deletion never changes source");return -50}
        b.applySelection={_,_ in check(false,"long deletion never writes AX");return false}
        b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:text,selection:range))
        b.observe(.keyDown,key(51,scenario=="shortcut" ? .maskAlternate:[]))
        text=fixed+"그럼이ㄱ뒤";range=NSRange(location:text.utf16.count-1,length:0)
        if scenario=="repeat" {
            b.observe(.keyDown,key(51));text=fixed+"그럼이뒤";range.location=text.utf16.count-1
            b.observe(.keyDown,key(15));text=fixed+"그럼이ㄱ뒤";range.location=text.utf16.count-1
        }
        if scenario=="body" {text="옆"+String(text.dropFirst())}
        if scenario=="suffix" {text=String(text.dropLast())+"끝"}
        if scenario=="caret" {range.location-=1}
        if scenario=="selection" {range.length=1}
        if scenario=="field" {focused=other}
        if scenario=="source" {selected=en}
        if scenario=="unreadable" {readable=false}
        let actual=text,selection=range
        b.observe(.keyDown,key(38))
        if ["split","repeat"].contains(scenario) {
            check(b.expected?.0==fixed+"그럼이거뒤","long observed split restores composition: \(scenario)")
            check(b.expected?.1==NSRange(location:(fixed+"그럼이거").utf16.count,length:0),"long restoration retains UTF-16 caret")
        } else if scenario=="unreadable" {check(b.expected==nil,"unreadable long history stays unavailable")}
        else {
            let inserted=selected==en ? "j":"ㅓ"
            check(b.expected?.0==(actual as NSString).replacingCharacters(in:selection,with:inserted),"long unsafe history uses actual snapshot: \(scenario)")
            check(b.expected?.1==NSRange(location:selection.location+inserted.utf16.count,length:0),"long unsafe history uses actual selection")
        }
        check(!b.busy,"long restoration owns no input transaction")
        b.fail("test_cleanup")
    }
    // A restored short final segment can still be supplied to the existing
    // mismatch detector even when the committed document/history is long.
    for scenario in ["split","normal","field","body","selection","source","expired","boundary","not_ready"] {
        let b=SourceSwitchBarrier();var clock=ProcessInfo.processInfo.systemUptime,selected=ko,ready=true
        var replay=MismatchReplayLedger(before:context+"뒤",caret:context.utf16.count)
        replay.append(source:ko,keys:codes.map{($0,false)})
        let fixed=context+repeated+"그럼이"
        var text=replay.text,range=replay.selection
        b.now={clock};b.source={selected};b.ready={ready};b.readFocus={field}
        b.read={.init(field:field,text:text,selection:range)}
        b.send={_ in check(false,"long detection never posts")};b.applySelection={_,_ in check(false,"long detection never writes");return false}
        b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:text,selection:range))
        b.observe(.keyDown,key(51));text=fixed+"ㄱ뒤";range.location=text.utf16.count-1
        b.observe(.keyDown,key(38))
        text=fixed+(scenario=="normal" ? "거":"ㄱㅓ")+"뒤";range.location=text.utf16.count-1
        if scenario=="body" {text="옆"+String(text.dropFirst())}
        if scenario=="selection" {range.length=1}
        if scenario=="source" {selected=en}
        if scenario=="expired" {clock+=6}
        if scenario=="not_ready" {ready=false}
        let snap=MismatchSnapshot(element:scenario=="field" ? other:field,text:text,selection:range)
        let result=b.verifiedTwoSetHistory(snap,after:scenario=="boundary" ? UInt64.max:0)
        if ["split","normal"].contains(scenario) {
            check(result?.plan.before==fixed+"뒤" && result?.plan.expected==fixed+"rj뒤" && result?.plan.codes.count==2,"long committed prefix stays outside short repair key interval")
            let engine=MismatchRecoveryEngine(detectionOnly:true)
            engine.enabled=true;engine.locked=field;engine.testSource={selected};engine.testSnapshot={snap}
            engine.verifiedDeliveryHistory={s,prior in b.verifiedTwoSetHistory(s,after:0,allowPrior:prior)}
            engine.testPost={_ in check(false,"long detection-only engine never posts")}
            engine.sample(synchronous:true)
            check(engine.detectionCount==(scenario=="split" ? 1:0),"long history detects only actual detached jamo")
        } else {check(result==nil,"long repair handoff rejects \(scenario)")}
        b.fail("test_cleanup")
    }
    // Canonical equality is intentional, including at an insertion boundary.
    // Different actual UTF-16 caret lengths must still fail full matching.
    for before in ["e", "\u{1100}", "🙂 e\u{0301} ", context] {
        let b=SourceSwitchBarrier()
        var replay=MismatchReplayLedger(before:before,caret:before.utf16.count)
        replay.append(source:ko,keys:[(15,false),(40,false)])
        b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:replay.text,selection:replay.selection))
        let decomposed=replay.text.decomposedStringWithCanonicalMapping
        let snap=SourceSwitchBarrier.Snapshot(field:field,text:decomposed,selection:NSRange(location:decomposed.utf16.count,length:0))
        check(b.matchesText(snap),"canonical NFD remains an exact text match")
        check(!b.matches(snap),"canonical equivalence does not bypass UTF-16 caret agreement")
        b.fail("test_cleanup")
    }
    // AX strings may retain malformed UTF-16 in foreign storage. Distinct
    // unpaired surrogates have the same repaired Swift string value. NFC-only
    // NSString comparison must not replace that existing acceptance rule.
    let raw:[[UInt16]]=[[0xd800],[0xdc00],[0xfffd],[0x61,0xd800],[0x61,0xfffd],[0xd800,0xd800],[0xd800,0xdc00],[0xfffd,0xfffd],[0xdc00,0x301],[0xfffd,0x301],[0x65,0x301],[0xe9]]
    for prefix in ["",String(repeating:"한",count:300)] {for a in raw {for c in raw {
        let leftUnits=Array(prefix.utf16)+a,rightUnits=Array(prefix.utf16)+c
        let left=leftUnits.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String}
        let right=rightUnits.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String}
        let b=SourceSwitchBarrier(),replay=MismatchReplayLedger(before:left,caret:left.utf16.count)
        b.adoptVerifiedReplay(replay,snapshot:.init(element:field,text:left,selection:replay.selection))
        let snap=SourceSwitchBarrier.Snapshot(field:field,text:right,selection:NSRange(location:right.utf16.count,length:0))
        check(b.matchesText(snap)==(left==right),"foreign UTF-16 retains original canonical equality")
        check(b.matches(snap)==(left==right && left.utf16.count==right.utf16.count),"foreign UTF-16 retains original caret guard")
        b.fail("test_cleanup")
    }}}
}
