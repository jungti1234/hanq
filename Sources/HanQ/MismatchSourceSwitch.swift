import AppKit
import Carbon

// Select an explicit source. No keyboard synthesis or shortcut preferences.
final class MismatchSourceSwitch {
    var busy=false
    private(set) var observed=""
    private var expected:String?
    private var expectedUntil=0.0
    var now:()->Double = {ProcessInfo.processInfo.systemUptime}
    var didSelect:(String,OSStatus)->Void = {_,_ in}
    func reset(_ source:String){observed=source;expected=nil;busy=false}
    func cancel(){expected=nil;busy=false}
    var unsettled:Bool {expected != nil && now()<expectedUntil}
    /// Returns true only for a source change not owned by this selector.
    func observe(_ source:String)->Bool {
        guard source != observed else{return false}
        observed=source
        if source==expected,(busy || now()<expectedUntil){expected=nil;return false}
        return true
    }
    func request(_ target:String,valid:()->Bool,current:()->String,
                 select:(String)->OSStatus=InputSourceAccess.select)->OSStatus {
        guard !busy,!target.isEmpty,valid() else{return -50}
        busy=true;expected=target;expectedUntil=now()+0.5
        let result=select(target)
        busy=false
        if result != noErr{expected=nil;didSelect(target,result);return result}
        let actual=current();observed=actual
        if actual==target{expected=nil}
        didSelect(target,result)
        return result
    }
}

// A replay ledger models composition across batches, but commits a segment at
// every source boundary. Key-up events never create a boundary or a character.
struct MismatchReplayLedger {
    static func modelShift(code:UInt16,flags:CGEventFlags,source:String)->Bool {
        let shift=flags.contains(.maskShift)
        guard !MismatchKeyboardLayout.supports(source),PhysicalLetterKeys.letters[code] != nil else{return shift}
        return shift || flags.contains(.maskAlphaShift)
    }
    let before:String
    let caret:Int
    var segments:[(source:String,keys:[(UInt16,Bool)])]=[]
    // A verified post-backspace body does not prove its IME marked range.
    // Retain the possible commit boundary until actual subsequent text proves it.
    var postDeletionPrefixCount:Int?
    mutating func append(source:String,keys:[(UInt16,Bool)]) {
        guard !keys.isEmpty else{return}
        if segments.last?.source==source{segments[segments.count-1].keys+=keys}
        else{segments.append((source,keys));postDeletionPrefixCount=nil}
    }
    func committingDeletionPrefix()->MismatchReplayLedger? {
        guard let count=postDeletionPrefixCount,let last=segments.last,
              last.source==KoreanKeyboardLayout.twoSetID,count>0,count<last.keys.count,
              let onset=MismatchKeyboardLayout.output(code:last.keys[count].0,shift:last.keys[count].1,sourceID:last.source),
              onset.unicodeScalars.count==1,let scalar=onset.unicodeScalars.first,
              (0x3131...0x314e).contains(scalar.value) else{return nil}
        var result=self
        result.segments.removeLast()
        result.segments.append((source:last.source,keys:Array(last.keys.prefix(count))))
        result.segments.append((source:last.source,keys:Array(last.keys.dropFirst(count))))
        result.postDeletionPrefixCount=nil
        return result
    }
    static func render(_ segment:(source:String,keys:[(UInt16,Bool)]))->String {
        let roman=segment.keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        guard MismatchKeyboardLayout.supports(segment.source) else{return roman}
        return MismatchKeyboardLayout.render(keys:segment.keys,sourceID:segment.source) ?? roman
    }
    var insertion:String{segments.map{Self.render($0)}.joined()}
    var text:String{(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:insertion)}
    var selection:NSRange{NSRange(location:caret+insertion.utf16.count,length:0)}
    // Prove the entire latest Korean interval, including keys whose first
    // consonant was already acknowledged before the buffered batch arrived.
    func lastTwoSetPlan()->MismatchRecoveryPlan? {
        guard let segment=segments.last,segment.source==KoreanKeyboardLayout.twoSetID,
              caret>=0,caret<=before.utf16.count else{return nil}
        let committed=segments.dropLast().map{Self.render($0)}.joined()
        let base=(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:committed)
        var candidate=MismatchRecoveryPlan(before:base,caret:caret+committed.utf16.count,sourceID:segment.source)
        candidate.codes=segment.keys
        guard !candidate.codes.isEmpty,candidate.codes.count<=64 else{return nil}
        candidate.roman=candidate.replayRoman
        return candidate
    }
    func decomposedPlan(text:String,selection:NSRange)->MismatchRecoveryPlan? {
        lastTwoSetPlan()?.decomposedPlan(text:text,selection:selection)
    }
    func interruptedCompositionPlan(text:String,selection:NSRange)->MismatchRecoveryPlan? {
        lastTwoSetPlan()?.interruptedCompositionPlan(text:text,selection:selection)
    }
}
