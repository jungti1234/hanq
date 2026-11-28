import AppKit

/// The quit coordinator owns the decision. Updating its presentation never
/// dismisses the window, brings it forward a second time, or replies to AppKit.
final class DiagnosticQuitAlert: NSObject {
    let alert = NSAlert()
    private var choice: ((DiagnosticQuitCoordinator.Choice) -> Void)?
    private var saved = false

    override init() {
        super.init()
        alert.alertStyle = .informational
        for title in ["계속 사용하기", "대기 기록 내보내기…", "저장하지 않고 종료"] {
            let button = alert.addButton(withTitle: title)
            button.target = self
            button.action = #selector(choose(_:))
        }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = ""
    }

    func update(_ state: DiagnosticQuitState?, choice: @escaping (DiagnosticQuitCoordinator.Choice) -> Void) {
        self.choice = choice
        saved = state?.hasPending == false
        if saved {
            alert.messageText = "대기 진단 기록을 모두 저장했습니다."
            alert.informativeText = "지금 한Q를 종료할까요?"
        } else {
            alert.messageText = state == nil ? "진단 기록 저장을 확인하지 못했어요." : "저장하지 못한 진단 기록이 있어요."
            let detail = state.map {
                "상세 구간 \($0.detailPhases)개와 오류·사건 기록 \($0.errors + $0.observations)개가 저장 대기 중입니다."
            } ?? "저장 상태 확인이 지연되고 있습니다."
            alert.informativeText = detail + "\n지금 종료하면 메모리에 남은 진단 기록은 사라집니다.\n계속 사용하거나 대기 기록을 내보낼 수 있습니다."
        }
        alert.buttons[1].isEnabled = !saved
        alert.buttons[2].title = saved ? "한Q 종료" : "저장하지 않고 종료"
        alert.layout()
    }

    @objc private func choose(_ sender: NSButton) {
        switch sender {
        case alert.buttons[0]: choice?(.cancel)
        case alert.buttons[1] where sender.isEnabled: choice?(.export)
        case alert.buttons[2]: choice?(saved ? .quit : .discard)
        default: break
        }
    }
}
