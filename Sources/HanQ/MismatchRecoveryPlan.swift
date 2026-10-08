import Foundation

// Track observed printable keys across digits/punctuation, including delayed AX batches.
struct MismatchRecoveryPlan {
    var before: String
    let caret: Int
    var sourceID = KoreanKeyboardLayout.twoSetID
    var roman = ""
    // Only an exact rendering of the observed keys may set a mixed replacement.
    var verifiedReplacement:String?
    // An unchanged autocomplete selection may remain visible while newer
    // physical keys are already queued. Preserve those keys without treating
    // a new or changed selection as the same completion transaction.
    var pendingCompletion:(text:String,selection:NSRange)?
    var codes: [(UInt16, Bool)] = []
    static let punctuation: [UInt16:(String,String)] = [18:("1","!"),19:("2","@"),20:("3","#"),21:("4","$"),23:("5","%"),22:("6","^"),26:("7","&"),28:("8","*"),25:("9","("),29:("0",")"),27:("-","_"),24:("=","+"),33:("[","{"),30:("]","}"),42:("\\","|"),41:(";",":"),39:("'","\""),43:(",","<"),47:(".",">"),44:("/","?"),50:("`","~"),49:(" "," ")]
    static func character(_ code:UInt16,_ shift:Bool)->String? {
        if let key=PhysicalLetterKeys.letters[code]{return shift ? key.uppercased():key}
        guard let pair=punctuation[code] else{return nil}
        return shift ? pair.1:pair.0
    }
    // Comparison only: browser editors exchange U+0020/U+00A0 while typing.
    // Both occupy one UTF-16 unit; never collapse, trim, or rewrite document text.
    static func sameEditorText(_ actual:String,_ expected:String)->Bool {
        let a=Array(actual.utf16),b=Array(expected.utf16)
        guard a.count==b.count else{return false}
        for i in a.indices {
            if a[i]==b[i]{continue}
            if a[i]==32 && b[i]==160{continue}
            if a[i]==160 && b[i]==32{continue}
            return false
        }
        return true
    }
    // Some editors expose one terminal LF after the caret in an empty final
    // paragraph, then omit that AX-only suffix once typing starts. Accept only
    // this exact end boundary; never normalize interior newlines or move offsets.
    func sameObservedSurroundings(_ actual:String)->Bool {
        if Self.sameEditorText(actual,before){return true}
        let original=before as NSString
        guard caret==original.length-1,original.substring(from:caret)=="\n",
              actual.utf16.count==caret else{return false}
        return Self.sameEditorText(actual,original.substring(to:caret))
    }
    var hasLetters:Bool{codes.contains{MismatchKeyboardLayout.expectsHangul(code:$0.0,shift:$0.1,sourceID:sourceID)}}
    mutating func append(code:UInt16,shift:Bool)->Bool {
        guard let key=Self.character(code,shift),codes.count<256 else{return false}
        roman += key;codes.append((code,shift));return true
    }
    // AX may expose only a prefix of the keys already passed to the editor.
    func observedPrefix(text:String,selection:NSRange)->Bool {
        let length=selection.location-caret
        let ns=text as NSString
        guard selection.length==0,length>=0,length<=roman.utf16.count,
              caret>=0,selection.location<=ns.length else{return false}
        let range=NSRange(location:caret,length:length)
        if sameObservedSurroundings(ns.replacingCharacters(in:range,with:"")) &&
            ns.substring(with:range).lowercased()==String(roman.prefix(length)).lowercased() { return true }
        if observedTwoSetPrefix(text:text,selection:selection){return true}
        return mixedInsertion(text:text,selection:selection,allowPendingKeys:true) != nil
    }
    static func next(previous:MismatchRecoveryPlan?,text:String,selection:NSRange,code:UInt16,shift:Bool,sourceID:String=KoreanKeyboardLayout.twoSetID)->MismatchRecoveryPlan? {
        let ns=text as NSString
        guard selection.location>=0,selection.length>=0,selection.location<=ns.length,
              selection.length<=ns.length-selection.location else{return nil}
        // The first key replaces a selection. Its baseline excludes exactly
        // that range so the first wrong-language character remains observable.
        let replacingSelection=ns.replacingCharacters(in:selection,with:"")
        var candidate=MismatchRecoveryPlan(before:replacingSelection,caret:selection.location,sourceID:sourceID)
        if let previous,previous.sourceID==sourceID {
            // An address field can append and select an autocomplete suffix.
            // Keep the typed prefix only when removing that selection leaves
            // every observed ASCII key and all original surroundings intact.
            // Full/partial user selections and existing suffix text fail this
            // exact proof; suggested characters never become replay keys.
            let sameCompletion=selection.length>0 && previous.pendingCompletion.map{
                $0.text==text && $0.selection==selection
            } == true
            let continues=selection.length==0
                ? previous.observedPrefix(text:text,selection:selection)
                : previous.verifiedReplacement==nil && (sameCompletion || previous.matches(text:replacingSelection,
                    selection:NSRange(location:selection.location,length:0)))
            if continues {
                candidate=previous
                let inserted=NSRange(location:previous.caret,length:selection.location-previous.caret)
                candidate.before=(replacingSelection as NSString).replacingCharacters(in:inserted,with:"")
                candidate.pendingCompletion=selection.length>0 ? (text,selection):nil
            }
        }
        guard candidate.append(code:code,shift:shift) else{return nil}
        return candidate
    }
    var replayRoman:String {
        codes.map{Self.character($0.0,$0.1)!}.joined()
    }
    mutating func captureObserved(text:String){
        let range=NSRange(location:caret,length:roman.utf16.count)
        let observed=text as NSString
        roman=observed.substring(with:range)
        before=observed.replacingCharacters(in:range,with:"")
    }
    // An editor may capitalize the selected ASCII run after our AX selection
    // request. Accept only case changes in this exact run, with unchanged
    // surrounding UTF-16 text; physical replay keys remain unchanged.
    func recapturingASCIICase(text:String)->MismatchRecoveryPlan? {
        let ns=text as NSString,range=NSRange(location:caret,length:roman.utf16.count)
        guard verifiedReplacement==nil,caret>=0,NSMaxRange(range)<=ns.length,
              ns.replacingCharacters(in:range,with:"")==before else{return nil}
        let inserted=ns.substring(with:range)
        guard roman.utf8.allSatisfy({(32...126).contains($0)}),
              inserted.utf8.allSatisfy({(32...126).contains($0)}),
              inserted.lowercased()==roman.lowercased() else{return nil}
        var result=self;result.captureObserved(text:text);return result
    }
    var expected:String? {
        let ns=before as NSString
        guard caret>=0,caret<=ns.length else{return nil}
        return ns.replacingCharacters(in:NSRange(location:caret,length:0),with:roman)
    }
    func matches(text:String,selection:NSRange)->Bool {
        let ns=text as NSString
        let range=NSRange(location:caret,length:roman.utf16.count)
        guard hasLetters,caret>=0,range.location+range.length<=ns.length,
              selection==NSRange(location:caret+range.length,length:0),
              sameObservedSurroundings(ns.replacingCharacters(in:range,with:"")) else{return false}
        let inserted=ns.substring(with:range)
        if let literal=verifiedReplacement{return inserted==literal}
        // Case is irrelevant only within the new ASCII run, never surrounding text.
        guard inserted.utf8.allSatisfy({(32...126).contains($0)}) else{return false}
        return inserted.lowercased()==roman.lowercased()
    }
}

// Source cycling can commit the original marked syllable before our edit.
// Accept only the exact rendering of these physical keys, at the same caret,
// with every surrounding UTF-16 unit intact. Replaying this verified range
// reopens composition so queued vowels join it instead of becoming loose jamo.
extension MismatchRecoveryPlan {
    func restoredKoreanPlan(text:String,selection:NSRange)->MismatchRecoveryPlan? {
        guard let korean=MismatchKeyboardLayout.render(keys:codes,sourceID:sourceID),
              korean != replayRoman,caret>=0,caret<=(before as NSString).length,
              text==(before as NSString).replacingCharacters(in:NSRange(location:caret,length:0),with:korean),
              selection==NSRange(location:caret+korean.utf16.count,length:0) else{return nil}
        var result=self;result.roman=korean;result.verifiedReplacement=korean;return result
    }
}

// A batch may straddle the observed ABC -> Korean restoration. Each key is
// accounted for exactly once: an ASCII prefix followed by a Korean suffix.
extension MismatchRecoveryPlan {
    static func matchesRestoredBatch(roman:String,inserted:String,sourceID:String=KoreanKeyboardLayout.twoSetID)->Bool {
        guard !roman.isEmpty,roman.utf8.allSatisfy({(32...126).contains($0)}) else{return false}
        guard MismatchKeyboardLayout.supports(sourceID) else{return false}
        let chars=Array(roman)
        for boundary in 0...chars.count {
            let prefix=String(chars.prefix(boundary)),suffix=String(chars.dropFirst(boundary))
            let korean=suffix.isEmpty ? "":MismatchKeyboardLayout.render(roman:suffix,sourceID:sourceID)
            if let korean,prefix+korean==inserted{return true}
        }
        return false
    }
}

extension MismatchRecoveryPlan {
    // Exactly one Korean -> ASCII -> Korean processing interval. Empty outer
    // segments also cover either direction alone. No keys may be skipped.
    static func matchesSourceRoundTrip(roman:String,inserted:String,sourceID:String=KoreanKeyboardLayout.twoSetID)->Bool {
        guard !roman.isEmpty,roman.count<=256,roman.utf8.allSatisfy({(32...126).contains($0)}) else{return false}
        guard MismatchKeyboardLayout.supports(sourceID) else{return false}
        let chars=Array(roman)
        func render(_ text:String)->String {
            if text.isEmpty{return ""}
            return MismatchKeyboardLayout.render(roman:text,sourceID:sourceID) ?? text
        }
        let prefixes=(0...chars.count).map{render(String(chars.prefix($0)))}
        let suffixes=(0...chars.count).map{render(String(chars.dropFirst($0)))}
        for start in 0...chars.count {
            // Source changes can commit one Korean prefix before the following
            // Korean keys reach the app, even before ASCII becomes visible.
            for commit in 0...start {
                let prefix=prefixes[commit]+render(String(chars[commit..<start]))
                guard inserted.hasPrefix(prefix) else{continue}
                for end in start...chars.count {
                    let middle=String(chars[start..<end])
                    if prefix+middle+suffixes[end]==inserted{return true}
                }
            }
        }
        return false
    }
}

// A source transition can be processed between two keys already observed by
// the tap. Prove the entire ASCII-prefix + Korean-suffix insertion from those
// keys; normal Korean, legitimate layout ASCII, or changed surroundings fail.
extension MismatchRecoveryPlan {
    func mixedInsertion(text:String,selection:NSRange,allowPendingKeys:Bool=false)->String? {
        let ns=text as NSString,length=selection.location-caret
        guard verifiedReplacement==nil,selection.length==0,caret>=0,length>0,
              caret<=ns.length,length<=ns.length-caret,codes.count>1,codes.count<=64,
              MismatchKeyboardLayout.supports(sourceID) else{return nil}
        let range=NSRange(location:caret,length:length)
        guard sameObservedSurroundings(ns.replacingCharacters(in:range,with:"")) else{return nil}
        let inserted=ns.substring(with:range),units=Array(inserted.utf16)
        let asciiCount=units.prefix(while:{(32...126).contains($0)}).count
        guard asciiCount>0,asciiCount<units.count else{return nil}
        let romanKeys=codes.map{Self.character($0.0,$0.1)!}
        let counts=allowPendingKeys ? Array(2...codes.count):[codes.count]
        for count in counts {
            for split in 1...min(asciiCount,count-1) {
                let prefixKeys=Array(codes.prefix(split))
                guard prefixKeys.contains(where:{MismatchKeyboardLayout.expectsHangul(code:$0.0,shift:$0.1,sourceID:sourceID)}) else{continue}
                let prefix=romanKeys.prefix(split).joined()
                guard inserted.hasPrefix(prefix),
                      let suffix=MismatchKeyboardLayout.render(keys:Array(codes[split..<count]),sourceID:sourceID),
                      prefix+suffix==inserted else{continue}
                return inserted
            }
        }
        return nil
    }
    func mixedPlan(text:String,selection:NSRange)->MismatchRecoveryPlan? {
        guard let inserted=mixedInsertion(text:text,selection:selection) else{return nil}
        var result=self;result.roman=inserted;result.verifiedReplacement=inserted
        return result
    }
}

// A two-set IME can remain selected while committing every physical jamo
// separately. Preserve normal Korean prefixes long enough to prove that exact
// failure; never normalize arbitrary document jamo or unobserved input.
extension MismatchRecoveryPlan {
    private func twoSetInsertion(text:String,selection:NSRange)->String? {
        let ns=text as NSString,length=selection.location-caret
        guard sourceID==KoreanKeyboardLayout.twoSetID,verifiedReplacement==nil,
              !codes.isEmpty,codes.count<=64,selection.length==0,caret>=0,length>0,
              selection.location<=ns.length else{return nil}
        let range=NSRange(location:caret,length:length)
        guard ns.replacingCharacters(in:range,with:"")==before else{return nil}
        return ns.substring(with:range)
    }
    private func detachedTwoSet(_ keys:[(UInt16,Bool)])->String? {
        var result=""
        for key in keys {
            guard let value=MismatchKeyboardLayout.output(code:key.0,shift:key.1,sourceID:sourceID) else{return nil}
            result.append(value)
        }
        return result
    }
    func observedTwoSetPrefix(text:String,selection:NSRange)->Bool {
        guard let insertion=twoSetInsertion(text:text,selection:selection) else{return false}
        for count in (1...codes.count).reversed() {
            let prefix=Array(codes.prefix(count))
            if MismatchKeyboardLayout.render(keys:prefix,sourceID:sourceID)==insertion || detachedTwoSet(prefix)==insertion{return true}
        }
        return false
    }
    func decomposedPlan(text:String,selection:NSRange)->MismatchRecoveryPlan? {
        guard hasLetters,let insertion=twoSetInsertion(text:text,selection:selection),
              let detached=detachedTwoSet(codes),detached==insertion,
              let composed=MismatchKeyboardLayout.render(keys:codes,sourceID:sourceID),
              composed != insertion else{return nil}
        var result=self;result.roman=insertion;result.verifiedReplacement=insertion;return result
    }
}
