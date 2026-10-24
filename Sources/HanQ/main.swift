import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let updater = AppUpdater()
    var updateRestricted = false
    let jamoRepair = JamoRepair()
    lazy var onsetRecovery: OnsetRecoveryController = {
        let controller = OnsetRecoveryController()
        controller.canRun = { [weak self] in
            guard let self else { return false }
            return self.enabled && self.permissionGranted && !self.updateRestricted && self.tap != nil
        }
        controller.canBeginRepair = { [weak self] in
            guard let self else { return false }
            return !self.jamoRepair.isEditing && !self.externalKeyboards.isCapturing && !self.mismatchRecovery.busy && !self.sourceSwitchBarrier.busy
        }
        controller.willBeginRepair = { [weak self] in
            self?.sourceSwitchBarrier.resetObservation()
            self?.mismatchRecovery.engine.cancelDetection()
            self?.jamoRepair.inputDidChange()
        }
        controller.willReplay = { [weak self] field,text,caret in
            self?.sourceSwitchBarrier.beginOnsetReplay(field:field,before:text,caret:caret)
        }
        controller.didPostReplayEvent = { [weak self] event in
            self?.sourceSwitchBarrier.observe(event.type,event)
        }
        controller.didProcessPhysicalKey = { [weak self] event,passed in
            self?.sourceSwitchBarrier.confirmOnsetDelivery(event,passed:passed)
        }
        return controller
    }()
    lazy var mismatchRecovery: MismatchRecoveryController = {
        let controller=MismatchRecoveryController()
        controller.engine.sourceEvidence=self.inputSourceEvidence
        controller.canRun = { [weak self] in
            guard let self else{return false}
            return self.enabled && self.permissionGranted && !self.updateRestricted && self.tap != nil
        }
        controller.engine.didStart = { [weak self] in self?.refreshInputDeliveryOrigin() }
        controller.engine.verifiedDeliveryHistory = { [weak self] snap,allowPrior in
            guard let self else{return nil}
            return self.sourceSwitchBarrier.verifiedTwoSetHistory(snap,after:self.mismatchRecovery.engine.lastUserSourceSwitchTimestamp,allowPrior:allowPrior)
        }
        controller.engine.canToggleRightCommand = { [weak self] in
            guard let self else{return false}
            let busy=self.sourceSwitchBarrier.busy
            if !self.koreanEnabled{self.mismatchRecovery.engine.switchGate?.acceptanceReason=9}
            else if busy{self.mismatchRecovery.engine.switchGate?.acceptanceReason=10}
            return self.koreanEnabled && !busy
        }
        controller.engine.canObserve = { [weak self] in
            guard let self else{return false}
            if self.jamoRepair.isEditing {InputIncidentTrace.shared.decision(.eligibility,.manualEdit);return false}
            if self.externalKeyboards.isCapturing {InputIncidentTrace.shared.decision(.eligibility,.keyboardCapture);return false}
            if self.onsetRecovery.engine?.recovering == true {InputIncidentTrace.shared.decision(.eligibility,.onsetRepair);return false}
            if self.onsetRecovery.engine?.gate?.reservation() != nil {InputIncidentTrace.shared.decision(.eligibility,.onsetReservation);return false}
            InputIncidentTrace.shared.decision(.eligibility,.observationAllowed)
            return true
        }
        controller.engine.canBeginRepair = { [weak self] in
            guard let self else{return false}
            return !self.jamoRepair.isEditing && !self.externalKeyboards.isCapturing && self.onsetRecovery.prepareManualEdit()
        }
        controller.engine.willBeginRepair = { [weak self] in
            self?.sourceSwitchBarrier.noteExternalEdit()
            self?.jamoRepair.inputDidChange()
        }
        controller.engine.didVerifyReplay = { [weak self] ledger,snap in
            self?.sourceSwitchBarrier.adoptVerifiedReplay(ledger,snapshot:snap)
        }
        controller.engine.didProcessEvent = { [weak self] type,event,passed in
            self?.sourceSwitchBarrier.confirmDelivery(type,event,passed:passed)
        }
        controller.engine.willForwardEvent = { [weak self] type,event in
            self?.sourceSwitchBarrier.beginRepairBoundary(type,event)
        }
        controller.engine.didRetainInput = { [weak self] in
            DispatchQueue.main.async{self?.refreshStatus()}
        }
        return controller
    }()
    lazy var externalKeyboards: ExternalKeyboardController = {
        let controller = ExternalKeyboardController()
        controller.canConfigure = { [weak self] in
            guard let self else { return false }
            return self.permissionGranted && !self.updateRestricted && self.tap != nil && self.enabled
                && !self.filter.consuming && !self.optionFilter.consuming && !self.mismatchRecovery.busy
        }
        controller.onBeginCapture = { [weak self] in self?.jamoRepair.inputDidChange() }
        return controller
    }()
    let inputSourceEvidence=MismatchSourceEvidence()
    let hud = HUDController()
    let inputSource = InputSourceObserver()
    let selectionSourceSwitch: SelectionPreservingSourceSwitch = {
        let controller = SelectionPreservingSourceSwitch()
        controller.trace = { stage in InputDiagnostics.shared.record("switch.selection.stage=\(stage.rawValue)") }
        return controller
    }()
    lazy var sourceSwitchBarrier: SourceSwitchBarrier = {
        let barrier=SourceSwitchBarrier()
        barrier.sourceEvidence=self.inputSourceEvidence
        barrier.didConfirmSource = { [weak self] id,timestamp in
            guard let self else{return}
            self.inputSourceEvidence.didCommit(id,at:timestamp)
            InputIncidentTrace.shared.sourceEvidence(.committed,self.inputSourceEvidence.diagnostic(selected:id))
        }
        barrier.read = { [weak self] in
            guard let self,self.permissionGranted,!self.updateRestricted,!IsSecureEventInputEnabled() else{return nil}
            self.mismatchRecovery.engine.followFrontmost()
            guard let snap=self.mismatchRecovery.engine.snapshot(allowComboBox:true) else{return nil}
            return SourceSwitchBarrier.Snapshot(field:snap.element,text:snap.text,selection:snap.selection)
        }
        barrier.ready = { [weak self] in
            guard let self else{return false}
            return !self.mismatchRecovery.busy && self.onsetRecovery.engine?.recovering != true && self.onsetRecovery.engine?.gate?.reservation() == nil
        }
        barrier.readFocus = { [weak self] in
            guard let self,self.permissionGranted,!self.updateRestricted,!IsSecureEventInputEnabled() else{return nil}
            let access=self.mismatchRecovery.engine.focusAccess
            return access.read(access.system)
        }
        barrier.select = { [weak self] target in self?.selectionSourceSwitch.select(target,asynchronous:true) ?? -50 }
        barrier.selectionPending = { [weak self] in self?.selectionSourceSwitch.isPending ?? false }
        barrier.cancelSelection = { [weak self] in self?.selectionSourceSwitch.cancelPending() }
        barrier.didSelect = { [weak self] timestamp in
            self?.mismatchRecovery.engine.noteUserSourceSwitch(at:timestamp)
        }
        barrier.commitSelection = { [weak self] snap in
            self?.selectionSourceSwitch.commitSelection(field:snap.field,text:snap.text,range:snap.selection,asynchronous:true) ?? -50
        }
        barrier.retained = { [weak self] events in
            guard let self else{return}
            InputIncidentTrace.shared.sourceBoundary(.retained,queued:events.count,awaitingOnset:0)
            self.settleRetainedModifierState(events)
            self.mismatchRecovery.engine.retained.append(contentsOf:events)
            self.refreshStatus()
        }
        barrier.cancelledModifiers = { [weak self] events in
            self?.settleRetainedModifierState(events)
        }
        barrier.trace = { [weak barrier] stage in
            InputDiagnostics.shared.record("switch.barrier."+stage)
            if InputIncidentTrace.shared.enabled,let kind=InputIncidentTrace.BoundaryStage.event(stage),let counts=barrier?.diagnosticCounts {
                InputIncidentTrace.shared.sourceBoundary(kind,queued:counts.queued,awaitingOnset:counts.awaitingOnset)
            }
        }
        return barrier
    }()
    // The failed queue will not be replayed. Settle only state from edges we
    // actually observed, with actions disabled, so a queued release cannot
    // leave the default or per-device key filter owning the next press.
    func settleRetainedModifierState(_ events:[CGEvent]) {
        for event in events {
            let external=externalKeyboards.process(type:event.type,event:event,active:false,
                koreanAllowed:false,hanjaAllowed:false)
            let key=external.handled ? Int64(-1):event.getIntegerValueField(.keyboardEventKeycode)
            let command=filter.process(type:event.type,key:key,flags:external.flags,acceptNewPress:false)
            _=optionFilter.process(type:event.type,key:key,flags:command.flags,acceptNewPress:false)
        }
    }
    var sourceObservations = 0
    var diagnosticEventCount = 0
    var window: NSWindow!
    var permissionContent: NSView!
    var permissionTimer: Timer?
    var safetyPulseTimer: Timer?
    let inputSafety = InputSafetyWatchdog()
    let permissionRecovery = PermissionRecovery()
    lazy var freshPermission = FreshPermissionMonitor { [weak self] reason in
        NSLog("입력 안전 종료: 새 프로세스 권한 검사 (%@)", reason)
        if reason == "permission-denied" { self?.permissionRecovery.exitAfterPermissionLoss() }
        _exit(72)
    }
    var permissionGranted = false
    var pendingActivation = true
    private(set) var inputInterruption: InputMonitoringInterruption?
    let inputMonitoringNotice = InputMonitoringNotice()
    let status = NSTextField(wrappingLabelWithString: "한영키·한자키 꺼짐")
    var tap: CFMachPort?
    var inputDeliveryOrigin: InputDeliveryOrigin?
    var tapSource: CFRunLoopSource?
    var optionFilter = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
    var filter = CommandFilter()
    var enabled = false
    var koreanEnabled = false
    var hanjaEnabled = false
    let statusIcon = StatusItemController()
    lazy var statusReopenNotice = MenuBarRecoveryNotice { [weak self] in self?.openFeedback() }
    let toggleItem = NSMenuItem(title: "한영키 사용", action: #selector(toggleKorean), keyEquivalent: "")
    let hanjaItem = NSMenuItem(title: "한자키 사용", action: #selector(toggleHanja), keyEquivalent: "")
    let capsItem = NSMenuItem(title: "한/A (Caps Lock) 키로 입력 소스 전환", action: #selector(toggleCaps), keyEquivalent: "")
    let retainedMismatchItem = NSMenuItem(title:"복구 중 보관된 입력 복사", action:#selector(copyMismatchInput), keyEquivalent:"")
    let hudItem = NSMenuItem(title: "입력 소스 변경 시 화면에 표시", action: #selector(toggleHUD), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    let inputDiagnosticsItem = NSMenuItem(title:"진단 기록 활성화",action:#selector(toggleInputDiagnostics),keyEquivalent:"")
    let inputIncidentItem = NSMenuItem(title:"방금 발생한 문제 기록",action:#selector(markInputIncident),keyEquivalent:"")
    let inputDiagnosticExportItem = NSMenuItem(title:"진단 기록 내보내기…",action:#selector(exportInputDiagnostics),keyEquivalent:"")
    private var changingInputDiagnostics=false
    private var diagnosticReview:DiagnosticReviewController?
    private var hasDiagnosticLogs=false
    let menuStatus = NSMenuItem(title: "준비 중", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.shared.start()
        InputIncidentTrace.shared.start()
        KeyboardStateMirror.shared.diagnosticBoundary={type,event,consumed in
            InputIncidentTrace.shared.event(.boundary,type,event,consumed:consumed)
        }
        permissionRecovery.prepare()
        let preferences = UserDefaults.standard
        // Only initialize once, so disabling in macOS Settings is respected too.
        if !preferences.bool(forKey: "didInitializeLaunchAtLogin") {
            if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                do { try SMAppService.mainApp.register() }
                catch { NSLog("자동 실행 초기 설정 실패: %@", error.localizedDescription) }
            }
            let loginStatus = SMAppService.mainApp.status
            if loginStatus == .enabled || loginStatus == .requiresApproval {
                preferences.set(true, forKey: "didInitializeLaunchAtLogin")
            }
        }
        // Preserve the macOS Caps Lock setting, including on first launch.
        // Discard any pending automatic enable left by an older build.
        preferences.removeObject(forKey: "pendingInitialRomanSwitchEnable")
        preferences.removeObject(forKey: "mismatchRecoveryEnabled")
        UserDefaults.standard.register(defaults: ["hudEnabled": true])
        for key in ["koreanKeyEnabled", "hanjaKeyEnabled"] where UserDefaults.standard.object(forKey:key) == nil {
            UserDefaults.standard.set(true, forKey:key)
        }
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        capsItem.toolTip = "시스템 설정에 반영되며, 한Q를 종료해도 유지됩니다."
        menuStatus.isEnabled = false
        statusMenu.addItem(menuStatus)
        statusMenu.addItem(externalKeyboards.menuSeparator)
        statusMenu.addItem(externalKeyboards.menuItem)
        statusMenu.addItem(.separator())
        toggleItem.target = self; statusMenu.addItem(toggleItem)
        capsItem.target = self; capsItem.indentationLevel = 1; statusMenu.addItem(capsItem)
        hanjaItem.target = self; statusMenu.addItem(hanjaItem)
        retainedMismatchItem.target=self;statusMenu.addItem(retainedMismatchItem)
        statusMenu.addItem(.separator())
        hudItem.target = self; hudItem.state = UserDefaults.standard.bool(forKey: "hudEnabled") ? .on : .off
        statusMenu.addItem(hudItem)
        loginItem.target = self
        statusMenu.addItem(loginItem)
        statusMenu.addItem(updater.automaticItem)
        refreshLaunchAtLogin()
        statusMenu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "한Q 정보", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        statusMenu.addItem(aboutItem)
        statusMenu.addItem(updater.checkItem)
        statusMenu.addItem(makeFeedbackItem())
        statusMenu.addItem(.separator())
        let diagnostics=NSMenu(title:"진단 및 로그")
        diagnostics.autoenablesItems=false
        let diagnosticsItem=NSMenuItem(title:"진단 및 로그",action:nil,keyEquivalent:"")
        diagnosticsItem.submenu=diagnostics
        inputDiagnosticsItem.target=self
        inputDiagnosticsItem.toolTip="재실행·재부팅 후에도 설정을 유지합니다. 끄면 수집을 중단하고 기존 기록은 보존합니다."
        inputIncidentItem.target=self
        inputIncidentItem.attributedTitle=NSAttributedString(string:inputIncidentItem.title,attributes:[.font:NSFont.boldSystemFont(ofSize:NSFont.systemFontSize)])
        inputIncidentItem.toolTip="최근 입력 처리 상태를 로컬에 저장합니다. 입력 본문·키 값·클립보드는 저장하지 않습니다."
        inputDiagnosticExportItem.target=self
        inputDiagnosticExportItem.toolTip="보관 중인 최근 기록을 선택하고 파일 미리보기를 확인한 뒤 ZIP 파일로 저장합니다."
        diagnostics.addItem(inputDiagnosticsItem)
        diagnostics.addItem(.separator())
        diagnostics.addItem(inputIncidentItem)
        diagnostics.addItem(inputDiagnosticExportItem)
        statusMenu.addItem(diagnosticsItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "한Q 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusIcon.onRepeatedUserLaunch = { [weak self] in self?.statusReopenNotice.show() }
        statusIcon.start(menu: statusMenu)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let appAboutItem = NSMenuItem(title: "한Q 정보", action: #selector(showAbout), keyEquivalent: "")
        appAboutItem.target = self
        appMenu.addItem(appAboutItem)
        appMenu.addItem(makeFeedbackItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "한Q 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "편집"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "한Q 시작하기"
        window.isReleasedWhenClosed = false
        buildPermissionView()
        inputSource.onObservation = { [weak self] snapshot in
            guard let self,!self.mismatchRecovery.engine.recovering else{return}
            let id=snapshot?.id ?? "unknown"
            if self.inputSourceEvidence.observe(id) {
                InputIncidentTrace.shared.sourceEvidence(.observed,self.inputSourceEvidence.diagnostic(selected:id))
            }
        }
        inputSource.onChange = { [weak self] snapshot in
            guard let self else { return }
            if let snapshot{self.mismatchRecovery.engine.observeRecoverySource(snapshot.id)}
            self.jamoRepair.inputSourceDidChange()
            self.sourceObservations += 1
            if self.permissionGranted && !self.updateRestricted && self.sourceObservations > 1 && UserDefaults.standard.bool(forKey: "hudEnabled") { self.hud.show(name: snapshot?.name,sourceClass:KoreanEnglishSwitch.sourceClass(snapshot)) }
            else {InputIncidentTrace.shared.hud(.suppressed,sourceClass:KoreanEnglishSwitch.sourceClass(snapshot))}
        }
        jamoRepair.beginTextEdit = { [weak self] field,source in
            self?.sourceSwitchBarrier.beginManualEdit(field:field,source:source)
        }
        jamoRepair.endTextEdit = { [weak self] token,field,text,range in
            let snapshot=text.flatMap{value in range.map{SourceSwitchBarrier.Snapshot(field:field,text:value,selection:$0)}}
            self?.sourceSwitchBarrier.finishManualEdit(token,snapshot:snapshot)
        }
        jamoRepair.canBeginEdit = { [weak self] in
            guard let self else{return false}
            return self.mismatchRecovery.prepareManualEdit() && self.onsetRecovery.prepareManualEdit()
        }
        inputSource.start()
        mismatchRecovery.engine.capsSwitchEnabled = { (try? RomanSwitchController.isEnabled()) == true }
        window.center()
        let pulse = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.inputSafety.pulse()
            InputDiagnostics.shared.record("main.pulse tap=\(self.tap != nil) enabled=\(self.enabled) cachedAX=\(self.permissionGranted) events=\(self.diagnosticEventCount) mismatchEnabled=\(self.mismatchRecovery.engine.enabled) mismatchSuspended=\(self.mismatchRecovery.engine.suspended) mismatchRecovering=\(self.mismatchRecovery.engine.recovering) mismatchTap=\(self.mismatchRecovery.engine.tap != nil) mismatchSwitchTap=\(self.mismatchRecovery.engine.switchGate?.tap != nil) sourceKind=\(KoreanKeyboardLayout.supportedIDs.firstIndex(of:InputSourceAccess.currentID()).map{$0+1} ?? 0)")
        }
        safetyPulseTimer = pulse
        RunLoop.main.add(pulse, forMode: .common)
        updatePermission()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updatePermission() }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        showWindow()
        if !permissionGranted { requestAccessibility() }
        updater.onRestrictionChange = { [weak self] restricted in self?.setUpdateRestricted(restricted) }
        updater.start()
        #if HANQ_DEVELOPMENT
        showDevelopmentTestPanels()
        #endif
    }

    func buildPermissionView() {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(panel)
        permissionContent = panel
        let badge: NSView
        if let logoURL = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            let logo = NSImageView(image: logoImage)
            logo.imageScaling = .scaleProportionallyUpOrDown
            logo.translatesAutoresizingMaskIntoConstraints = false
            logo.setAccessibilityLabel("한Q 로고")
            NSLayoutConstraint.activate([
                logo.widthAnchor.constraint(equalToConstant: 120),
                logo.heightAnchor.constraint(equalToConstant: 120 * 704 / 920)
            ])
            badge = logo
        } else {
            let fallback = NSTextField(labelWithString: "한Q")
            fallback.font = .systemFont(ofSize: 46, weight: .bold)
            fallback.textColor = .controlAccentColor
            badge = fallback
        }
        let title = NSTextField(labelWithString: "한Q를 시작할 준비가 됐어요")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "어느 앱에서나 한영키와 한자키를 사용하려면\n손쉬운 사용 권한이 필요해요.")
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let steps = NSTextField(wrappingLabelWithString: "시스템 설정에서 ‘한Q’ 또는 ‘HanQ’를 켜주세요.\n목록에 없다면 + 버튼으로 이 앱을 추가해주세요.")
        steps.font = .systemFont(ofSize: 13)
        steps.alignment = .center
        let button = NSButton(title: "손쉬운 사용 설정 열기", target: self, action: #selector(openAccessibility))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        let hint = NSTextField(labelWithString: "허용하면 자동으로 시작할게요")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [badge, title, detail, steps, button, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            panel.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            panel.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: panel.widthAnchor, constant: -64)
        ])
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc func openAccessibility() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func updatePermission() {
        InputDiagnostics.shared.record("main.ax.begin")
        let granted = AXIsProcessTrusted()
        InputDiagnostics.shared.record("main.ax.end granted=\(granted)")
        permissionRecovery.observePermission(granted)
        let lostPermission = permissionGranted && !granted
        if lostPermission {
            // Revocation/deletion can wedge WindowServer during tap cleanup.
            // Release the process's ports through process exit, without calling
            // back into CGEventTapEnable or AppKit termination handlers.
            NSLog("입력 안전 종료: 손쉬운 사용 권한 철회 또는 목록 삭제")
            InputDiagnostics.shared.record("exit.permissionLost")
            permissionRecovery.exitAfterPermissionLoss()
        }
        if !granted {
            inputMonitoringNotice.closeNotice()
            if permissionGranted || tap != nil {
                NSLog("입력 감지 해제: 손쉬운 사용 권한 없음")
            }
            stopMapping()
            pendingActivation = true
            hud.hide()
        }
        permissionGranted = granted
        permissionContent.isHidden = granted
        if granted { window.orderOut(nil) }
        if granted && pendingActivation && !updateRestricted {
            let korean = UserDefaults.standard.bool(forKey: "koreanKeyEnabled")
            let hanja = UserDefaults.standard.bool(forKey: "hanjaKeyEnabled")
            if korean || hanja {
                startMapping()
                if enabled {
                    koreanEnabled = korean; hanjaEnabled = hanja
                    pendingActivation = false
                }
            } else { pendingActivation = false }
        }
        refreshStatus()
        externalKeyboards.tick()
    }

    func setUpdateRestricted(_ restricted: Bool) {
        guard updateRestricted != restricted else { return }
        updateRestricted = restricted
        if restricted {
            inputMonitoringNotice.closeNotice()
            pendingActivation = false
            stopMapping()
            hud.hide()
        } else {
            pendingActivation = true
            updatePermission()
        }
        refreshStatus()
    }

    func switchInputSource(to target: String, at timestamp: CGEventTimestamp = 0) -> OSStatus {
        // The HID gate normally owns these presses. If another event source
        // bypasses that gate, the primary tap must still use the user's intended
        // boundary, not toggle from recovery's temporary English source.
        if mismatchRecovery.busy {
            var evidence=InputIncidentControl();evidence.route=InputIncidentControl.Route.recoveryRedirect.rawValue;evidence.runtime=64
            InputIncidentTrace.shared.control(.main,.flagsChanged,nil,evidence)
            mismatchRecovery.engine.userToggleDuringRecovery(at: timestamp)
            return noErr
        }
        // Requesting a boundary does not change the source yet. Keep the
        // preceding candidate alive until the barrier verifies its repair.
        inputSourceEvidence.request(target,at:timestamp)
        InputIncidentTrace.shared.sourceEvidence(.requested,inputSourceEvidence.diagnostic(selected:InputSourceAccess.currentID()))
        if sourceSwitchBarrier.request(target,at:timestamp) { return noErr }
        mismatchRecovery.engine.noteUserSourceSwitch(at: timestamp)
        let result=selectionSourceSwitch.select(target)
        if result==noErr,!selectionSourceSwitch.isPending,InputSourceAccess.currentID()==target {
            inputSourceEvidence.didCommit(target,at:timestamp)
            InputIncidentTrace.shared.sourceEvidence(.committed,inputSourceEvidence.diagnostic(selected:target))
        }
        return result
    }

    @objc func startMapping() {
        guard !updateRestricted else { return }
        guard !filter.consuming && !optionFilter.consuming && !externalKeyboards.consuming else { status.stringValue = "누른 한영키와 한자키를 놓은 뒤 다시 시작하세요."; return }
        guard !CGEventSource.keyState(.combinedSessionState, key: 54) && !CGEventSource.keyState(.combinedSessionState, key: 61) else {
            status.stringValue = "우측 Command와 Option을 놓은 뒤 시작하세요."; return
        }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            status.stringValue = "손쉬운 사용에서 ‘한Q’를 허용한 뒤 원하는 키를 다시 켜세요."
            return
        }
        if tap == nil {
            KeyboardStateMirror.shared.failed = { [weak self] in self?.stopMapping() }
            guard KeyboardStateMirror.shared.start() else {
                status.stringValue = "키 상태 감지 시작 실패 — 손쉬운 사용 권한을 확인하세요."; return
            }
            let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            let callback: CGEventTapCallBack = { proxy, type, event, context in
                let incidentStart=InputIncidentTrace.shared.beginCallback(type)
                let owner = Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue()
                var control=InputIncidentControl.begin(.shared,type,event)
                control?.runtime=(owner.enabled ? 1:0) | (owner.permissionGranted ? 2:0) | (owner.updateRestricted ? 4:0) | (owner.koreanEnabled ? 8:0) | (owner.hanjaEnabled ? 16:0) | (owner.sourceSwitchBarrier.busy ? 32:0) | (owner.mismatchRecovery.busy ? 64:0)
                func process() -> Unmanaged<CGEvent>? {
                    owner.diagnosticEventCount += 1
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        control?.route=InputIncidentControl.Route.tapDisabled.rawValue
                        // Never re-enable a tap that macOS disabled. Release the input
                        // path before doing UI or permission work on the main run loop.
                        InputDiagnostics.shared.record("tap.disabled type=\(type.rawValue)")
                        owner.enabled = false
                        owner.koreanEnabled = false
                        owner.hanjaEnabled = false
                        owner.pendingActivation = false
                        NSLog("입력 감지 중단: %u; 콜백 반환 후 해제", type.rawValue)
                        let stoppedTap = owner.tap
                        DispatchQueue.main.async {
                            // Ignore a queued notification from a replaced tap.
                            guard let stoppedTap, owner.tap === stoppedTap else { return }
                            owner.stopMapping()
                            owner.updatePermission()
                            if let reason = InputMonitoringInterruption(eventType: type) {
                                owner.noteInputInterruption(reason)
                            }
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    guard owner.permissionGranted && !owner.updateRestricted else {
                        control?.route=(owner.updateRestricted ? InputIncidentControl.Route.updateRestricted: .permissionDenied).rawValue
                        owner.enabled = false
                        DispatchQueue.main.async { owner.stopMapping() }
                        return Unmanaged.passUnretained(event)
                    }
                    if event.getIntegerValueField(.eventSourceUserData) == SyntheticInputMarker.manualEdit || OnsetInputGate.isRecoveryMarker(event.getIntegerValueField(.eventSourceUserData)) {
                        control?.route=(event.getIntegerValueField(.eventSourceUserData)==SyntheticInputMarker.manualEdit ? InputIncidentControl.Route.manualMarker:.replayMarker).rawValue
                        return Unmanaged.passUnretained(event)
                    }
                    let originalRecipient=owner.inputDeliveryOrigin?.take(type,event)
                    func forwardOriginalIfMoved()->Bool {
                        guard let routing=owner.inputDeliveryOrigin else{return false}
                        let token=event.getIntegerValueField(.eventSourceUserData)
                        guard routing.forwardIfMoved(event,origin:originalRecipient) else{return false}
                        owner.onsetRecovery.engine?.cancelDeferredObservation()
                        owner.mismatchRecovery.engine.discardEventOrigin(token)
                        if owner.sourceSwitchBarrier.busy {owner.sourceSwitchBarrier.fail("recipient_changed")}
                        else {owner.sourceSwitchBarrier.resetObservation()}
                        if !owner.mismatchRecovery.busy {owner.mismatchRecovery.engine.cancelDetection()}
                        InputDiagnostics.shared.record("input.original_recipient_preserved")
                        return true
                    }
                    if forwardOriginalIfMoved(){control?.route=InputIncidentControl.Route.recipientMovedEarly.rawValue;return nil}
                    switch owner.jamoRepair.receiveCandidates(type, event) {
                    case .consumed: control?.route=InputIncidentControl.Route.candidateConsumed.rawValue;return nil
                    case .panelMouse: control?.route=InputIncidentControl.Route.candidatePanel.rawValue;return Unmanaged.passUnretained(event)
                    case .normal: break
                    }
                    if !owner.sourceSwitchBarrier.busy {
                        owner.onsetRecovery.engine?.observeDeferredBeforeInput(type,event)
                    }else{owner.onsetRecovery.engine?.cancelDeferredObservation()}
                    if owner.sourceSwitchBarrier.receive(type,event) {control?.route=InputIncidentControl.Route.barrierQueued.rawValue;return nil}
                    if [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                        owner.jamoRepair.inputDidChange(type: type, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
                    }
                    let active = owner.enabled && !IsSecureEventInputEnabled()
                    let key = event.getIntegerValueField(.keyboardEventKeycode)
                    let externalQueryBegan=InputIncidentTrace.shared.enabled ? ProcessInfo.processInfo.systemUptime:0
                    let externalQueried=owner.externalKeyboards.wantsInputSource(type:type,event:event)
                    let snapshot = externalQueried ? InputSourceSnapshot.read():nil
                    let externalResolution = active && owner.koreanEnabled && snapshot != nil ? KoreanEnglishSwitch.targetResolution(for:snapshot):nil
                    let externalTarget=externalResolution?.target
                    let external = owner.externalKeyboards.process(type: type, event: event, active: active,
                        koreanAllowed: externalTarget != nil, hanjaAllowed: owner.hanjaEnabled)
                    if control == nil,InputIncidentTrace.shared.enabled,!IsSecureEventInputEnabled(),external.diagnosticRole>0 {
                        control=InputIncidentControl();control?.role=external.diagnosticRole
                        control?.eventType=type == .flagsChanged ? 1:(type == .keyDown ? 2:3)
                        control?.runtime=(owner.enabled ? 1:0) | (owner.permissionGranted ? 2:0) | (owner.koreanEnabled ? 8:0) | (owner.hanjaEnabled ? 16:0) | (owner.sourceSwitchBarrier.busy ? 32:0) | (owner.mismatchRecovery.busy ? 64:0)
                    }
                    if external.diagnosticRole>0 {
                        control?.role=external.diagnosticRole;control?.incomingFlags=0
                        control?.filterMeasured=true;control?.filterBefore=external.diagnosticBefore;control?.filterAfter=external.diagnosticAfter
                        control?.filterAccepted=external.diagnosticAccepted;control?.filterEdge=external.diagnosticEdge
                        control?.filterConsumed=external.consume;control?.filterReason=external.diagnosticReason
                    }
                    control?.externalDevice=external.diagnosticDevice;control?.externalHandling=external.diagnosticHandling;control?.externalRole=external.diagnosticRole
                    if let resolution=externalResolution {
                        control?.query(site:2,status:resolution.status,current:resolution.currentClass,target:resolution.targetClass,available:resolution.availableCount,korean:resolution.koreanCount,english:resolution.englishCount,began:externalQueryBegan)
                    } else if externalQueried {
                        control?.query(site:2,status:snapshot==nil ? 1:5,current:KoreanEnglishSwitch.sourceClass(snapshot),began:externalQueryBegan)
                    }
                    if external.korean, let externalTarget {
                        let selection = owner.switchInputSource(to: externalTarget, at: owner.mismatchRecovery.engine.takeSourceSwitchTimestamp(type,event))
                        DispatchQueue.main.async {
                            owner.inputSource.refresh()
                            if selection != 0 { NSLog("입력 소스 전환 실패: %d", selection) }
                        }
                    }
                    if external.hanja {
                        owner.jamoRepair.request(allowHanja: snapshot.map {
                            $0.isKorean && $0.id.hasPrefix("com.apple.inputmethod.Korean.")
                        } == true)
                    }
                    if external.consume {control?.route=InputIncidentControl.Route.externalConsumed.rawValue;return nil}
                    event.flags = external.flags
                    let legacyKey = external.handled ? Int64(-1) : key
                    var target:String?
                    if active && !external.handled && owner.koreanEnabled && type == .flagsChanged && key == 54 {
                        let began=control == nil ? 0:ProcessInfo.processInfo.systemUptime
                        let resolution=KoreanEnglishSwitch.targetResolution(for:InputSourceSnapshot.read());target=resolution.target
                        control?.query(site:1,status:resolution.status,current:resolution.currentClass,target:resolution.targetClass,available:resolution.availableCount,korean:resolution.koreanCount,english:resolution.englishCount,began:began)
                    }
                    let commandBefore=owner.filter.diagnosticState,commandFlags=event.flags
                    let result = owner.filter.process(type: type,
                        key: legacyKey,
                        flags: event.flags, acceptNewPress: active && target != nil)
                    if control?.role==1 {
                        control?.filter(before:commandBefore,after:owner.filter.diagnosticState,flags:commandFlags,accepted:active && target != nil,edge:result.edge,consumed:result.consume,matching:type == .flagsChanged && legacyKey==54)
                    }
                    if let edge = result.edge {
                        if edge == "right-down" {
                            if let target {
                                let result = owner.switchInputSource(to: target, at: owner.mismatchRecovery.engine.takeSourceSwitchTimestamp(type,event))
                                DispatchQueue.main.async {
                                    owner.inputSource.refresh()
                                    if result != 0 { NSLog("입력 소스 전환 실패: %d", result) }
                                }
                            }
                        }
                        owner.refreshStatus()
                    }
                    var isKorean=false
                    if active && !external.handled && owner.hanjaEnabled && type == .flagsChanged && key == 61 {
                        let began=control == nil ? 0:ProcessInfo.processInfo.systemUptime
                        let source=InputSourceSnapshot.read()
                        isKorean=source.map{$0.isKorean && $0.id.hasPrefix("com.apple.inputmethod.Korean.")} == true
                        control?.query(site:3,status:source==nil ? 1:5,current:KoreanEnglishSwitch.sourceClass(source),began:began)
                    }
                    let optionBefore=owner.optionFilter.diagnosticState
                    let option = owner.optionFilter.process(type: type, key: legacyKey,
                        flags: result.flags, acceptNewPress: active && !external.handled && owner.hanjaEnabled && result.flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty)
                    if control?.role==2 {
                        control?.filter(before:optionBefore,after:owner.optionFilter.diagnosticState,flags:result.flags,accepted:active && !external.handled && owner.hanjaEnabled && result.flags.intersection([.maskCommand,.maskControl,.maskShift]).isEmpty,edge:option.edge,consumed:option.consume,matching:type == .flagsChanged && legacyKey==61)
                    }
                    if option.edge == "right-up", active && owner.hanjaEnabled {
                        owner.jamoRepair.request(allowHanja: isKorean)
                    }
                    if result.consume || option.consume {control?.route=InputIncidentControl.Route.filterConsumed.rawValue;return nil}
                    event.flags = option.flags
                    owner.sourceSwitchBarrier.observeBeforeOnset(type,event,waiting:
                        owner.onsetRecovery.engine?.gate?.hasActiveReplayHold() == true)
                    if forwardOriginalIfMoved(){control?.route=InputIncidentControl.Route.recipientMovedLate.rawValue;return nil}
                    return Unmanaged.passUnretained(event)
                }
                var processed=false
                let preserved=KeyboardStateMirror.shared.preserve(type,event) {
                    processed=true
                    let began=InputIncidentTrace.shared.enabled ? ProcessInfo.processInfo.systemUptime:nil
                    let result=process()
                    if let control{InputIncidentTrace.shared.control(.main,type,event,control,consumed:result==nil)}
                    if let began{InputIncidentTrace.shared.event(.main,type,event,consumed:result==nil,duration:ProcessInfo.processInfo.systemUptime-began,started:incidentStart)}
                    return result
                }
                if !processed,var value=control {
                    value.route=(KeyboardStateMirror.isMarker(event.getIntegerValueField(.eventSourceUserData)) ? InputIncidentControl.Route.mirrorMarker:.mirrorInactive).rawValue
                    InputIncidentTrace.shared.control(.main,type,event,value)
                }
                return preserved
            }
            inputSafety.arm()
            InputDiagnostics.shared.record("tap.create.begin")
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            InputDiagnostics.shared.record("tap.create.end present=\(tap != nil)")
            guard let tap else {
                KeyboardStateMirror.shared.stop()
                inputSafety.disarm()
                status.stringValue = "감지 시작 실패 — 손쉬운 사용 권한을 확인하세요."
                return
            }
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource!, .commonModes)
            freshPermission.start()
        }
        enabled = true
        externalKeyboards.start()
        onsetRecovery.start()
        mismatchRecovery.start()
        if inputDeliveryOrigin == nil {refreshInputDeliveryOrigin()}

        inputInterruption = nil
        inputMonitoringNotice.closeNotice()
        refreshStatus()
    }

    func noteInputInterruption(_ reason: InputMonitoringInterruption) {
        guard inputInterruption != reason else { return }
        inputInterruption = reason
        refreshStatus()
        if permissionGranted && !updateRestricted { inputMonitoringNotice.show(reason) }
    }

    func refreshInputDeliveryOrigin() {
        guard enabled,permissionGranted,!updateRestricted,tap != nil else{return}
        // A restarted mismatch gate inserts a HID head tap. Install provenance
        // after it so capture remains ahead of all main-run-loop input work.
        inputDeliveryOrigin?.stop()
        let routing=InputDeliveryOrigin()
        routing.diagnosticReceive={type,event,process in
            let started=InputIncidentTrace.shared.beginCallback(type)
            let result=process()
            InputIncidentTrace.shared.event(.hid,type,event,consumed:result==nil,started:started)
            return result
        }
        inputDeliveryOrigin=routing;routing.start()
    }

    /// Fail open: remove the system hook, not just the feature flags.
    /// Called outside the tap callback. The watchdog stays armed until cleanup ends.
    func stopMapping() {
        inputDeliveryOrigin?.stop();inputDeliveryOrigin=nil
        sourceSwitchBarrier.fail("input_stopped")
        InputDiagnostics.shared.record("tap.stop.begin present=\(tap != nil)")
        mismatchRecovery.stop()
        onsetRecovery.stop()
        enabled = false
        koreanEnabled = false
        hanjaEnabled = false
        let oldTap = tap
        let oldSource = tapSource
        tap = nil
        tapSource = nil
        if let oldSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), oldSource, .commonModes)
            CFRunLoopSourceInvalidate(oldSource)
        }
        if let oldTap { CFMachPortInvalidate(oldTap) }
        inputSafety.disarm()
        freshPermission.stop()
        filter = CommandFilter()
        optionFilter = CommandFilter(keyCode: 61, left: 0x20, right: 0x40, aggregate: .maskAlternate)
        jamoRepair.stop()
        externalKeyboards.stop()
        KeyboardStateMirror.shared.stop()
        InputDiagnostics.shared.record("tap.stop.end")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
        refreshLaunchAtLogin()
        externalKeyboards.updateMenu()
    }
    func menuWillOpen(_ menu: NSMenu) { statusIcon.setMenuOpen(true);refreshDiagnosticLogAvailability() }
    func menuDidClose(_ menu: NSMenu) { statusIcon.setMenuOpen(false) }
    private func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.toolTip = "로그인하면 한Q가 자동으로 시작됩니다."
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.toolTip = "시스템 설정에서 허용이 필요합니다. 클릭하면 자동 실행 등록을 해제합니다."
        default:
            loginItem.state = .off
            loginItem.toolTip = "로그인하면 한Q가 자동으로 시작되도록 설정합니다."
        }
    }
    @objc func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(true, forKey: "didInitializeLaunchAtLogin")
            default:
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "didInitializeLaunchAtLogin")
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "자동 실행 설정을 변경하지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLaunchAtLogin()
    }
    @objc func toggleInputDiagnostics(){
        guard !changingInputDiagnostics else{return}
        let active = !InputIncidentTrace.shared.enabled
        UserDefaults.standard.set(active,forKey:InputIncidentPreferences.key)
        changingInputDiagnostics=true
        InputIncidentTrace.shared.setCollectionEnabled(active){[weak self] in
            self?.changingInputDiagnostics=false;self?.refreshStatus()
        }
        refreshStatus()
    }
    private func refreshDiagnosticLogAvailability(){
        guard let directory=InputIncidentTrace.shared.destinationDirectory else{return}
        DispatchQueue.global(qos:.utility).async{[weak self] in
            let found=((try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []).contains{$0.hasPrefix("incident-") && $0.hasSuffix(".json")}
            DispatchQueue.main.async{self?.hasDiagnosticLogs=found;self?.refreshStatus()}
        }
    }
    @objc func exportInputDiagnostics(){
        if let diagnosticReview {
            NSApp.activate(ignoringOtherApps:true)
            if diagnosticReview.window?.isMiniaturized == true {diagnosticReview.window?.deminiaturize(nil)}
            diagnosticReview.window?.makeKeyAndOrderFront(nil);return
        }
        let review=DiagnosticReviewController(environment:diagnosticReviewEnvironment())
        diagnosticReview=review
        review.onClose={ [weak self] in self?.diagnosticReview=nil }
        review.onFeedback={ [weak self] in self?.openFeedback() }
        review.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
        review.load(from:InputIncidentTrace.shared)
    }
    private func diagnosticReviewEnvironment()->DiagnosticReviewEnvironment {
        let defaults=UserDefaults.standard,info=Bundle.main.infoDictionary ?? [:]
        let os=ProcessInfo.processInfo.operatingSystemVersion
        let source=InputSourceAccess.currentID()
        let layouts:[DiagnosticReviewEnvironment.KeyboardLayout]=[.twoSet,.threeSet,.threeSet390,.gongjinRoman,.hancomRoman]
        let layout=KoreanKeyboardLayout.supportedIDs.firstIndex(of:source).map{layouts[$0]} ?? .unknownOrOther
        let login:DiagnosticReviewEnvironment.LoginItemState
        switch SMAppService.mainApp.status {
        case .enabled:login = .enabled
        case .requiresApproval:login = .requiresApproval
        case .notRegistered:login = .notRegistered
        default:login = .unknown
        }
        return DiagnosticReviewEnvironment(
            appVersion:info["HanQReleaseVersion"] as? String ?? "unknown",
            build:info["CFBundleVersion"] as? String ?? "unknown",
            macOSVersion:"\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            modelIdentifier:FeedbackForm.modelIdentifier(),keyboardLayout:layout,
            koreanKeyEnabled:defaults.bool(forKey:"koreanKeyEnabled"),
            hanjaKeyEnabled:defaults.bool(forKey:"hanjaKeyEnabled"),hudEnabled:defaults.bool(forKey:"hudEnabled"),
            capsLockSwitchEnabled:try? RomanSwitchController.isEnabled(),loginItemState:login,
            diagnosticsEnabled:InputIncidentTrace.shared.enabled,inputMonitoringEnabled:enabled,
            cachedAccessibilityPermission:permissionGranted,updateRestricted:updateRestricted)
    }
    @objc func markInputIncident(){InputIncidentTrace.shared.mark();refreshDiagnosticLogAvailability()}
    @objc func copyMismatchInput(){mismatchRecovery.copyRetained();refreshStatus()}
    func refreshStatus() {
        inputDiagnosticsItem.state=changingInputDiagnostics ? .mixed:(InputIncidentTrace.shared.enabled ? .on:.off)
        inputDiagnosticsItem.isEnabled = !changingInputDiagnostics
        inputIncidentItem.isEnabled=InputIncidentTrace.shared.enabled
        inputDiagnosticExportItem.isEnabled=hasDiagnosticLogs && !changingInputDiagnostics
        retainedMismatchItem.isHidden=mismatchRecovery.engine.retained.isEmpty
        retainedMismatchItem.isEnabled = !mismatchRecovery.busy

        status.stringValue = "한영키 \(koreanEnabled ? "켜짐" : "꺼짐") · 한자키 \(hanjaEnabled ? "켜짐" : "꺼짐")"
        if filter.consuming || optionFilter.consuming { status.stringValue += " · 누른 우측 키를 놓아주세요" }
        toggleItem.state = koreanEnabled ? .on : .off
        hanjaItem.state = hanjaEnabled ? .on : .off
        let romanEnabled = try? RomanSwitchController.isEnabled()
        capsItem.isEnabled = koreanEnabled && RomanSwitchController.isSupported && romanEnabled != nil
        capsItem.state = romanEnabled.map { $0 ? .on : .off } ?? .mixed

        if !permissionGranted {
            toggleItem.state = UserDefaults.standard.bool(forKey: "koreanKeyEnabled") ? .on : .off
            hanjaItem.state = UserDefaults.standard.bool(forKey: "hanjaKeyEnabled") ? .on : .off
        }
        toggleItem.isEnabled = permissionGranted && !updateRestricted
        hanjaItem.isEnabled = permissionGranted && !updateRestricted
        hudItem.isEnabled = permissionGranted && !updateRestricted
        menuStatus.title = permissionGranted ? status.stringValue : "손쉬운 사용 권한을 기다리고 있어요"
        menuStatus.toolTip = nil
        if let reason = inputInterruption, permissionGranted {
            menuStatus.title = reason.status
            menuStatus.toolTip = reason.explanation + "\n" + reason.guidance
        }
        if updateRestricted { menuStatus.title = "업데이트가 필요해요 · 한Q 기능 중단" }
        if updateRestricted { menuStatus.toolTip = nil }
        statusIcon.setDisabled(!koreanEnabled && !hanjaEnabled)
    }
    @objc func toggleKorean() {
        guard !updateRestricted else { return }
        if !koreanEnabled { startMapping(); guard enabled else { return } }
        koreanEnabled.toggle()
        UserDefaults.standard.set(koreanEnabled, forKey: "koreanKeyEnabled")
        enabled = koreanEnabled || hanjaEnabled
        refreshStatus()
    }
    @objc func toggleHanja() {
        guard !updateRestricted else { return }
        if !hanjaEnabled { startMapping(); guard enabled else { return } }
        hanjaEnabled.toggle()
        UserDefaults.standard.set(hanjaEnabled, forKey: "hanjaKeyEnabled")
        enabled = koreanEnabled || hanjaEnabled
        refreshStatus()
    }
    @objc func toggleCaps() {
        guard koreanEnabled && RomanSwitchController.isSupported else { return }
        do {
            let enabled = try RomanSwitchController.isEnabled()
            try RomanSwitchController.setEnabled(!enabled)
            refreshStatus()
        } catch {
            refreshStatus()
            let alert = NSAlert()
            alert.messageText = "Caps Lock 설정을 변경하지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    @objc func toggleHUD() {
        let enabled = !UserDefaults.standard.bool(forKey: "hudEnabled")
        UserDefaults.standard.set(enabled, forKey: "hudEnabled")
        hudItem.state = enabled ? .on : .off
        if !enabled { hud.hide() }
    }
    private func makeFeedbackItem() -> NSMenuItem {
        let item = NSMenuItem(title: "피드백 남기기…", action: #selector(openFeedback), keyEquivalent: "")
        item.target = self
        item.toolTip = "한Q에 관한 의견을 남길 수 있는 피드백 폼을 브라우저에서 엽니다."
        return item
    }

    @objc func openFeedback() {
        guard let url = FeedbackForm.url(), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "피드백 페이지를 열 수 없어요."
            alert.informativeText = "기본 웹 브라우저를 확인한 뒤 다시 시도해 주세요."
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
    }

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "한Q",
            .applicationVersion: info["HanQReleaseVersion"] as? String ?? "",
            .version: info["CFBundleVersion"] as? String ?? ""
        ]
        if let logoURL = Bundle.main.url(forResource: "HanQ-Logo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            options[.applicationIcon] = logo
        }
        if let licenseURL = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            options[.credits] = NSAttributedString(string: "라이선스", attributes: [
                .link: licenseURL,
                .font: NSFont.systemFont(ofSize: 12),
                .paragraphStyle: style
            ])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWindow() {
        guard !permissionGranted else { return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusIcon.requestUserRepair()
        updatePermission()
        showWindow()
        updater.showRequiredUpdate()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        statusIcon.stop()
        updater.stop()
        permissionTimer?.invalidate()
        safetyPulseTimer?.invalidate()
        hud.hide()
        stopMapping()
        InputIncidentTrace.shared.stopAndFlush()
    }
}

// MARK: Executable entry
HanjaCandidates.runProbeIfRequested()
PermissionRelauncher.runIfRequested()
let app = NSApplication.shared
PermissionProbe.runIfRequested()
app.setActivationPolicy(.accessory)
guard let instanceLock = AppInstanceLock() else {
    StatusItemController.requestRunningInstanceRepair()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
