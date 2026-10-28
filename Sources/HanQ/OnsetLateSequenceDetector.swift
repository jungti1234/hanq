import Foundation

// Reconstruct only a bounded, fully observed selected-layout key sequence. A candidate
// requires the entire baseline, inserted text, caret and physical key history.
enum OnsetLateSequenceDetector {
    enum Result { case waiting, complete, rejected, candidate(OnsetRecoveryPlan) }
    static func inspect(keys:[(UInt16,Bool)],before:String,caret:Int,text:String,selection:NSRange,
                        sourceID:String=KoreanKeyboardLayout.twoSetID,allowObservedReplay:Bool=false)->Result {
        guard (2...16).contains(keys.count),caret>=0,caret<=before.utf16.count,selection.length==0,
              let layout=KoreanKeyboardLayout.load(sourceID:sourceID),
              let initial=OnsetKeyboardLayout.load(sourceID:sourceID),
              !initial.variants(code:keys[0].0,shift:keys[0].1).isEmpty else{return .rejected}
        var chars:[Character]=[]
        for (code,shift) in keys {
            if code==49 {guard !shift else{return .rejected};chars.append(" ");continue}
            guard PhysicalLetterKeys.printableCodes.contains(code) else{return .rejected}
            let char:Character?
            if layout.physicalKeys.isEmpty {
                char=PhysicalLetterKeys.letters[code].flatMap{layout.keys[Character(shift ? $0.uppercased():$0)]}
            }else{char=(shift ? layout.shiftedPhysicalKeys:layout.physicalKeys)[code]}
            guard let char else{return .rejected};chars.append(char)
        }
        func medial(_ char:Character)->Bool {
            guard let scalar=char.unicodeScalars.first else{return false}
            return "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ".contains(char) || (0x1161...0x1175).contains(scalar.value)
        }
        // Three-set doubles an initial by repeating its key before the medial.
        // Final-only keys and runs without a medial never start a repair.
        guard medial(chars[1]) || (layout.kind == .threeSet && chars.count>=3 && chars[1]==chars[0] && medial(chars[2])) else{return .rejected}
        func render(_ chars:ArraySlice<Character>)->String {
            let raw=String(chars)
            switch layout.kind {
            case .twoSet:return JamoComposer.compose(raw,combineStandalone:true)
            case .threeSet:return JamoComposer.composeNativeThreeSet(raw)
            case .gongjinRoman,.hncRoman:return JamoComposer.composeRomanized(raw,kind:layout.kind)
            }
        }
        func view(_ value:String)->Bool {
            selection==NSRange(location:caret+value.utf16.count,length:0)
            && InputFocusAccess.sameText(text,(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:value))
        }
        let split=render(chars.prefix(1))+render(chars.dropFirst())
        let joined=render(chars[...])
        if view(joined){return .complete}
        if view(split),split != joined {
            // Only the caller with an independently observed pre-key baseline
            // may request this IME replay. Normal composition is already complete.
            if allowObservedReplay,caret==before.utf16.count {
                return .candidate(OnsetRecoveryPlan(before:before,caret:caret,allowSingle:false,roman:split,codes:keys,onsetVariants:[],observedReplayText:joined))
            }
            guard keys.last?.0==49,keys.last?.1==false else{return .waiting}
            return .candidate(OnsetRecoveryPlan(before:before,caret:caret,allowSingle:false,roman:split,codes:keys,onsetVariants:[],replayedText:joined))
        }
        if view(""){return .waiting}
        for length in 1..<chars.count {
            let prefix=Array(chars.prefix(length))
            if view(render(prefix.prefix(1))+render(prefix.dropFirst())) {return .waiting}
        }
        return .rejected
    }
}
