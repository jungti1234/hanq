import Foundation

// Reconstruct only a bounded, fully observed selected-layout key sequence. A candidate
// requires the entire baseline, inserted text, caret and physical key history.
enum OnsetLateSequenceDetector {
    enum Result { case waiting, complete, rejected, candidate(OnsetRecoveryPlan) }
    enum Rejection:Int {case unmeasured=0,keyCount,selectionOrRange,layoutUnavailable,initialUnsupported,shiftedSpace,unmappedKey,missingMedial,bodyMismatch}
    static func inspect(keys:[(UInt16,Bool)],before:String,caret:Int,text:String,selection:NSRange,
                        sourceID:String=KoreanKeyboardLayout.twoSetID,allowObservedReplay:Bool=false,
                        romanBaseline:(text:String,caret:Int)?=nil,
                        onSpan:((InputIncidentTrace.InsertedSpan)->Void)?=nil,
                        onRejected:((Rejection)->Void)?=nil)->Result {
        func reject(_ reason:Rejection)->Result{onRejected?(reason);return .rejected}
        guard (2...16).contains(keys.count) else{return reject(.keyCount)}
        guard caret>=0,caret<=before.utf16.count,selection.length==0 else{return reject(.selectionOrRange)}
        guard let layout=KoreanKeyboardLayout.load(sourceID:sourceID),
              let initial=OnsetKeyboardLayout.load(sourceID:sourceID) else{return reject(.layoutUnavailable)}
        guard !initial.variants(code:keys[0].0,shift:keys[0].1).isEmpty else{return reject(.initialUnsupported)}
        var chars:[Character]=[]
        for (code,shift) in keys {
            if code==49 {guard !shift else{return reject(.shiftedSpace)};chars.append(" ");continue}
            guard PhysicalLetterKeys.printableCodes.contains(code) else{return reject(.unmappedKey)}
            let char:Character?
            if layout.physicalKeys.isEmpty {
                char=PhysicalLetterKeys.letters[code].flatMap{layout.keys[Character(shift ? $0.uppercased():$0)]}
            }else{char=(shift ? layout.shiftedPhysicalKeys:layout.physicalKeys)[code]}
            guard let char else{return reject(.unmappedKey)};chars.append(char)
        }
        func medial(_ char:Character)->Bool {
            guard let scalar=char.unicodeScalars.first else{return false}
            return "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ".contains(char) || (0x1161...0x1175).contains(scalar.value)
        }
        // Three-set doubles an initial by repeating its key before the medial.
        // Final-only keys and runs without a medial never start a repair.
        guard medial(chars[1]) || (layout.kind == .threeSet && chars.count>=3 && chars[1]==chars[0] && medial(chars[2])) else{return reject(.missingMedial)}
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
        // This option requires a pre-key editor baseline. A disappearing
        // display and a matching word alone cannot prove who inserted it.
        if romanBaseline != nil{onSpan?(.anchorOrRangeInvalid)}
        if let anchor=romanBaseline,sourceID==KoreanKeyboardLayout.twoSetID,
           !keys.contains(where:{$0.0==49}),anchor.caret>=0,anchor.caret<=anchor.text.utf16.count,
           selection.location>anchor.caret,selection.location<=text.utf16.count {
            let body=text as NSString
            let range=NSRange(location:anchor.caret,length:selection.location-anchor.caret)
            let inserted=body.substring(with:range)
            if inserted.utf8.first.map({(65...90).contains($0) || (97...122).contains($0)}) != true {onSpan?(.notRomanFirst)}
            else if !body.replacingCharacters(in:range,with:"").utf16.elementsEqual(anchor.text.utf16){onSpan?(.surroundingsChanged)}
            else {
                onSpan?(.keysDiffer)
                var roman=""
                var pending=false
                for (index,key) in keys.enumerated() {
                    guard let letter=PhysicalLetterKeys.letters[key.0] else{break}
                    roman += key.1 ? letter.uppercased():letter
                    guard inserted.hasPrefix(roman) else{break}
                    for end in (index+1)...keys.count {
                        let candidate=roman+render(chars[(index+1)..<end])
                        guard inserted.utf16.elementsEqual(candidate.utf16) else{continue}
                        if end==keys.count {
                            onSpan?(.matched)
                            return .candidate(OnsetRecoveryPlan(before:anchor.text,caret:anchor.caret,roman:inserted,codes:keys,observedReplayText:joined,literalBody:true))
                        }
                        pending=true
                    }
                }
                if pending{onSpan?(.partial);return .waiting}
            }
        }
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
        return reject(.bodyMismatch)
    }
}
