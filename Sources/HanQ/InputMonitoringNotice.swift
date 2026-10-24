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
        case .timeout: return "macOS가 한Q의 응답 시간 초과를 감지해\n한영·한자키 기능을 중단했어요."
        case .systemInput: return "macOS가 한Q의 한영·한자키 기능을 중단했어요."
        }
    }
    var guidance: String { "한Q 메뉴에서 ‘한영키 사용’\n또는 ‘한자키 사용’을 다시 켜세요." }
}

/// A nonmodal notice shown only after the input path has been torn down.
final class InputMonitoringNotice: NSObject {
    private(set) var alert: NSAlert?
    var onReport: (() -> Void)?
    var onClose: (() -> Void)?
    private var reportButton: NSButton?

    func setReporting(_ active: Bool) {
        reportButton?.isEnabled = !active
        reportButton?.title = active ? "기록 확인 중…" : "문제 알리기…"
    }

    @objc private func reportIssue() { onReport?() }

    func show(_ reason: InputMonitoringInterruption) {
        if alert == nil {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "한영·한자키 기능이 중단됐어요"
            let close = alert.addButton(withTitle: "닫기")
            close.target = self
            close.action = #selector(closeNotice)
            close.keyEquivalent = "\r"
            let report = alert.addButton(withTitle: "문제 알리기…")
            report.target = self
            report.action = #selector(reportIssue)
            reportButton = report
            alert.window.title = "한Q 기능 안내"
            alert.window.isReleasedWhenClosed = false
            self.alert = alert
        }
        alert?.informativeText = reason.explanation + "\n\n" + reason.guidance
            + "\n\n진단 기록과 함께 문제를 알려주시면\n개선에 도움이 돼요."
        alert?.layout()
        alert?.window.center()
        alert?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeNotice() {
        alert?.window.orderOut(nil)
        setReporting(false)
        onClose?()
    }
}
