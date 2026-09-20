import Foundation

/// Converts QWERTY ASCII keystrokes using the explicitly selected Korean layout.
/// Unavailable or unsupported layouts use the product default: two-set Korean.
struct KoreanKeyboardLayout {
    enum Kind { case twoSet, threeSet }
    let kind: Kind
    let keys: [Character: Character]

    static let twoSetID = "com.apple.inputmethod.Korean.2SetKorean"
    static let threeSetID = "com.apple.inputmethod.Korean.3SetKorean"
    static let threeSet390ID = "com.apple.inputmethod.Korean.390Sebulshik"

    static func load(sourceID: String?) -> KoreanKeyboardLayout? {
        switch sourceID {
        case twoSetID: return twoSet
        case threeSetID: return threeSet
        case threeSet390ID: return threeSet390
        default: return nil
        }
    }

    /// Central fallback policy, including missing/unreadable system resources.
    static func resolve(sourceID: String?,
                        loader: (String?) -> KoreanKeyboardLayout? = load) -> KoreanKeyboardLayout {
        loader(sourceID) ?? twoSet
    }

    private static let twoSet: KoreanKeyboardLayout = {
        var keys = Dictionary(uniqueKeysWithValues:
            zip(Array("abcdefghijklmnopqrstuvwxyz"), Array("ㅁㅠㅊㅇㄷㄹㅎㅗㅑㅓㅏㅣㅡㅜㅐㅔㅂㄱㄴㅅㅕㅍㅈㅌㅛㅋ")))
        for (key, value) in Array(keys) { keys[Character(String(key).uppercased())] = value }
        for (key, value): (Character, Character) in ["Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ"] {
            keys[key] = value
        }
        return KoreanKeyboardLayout(kind: .twoSet, keys: keys)
    }()

    private static let threeSet = readSystemLayout(named: "3SetHangul")
    private static let threeSet390 = readSystemLayout(named: "390Hangul")

    private static func readSystemLayout(named name: String) -> KoreanKeyboardLayout? {
        // Resource locations differ between app-based and extension-based macOS IMEs.
        let root = "/System/Library/Input Methods/KoreanIM.app/Contents/"
        for resources in ["PlugIns/KIM_Extension.appex/Contents/Resources/", "Resources/"] {
            let url = URL(fileURLWithPath: root + resources + name + ".keylayout")
            if let data = try? Data(contentsOf: url), let layout = parseSystemLayout(data) { return layout }
        }
        return nil
    }

    /// Reads Apple's installed tables instead of shipping a second, drifting copy.
    /// Only the known, stateless ANSI maps and modifier structure are accepted.
    static func parseSystemLayout(_ data: Data) -> KoreanKeyboardLayout? {
        guard var xml = String(data: data, encoding: .utf8) else { return nil }
        // Apple's XML 1.1 files include control-key entities forbidden by XML 1.0.
        // They are irrelevant to printable-key conversion; replace them before parsing.
        xml = xml.replacingOccurrences(of: "version=\"1.1\"", with: "version=\"1.0\"")
        let entities = try! NSRegularExpression(pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));")
        for match in entities.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).reversed() {
            let hex = match.range(at: 1)
            let numberRange = hex.location == NSNotFound ? match.range(at: 2) : hex
            guard let range = Range(numberRange, in: xml),
                  let value = UInt32(xml[range], radix: hex.location == NSNotFound ? 10 : 16),
                  value < 32, ![9, 10, 13].contains(value),
                  let whole = Range(match.range, in: xml) else { continue }
            xml.replaceSubrange(whole, with: "&#xFFFD;")
        }
        let delegate = LayoutParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid,
              delegate.modifiers[0] == ["caps?"],
              delegate.modifiers[1] == ["anyShift caps?"],
              let lower = delegate.maps[0], let upper = delegate.maps[1],
              let roman = delegate.maps[2], let shiftedRoman = delegate.maps[5] else { return nil }
        var keys: [Character: Character] = [:]
        for (input, output) in [(roman, lower), (shiftedRoman, upper)] {
            // Main typing block only: keypad digits cannot stand in for top-row keys.
            for (code, ascii) in input where (0...50).contains(code) {
                guard ascii.unicodeScalars.count == 1, let scalar = ascii.unicodeScalars.first,
                      (33...126).contains(scalar.value) else { continue }
                guard let value = output[code], value.unicodeScalars.count == 1,
                      let out = value.unicodeScalars.first,
                      (0x1100...0x1112).contains(out.value) || (0x1161...0x1175).contains(out.value)
                        || (0x11A8...0x11C2).contains(out.value)
                        || (!CharacterSet.controlCharacters.contains(out) && out.value != 0xFFFD),
                      keys[ascii] == nil || keys[ascii] == value else { return nil }
                keys[ascii] = value
            }
        }
        guard keys.count == 94, keys.values.contains(where: { char in
            char.unicodeScalars.contains { (0x1100...0x11C2).contains($0.value) }
        }) else { return nil }
        return KoreanKeyboardLayout(kind: .threeSet, keys: keys)
    }
}

private final class LayoutParser: NSObject, XMLParserDelegate {
    var maps: [Int: [Int: Character]] = [:]
    var modifiers: [Int: Set<String>] = [:]
    var invalid = false
    private var inANSI = false
    private var inCommon = false
    private var mapIndex: Int?
    private var modifierIndex: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "keyMapSet": inANSI = attributes["id"] == "ANSI"
        case "modifierMap": inCommon = attributes["id"] == "common"
        case "keyMapSelect" where inCommon: modifierIndex = attributes["mapIndex"].flatMap(Int.init)
        case "modifier" where inCommon:
            if let index = modifierIndex, let keys = attributes["keys"] { modifiers[index, default: []].insert(keys) }
        case "keyMap" where inANSI:
            mapIndex = attributes["index"].flatMap(Int.init)
            if let index = mapIndex, [0, 1, 2, 5].contains(index) {
                if maps[index] != nil || attributes["baseMapSet"] != nil { invalid = true }
                maps[index] = [:]
            }
        case "key" where inANSI:
            guard let index = mapIndex, [0, 1, 2, 5].contains(index),
                  let code = attributes["code"].flatMap(Int.init), (0...50).contains(code) else { return }
            guard let output = attributes["output"], output.count == 1, attributes["action"] == nil,
                  maps[index]?[code] == nil else { invalid = true; return }
            maps[index]?[code] = output.first!
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "keyMapSet": inANSI = false
        case "keyMap": mapIndex = nil
        case "modifierMap": inCommon = false
        case "keyMapSelect": modifierIndex = nil
        default: break
        }
    }
}
