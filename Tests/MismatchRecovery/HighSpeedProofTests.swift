import Foundation

func runHighSpeedProofTests(){
    var checks=0
    func check(_ condition:Bool,_ message:String){checks+=1;probeTestCheck(condition,message)}
    let before="앞🙂e\u{301} "+String(repeating:"한",count:1000)+" 뒤"
    let caret=(before as NSString).length-2
    func plan(_ keys:[(UInt16,Bool)])->MismatchRecoveryPlan {
        var result=MismatchRecoveryPlan(before:before,caret:caret)
        for key in keys{check(result.append(code:key.0,shift:key.1),"known physical key appended")}
        return result
    }
    for shift in [false,true] {
        let p=plan([(15,shift),(40,false),(1,false),(40,true),(41,false),(50,false)])
        let syllable=shift ? "깐":"간"
        let variants=[syllable+"K;`",syllable+"K\u{37e}\u{1fef}",(syllable+"K;`").decomposedStringWithCanonicalMapping]
        for inserted in variants {
            let text=(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:inserted)
            let selection=NSRange(location:caret+inserted.utf16.count,length:0)
            let recovered=p.interruptedCompositionPlan(text:text,selection:selection)
            check(recovered?.verifiedReplacement?.utf16.elementsEqual(inserted.utf16)==true,"complete interrupted proof preserves canonical Roman aliases and original UTF16")
            check(p.partialFailurePlan(text:text,selection:selection) != nil,"same full failure remains detectable")
        }
    }
    let group:[(UInt16,Bool)]=[(15,false),(40,false),(1,false),(49,false)]
    let keys:[(UInt16,Bool)]=Array(repeating:group,count:16).flatMap{$0}
    let p=plan(keys)
    for count in [1,2,3,4,8,16,32,48,63,64] {
        let inserted=MismatchKeyboardLayout.render(keys:Array(keys.prefix(count)),sourceID:p.sourceID)!
        let text=(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:inserted)
        let selection=NSRange(location:caret+inserted.utf16.count,length:0)
        check(p.observedTwoSetPrefix(text:text,selection:selection),"lagging normal prefix is retained")
        check(p.partialFailurePlan(text:text,selection:selection)==nil,"missing future components never trigger a complete failure repair")
        check(!p.observedTwoSetPrefix(text:"X"+String(text.dropFirst()),selection:selection),"changed surrounding document is rejected")
        check(!p.observedTwoSetPrefix(text:text,selection:NSRange(location:selection.location,length:1)),"changed selection is rejected")
    }
    var samples=["","a","A","a b","a\u{a0}b","é","e\u{301}","Å","Å","K","K","\0","🙂","\u{fffd}"]
    for units:[UInt16] in [[0xd800],[0xd801],[0xdc00],[0xdc01],[0xd800,0xdc00],[0xd800,0xdc01]] {
        samples.append(units.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String})
    }
    for a in samples {for b in samples {
        let left=String(repeating:"한",count:300)+a,right=String(repeating:"한",count:300)+b
        let x=Array(left.utf16),y=Array(right.utf16)
        let unitsMatch=zip(x,y).allSatisfy{pair in
            let l=pair.0,r=pair.1
            return l==r || (l==32 && r==160) || (l==160 && r==32)
        }
        let expected=x.count==y.count && unitsMatch
        check(MismatchRecoveryPlan.sameEditorText(left,right)==expected,"strict UTF16/space comparison retains original error-corrected view contract")
        check(!InputFocusAccess.literalTextEqual(left,right) || left==right,"literal proof is sufficient for canonical equality")
    }}
    let rawSamples:[[UInt16]]=[[],[32],[160],[65],[0xfffd],[0xd800],[0xdbff],[0xdc00],[0xdfff],
        [0xd800,0xdc00],[0xdbff,0xdfff],[0xd800,65],[0xfffd,65],[65,0xdc00],[65,0xfffd],
        [0xd800,0xfffd],[0xfffd,0xfffd],[0xdc00,0xd800]]
    for count in [0,126,127,128,255,256] {for a in rawSamples {for b in rawSamples {
        func text(_ suffix:[UInt16])->String {
            let units=[UInt16](repeating:0xac00,count:count)+suffix+[66]
            return units.withUnsafeBufferPointer{NSString(characters:$0.baseAddress!,length:$0.count) as String}
        }
        let left=text(a),right=text(b),x=Array(left.utf16),y=Array(right.utf16)
        let same=zip(x,y).allSatisfy{pair in
            pair.0==pair.1 || (pair.0==32 && pair.1==160) || (pair.0==160 && pair.1==32)
        }
        check(MismatchRecoveryPlan.sameEditorText(left,right)==(x.count==y.count && same),
              "equal blocks retain surrogate context and exact old SPACE/NBSP contract")
    }}}
    print("PASS \(checks) high-speed delayed-prefix, full-body/selection, canonical-alias and strict UTF16 checks; no OS keys")
}
