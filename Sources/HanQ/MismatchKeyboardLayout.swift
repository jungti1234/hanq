import Foundation

/// Automatic recovery must use the selected source's real physical layout.
/// Unlike manual Roman conversion this must never fall back to two-set.
enum MismatchKeyboardLayout {
    static let gongjinID = KoreanKeyboardLayout.gongjinID
    static let hncID = KoreanKeyboardLayout.hncID
    static func load(_ id:String)->KoreanKeyboardLayout? {
        KoreanKeyboardLayout.load(sourceID:id)
    }
    static func supports(_ sourceID:String)->Bool { load(sourceID) != nil }
    static func output(code:UInt16,shift:Bool,sourceID:String)->Character? {
        guard let layout=load(sourceID),
              let roman=MismatchRecoveryPlan.character(code,shift),let char=roman.first else{return nil}
        if layout.physicalKeys.isEmpty{return layout.keys[char] ?? char}
        if code==49{return " "}
        return (shift ? layout.shiftedPhysicalKeys:layout.physicalKeys)[code]
    }
    static func isHangul(_ char:Character)->Bool {
        char.unicodeScalars.contains{(0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7A3).contains($0.value)}
    }
    static func expectsHangul(code:UInt16,shift:Bool,sourceID:String)->Bool {
        output(code:code,shift:shift,sourceID:sourceID).map(isHangul) ?? false
    }
    static func render(keys:[(UInt16,Bool)],sourceID:String)->String? {
        guard let layout=load(sourceID) else{return nil}
        var jamo=""
        for (code,shift) in keys {
            guard let char=output(code:code,shift:shift,sourceID:sourceID) else{return nil}
            jamo.append(char)
        }
        if sourceID==gongjinID || sourceID==hncID{return JamoComposer.composeRomanized(jamo,kind:layout.kind)}
        return layout.kind == .twoSet ? JamoComposer.compose(jamo):threeSet(jamo)
    }
    static func render(roman:String,sourceID:String)->String? {
        var keys:[(UInt16,Bool)]=[]
        for char in roman {
            guard let key=positions[char] else{return nil};keys.append(key)
        }
        return render(keys:keys,sourceID:sourceID)
    }
    private static let positions:[Character:(UInt16,Bool)] = {
        var result:[Character:(UInt16,Bool)]=[:]
        for code in Array(PhysicalLetterKeys.letters.keys)+Array(MismatchRecoveryPlan.punctuation.keys) {
            for shift in [false,true] {
                if let char=MismatchRecoveryPlan.character(code,shift)?.first,result[char]==nil{result[char]=(code,shift)}
            }
        }
        return result
    }()
}


extension MismatchKeyboardLayout {
    private static func threeSet(_ text:String)->String {
        var accepted=""
        for scalar in text.unicodeScalars {
            if (0x11A8...0x11C2).contains(scalar.value),
               let last=JamoComposer.composeThreeSet(accepted,preserveStandaloneFinals:true).unicodeScalars.last,
               (0x3131...0x3163).contains(last.value) {
                // Apple ignores a final key after an incomplete initial/medial.
                continue
            }
            accepted.unicodeScalars.append(scalar)
        }
        return JamoComposer.composeThreeSet(accepted,preserveStandaloneFinals:true)
    }
}
