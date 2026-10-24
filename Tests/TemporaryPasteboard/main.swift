import AppKit

var assertions = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard value() else { fatalError(message) }
}

final class Destination: TemporaryPasteboardDestination {
    var changeCount = 20
    var options: NSPasteboard.ContentsOptions?
    var writes = 0
    var written = true
    var beforeWriteTakeover = false
    var duringWriteTakeover = false
    var objects: [NSPasteboardWriting] = []
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        self.options = options
        changeCount += 1
        let generation = changeCount
        if beforeWriteTakeover { changeCount += 1 }
        return generation
    }
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        writes += 1; self.objects = objects
        if duringWriteTakeover { changeCount += 1 }
        return written
    }
}

let single = TemporaryPasteboard(string: "안녕")!
let destination = Destination()
var restores = 0
expect(single.publish(to: destination, restore: { restores += 1 }) == 21, "owned generation")
expect(destination.options == .currentHostOnly, "temporary contents stay on this host")
expect(destination.writes == 1 && destination.objects.count == 1, "one complete publication")
let item = destination.objects[0] as! NSPasteboardItem
expect(item.string(forType: .string) == "안녕", "converted text")
expect(item.data(forType: TemporaryPasteboard.transientType) == Data(), "transient present before publication")
expect(item.data(forType: .multipleTextSelection) == nil && restores == 0, "single payload has no multi metadata")

for fail in [false, true] {
    let takeover = Destination(); takeover.beforeWriteTakeover = true; takeover.written = !fail
    restores = 0
    expect(single.publish(to: takeover, restore: { restores += 1 }) == nil, "prepare takeover stops paste")
    expect(takeover.writes == 0 && restores == 0, "prepare takeover preserves newer copy")
    let during = Destination(); during.duringWriteTakeover = true; during.written = !fail
    expect(single.publish(to: during, restore: { restores += 1 }) == nil, "write takeover stops paste")
    expect(during.writes == 1 && restores == 0, "write takeover preserves newer copy")
}
let failed = Destination(); failed.written = false
restores = 0
expect(single.publish(to: failed, restore: { restores += 1 }) == nil, "failed publication stops paste")
expect(restores == 1, "failed owned publication restores original")

// Real AppKit pasteboard and native multi-paste; no general clipboard access.
_ = NSApplication.shared
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
let fragments = JamoPasteboard.make(["안녕", "반가워"])!
let multi = TemporaryPasteboard(string: fragments.string, multipleSelection: fragments.multipleSelection)!
let generation = multi.publish(to: board, restore: { fatalError("native write failed") })
expect(generation == board.changeCount, "native publication retains prepared generation")
expect(board.pasteboardItems?.count == 1, "native board receives one item")
expect(board.data(forType: TemporaryPasteboard.transientType) == Data(), "native transient data is present")
expect(board.data(forType: .multipleTextSelection) == fragments.multipleSelection, "opaque native metadata unchanged")
expect(board.string(forType: .string) == fragments.string, "native text unchanged")
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
view.isRichText = true; view.allowsUndo = true
view.string = "ㅇㅏㄴㄴㅕㅇ 가운데 ㅂㅏㄴㄱㅏㅇㅝ"
let original = view.string
let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = view; window.makeFirstResponder(view)
view.undoManager?.removeAllActions()
view.selectedRanges = [NSValue(range: (original as NSString).range(of: "ㅇㅏㄴㄴㅕㅇ")),
                       NSValue(range: (original as NSString).range(of: "ㅂㅏㄴㄱㅏㅇㅝ"))]
expect(view.readSelection(from: board), "protected item supports native multi-paste")
expect(view.string == "안녕 가운데 반가워", "protected item preserves fragment mapping")
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
view.undoManager?.undo()
expect(view.string.utf8.elementsEqual(original.utf8), "one native undo")
view.undoManager?.redo()
expect(view.string == "안녕 가운데 반가워", "one native redo")
board.clearContents()
expect(board.types?.contains(TemporaryPasteboard.transientType) != true, "clear removes temporary marker")
print("PASS: temporary pasteboard protection (\(assertions) assertions; private native board, no physical keys)")
