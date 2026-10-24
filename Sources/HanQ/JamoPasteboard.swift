import AppKit

/// Carries only converted fragments. Original rich text never enters this board.
struct JamoPasteboard {
    let string: String
    let multipleSelection: Data?

    static func make(_ replacements: [String]) -> JamoPasteboard? {
        guard !replacements.isEmpty else { return nil }
        if replacements.count == 1 { return JamoPasteboard(string: replacements[0], multipleSelection: nil) }
        // Let AppKit encode its public multiple-selection format. Do not infer
        // its opaque representation or copy any source document/attachment.
        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        source.isRichText = false
        source.string = replacements.joined(separator: "\n")
        var offset = 0
        source.selectedRanges = replacements.map { value in
            defer { offset += value.utf16.count + 1 }
            return NSValue(range: NSRange(location: offset, length: value.utf16.count))
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard source.writeSelection(to: board, types: source.writablePasteboardTypes),
              let string = board.string(forType: .string),
              string.utf8.elementsEqual(source.string.utf8),
              let metadata = board.data(forType: .multipleTextSelection), !metadata.isEmpty else { return nil }
        return JamoPasteboard(string: string, multipleSelection: metadata)
    }
}
