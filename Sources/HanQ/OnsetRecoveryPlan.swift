import Foundation

// Pure detector: only a contiguous run created by observed physical letter keys.
struct OnsetRecoveryPlan {
    let before: String
    let caret: Int
    var allowSingle=false
    var roman = ""
    var codes: [(UInt16, Bool)] = []
    var onsetVariants:[String] = []
    static let keys: [UInt16:String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",31:"o",32:"u",34:"i",35:"p",37:"l",38:"j",40:"k",45:"n",46:"m"]
    mutating func append(code:UInt16,shift:Bool)->Bool {
        guard let key=Self.keys[code],codes.count<80 else{return false}
        roman += shift ? key.uppercased():key;codes.append((code,shift));return true
    }
    var expected:String? {
        let ns=before as NSString
        guard caret>=0,caret<=ns.length else{return nil}
        return ns.replacingCharacters(in:NSRange(location:caret,length:0),with:roman)
    }
    func matches(text:String,selection:NSRange)->Bool {
        (codes.count>=2 || (allowSingle && codes.count==1)) && text==expected && selection==NSRange(location:caret+roman.utf16.count,length:0)
    }
}
