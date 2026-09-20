#if HANQ_DEVELOPMENT
import AppKit
import ApplicationServices
import Carbon

// Manual integration tools, compiled only with the development build flag.
extension AppDelegate {
    func showDevelopmentTestPanels() {
        if ProcessInfo.processInfo.arguments.contains("--test-jamo-panel") {
            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 180),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "한Q 자모 통합 테스트"
            panel.isReleasedWhenClosed = false
            let button = NSButton(title: "10초 뒤 Edge 입력란 자모 조합 테스트", target: self,
                                  action: #selector(testJamoRepair))
            button.frame = NSRect(x: 30, y: 65, width: 420, height: 40)
            panel.contentView?.addSubview(button)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--test-hanja-panel") {
            let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 240),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "한Q 한자 실제 입력 검증"
            panel.isReleasedWhenClosed = false
            let hint = NSTextField(wrappingLabelWithString: "버튼을 누른 뒤 5초 안에 텍스트 편집기로 이동하세요. 한국어 입력 상태에서 원문을 입력한 뒤 후보 선택과 취소 결과를 직접 확인합니다. 다른 앱이 전면이면 시험을 취소합니다.")
            hint.frame = NSRect(x: 20, y: 155, width: 520, height: 65)
            panel.contentView?.addSubview(hint)
            let button = NSButton(title: "5초 뒤 텍스트 편집기에서 한큐 한자 변환", target: self,
                                  action: #selector(testHanjaRepair))
            button.frame = NSRect(x: 20, y: 105, width: 520, height: 40)
            panel.contentView?.addSubview(button)
            let korean = NSButton(title: "테스트용 두벌식 입력 소스 선택", target: self,
                                  action: #selector(testHanjaSource))
            korean.frame = NSRect(x: 20, y: 50, width: 520, height: 40)
            panel.contentView?.addSubview(korean)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func testJamoRepair() {
        NSLog("자모 테스트 예약: permission=%d", AXIsProcessTrusted() ? 1 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.microsoft.edgemac" else {
                NSLog("자모 테스트 취소: Edge가 전면이 아님")
                return
            }
            self?.jamoRepair.request(allowHanja: false)
        }
    }

    @objc private func testHanjaSource() {
        _ = KoreanEnglishSwitch.select("com.apple.inputmethod.Korean.2SetKorean")
    }

    @objc private func testHanjaRepair() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
                NSLog("한자 테스트 취소: 텍스트 편집기가 전면이 아님")
                return
            }
            guard let source = InputSourceSnapshot.read(), source.isKorean,
                  source.id.hasPrefix("com.apple.inputmethod.Korean.") else {
                NSLog("한자 테스트 취소: Apple 한국어 입력 소스가 아님")
                return
            }
            self?.jamoRepair.request(allowHanja: true)
        }
    }

}
#endif
