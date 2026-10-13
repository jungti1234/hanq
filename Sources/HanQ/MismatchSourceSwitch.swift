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
    mutating func append(source:String,keys:[(UInt16,Bool)]) {
        guard !keys.isEmpty else{return}
        if segments.last?.source==source{segments[segments.count-1].keys+=keys}
        else{segments.append((source,keys))}
    }
    static func render(_ segment:(source:String,keys:[(UInt16,Bool)]))->String {
        let roman=segment.keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        guard MismatchKeyboardLayout.supports(segment.source) else{return roman}
        return MismatchKeyboardLayout.render(keys:segment.keys,sourceID:segment.source) ?? roman
    }
    var insertion:String{segments.map{Self.render($0)}.joined()}
    var text:String{(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:insertion)}
    var selection:NSRange{NSRange(location:caret+insertion.utf16.count,length:0)}
}
