import AppKit

private final class SourcePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RoundedHUDView: NSView {
    var firstDraw:(()->Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        let callback=firstDraw;firstDraw=nil;callback?()
    }
}

final class HUDController {
    private let panel = SourcePanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private let background = RoundedHUDView()
    private var dismissal: Timer?
    private var presentation=0

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.isSelectable = false
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18)
        ])
        panel.contentView = background
    }

    func show(name: String?, sourceClass:Int=0) {
        let trace=InputIncidentTrace.shared
        presentation+=1
        let request=presentation
        trace.hud(.requested,sourceClass:sourceClass,presentation:request)
        dismissal?.invalidate()
        guard let sourceName = name, !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let screen = NSScreen.main ?? NSScreen.screens.first else { trace.hud(.unavailable,sourceClass:sourceClass,presentation:request);hide(); return }
        background.firstDraw=trace.enabled ? {trace.hud(.firstDraw,sourceClass:sourceClass,presentation:request)}:nil
        let name = sourceName
        label.stringValue = name
        panel.setAccessibilityLabel("입력 소스: \(name)")
        let frame = screen.visibleFrame
        let maxWidth = max(80, frame.width - 96)
        let textWidth = min(maxWidth - 56, max(110, (name as NSString).size(withAttributes: [.font: label.font!]).width))
        let size = NSSize(width: textWidth + 56, height: 66)
        // Reusing the panel replaces the previous name; an old timer cannot hide a new one.
        panel.alphaValue = 1
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.30,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        trace.hud(.ordered,sourceClass:sourceClass,presentation:request)
        let shownAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - shownAt
            if elapsed < 0.8 { return }
            if elapsed >= 0.98 { self.panel.orderOut(nil); timer.invalidate(); return }
            self.panel.alphaValue = 1 - (elapsed - 0.8) / 0.18
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissal = timer
    }
    func hide() {
        background.firstDraw=nil
        dismissal?.invalidate(); panel.orderOut(nil)
    }
}
