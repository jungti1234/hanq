import AppKit

/// Keep three recent user reopen attempts; explain once until the burst expires.
struct MenuBarReopenAttempts {
    private var times: [TimeInterval] = []
    private var explained = false

    mutating func record(at time: TimeInterval) -> Bool {
        times.removeAll { $0 < time - 60 }
        if times.isEmpty { explained = false }
        times.append(time)
        if times.count > 3 { times.removeFirst(times.count - 3) }
        guard times.count == 3, !explained else { return false }
        explained = true
        return true
    }
}

/// Owns the menu-bar registration independently of input permissions and taps.
/// AppKit's isVisible is not a pixel-visibility test: overflow and the system's
/// per-app menu-bar setting can hide an item while this property remains true.
final class StatusItemController {
    private static let reopenNotification = Notification.Name("taek.in.hanq.menu-bar-reopen")

    /// Forward a blocked duplicate UI launch. Helpers exit before the UI lock.
    static func requestRunningInstanceRepair() {
        DistributedNotificationCenter.default().postNotificationName(
            reopenNotification, object: Bundle.main.bundleIdentifier,
            userInfo: nil, deliverImmediately: true)
    }

    private(set) var item: NSStatusItem?
    private var menu: NSMenu?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: (reason: String, due: TimeInterval)?
    private var pendingUserRepair: (reason: String, due: TimeInterval)?
    private var lastUserRepair = -TimeInterval.infinity
    private var reopenAttempts = MenuBarReopenAttempts()
    private var pendingNotice = false
    private var lastRegistration = -TimeInterval.infinity
    private var lastState = ""
    private var unavailableSince: TimeInterval?
    private var shownSince: TimeInterval?
    private var attemptedWindowRepair = false
    private var menuOpen = false
    private var stopped = true
    private var disabled = false
    private let now: () -> TimeInterval
    private let loadImage: () -> NSImage?
    private let settleDelay: TimeInterval
    private let cooldown: TimeInterval
    var trace: (String) -> Void = { InputDiagnostics.shared.record($0) }
    var onRepeatedUserLaunch: () -> Void = {}

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         loadImage: @escaping () -> NSImage? = {
             Bundle.main.url(forResource: "HanQ-MenuBar-Template", withExtension: "pdf")
                 .flatMap { NSImage(contentsOf: $0) }
         }, settleDelay: TimeInterval = 2, cooldown: TimeInterval = 30) {
        self.now = now
        self.loadImage = loadImage
        self.settleDelay = settleDelay
        self.cooldown = cooldown
    }

    func start(menu: NSMenu) {
        guard stopped else { return }
        stopped = false
        unavailableSince = nil
        shownSince = nil
        attemptedWindowRepair = false
        self.menu = menu
        register(reason: "launch")
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Self.reopenNotification,
            object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in
                self?.requestUserRepair(reason: "duplicate-launch")
            }
        observers.append((distributed, token))
        observe(.default, NSApplication.didChangeScreenParametersNotification, reason: "screens-changed")
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification, reason: "wake")
        observe(workspace, NSWorkspace.screensDidWakeNotification, reason: "screens-wake")
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, reason: "session-active")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Debounce display/wake bursts. One registration per cooldown also bounds
    /// failures and system-controlled hiding; healthy items are never polled away.
    func requestRefresh(reason: String) {
        guard !stopped else { return }
        guard pendingUserRepair == nil else { return }
        pending = (reason, max(now() + settleDelay, lastRegistration + cooldown))
        trace("status.refresh.request reason=\(reason)")
    }

    /// A user reopen requests repair even when AppKit reports a healthy item.
    /// Bypass the automatic delay; rapid requests keep the first fixed deadline.
    func requestUserRepair(reason: String = "reopen") {
        guard !stopped else { return }
        if reopenAttempts.record(at: now()) { pendingNotice = true }
        pending = nil
        if pendingUserRepair == nil {
            pendingUserRepair = (reason, max(now(), lastUserRepair + 2))
        }
        if !menuOpen, let button = item?.button { configure(button) }
        trace("status.user-repair.request reason=\(reason)")
        check()
    }

    func setMenuOpen(_ open: Bool) { menuOpen = open }

    func setDisabled(_ value: Bool) {
        disabled = value
        item?.button?.appearsDisabled = value
    }

    func check() {
        guard !stopped else { return }
        recordState()
        // Replacing a status item while its menu is tracking can close the menu
        // and interrupt a selection. Leave pending work for the next tick.
        guard !menuOpen else { return }
        if let request = pendingUserRepair {
            guard now() >= request.due else { return }
            pendingUserRepair = nil
            lastUserRepair = now()
            register(reason: request.reason)
            if pendingNotice {
                pendingNotice = false
                onRepeatedUserLaunch()
            }
            return
        }
        if let pending, now() >= pending.due {
            self.pending = nil
            register(reason: pending.reason)
            return
        }
        guard let item, let button = item.button else {
            if pending == nil { requestRefresh(reason: "missing-item-or-button") }
            return
        }
        if !item.isVisible {
            item.isVisible = true
            trace("status.restore visibility")
        }
        if item.length != NSStatusItem.variableLength {
            item.length = NSStatusItem.variableLength
            trace("status.restore length")
        }
        if button.image == nil && button.title.isEmpty {
            configure(button)
            trace("status.restore content")
        }
        if item.menu !== menu {
            item.menu = menu
            trace("status.restore menu")
        }
        // A removed registration can keep isVisible=true and a live button,
        // but lose its visible window. Overflow/system hiding can look identical.
        // Try once per continuous incident, then require 30s of stable display
        // before rearming. Never endlessly recreate a system-hidden item.
        if button.window?.isVisible != true {
            shownSince = nil
            if unavailableSince == nil { unavailableSince = now() }
            if !attemptedWindowRepair, pending == nil,
               now() - unavailableSince! >= settleDelay {
                attemptedWindowRepair = true
                requestRefresh(reason: "unavailable-window")
            }
        } else {
            unavailableSince = nil
            if shownSince == nil { shownSince = now() }
            if now() - shownSince! >= cooldown { attemptedWindowRepair = false }
        }
    }

    func stop() {
        stopped = true
        pending = nil
        pendingUserRepair = nil
        pendingNotice = false
        reopenAttempts = MenuBarReopenAttempts()
        lastUserRepair = -TimeInterval.infinity
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let item { removePreservingPosition(item) }
        item = nil
        menu = nil
        menuOpen = false
        unavailableSince = nil
        shownSince = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.requestRefresh(reason: reason)
        }
        observers.append((center, token))
    }

    private func register(reason: String) {
        if let item {
            item.menu = nil
            removePreservingPosition(item)
        }
        let replacement = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = replacement
        // Keep the same identity across repairs so Command-drag ordering survives.
        replacement.autosaveName = "HanQ.StatusItem"
        replacement.behavior = []
        replacement.isVisible = true
        if let button = replacement.button { configure(button) }
        replacement.menu = menu
        lastRegistration = now()
        shownSince = nil
        trace("status.register reason=\(reason)")
        if reason != "launch" { NSLog("메뉴바 항목 재등록: %@", reason) }
        recordState()
    }

    private func removePreservingPosition(_ item: NSStatusItem) {
        // AppKit deletes the preferred position on explicit removal. The same
        // autosave name alone therefore cannot keep Command-drag/Ice placement.
        // Preserve only this item's existing value; never choose a new position
        // or alter a menu-bar manager's hidden/visible sections.
        let key = "NSStatusItem Preferred Position " + item.autosaveName
        let position = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(item)
        if let position { UserDefaults.standard.set(position, forKey: key) }
    }

    private func configure(_ button: NSStatusBarButton) {
        if let image = loadImage(), image.isValid {
            image.isTemplate = true
            image.size = NSSize(width: 144.0 / 112.0 * 18.0, height: 18)
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "한Q"
        }
        button.toolTip = "한Q"
        button.setAccessibilityLabel("한Q")
        button.appearsDisabled = disabled
        button.needsDisplay = true
    }

    private func recordState() {
        let button = item?.button
        let window = button?.window
        let frameOnScreen = window.map { window in NSScreen.screens.contains { $0.frame.intersects(window.frame) } } ?? false
        let state = "item=\(item != nil) visible=\(item?.isVisible == true) button=\(button != nil) image=\(button?.image != nil) title=\(button?.title.isEmpty == false) window=\(window != nil) windowVisible=\(window?.isVisible == true) onScreen=\(frameOnScreen) screens=\(NSScreen.screens.count)"
        guard state != lastState else { return }
        lastState = state
        trace("status.state " + state)
    }

    deinit {
        timer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
