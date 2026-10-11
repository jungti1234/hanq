import Foundation

/// One nine-key page at a time, retaining the dictionary's candidate order.
struct HanjaCandidateSelection {
    let candidates: [String]
    private(set) var index = 0
    static let pageSize = 9
    var pageStart: Int { index / Self.pageSize * Self.pageSize }
    var page: [String] { Array(candidates.dropFirst(pageStart).prefix(Self.pageSize)) }
    var selected: String? { candidates.indices.contains(index) ? candidates[index] : nil }

    mutating func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        index = min(max(0, index + delta), candidates.count - 1)
    }
    mutating func selectOnPage(_ number: Int) -> Bool {
        let target = pageStart + number
        guard number >= 0, number < Self.pageSize, candidates.indices.contains(target) else { return false }
        index = target
        return true
    }
    mutating func select(_ value: String) -> Bool {
        guard let target = candidates.firstIndex(of: value) else { return false }
        index = target
        return true
    }

    enum Key {
        case number(Int), move(Int), first, last, confirm, cancel, other
    }
    static func key(_ code: Int64) -> Key {
        let digits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
                                  83: 0, 84: 1, 85: 2, 86: 3, 87: 4, 88: 5, 89: 6, 91: 7, 92: 8]
        if let number = digits[code] { return .number(number) }
        switch code {
        case 125, 124: return .move(1)
        case 126, 123: return .move(-1)
        case 121: return .move(pageSize)
        case 116: return .move(-pageSize)
        case 115: return .first
        case 119: return .last
        case 36, 76: return .confirm
        case 53: return .cancel
        default: return .other
        }
    }
}
