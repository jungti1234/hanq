import AppKit

// A witnessed replacement of a prior representation is not a claim that the
// prior document was empty. It authorizes only later exact whole-body matching.
struct OnsetFirstPublication {
    let first:OnsetInputGate.Reservation
    let field:AXUIElement
    let isCurrent:()->Bool
    func matches(_ passed:OnsetInputGate.PassedInput,_ snap:OnsetSnapshot)->Bool {
        first.time==passed.first.time && first.sourceID==passed.first.sourceID
            && first.code==passed.first.code && first.shift==passed.first.shift
            && CFEqual(field,snap.element) && passed.keys.count>=2 && isCurrent()
    }
}

extension OnsetRecoveryEngine {
    /// True means the exact first-character prefix is still being published.
    /// The caller must retain observation instead of rejecting it against the
    /// prior displayed value. This grants no edit/replay proof.
    @discardableResult
    func observeFirstPublication(_ passed:OnsetInputGate.PassedInput,_ snap:OnsetSnapshot)->Bool {
        let first=passed.first
        guard firstPublication==nil,firstPublicationAttemptedTime != first.time,
              canBeginRepair(),currentSource()==first.sourceID,
              let previous=focusHandoff.representedEntry(for:snap.element,before:first.time) else{return false}
        // The provider may still be publishing the original display. Waiting
        // never holds a key, treats a label as empty, or writes to the editor.
        guard !InputFocusAccess.literalTextEqual(previous.text,snap.text) else{return false}
        let time=ProcessInfo.processInfo.systemUptime
        guard time>=first.time,time-first.time<0.15,
              (1...2).contains(passed.keys.count),
              passed.keys[0].0==first.code,passed.keys[0].1==first.shift,
              let layout=currentLayout() else{firstPublicationAttemptedTime=first.time;return false}
        let firstOnly=snap.text.utf16.count==1 && snap.selection==NSRange(location:1,length:0)
            && layout.variants(code:first.code,shift:first.shift).contains(snap.text)
        // AX can publish the first character after both original keys passed.
        // This exact prefix only permits observation within the original limit;
        // it neither creates a replay proof nor holds any following input.
        if passed.keys.count==2,firstOnly{return true}
        firstPublicationAttemptedTime=first.time
        if passed.keys.count==1 {
            guard firstOnly else{return false}
        }else{
            guard case .candidate(let proof)=OnsetLateSequenceDetector.inspect(keys:passed.keys,before:"",caret:0,
                text:snap.text,selection:snap.selection,sourceID:first.sourceID,allowObservedReplay:true),
                proof.isObservedReplay else{return false}
        }
        let observer=focusHandoff,field=snap.element
        firstPublication=OnsetFirstPublication(first:first,field:field,isCurrent:{
            observer.representedEntry(for:field,before:first.time) != nil
        })
        log("first_publication_observed")
        return false
    }
}
