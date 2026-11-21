import AppKit
import CoreGraphics

enum InputMonitoringInterruption: Equatable {
    case timeout
    case systemInput

    init?(eventType: CGEventType) {
        switch eventType {
        case .tapDisabledByTimeout: self = .timeout
        case .tapDisabledByUserInput: self = .systemInput
        default: return nil
        }
    }

    var status: String {
        switch self {
        case .timeout: return "한영·한자키 중단 · 응답 시간 초과"
        case .systemInput: return "한영·한자키 중단 · 시스템에서 중단"
        }
    }
    var explanation: String {
        switch self {
        case .timeout: return "macOS가 한Q의 응답 시간 초과를 감지했어요."
        case .systemInput: return "macOS에서 중단을 요청했어요."
        }
    }
    var guidance: String { "한Q 메뉴에서 ‘한영키 사용’\n또는 ‘한자키 사용’을 다시 켜세요." }
}

/// A nonmodal notice shown only after the input path has been torn down.
final class InputMonitoringNotice: NSObject, NSWindowDelegate {
    private(set) var panel: NSPanel?
    var onFeedback: (() -> Void)?
    var onReview: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var feedbackButton: NSButton?
    private(set) var exportButton: NSButton?
    private(set) var closeButton: NSButton?
    private var causeLabel: NSTextField?

    var isVisible: Bool { panel?.isVisible == true }

    func setPreparingExport(_ active: Bool) {
        exportButton?.isEnabled = !active
        exportButton?.title = active ? "기록 확인 중…" : "진단 기록 내보내기…"
    }

    @objc private func leaveFeedback() { onFeedback?() }
    @objc private func reviewRecords() { onReview?() }

    func show(_ reason: InputMonitoringInterruption) {
        if panel == nil { makePanel(guidance: reason.guidance) }
        causeLabel?.stringValue = reason.explanation
        if !isVisible { panel?.center() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel(guidance: String) {
        // Match storage help: 56x48 logo, 19pt heading, 28pt content inset,
        // left-aligned guidance and a separated footer with rounded buttons.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 284),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "한Q - 한영·한자키 기능 중단"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let root = NSView(); panel.contentView = root
        let logo = NSImageView(frame: NSRect(x: 28, y: 208, width: 56, height: 48))
        if let url = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png") {
            logo.image = NSImage(contentsOf: url)
        }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("한Q 로고")
        let title = NSTextField(labelWithString: "한영·한자키 기능이 중단됐어요")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 98, y: 232, width: 354, height: 24)
        let cause = NSTextField(labelWithString: "")
        cause.font = .systemFont(ofSize: 12)
        cause.textColor = .secondaryLabelColor
        cause.frame = NSRect(x: 98, y: 208, width: 354, height: 16)
        cause.setAccessibilityIdentifier("inputInterruptionCause")
        let action = NSTextField(wrappingLabelWithString: guidance)
        action.font = .systemFont(ofSize: 13)
        action.frame = NSRect(x: 28, y: 152, width: 424, height: 36)
        action.setAccessibilityIdentifier("inputInterruptionAction")
        let hint = NSTextField(wrappingLabelWithString: "가능하면 진단 기록을 첨부해\n피드백을 남겨 주세요.")
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 28, y: 96, width: 424, height: 36)
        let separator = NSBox(frame: NSRect(x: 0, y: 65, width: 480, height: 1))
        separator.boxType = .separator
        let close = NSButton(title: "닫기", target: self, action: #selector(closeNotice))
        close.keyEquivalent = "\u{1b}"
        close.frame = NSRect(x: 24, y: 16, width: 64, height: 32)
        let feedback = NSButton(title: UserFacingText.feedbackAction, target: self, action: #selector(leaveFeedback))
        feedback.keyEquivalent = "\r"
        feedback.frame = NSRect(x: 324, y: 16, width: 132, height: 32)
        feedback.setAccessibilityIdentifier("inputInterruptionFeedback")
        let export = NSButton(title: "진단 기록 내보내기…", target: self, action: #selector(reviewRecords))
        export.frame = NSRect(x: 156, y: 16, width: 158, height: 32)
        export.setAccessibilityIdentifier("inputInterruptionExport")
        for button in [close, export, feedback] { button.bezelStyle = .rounded }
        for view in [logo, title, cause, action, hint, separator, close, export, feedback] { root.addSubview(view) }
        self.panel = panel
        causeLabel = cause
        closeButton = close
        feedbackButton = feedback
        exportButton = export
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The titlebar close button must cancel a pending export lookup too.
        closeNotice()
        return false
    }

    @objc func closeNotice() {
        panel?.orderOut(nil)
        setPreparingExport(false)
        onClose?()
    }
}
