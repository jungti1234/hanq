import AppKit
import UniformTypeIdentifiers

private final class DiagnosticReviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

private final class DiagnosticReviewHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 10, dy: 0), in: controlView)
    }
}

private final class DiagnosticReviewScrollView: NSScrollView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// A standalone review window. It never creates input hooks or changes the
/// diagnostic collection preference, and works while collection is OFF.
final class DiagnosticReviewController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let worker = DispatchQueue(label: "hanq.diagnostics.review", qos: .utility)
    private let environment: DiagnosticReviewEnvironment
    private var snapshot: DiagnosticReviewSnapshot?
    private var selected = Set<String>()
    private var archive: DiagnosticReviewArchive?
    private var generation = 0
    private var closed = false
    private var saving = false
    private var savedURL: URL?
    var onClose: (() -> Void)?
    var onFeedback: (() -> Void)?

    private let recordTable = NSTableView()
    private let fileTable = NSTableView()
    private let textView = NSTextView()
    private let countLabel = NSTextField(labelWithString: "기록을 불러오는 중…")
    private let selectionLabel = NSTextField(labelWithString: "선택한 기록 0/5건")
    private let statusLabel = NSTextField(labelWithString: "저장 중인 후속 기록을 기다리고 있습니다.")
    private let previewTitle = NSTextField(labelWithString: "미리보기")
    private let saveButton = NSButton(title: "내보내기…", target: nil, action: nil)
    private let finderButton = NSButton(title: "Finder에서 보기", target: nil, action: nil)
    private let feedbackButton = NSButton(title: "피드백 열기", target: nil, action: nil)
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)

    init(environment: DiagnosticReviewEnvironment) {
        self.environment = environment
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "한Q - 진단 기록 내보내기"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 740)
        window.contentView = DiagnosticReviewBackground(frame: window.contentView!.bounds)
        super.init(window: window)
        window.delegate = self
        buildView()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(from trace: InputIncidentTrace) {
        guard !closed else { return }
        generation += 1
        let request = generation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HanQ-Review-" + UUID().uuidString)
        trace.prepareExport(to: directory, reviewMetadata: true) { [weak self] result in
            Self.worker.async {
                let loaded: Result<DiagnosticReviewSnapshot, Error>
                do { try result.get(); loaded = .success(try DiagnosticReviewSnapshot(directory: directory)) }
                catch { try? FileManager.default.removeItem(at: directory); loaded = .failure(error) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.generation == request else { return }
                    switch loaded {
                    case .success(let snapshot): self.install(snapshot)
                    case .failure:
                        self.countLabel.stringValue = "기록을 불러오지 못했습니다."
                        self.statusLabel.stringValue = "기록을 안전하게 읽을 수 없습니다. 원본은 유지됩니다. 창을 닫고 다시 시도해 주세요."
                    }
                }
            }
        }
    }
    /// Also used by an isolated UI fixture; no app singleton is needed.
    func install(_ snapshot: DiagnosticReviewSnapshot) {
        guard !closed else { return }
        self.snapshot = snapshot
        selected.removeAll()
        if let first = snapshot.incidents.first { selected = [first.id] }
        countLabel.stringValue = "전체 \(snapshot.incidents.count)건 · 최신순"
        prepareSelection()
        if !snapshot.incidents.isEmpty { recordTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    private func label(_ title: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 12; stack.alignment = .centerY
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    private func scrollView(document: NSView) -> NSScrollView {
        let scroll = DiagnosticReviewScrollView()
        scroll.wantsLayer = true; scroll.borderType = .noBorder
        scroll.documentView = document; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }
    private func cell(_ view: NSView, centered: Bool = false) -> NSView {
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        if let field = view as? NSTextField {
            cell.textField = field
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        view.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        if centered {
            view.centerXAnchor.constraint(equalTo: cell.centerXAnchor).isActive = true
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                view.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10)])
        }
        return cell
    }
    private func configure(_ table: NSTableView, columns: [(String, String, CGFloat)]) -> NSScrollView {
        table.delegate = self; table.dataSource = self; table.headerView = NSTableHeaderView()
        table.rowHeight = 40; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.headerCell = DiagnosticReviewHeaderCell(textCell: title)
            column.width = width; column.minWidth = width
            column.resizingMask = id == "title" || id == "file" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        return scrollView(document: table)
    }
    private func buildView() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 28)])
        let logo = NSImageView()
        logo.imageScaling = .scaleProportionallyUpOrDown
        if let url = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png") { logo.image = NSImage(contentsOf: url) }
        logo.setAccessibilityLabel("한Q 로고")
        let title = label("진단 기록 내보내기", size: 19); title.font = .systemFont(ofSize: 19, weight: .semibold)
        let subtitle = label("내보낼 기록을 선택하고 내용을 확인하세요.", size: 12)
        subtitle.textColor = .secondaryLabelColor
        let headingText = NSStackView(views: [title, subtitle])
        headingText.orientation = .vertical; headingText.alignment = .leading; headingText.spacing = 8
        let intro = horizontal([logo, headingText]); intro.spacing = 14
        logo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 48).isActive = true
        root.addArrangedSubview(intro); root.setCustomSpacing(20, after: intro)
        countLabel.font = .systemFont(ofSize: 12); countLabel.textColor = .secondaryLabelColor
        countLabel.toolTip = "검토창을 연 시점의 사본입니다. 새 기록은 창을 닫고 다시 열어 확인하세요."
        selectionLabel.font = .systemFont(ofSize: 12)
        selectionLabel.toolTip = "최대 5건까지 선택할 수 있습니다. 같은 사건의 전후 기록은 1건으로 계산합니다."
        let heading = horizontal([label("보관 중인 최근 기록", size: 16, bold: true), spacer(), selectionLabel, countLabel])
        root.addArrangedSubview(heading)
        let records = configure(recordTable, columns: [("check", "", 34), ("date", "저장 시각", 165), ("title", "기록 내용", 515), ("kind", "구분", 70)])
        records.heightAnchor.constraint(equalToConstant: 232).isActive = true
        root.addArrangedSubview(records)
        root.addArrangedSubview(label("미리보기", size: 16, bold: true))

        let filesScroll = configure(fileTable, columns: [("file", "포함 파일", 220)])
        fileTable.headerView = nil
        let left = NSStackView(); left.orientation = .vertical; left.alignment = .leading; left.spacing = 8
        left.addArrangedSubview(label("포함 파일", bold: true))
        left.addArrangedSubview(filesScroll)
        filesScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        left.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let right = NSStackView(); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        previewTitle.identifier = NSUserInterfaceItemIdentifier("diagnosticPreviewTitle")
        previewTitle.font = .systemFont(ofSize: 13, weight: .medium); right.addArrangedSubview(previewTitle)
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let preview = scrollView(document: textView)
        right.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let split = horizontal([left, right]); split.alignment = .top
        // Stack-view hugging must not shrink the preview to the selected title's
        // intrinsic width (particularly the short summary title).
        right.widthAnchor.constraint(equalTo: split.widthAnchor, constant: -262).isActive = true
        previewTitle.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        left.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(split)
        for button in [saveButton, finderButton, feedbackButton, cancelButton] { button.bezelStyle = .rounded; button.target = self }
        saveButton.action = #selector(saveZIP); saveButton.keyEquivalent = "\r"; saveButton.isEnabled = false
        cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        finderButton.action = #selector(reveal); feedbackButton.action = #selector(feedback)
        finderButton.isHidden = true; feedbackButton.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.lineBreakMode = .byTruncatingMiddle
        let footer = horizontal([cancelButton, finderButton, feedbackButton, spacer(), statusLabel, saveButton])
        footer.spacing = 10
        let separator = NSBox(); separator.boxType = .separator
        for view in [separator, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: root.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        for view in [heading, records, split] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === recordTable ? snapshot?.incidents.count ?? 0 : archive?.files.count ?? 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === fileTable {
            guard let files = archive?.files, files.indices.contains(row) else { return nil }
            let field = label(files[row].title); field.toolTip = files[row].path; return cell(field)
        }
        guard let incidents = snapshot?.incidents, incidents.indices.contains(row) else { return nil }
        let incident = incidents[row]
        switch tableColumn?.identifier.rawValue {
        case "check":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRecord(_:)))
            button.tag = row; button.state = selected.contains(incident.id) ? .on : .off
            button.setAccessibilityLabel("\(incident.title) 내보내기 선택")
            button.isEnabled = !saving && (selected.contains(incident.id) || selected.count < DiagnosticReviewSnapshot.selectionLimit)
            if !button.isEnabled && !saving { button.toolTip = DiagnosticReviewError.tooManySelections.localizedDescription }
            return cell(button, centered: true)
        case "date":
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR"); formatter.dateFormat = "MM-dd HH:mm:ss"
            return cell(label(incident.savedAt.map(formatter.string) ?? "저장 시각 미확인"))
        case "kind": return cell(label(incident.manual ? "수동" : "자동"))
        default:
            return cell(label(incident.title + (incident.complete ? "" : " · 전후 기록 일부 없음")))
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === fileTable { showFile() }
    }
    @objc private func toggleRecord(_ sender: NSButton) {
        guard !saving, let incidents = snapshot?.incidents, incidents.indices.contains(sender.tag) else { return }
        let id = incidents[sender.tag].id
        if selected.contains(id) {
            selected.remove(id)
        } else {
            guard selected.count < DiagnosticReviewSnapshot.selectionLimit else { sender.state = .off; return }
            selected.insert(id)
        }
        prepareSelection()
    }
    private func prepareSelection() {
        generation += 1
        let request = generation
        selectionLabel.stringValue = "선택한 기록 \(selected.count)/\(DiagnosticReviewSnapshot.selectionLimit)건"
        recordTable.reloadData()
        archive = nil; savedURL = nil
        finderButton.isHidden = true; feedbackButton.isHidden = true
        saveButton.isEnabled = false; fileTable.reloadData(); textView.string = ""
        previewTitle.stringValue = "미리보기"
        guard let snapshot, !selected.isEmpty else {
            statusLabel.stringValue = snapshot?.incidents.isEmpty == true ? "보관 중인 기록이 없습니다." : "저장할 기록을 하나 이상 선택해 주세요."
            return
        }
        let selection = selected, environment = environment
        statusLabel.stringValue = "선택한 기록의 ZIP을 준비하고 있습니다…"
        Self.worker.async { [weak self] in
            let result = Result { try DiagnosticReviewArchive(files: snapshot.files(selected: selection, environment: environment)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                switch result {
                case .success(let archive):
                    self.archive = archive
                    self.fileTable.reloadData()
                    self.fileTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.showFile()
                    self.saveButton.isEnabled = true
                    self.statusLabel.stringValue = "ZIP · \(ByteCountFormatter.string(fromByteCount: Int64(archive.bytes), countStyle: .file))"
                case .failure:
                    self.statusLabel.stringValue = "ZIP을 준비하지 못했습니다. 선택을 바꾸거나 창을 다시 열어 주세요."
                }
            }
        }
    }
    private func showFile() {
        guard let files = archive?.files, files.indices.contains(fileTable.selectedRow) else { return }
        let file = files[fileTable.selectedRow]
        previewTitle.stringValue = file.title
        let value = NSMutableAttributedString(string: file.readableText, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let paragraphs = NSMutableParagraphStyle(); paragraphs.lineSpacing = 5; paragraphs.paragraphSpacing = 4
        value.addAttribute(.paragraphStyle, value: paragraphs, range: NSRange(location: 0, length: value.length))
        if let document = file.previewDocument {
            for title in [document.title] + document.sections.map(\.title) {
                let range = (value.string as NSString).range(of: title)
                if range.location != NSNotFound { value.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: range) }
            }
        }
        textView.textStorage?.setAttributedString(value)
        textView.scrollToBeginningOfDocument(nil)
    }
    @objc private func saveZIP() {
        guard let archive, let window, !saving else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "HanQ-Diagnostics-" + formatter.string(from: Date()) + ".zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.saving = true; self.saveButton.isEnabled = false; self.recordTable.reloadData()
            self.statusLabel.stringValue = "ZIP을 저장하고 있습니다…"
            Self.worker.async { [weak self] in
                let result = Result { try archive.save(to: destination) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.saving = false; self.saveButton.isEnabled = true; self.recordTable.reloadData()
                    switch result {
                    case .success:
                        self.savedURL = destination
                        self.statusLabel.stringValue = "ZIP을 저장했습니다. 피드백 폼에 직접 첨부해 주세요."
                        self.finderButton.isHidden = false; self.feedbackButton.isHidden = false
                    case .failure:
                        self.statusLabel.stringValue = "ZIP을 저장하지 못했습니다. 다른 위치에 다시 저장해 주세요."
                    }
                }
            }
        }
    }
    @objc private func cancel() { if !saving { close() } }
    @objc private func reveal() { if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) } }
    @objc private func feedback() { onFeedback?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !saving }
    func windowWillClose(_ notification: Notification) {
        closed = true
        generation += 1; archive = nil; snapshot = nil; onClose?()
    }
}
