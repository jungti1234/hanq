// QWERTY physical letter positions, independent of the selected input source.
enum PhysicalLetterKeys {
    // ANSI typing block: three-set layouts also place jamo on these positions.
    static let printableCodes = Set(letters.keys).union([18,19,20,21,23,22,26,28,25,29,27,24,33,30,42,41,39,43,47,44,50,49])
    static let letters: [UInt16:String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",31:"o",32:"u",34:"i",35:"p",37:"l",38:"j",40:"k",45:"n",46:"m"]
}
