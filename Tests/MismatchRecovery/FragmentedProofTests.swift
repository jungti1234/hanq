import Foundation

// Reference model of the original complete contiguous-segment proof. Small
// inputs allow exhaustive output partitions without global input or AX.
func runFragmentedProofTests(){
    var checks=0
    func check(_ value:Bool,_ message:String){checks+=1;probeTestCheck(value,message)}
    let source=KoreanKeyboardLayout.twoSetID
    func outputs(_ keys:[(UInt16,Bool)])->Set<String>{
        let normal=MismatchKeyboardLayout.render(keys:keys,sourceID:source)!
        let detached=String(keys.map{MismatchKeyboardLayout.output(code:$0.0,shift:$0.1,sourceID:source)!})
        let roman=keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        return [normal,detached,roman]
    }
    func reference(_ keys:[(UInt16,Bool)],_ inserted:String)->Bool {
        let target=Array(inserted.utf16)
        func prove(_ start:Int,_ offset:Int)->Bool {
            if start==keys.count{return offset==target.count}
            guard offset<target.count else{return false}
            for end in (start+1)...keys.count {
                for output in outputs(Array(keys[start..<end])) {
                    let units=Array(output.utf16),next=offset+units.count
                    if !units.isEmpty,next<=target.count,target[offset..<next].elementsEqual(units),prove(end,next){return true}
                }
            }
            return false
        }
        let normal=MismatchKeyboardLayout.render(keys:keys,sourceID:source)!
        let hangul=inserted.unicodeScalars.contains{(0x3131...0x318e).contains($0.value) || (0xac00...0xd7a3).contains($0.value)}
        return normal != inserted && hangul && prove(0,0)
    }
    // Include ordinary, compound vowel/final, shifted initial and punctuation.
    let alphabet:[(UInt16,Bool)]=[(15,false),(40,false),(1,false),(4,false),(15,true),(49,false)]
    var sequences:[[(UInt16,Bool)]]=[[]]
    for _ in 0..<3 {sequences=sequences.flatMap{prefix in alphabet.map{prefix+[$0]}}}
    sequences += [[(15,false),(4,false),(40,false),(15,false),(17,false)],[(15,true),(40,false),(15,true)],[(15,false),(35,false),(49,false)],[(15,false),(40,false),(3,false),(5,false)]]
    for keys in sequences {
        var candidates=outputs(keys)
        for split in 1..<keys.count {
            for a in outputs(Array(keys.prefix(split))) {for b in outputs(Array(keys.dropFirst(split))){candidates.insert(a+b)}}
        }
        // A different elementary-jamo order, incomplete prefix, and extra jamo
        // must keep the reference rejection; component equality alone is never
        // permission to accept an arbitrary partition or edit.
        candidates.insert("가ㄴ");candidates.insert("ㄱ나");candidates.insert("간ㄱ")
        if let normal=MismatchKeyboardLayout.render(keys:keys,sourceID:source){candidates.insert(String(normal.dropLast()))}
        var plan=MismatchRecoveryPlan(before:"앞🙂 뒤",caret:4);plan.codes=keys
        plan.roman=keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        for value in candidates where !value.isEmpty {
            let text="앞🙂 "+value+"뒤",selection=NSRange(location:4+value.utf16.count,length:0)
            check((plan.fragmentedCompositionPlan(text:text,selection:selection) != nil)==reference(keys,value),"fragmented reference equivalence")
            check(plan.fragmentedCompositionPlan(text:"변경"+value+"뒤",selection:selection)==nil,"changed surroundings rejected")
            check(plan.fragmentedCompositionPlan(text:text,selection:NSRange(location:selection.location,length:1))==nil,"selection rejected")
        }
    }
    // A saved normal editor prefix can trail the complete observed history.
    // The same failure used to spend long periods partitioning that impossible
    // whole-history match in the synchronous event callback.
    let word:[(UInt16,Bool)]=[0,45,1,13,40,2,49,13,45,2,15,40,1,2,46,37,49,15,46,3,13,40,14,4,49,15,46,14,31,3,4,49,1,40,0,2,40,2,34,49,5,40,12,1,37,14,40,47].map{($0,false)}
    var maximum=0.0
    for count in [16,24,32,48,64] {
        let keys=Array((word+word).prefix(count));var p=MismatchRecoveryPlan(before:"앞🙂 뒤",caret:4);p.codes=keys;p.roman=keys.compactMap{MismatchRecoveryPlan.character($0.0,$0.1)}.joined()
        let insertion=MismatchKeyboardLayout.render(keys:Array(keys.prefix(count/2)),sourceID:source)!
        let began=ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {check(p.fragmentedCompositionPlan(text:"앞🙂 "+insertion+"뒤",selection:NSRange(location:4+insertion.utf16.count,length:0))==nil,"lagging normal prefix is not full-key evidence")}
        let elapsed=ProcessInfo.processInfo.systemUptime-began;maximum=max(maximum,elapsed)
        check(elapsed<0.25,"five lagging-prefix proofs stay below callback stall budget")
    }
    print("PASS: \(checks) fragmented proof/reference, shifted/compound, surrounding/selection and lagging-prefix checks; maximum five-proof seconds \(maximum); no OS keys")
}
