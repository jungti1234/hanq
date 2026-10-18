import AppKit

// Main-thread observation/intent only. A stale display never authorizes an
// edit: deferred keys require a fresh independent Korean observation first.
final class MismatchSourceEvidence {
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    private(set) var confirmedID:String?
    private(set) var confirmedAt:Double?
    private(set) var targetID:String?
    private(set) var targetAt:Double?
    private(set) var targetTimestamp:UInt64=0
    private(set) var committed=false
    private(set) var epoch=0
    private var began:Double?
    private var validatedEpoch:Int?
    private var blocked=false
    static let preservationSeconds=0.3
    static let confirmationSeconds=0.5

    func interrupt() {
        epoch+=1;began=nil;validatedEpoch=nil;blocked=true;committed=false
    }
    func observeInteraction(_ type:CGEventType,_ event:CGEvent) {
        let code=event.getIntegerValueField(.keyboardEventKeycode)
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type) ||
            (type == .flagsChanged && code==57) ||
            (type == .keyDown && (!event.flags.intersection([.maskCommand,.maskControl,.maskAlternate]).isEmpty || MismatchRecoveryPlan.character(UInt16(clamping:code),event.flags.contains(.maskShift))==nil)) {
            interrupt()
        }
    }
    func request(_ id:String,at timestamp:UInt64) {
        epoch+=1;began=nil;validatedEpoch=nil;blocked=false
        targetID=id;targetAt=now();targetTimestamp=timestamp;committed=false
    }
    func didCommit(_ id:String,at timestamp:UInt64) {
        if targetID != id {request(id,at:timestamp)}
        committed=true
    }
    @discardableResult func observe(_ id:String)->Bool {
        let changed=confirmedID != id
        if changed {
            epoch+=1;began=nil;validatedEpoch=nil;blocked=false
            // A separately confirmed external source ends the old request's
            // authority. Returning to Korean alone cannot recommit that request.
            if id != targetID{committed=false}
        }
        confirmedID=id;confirmedAt=now()
        if let start=began,now()-start<=Self.preservationSeconds,id==mismatchKoreanID {
            validatedEpoch=epoch;began=nil;return true
        }
        return changed
    }
    // Returns an attribution for a short, uneditable quarantine, never a
    // replacement for the selected source used by repair safety checks.
    func deferredSource(for selected:String)->String? {
        if let start=began {
            guard now()>=start,now()-start<=Self.preservationSeconds,
                  confirmedID==mismatchKoreanID,
                  selected==mismatchKoreanID || selected.hasPrefix("com.apple.keylayout.") else {
                epoch+=1;began=nil;validatedEpoch=nil;blocked=true;return nil
            }
            return mismatchKoreanID
        }
        guard !blocked,selected.hasPrefix("com.apple.keylayout."),
              confirmedID==mismatchKoreanID,let at=confirmedAt,
              now()>=at,now()-at<=Self.confirmationSeconds,
              targetID==mismatchKoreanID,committed else{return nil}
        began=now();validatedEpoch=nil
        return mismatchKoreanID
    }
    func retains(_ saved:Int)->Bool {
        guard saved==epoch else{return false}
        if let start=began{return now()>=start && now()-start<=Self.preservationSeconds}
        return validatedEpoch==saved
    }
    func permitsHistory(_ saved:Int)->Bool {saved==epoch && validatedEpoch==saved && began==nil}
    func diagnostic(selected:String,candidate:Bool=false,history:Bool=false)->InputIncidentTrace.SourceEvidence {
        func kind(_ id:String?)->Int {
            guard let id else{return 0}
            if let i=KoreanKeyboardLayout.supportedIDs.firstIndex(of:id){return i+1}
            return id.hasPrefix("com.apple.keylayout.") ? 6:(id=="unknown" ? 0:7)
        }
        func millis(_ value:Double?)->Int?{value.map{Int(max(0,min($0*1000,9_000_000_000_000_000)))}}
        func age(_ value:Double?)->Int?{value.map{Int(max(0,min((now()-$0)*1_000_000,60_000_000)))}}
        return .init(selected:kind(selected),confirmed:kind(confirmedID),target:kind(targetID),observedAtMilliseconds:millis(now())!,targetEventMilliseconds:targetTimestamp>0 ? Int(targetTimestamp/1_000_000):nil,ageClipped:[confirmedAt,targetAt].contains{$0.map{now()-$0>60} ?? false},confirmedAtMilliseconds:millis(confirmedAt),targetAtMilliseconds:millis(targetAt),confirmedAgeMicros:age(confirmedAt),targetAgeMicros:age(targetAt),committed:committed,deferred:began != nil,candidatePreserved:candidate,historyPreserved:history)
    }
}
