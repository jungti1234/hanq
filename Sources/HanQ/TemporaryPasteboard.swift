import AppKit

protocol TemporaryPasteboardDestination {
    var changeCount: Int { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: TemporaryPasteboardDestination {}

/// Only the temporary conversion payload uses these protections. Original
/// clipboard data is restored separately, with its original types and bytes.
struct TemporaryPasteboard {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let item: NSPasteboardItem

    init?(string: String, multipleSelection: Data? = nil) {
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string),
              item.setData(Data(), forType: Self.transientType) else { return nil }
        if let multipleSelection {
            guard item.setData(multipleSelection, forType: .multipleTextSelection) else { return nil }
        }
        self.item = item
    }

    /// Build every representation before publishing once. Never paste or
    /// restore over a newer clipboard generation, including a failed write.
    func publish(to board: TemporaryPasteboardDestination, restore: () -> Void) -> Int? {
        let generation = board.prepareForNewContents(with: .currentHostOnly)
        guard board.changeCount == generation else { return nil }
        let written = board.writeObjects([item])
        guard written, board.changeCount == generation else {
            if board.changeCount == generation { restore() }
            return nil
        }
        return generation
    }
}
