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
        case .timeout: return "입력 감시 중단 · 응답 시간 초과"
        case .systemInput: return "입력 감시 중단 · 시스템에서 중단"
        }
    }
    var explanation: String {
        switch self {
        case .timeout: return "macOS가 입력 감시의 응답 시간 초과를 감지해 한Q의 입력 감시를 중단했어요."
        case .systemInput: return "macOS가 한Q의 입력 감시를 중단했어요."
        }
    }
    var guidance: String { "한Q 메뉴에서 ‘한영키 사용’ 또는 ‘한자키 사용’을 다시 켜세요." }
}

/// A nonmodal notice shown only after the input path has been torn down.
final class InputMonitoringNotice: NSObject {
    private(set) var alert: NSAlert?

    func show(_ reason: InputMonitoringInterruption) {
        if alert == nil {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "한Q 입력 감시가 중단됐어요"
            let close = alert.addButton(withTitle: "닫기")
            close.target = self
            close.action = #selector(closeNotice)
            close.keyEquivalent = "\r"
            alert.window.title = "한Q - 입력 감시 안내"
            alert.window.isReleasedWhenClosed = false
            self.alert = alert
        }
        alert?.informativeText = reason.explanation + "\n\n" + reason.guidance
        alert?.layout()
        alert?.window.center()
        alert?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeNotice() { alert?.window.orderOut(nil) }
}
