import AppKit
import Carbon

struct InputSourceSnapshot: Equatable {
    let id: String
    let name: String?
    var languages: [String] = []
    var isKorean: Bool { languages.contains("ko") }
    var isEnglish: Bool { languages.contains("en") }
    static func read() -> InputSourceSnapshot? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let snapshot = from(source) else { return nil }
        return snapshot
    }
    static func from(_ source: TISInputSource) -> InputSourceSnapshot? {
        guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
        var languages: [String] = []
        if let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            languages = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] ?? []
        }
        return InputSourceSnapshot(id: id, name: string(source, kTISPropertyLocalizedName), languages: languages)
    }
    static func available() -> [InputSourceSnapshot] {
        let query = [kTISPropertyInputSourceIsEnabled as String: true,
                     kTISPropertyInputSourceIsSelectCapable as String: true,
                     kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let sources = TISCreateInputSourceList(query, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return sources.compactMap { from($0) }
    }
    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

final class InputSourceObserver: NSObject {
    private var started = false
    private var poll: Timer?
    private var activation: NSObjectProtocol?
    private var last: InputSourceSnapshot?
    private var initialized = false
    var onChange: ((InputSourceSnapshot?) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(self,
            selector: #selector(sourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        // Notifications can arrive before the queried state settles. Reconcile even
        // while another app is active; identical snapshots never redisplay the HUD.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func sourceChanged(_ note: Notification) {
        if Thread.isMainThread { refresh() }
        else { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    }
    func refresh() {
        let current = InputSourceSnapshot.read()
        guard !initialized || current != last else { return }
        initialized = true; last = current
        KoreanEnglishSwitch.remember(current)
        onChange?(current)
    }
    deinit {
        poll?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }
}

// A missing target is an error, never a request to cycle through other languages.
enum KoreanEnglishSwitch {
    static func remember(_ source: InputSourceSnapshot?) {
        guard let source else { return }
        let key: String
        if source.isKorean { key = "lastKoreanSourceID" }
        else if source.isEnglish { key = "lastEnglishSourceID" }
        else { return }
        if UserDefaults.standard.string(forKey: key) != source.id { UserDefaults.standard.set(source.id, forKey: key) }
    }
    static func resolve(current: InputSourceSnapshot?, available: [InputSourceSnapshot], rememberedKorean: String?, rememberedEnglish: String?) -> String? {
        guard let current else { return nil }
        // English returns to Korean; Korean and all other known sources go to English.
        let toKorean = current.isEnglish && !current.isKorean
        let choices = available.filter { toKorean ? $0.isKorean : $0.isEnglish }
        let remembered = toKorean ? rememberedKorean : rememberedEnglish
        if let match = choices.first(where: { $0.id == remembered }) { return match.id }
        let preferred = toKorean ? "com.apple.inputmethod.Korean.2SetKorean" : "com.apple.keylayout.ABC"
        return choices.first(where: { $0.id == preferred })?.id ?? choices.first?.id
    }
    static func target(for current: InputSourceSnapshot?) -> String? {
        remember(current)
        return resolve(current: current, available: InputSourceSnapshot.available(),
            rememberedKorean: UserDefaults.standard.string(forKey: "lastKoreanSourceID"),
            rememberedEnglish: UserDefaults.standard.string(forKey: "lastEnglishSourceID"))
    }
    /// Text recovery must respect the chosen Korean source, not the switcher's
    /// fallback policy. Missing IDs are resolved to two-set by KoreanKeyboardLayout.
    static func romanSourceID(current: InputSourceSnapshot?, available: [InputSourceSnapshot],
                              rememberedKorean: String?) -> String? {
        guard let current else { return nil }
        if current.isKorean { return current.id }
        return available.first { $0.isKorean && $0.id == rememberedKorean }?.id
    }
    static func romanSourceID(for current: InputSourceSnapshot?) -> String? {
        romanSourceID(current: current, available: InputSourceSnapshot.available(),
                      rememberedKorean: UserDefaults.standard.string(forKey: "lastKoreanSourceID"))
    }
    static func select(_ id: String) -> OSStatus {
        let query = [kTISPropertyInputSourceID as String: id,
                     kTISPropertyInputSourceIsEnabled as String: true,
                     kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(query, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return OSStatus(-50) }
        return TISSelectInputSource(source)
    }
}
