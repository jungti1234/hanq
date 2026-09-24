import Foundation

struct OnsetRecoveryDetector {
    var layout:OnsetKeyboardLayout = .twoSet
    struct First { let code:UInt16; let shift:Bool; let time:Double; var entered:Double? }
    var first:First?
    mutating func outsideKey(code:UInt16,shift:Bool,time:Double,korean:Bool,plain:Bool) {
        first=nil
        guard korean,plain,!layout.variants(code:code,shift:shift).isEmpty else{return}
        first=First(code:code,shift:shift,time:time,entered:nil)
    }
    mutating func entered(time:Double) {
        guard var f=first,f.entered==nil else{return}
        guard time-f.time>=0,time-f.time<=0.35 else{first=nil;return}
        if f.entered==nil{f.entered=time;first=f}
    }
    mutating func firstConsonant(time:Double,text:String,selection:NSRange,previousText:String?=nil)->OnsetRecoveryPlan? {
        guard let f=first,let entry=f.entered,time>=entry,time-f.time<=0.35,
              selection.length==0,selection.location>=1,selection.location<=text.utf16.count else{return nil}
        let ns=text as NSString
        let position=selection.location-1
        let c=ns.substring(with:NSRange(location:position,length:1))
        let variants=layout.variants(code:f.code,shift:f.shift)
        guard variants.contains(c) else{return nil}
        let before=ns.replacingCharacters(in:NSRange(location:position,length:1),with:"")
        // Existing content requires an observed baseline; never guess which old jamo is new.
        guard before == (previousText ?? "") else{return nil}
        first=nil
        return OnsetRecoveryPlan(before:before,caret:position,allowSingle:true,roman:c,codes:[(f.code,f.shift)],onsetVariants:variants)
    }
    mutating func cancel(){first=nil}
}
