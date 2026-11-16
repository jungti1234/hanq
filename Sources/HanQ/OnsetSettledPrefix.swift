import AppKit

// A separate late proof never authorizes the fast IME replay path. Capture only
// the exact first pair while its original pre-key representation is still valid.
extension OnsetRecoveryEngine {
    func observeSettledPrefixPublication(_ p:OnsetInputGate.PassedInput,_ snap:OnsetSnapshot) {
        guard prefixCandidateEnabled else{return}
        if settledPrefixPublication?.first.time != p.first.time {settledPrefixPublication=nil}
        guard settledPrefixPublication==nil,firstPublication==nil,
              ProcessInfo.processInfo.systemUptime-p.first.time>=OnsetFirstPublication.observationLimit,
              ProcessInfo.processInfo.systemUptime-p.first.time<2,p.first.sourceID==onsetKoreanID,p.keys.count==2,
              case .candidate(let pair)=OnsetLateSequenceDetector.inspect(keys:p.keys,before:"",caret:0,
                text:snap.text,selection:snap.selection,sourceID:p.first.sourceID,allowObservedReplay:true),
              pair.isObservedReplay,pair.roman.utf16.count==2 else{return}
        if let witness=focusHandoff.representationWitness(for:snap.element,before:p.first.time),
           !InputFocusAccess.literalTextEqual(witness.snapshot.text,snap.text),witness.isCurrent() {
            settledPrefixPublication=OnsetFirstPublication(first:p.first,field:snap.element,isCurrent:witness.isCurrent)
        }else if p.baselineRevision != nil,let baseline=passedBaseline,baseline.text.isEmpty,
                 baseline.selection==NSRange(location:0,length:0),CFEqual(baseline.element,snap.element) {
            // The baseline was published before the first event at the tail tap.
            // Exact history revision and focused-field checks remain mandatory.
            settledPrefixPublication=OnsetFirstPublication(first:p.first,field:snap.element,isCurrent:{true})
        }
    }
    func sampleSettledPrefix(_ p:OnsetInputGate.PassedInput,_ snap:OnsetSnapshot)->Bool {
        guard prefixCandidateEnabled,settledPrefixPublication?.matches(p,snap)==true else{return false}
        // Empty marked ranges and elapsed idle time do not prove Korean commit.
        // Wait for the user's actual terminal Space and the exact complete body.
        guard p.keys.last?.0==49 else{return true}
        guard p.pressed.isEmpty else{return true}
        guard let plan=Self.settledPrefixPlan(keys:p.keys,text:snap.text,selection:snap.selection,sourceID:p.first.sourceID) else{return false}
        return prefixCoordinator.begin(plan,snap,passed:p)
    }
    static func settledPrefixPlan(keys:[(UInt16,Bool)],text:String,selection:NSRange,sourceID:String)->OnsetRecoveryPlan? {
        guard sourceID==onsetKoreanID,(4...16).contains(keys.count),keys.last?.0==49,keys.last?.1==false,
              !keys.dropLast().contains(where:{$0.0==49}),
              case .candidate(let full)=OnsetLateSequenceDetector.inspect(keys:keys,before:"",caret:0,text:text,
                selection:selection,sourceID:sourceID,allowObservedReplay:false),
              let joined=full.replayedText else{return nil}
        let ns=text as NSString
        guard ns.length>2 else{return nil}
        let pair=ns.substring(to:2),suffix=ns.substring(from:2)
        let replacement=JamoComposer.compose(pair,combineStandalone:true)
        guard replacement.utf16.count==1,let scalar=replacement.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value),
              (replacement+suffix).utf16.elementsEqual(joined.utf16) else{return nil}
        return OnsetRecoveryPlan(before:suffix,caret:0,roman:pair,codes:keys,replayedText:replacement,
            literalBody:true,prefixOriginalCaret:selection.location)
    }
    func restoreSettledPrefixCaret(_ snap:OnsetSnapshot) {
        guard let plan=currentPlan,plan.isSettledPrefix,let replacement=plan.replayedText,
              let live=snapshot(),CFEqual(live.element,snap.element),live.compositionEnded,
              currentSource()==repairSourceID,
              live.text.utf16.elementsEqual((replacement+plan.before).utf16),live.selection==snap.selection else{
            park("prefix_caret_context_changed");return
        }
        prefixCaretRestoring=true;committedCaretObservedAt=nil
        committedCaretRestoreDeadline=ProcessInfo.processInfo.systemUptime+0.12
        guard setRange(live.element,NSRange(location:plan.restoredCaret,length:0)) == .success else{
            park("prefix_caret_restore_failed");return
        }
        verifySettledPrefixCaret()
    }
    func verifySettledPrefixCaret() {
        guard recovering,prefixCaretRestoring,let plan=currentPlan,let field=planElement,
              let replacement=plan.replayedText else{return}
        guard gate?.healthy() ?? true,currentSource()==repairSourceID,
              let live=snapshot(),CFEqual(live.element,field),live.compositionEnded,
              live.text.utf16.elementsEqual((replacement+plan.before).utf16) else{
            park("prefix_caret_context_changed");return
        }
        let now=ProcessInfo.processInfo.systemUptime
        if live.selection==NSRange(location:plan.restoredCaret,length:0) {
            if let time=committedCaretObservedAt,now-time>=0.02 {
                prefixCaretRestoring=false;finishCommittedReplacement(live);return
            }
            if committedCaretObservedAt==nil {committedCaretObservedAt=now}
        }else{
            committedCaretObservedAt=nil
            guard live.selection==NSRange(location:plan.caret+replacement.utf16.count,length:0) else{
                park("prefix_caret_changed");return
            }
        }
        guard now<committedCaretRestoreDeadline else{park("prefix_caret_timeout");return}
        scheduleRecovery(0.002){[weak self] in self?.verifySettledPrefixCaret()}
    }
}
