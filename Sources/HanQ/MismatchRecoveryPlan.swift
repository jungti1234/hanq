import Foundation

// Track observed printable keys across digits/punctuation, including delayed AX batches.
struct MismatchRecoveryPlan {
    var before: String
    let caret: Int
    var sourceID = KoreanKeyboardLayout.twoSetID
    var roman = ""
    // Only recovery's exact, observed mixed Hangul/Roman range may set this.
    // Normal mismatch detection remains ASCII-only.
    var verifiedReplacement:String?
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
        return sameObservedSurroundings(ns.replacingCharacters(in:range,with:"")) &&
            ns.substring(with:range).lowercased()==String(roman.prefix(length)).lowercased()
    }
    static func next(previous:MismatchRecoveryPlan?,text:String,selection:NSRange,code:UInt16,shift:Bool,sourceID:String=KoreanKeyboardLayout.twoSetID)->MismatchRecoveryPlan? {
        guard selection.length==0 else{return nil}
        var candidate=MismatchRecoveryPlan(before:text,caret:selection.location,sourceID:sourceID)
        if let previous,previous.sourceID==sourceID,previous.observedPrefix(text:text,selection:selection){
            candidate=previous
            let inserted=NSRange(location:previous.caret,length:selection.location-previous.caret)
            candidate.before=(text as NSString).replacingCharacters(in:inserted,with:"")
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
