struct PostedKeys {
    struct Key: Equatable {let code:UInt16;let modifier:Bool}
    private(set) var held:[Key]=[]
    mutating func record(_ code:UInt16,down:Bool,modifier:Bool=false) {
        if down {
            if !held.contains(where:{$0.code==code}) {held.append(Key(code:code,modifier:modifier))}
        } else {held.removeAll{$0.code==code}}
    }
    mutating func takeReleases()->[Key] {let result=Array(held.reversed());held=[];return result}
}
