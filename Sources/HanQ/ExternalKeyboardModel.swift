import Foundation
import CoreGraphics
import CryptoKit

/// Only a locally hashed identity and the two bindings are persisted. No input history.
struct ExternalKeyboardIdentity {
    static func key(vendor: Int, product: Int, transport: String, serial: String?, location: Int, name: String, registryID: UInt64 = 0) -> String {
        let discriminator = serial.flatMap { $0.isEmpty ? nil : "serial:\($0)" }
            ?? (location != 0 ? "port:\(location)" : "connection:\(registryID)")
        let data = try! JSONEncoder().encode([String(vendor), String(product), transport, discriminator, name])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct KeyboardBinding: Codable, Equatable {
    let keyCode: Int64

    // Device-side masks from IOLLEvent.h. Caps Lock/Fn are deliberately excluded:
    // they have system state/translation semantics unlike a momentary key.
    var modifier: (mask: UInt64, opposite: UInt64, aggregate: CGEventFlags)? {
        switch keyCode {
        case 54: return (0x10, 0x08, .maskCommand)
        case 55: return (0x08, 0x10, .maskCommand)
        case 58: return (0x20, 0x40, .maskAlternate)
        case 61: return (0x40, 0x20, .maskAlternate)
        case 59: return (0x01, 0x2000, .maskControl)
        case 62: return (0x2000, 0x01, .maskControl)
        case 56: return (0x02, 0x04, .maskShift)
        case 60: return (0x04, 0x02, .maskShift)
        default: return nil
        }
    }
    var supported: Bool {
        [54, 61, 62, 60, 102, 104, 110].contains(keyCode)
    }
    var label: String {
        switch keyCode {
        case 54: return "오른쪽 Command (⌘)"
        case 55: return "왼쪽 Command (⌘)"
        case 58: return "왼쪽 Option / Alt (⌥)"
        case 61: return "오른쪽 Option / Alt (⌥)"
        case 59: return "왼쪽 Control (⌃)"
        case 62: return "오른쪽 Control (⌃)"
        case 56: return "왼쪽 Shift (⇧)"
        case 60: return "오른쪽 Shift (⇧)"
        case 102: return "언어 키 (英数 / 한자)"
        case 104: return "언어 키 (かな / 한영)"
        case 110: return "메뉴 키"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        default: return "지원하지 않는 키"
        }
    }
    func isDown(type: CGEventType, flags: CGEventFlags) -> Bool {
        if let modifier { return type == .flagsChanged && flags.rawValue & modifier.mask != 0 }
        return type == .keyDown
    }
    func matches(type: CGEventType, key: Int64) -> Bool {
        key == keyCode && (modifier != nil ? type == .flagsChanged : type == .keyDown || type == .keyUp)
    }
    func removingModifier(from flags: CGEventFlags) -> CGEventFlags {
        guard let modifier else { return flags }
        var clean = CGEventFlags(rawValue: flags.rawValue & ~modifier.mask)
        if flags.rawValue & modifier.opposite == 0 { clean.remove(modifier.aggregate) }
        return clean
    }
}

struct ExternalKeyboardProfile: Codable, Equatable {
    let korean: KeyboardBinding
    let hanja: KeyboardBinding
    var valid: Bool { korean.supported && hanja.supported && korean != hanja }
}

final class ExternalKeyboardProfiles {
    private let defaults: UserDefaults
    private let storageKey = "externalKeyboardProfiles.v1"
    private var values: [String: ExternalKeyboardProfile]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: ExternalKeyboardProfile].self, from: $0) } ?? [:]
        values = values.filter { $0.value.valid }
    }
    subscript(_ key: String) -> ExternalKeyboardProfile? { values[key] }
    func save(_ profile: ExternalKeyboardProfile, for key: String) {
        guard profile.valid else { return }
        values[key] = profile
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: storageKey) }
    }
}

/// Per-device press/release state. A press accepted here owns its matching release,
/// even if the feature is disabled before release. Never fires from an orphan up.
struct ExternalKeyboardKeyState {
    enum Edge { case down, up }
    private(set) var held = false
    private(set) var consuming = false
    mutating func process(binding: KeyboardBinding, type: CGEventType, key: Int64,
                          flags: CGEventFlags, repeated: Bool, accept: Bool) -> (consume: Bool, edge: Edge?) {
        guard binding.matches(type: type, key: key) else { return (false, nil) }
        if binding.isDown(type: type, flags: flags) {
            guard !held && !repeated else { return (consuming, nil) }
            held = true
            consuming = accept
            return (consuming, consuming ? .down : nil)
        }
        let owned = consuming
        held = false; consuming = false
        return (owned, owned ? .up : nil)
    }
}

/// Two complete, distinct press/release pairs are required before Save is enabled.
struct ExternalKeyboardCapture {
    private(set) var korean: KeyboardBinding?
    private(set) var hanja: KeyboardBinding?
    private(set) var pressed: KeyboardBinding?
    var profile: ExternalKeyboardProfile? {
        guard let korean, let hanja, pressed == nil else { return nil }
        let value = ExternalKeyboardProfile(korean: korean, hanja: hanja)
        return value.valid ? value : nil
    }
    mutating func cancelPendingPress() { pressed = nil }
    mutating func receive(type: CGEventType, key: Int64, flags: CGEventFlags, repeated: Bool) -> String? {
        guard profile == nil else { return nil }
        let binding = KeyboardBinding(keyCode: key)
        if let pressed {
            if pressed.matches(type: type, key: key), !pressed.isDown(type: type, flags: flags) {
                if korean == nil { korean = pressed } else { hanja = pressed }
                self.pressed = nil
            }
            return nil
        }
        guard binding.matches(type: type, key: key), binding.isDown(type: type, flags: flags), !repeated else { return nil }
        guard binding.supported else { return "오른쪽 Command·Option·Control·Shift, 한영키·한자키 또는 메뉴 키를 눌러주세요. 왼쪽 키와 일반 입력 키는 지정할 수 없어요." }
        guard binding != korean else { return "한영키와 다른 키를 눌러주세요." }
        let other = binding.removingModifier(from: flags).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard other.isEmpty else { return "다른 키를 모두 놓고 한 키만 눌러주세요." }
        pressed = binding
        return nil
    }
}
