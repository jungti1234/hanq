import Foundation

// Pure detector: only a contiguous run created by observed physical letter keys.
struct OnsetRecoveryPlan {
    let before: String
    let caret: Int
    var allowSingle=false
    var roman = ""
    var codes: [(UInt16, Bool)] = []
    var onsetVariants:[String] = []
    var expected:String? {
        let ns=before as NSString
        guard caret>=0,caret<=ns.length else{return nil}
        return ns.replacingCharacters(in:NSRange(location:caret,length:0),with:roman)
    }
    func matches(text:String,selection:NSRange)->Bool {
        (codes.count>=2 || (allowSingle && codes.count==1)) && text==expected && selection==NSRange(location:caret+roman.utf16.count,length:0)
    }
}
