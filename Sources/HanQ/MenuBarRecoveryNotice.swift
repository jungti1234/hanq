import AppKit

/// Nonmodal explanation after repeated user launches; never pauses input work.
final class MenuBarRecoveryNotice: NSObject {
    private(set) var panel: NSPanel?
    let onFeedback: () -> Void

    init(onFeedback: @escaping () -> Void) { self.onFeedback = onFeedback }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "한Q - 메뉴바 아이콘 안내"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let logo: NSView
            if let url = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                let view = NSImageView(image: image)
                view.imageScaling = .scaleProportionallyUpOrDown
                view.setAccessibilityLabel("한Q 로고")
                logo = view
            } else {
                let fallback = NSTextField(labelWithString: "한Q")
                fallback.font = .systemFont(ofSize: 24, weight: .bold)
                fallback.textColor = .controlAccentColor
                logo = fallback
            }
            let title = NSTextField(wrappingLabelWithString: "메뉴바 아이콘이 보이지 않나요?")
            title.font = .systemFont(ofSize: 19, weight: .semibold)
            let running = NSTextField(labelWithString: "한Q는 이미 실행 중이에요")
            running.font = .systemFont(ofSize: 12)
            running.textColor = .secondaryLabelColor
            let heading = NSStackView(views: [title, running])
            heading.orientation = .vertical
            heading.alignment = .leading
            heading.spacing = 8
            let intro = NSStackView(views: [logo, heading])
            intro.spacing = 14
            intro.alignment = .centerY
            let message = NSTextField(wrappingLabelWithString:
                "Mac의 노치나 메뉴바 공간 부족, 메뉴바 관리 앱의 숨김 설정으로 아이콘이 가려져 있을 수 있어요.")
            message.font = .systemFont(ofSize: 13)
            let hint = NSTextField(wrappingLabelWithString:
                "이런 경우가 아닌데도 아이콘이 보이지 않으면\n피드백을 남겨주세요.")
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabelColor
            let content = NSStackView(views: [intro, message, hint])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 20
            let separator = NSBox()
            separator.boxType = .separator
            let feedback = NSButton(title: "피드백 남기기…", target: self, action: #selector(openFeedback))
            let close = NSButton(title: "닫기", target: self, action: #selector(closeNotice))
            close.keyEquivalent = "\u{1b}"
            for button in [feedback, close] { button.bezelStyle = .rounded }
            let footer = NSStackView(views: [close, NSView(), feedback])
            footer.alignment = .centerY
            footer.spacing = 10
            for view in [content, separator, footer] {
                view.translatesAutoresizingMaskIntoConstraints = false
                panel.contentView?.addSubview(view)
            }
            logo.translatesAutoresizingMaskIntoConstraints = false
            if let root = panel.contentView {
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
                    content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
                    content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
                    intro.widthAnchor.constraint(equalTo: content.widthAnchor),
                    title.widthAnchor.constraint(equalTo: heading.widthAnchor),
                    logo.widthAnchor.constraint(equalToConstant: 56),
                    logo.heightAnchor.constraint(equalToConstant: 48),
                    message.widthAnchor.constraint(equalTo: content.widthAnchor),
                    hint.widthAnchor.constraint(equalTo: content.widthAnchor),
                    separator.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 22),
                    separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
                    footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
                    footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                    footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
                ])
            }
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openFeedback() {
        panel?.close()
        onFeedback()
    }

    @objc func closeNotice() { panel?.close() }
}
