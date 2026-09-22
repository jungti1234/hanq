import AppKit

/// A compact native row for one complete press/release pair.
final class KeyboardSetupRow: NSView {
    private let badge = NSView()
    private let number = NSTextField(labelWithString: "")
    private let binding = NSTextField(labelWithString: "")
    private var active = false

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        badge.wantsLayer = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        number.font = .systemFont(ofSize: 12, weight: .medium)
        number.alignment = .center
        binding.font = .systemFont(ofSize: 12)
        binding.alignment = .right
        binding.lineBreakMode = .byTruncatingTail
        binding.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [badge, number, titleLabel, binding] { view.translatesAutoresizingMaskIntoConstraints = false }
        badge.addSubview(number)
        for view in [badge, titleLabel, binding] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 66),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 25), badge.heightAnchor.constraint(equalToConstant: 25),
            number.centerXAnchor.constraint(equalTo: badge.centerXAnchor), number.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            binding.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            binding.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            binding.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = (active ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (active
            ? (NSColor.controlAccentColor.blended(withFraction: 0.92, of: .controlBackgroundColor) ?? NSColor.controlBackgroundColor)
            : NSColor.controlBackgroundColor).cgColor
        badge.layer?.cornerRadius = 12.5
        badge.layer?.backgroundColor = (active ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func update(index: Int, key: KeyboardBinding?, active: Bool, waitingForRelease: Bool) {
        self.active = active
        number.stringValue = key == nil ? String(index) : "✓"
        number.textColor = active ? .alternateSelectedControlTextColor : .secondaryLabelColor
        binding.stringValue = key?.label ?? (active ? (waitingForRelease ? "키를 놓아주세요" : "키를 눌러주세요") : "다음 단계")
        binding.textColor = active ? .controlAccentColor : .secondaryLabelColor
        needsDisplay = true
    }
}

final class ExternalKeyboardSetupView: NSView {
    let step = NSTextField(wrappingLabelWithString: "")
    let progress = NSTextField(labelWithString: "")
    let hint = NSTextField(wrappingLabelWithString: "")
    let korean = KeyboardSetupRow(title: "한영키")
    let hanja = KeyboardSetupRow(title: "한자키")
    let saveButton: NSButton

    init(deviceName: String, target: AnyObject, later: Selector, restart: Selector, save: Selector) {
        saveButton = NSButton(title: "저장", target: target, action: save)
        super.init(frame: .zero)
        let logo = NSImageView()
        logo.imageScaling = .scaleProportionallyUpOrDown
        if let url = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png") {
            logo.image = NSImage(contentsOf: url)
        }
        logo.setAccessibilityLabel("한Q 로고")
        let title = NSTextField(wrappingLabelWithString: "외부 키보드의 한영키·한자키를 설정해주세요")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let keyboard = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: "키보드") ?? NSImage())
        keyboard.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: deviceName)
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = deviceName
        let device = NSStackView(views: [keyboard, name])
        device.spacing = 6; device.alignment = .centerY
        let heading = NSStackView(views: [title, device])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 8
        let intro = NSStackView(views: [logo, heading])
        intro.spacing = 14; intro.alignment = .centerY
        step.font = .systemFont(ofSize: 13, weight: .medium)
        progress.font = .systemFont(ofSize: 12)
        progress.textColor = .secondaryLabelColor
        let stepRow = NSStackView(views: [step, NSView(), progress])
        stepRow.alignment = .centerY; stepRow.spacing = 8
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let rows = NSStackView(views: [korean, hanja])
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        let content = NSStackView(views: [intro, stepRow, rows, hint])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 20
        let separator = NSBox(); separator.boxType = .separator
        let laterButton = NSButton(title: "나중에", target: target, action: later)
        let restartButton = NSButton(title: "다시 지정", target: target, action: restart)
        for button in [laterButton, restartButton, saveButton] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [laterButton, NSView(), restartButton, saveButton])
        footer.alignment = .centerY; footer.spacing = 10
        for view in [content, separator, footer] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        for view in [logo, keyboard] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor),
            title.widthAnchor.constraint(equalTo: heading.widthAnchor),
            device.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor),
            logo.widthAnchor.constraint(equalToConstant: 56), logo.heightAnchor.constraint(equalToConstant: 48),
            keyboard.widthAnchor.constraint(equalToConstant: 16), keyboard.heightAnchor.constraint(equalToConstant: 14),
            stepRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
            korean.widthAnchor.constraint(equalTo: rows.widthAnchor), hanja.widthAnchor.constraint(equalTo: rows.widthAnchor),
            hint.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 22),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { nil }
}
