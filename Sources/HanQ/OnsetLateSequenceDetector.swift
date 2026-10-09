import Foundation

// Reconstruct only a bounded, fully observed two-set key sequence. A candidate
// requires the entire baseline, inserted text, caret and physical key history.
enum OnsetLateSequenceDetector {
    enum Result { case waiting, complete, rejected, candidate(OnsetRecoveryPlan) }
    static func inspect(keys:[(UInt16,Bool)],before:String,caret:Int,text:String,selection:NSRange)->Result {
        guard (2...16).contains(keys.count),caret>=0,caret<=before.utf16.count,selection.length==0,
              let layout=KoreanKeyboardLayout.load(sourceID:KoreanKeyboardLayout.twoSetID) else{return .rejected}
        var jamo=""
        for (code,shift) in keys {
            if code==49 {guard !shift else{return .rejected};jamo.append(" ");continue}
            guard let ascii=PhysicalLetterKeys.letters[code],let char=layout.keys[Character(shift ? ascii.uppercased():ascii)] else{return .rejected}
            jamo.append(char)
        }
        let chars=Array(jamo)
        guard "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".contains(chars[0]),
              "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ".contains(chars[1]) else{return .rejected}
        func view(_ value:String)->Bool {
            text==(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:value)
            && selection==NSRange(location:caret+value.utf16.count,length:0)
        }
        let split=String(chars[0])+JamoComposer.compose(String(chars.dropFirst()))
        let joined=JamoComposer.compose(jamo)
        if view(joined){return .complete}
        if view(split),split != joined {
            guard keys.last?.0==49,keys.last?.1==false else{return .waiting}
            return .candidate(OnsetRecoveryPlan(before:before,caret:caret,allowSingle:false,roman:split,codes:keys,onsetVariants:[],replayedText:joined))
        }
        if view(""){return .waiting}
        for length in 1..<chars.count {
            let prefix=Array(chars.prefix(length))
            if view(String(prefix[0])+JamoComposer.compose(String(prefix.dropFirst()))) {return .waiting}
        }
        return .rejected
    }
}
