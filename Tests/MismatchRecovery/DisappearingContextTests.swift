import Foundation

func runDisappearingContextTests(){
    let before="앞🙂기존 본문",end=before.utf16.count
    func candidate(_ codes:[UInt16])->MismatchRecoveryPlan{
        var p=MismatchRecoveryPlan(before:before,caret:end)
        for c in codes{probeTestCheck(p.append(code:c,shift:false))}
        return p
    }
    for (keys,surface,next) in [([UInt16(15),40],"rk",UInt16(1)),([15,46],"rm",UInt16(0)),([15,46],"rㅡ",UInt16(0)),([1,40],"sk",UInt16(1))] {
        let p=candidate(keys)
        let retained=MismatchRecoveryPlan.next(previous:p,text:surface,selection:NSRange(location:surface.utf16.count,length:0),code:next,shift:false)!
        probeTestCheck(retained.codes.count==keys.count+1 && retained.before==before && retained.caret==end,"lost prefix never becomes a draft baseline")
        let extra=MismatchRecoveryPlan.character(next,false)!
        for after in [surface+extra,surface+(MismatchKeyboardLayout.render(keys:[(next,false)],sourceID:retained.sourceID) ?? "")]{
            let caret=NSRange(location:after.utf16.count,length:0)
            probeTestCheck(!retained.matches(text:after,selection:caret) && retained.partialFailurePlan(text:after,selection:caret)==nil,"no suffix-only edit with ambiguous draft")
        }
        let full=before+retained.roman
        probeTestCheck(retained.matches(text:full,selection:NSRange(location:full.utf16.count,length:0)),"when surrounding text reappears all keys are eligible")
    }
    let p=candidate([15,40])
    let fresh=MismatchRecoveryPlan.next(previous:p,text:"older rk",selection:NSRange(location:8,length:0),code:0,shift:false)!
    probeTestCheck(fresh.before=="older rk" && fresh.codes.count==1,"different surrounding body starts genuine new run")
    let selected=MismatchRecoveryPlan.next(previous:p,text:"rk",selection:NSRange(location:0,length:2),code:0,shift:false)!
    probeTestCheck(selected.before.isEmpty && selected.codes.count==1,"explicit selection remains the new insertion boundary")
    print("PASS: complete wrong prefix retained without edit on lost surroundings; full recovery eligible on return")
}
