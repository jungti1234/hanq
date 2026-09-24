import Foundation

/// Strict mapping: automatic edits never fall back to a different Korean layout.
struct OnsetKeyboardLayout {
    let sourceID:String
    let normal:[UInt16:String]
    let shifted:[UInt16:String]
    static let initials=Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let twoSet=load(sourceID:KoreanKeyboardLayout.twoSetID)!
    static func load(sourceID:String)->OnsetKeyboardLayout? {
        guard let layout=KoreanKeyboardLayout.load(sourceID:sourceID) else{return nil}
        func initial(_ char:Character)->String? {
            guard let scalar=char.unicodeScalars.first,char.unicodeScalars.count==1 else{return nil}
            if layout.kind == .twoSet{return initials.contains(char) ? String(char):nil}
            // Three-set final consonant keys must not be treated as initial keys.
            guard (0x1100...0x1112).contains(scalar.value) else{return nil}
            return String(char)
        }
        var normal:[UInt16:String]=[:],shifted:[UInt16:String]=[:]
        if layout.kind == .twoSet {
            for (code,key) in OnsetRecoveryPlan.keys {
                if let char=layout.keys[Character(key)],let value=initial(char){normal[code]=value}
                if let char=layout.keys[Character(key.uppercased())],let value=initial(char){shifted[code]=value}
            }
        }else{
            for (code,char) in layout.physicalKeys{if let value=initial(char){normal[code]=value}}
            for (code,char) in layout.shiftedPhysicalKeys{if let value=initial(char){shifted[code]=value}}
        }
        return OnsetKeyboardLayout(sourceID:sourceID,normal:normal,shifted:shifted)
    }
    func variants(code:UInt16,shift:Bool)->[String] {
        guard let raw=(shift ? shifted:normal)[code] else{return []}
        if let scalar=raw.unicodeScalars.first,(0x1100...0x1112).contains(scalar.value){
            return [raw,String(Self.initials[Int(scalar.value-0x1100)])]
        }
        return [raw]
    }
}
