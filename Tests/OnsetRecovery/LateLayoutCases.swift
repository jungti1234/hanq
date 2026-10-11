import Foundation

// Expected text is independent of the product composer and is checked by real IMEs.
struct LateLayoutCase {
    let sourceID:String
    let name:String
    let keys:[(UInt16,Bool)]
    let split:String
    let joined:String
}
let lateLayoutCases:[LateLayoutCase] = {
    var result:[LateLayoutCase]=[]
    func add(_ id:String,_ name:String,_ keys:[(UInt16,Bool)],_ split:String,_ joined:String){
        result.append(.init(sourceID:id,name:name,keys:keys+[(49,false)],split:split+" ",joined:joined+" "))
    }
    let two=KoreanKeyboardLayout.twoSetID
    add(two,"final",[(15,false),(40,false),(1,false)],"ㄱㅏㄴ","간")
    add(two,"shift initial",[(15,true),(40,false),(1,false)],"ㄲㅏㄴ","깐")
    add(two,"compound vowel",[(15,false),(4,false),(40,false),(1,false)],"ㄱㅘㄴ","관")
    add(two,"compound final",[(15,false),(40,false),(15,false),(17,false)],"ㄱㅏㄱㅅ","갃")
    add(two,"next syllable",[(15,false),(40,false),(1,false),(40,false)],"ㄱㅏ나","가나")
    for id in [KoreanKeyboardLayout.threeSetID,KoreanKeyboardLayout.threeSet390ID] {
        add(id,"final",[(40,false),(3,false),(1,false)],"ㄱㅏ","간")
        add(id,"repeated initial",[(40,false),(40,false),(3,false),(1,false)],"ㄱ간","깐")
        add(id,"compound vowel punctuation",[(40,false),(44,false),(3,false)],"ㄱㅘ","과")
        add(id,"numeric initial",[(29,false),(3,false),(1,false)],"ㅋㅏ","칸")
        add(id,"punctuation initial numeric final",[(41,false),(3,false),(20,false)],"ㅂㅏ","밥")
        add(id,"shift final",[(40,false),(3,false),(id==KoreanKeyboardLayout.threeSetID ? 18:3,true)],"ㄱㅏ","갂")
    }
    for id in [KoreanKeyboardLayout.gongjinID,KoreanKeyboardLayout.hncID] {
        add(id,"final",[(5,false),(0,false),(45,false)],"ㄱㅏㄴ","간")
        add(id,"shift initial",[(5,true),(0,false),(45,false)],"ㄲㅏㄴ","깐")
        add(id,"phonetic compound vowel",[(5,false),(0,false),(id==KoreanKeyboardLayout.gongjinID ? 14:34,false)],"ㄱㅐ","개")
        add(id,"ng final",[(5,false),(0,false),(45,false),(5,false)],"ㄱㅏㅇ","강")
        add(id,"next syllable",[(5,false),(0,false),(45,false),(0,false)],"ㄱㅏ나","가나")
    }
    return result
}()
