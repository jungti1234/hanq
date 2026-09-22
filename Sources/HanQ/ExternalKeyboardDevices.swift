import Foundation
import CoreGraphics
import IOKit

struct ExternalKeyboardDevice: Equatable {
    let registryID: UInt64
    let identity: String
    let name: String
    let external: Bool
}

/// Read-only IORegistry notifications: no device seizure, global remapping,
/// input-value recording, or additional Input Monitoring permission.
final class ExternalKeyboardDevices {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private(set) var devices: [UInt64: ExternalKeyboardDevice] = [:]
    var onChange: (() -> Void)?

    init(snapshot: [UInt64: ExternalKeyboardDevice] = [:]) { devices = snapshot }
    func applySnapshot(_ next: [UInt64: ExternalKeyboardDevice]) {
        guard next != devices else { return }
        devices = next
        onChange?()
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            guard let context else { return }
            Unmanaged<ExternalKeyboardDevices>.fromOpaque(context).takeUnretainedValue().refresh()
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
            IOServiceMatching("IOHIDEventService"), callback, context, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            IOServiceMatching("IOHIDEventService"), callback, context, &removed)
        callback(context, added)
        callback(context, removed)
    }

    func stop() {
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        devices.removeAll()
    }

    private func refresh() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var next: [UInt64: ExternalKeyboardDevice] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let pairs = property("DeviceUsagePairs") as? [[String: Any]] ?? []
            let keyboard = ((property("PrimaryUsagePage") as? NSNumber)?.intValue == 1 &&
                            (property("PrimaryUsage") as? NSNumber)?.intValue == 6) || pairs.contains {
                ($0["DeviceUsagePage"] as? NSNumber)?.intValue == 1 && ($0["DeviceUsage"] as? NSNumber)?.intValue == 6
            }
            guard keyboard else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            let name = property("Product") as? String ?? "외부 키보드"
            let transport = property("Transport") as? String ?? ""
            let builtIn = (property("Built-In") as? NSNumber)?.boolValue == true
            let external = !builtIn && ["USB", "Bluetooth", "Bluetooth Low Energy"].contains(transport)
                && !name.localizedCaseInsensitiveContains("virtual")
            let key = ExternalKeyboardIdentity.key(
                vendor: (property("VendorID") as? NSNumber)?.intValue ?? 0,
                product: (property("ProductID") as? NSNumber)?.intValue ?? 0,
                transport: transport, serial: property("SerialNumber") as? String,
                location: (property("LocationID") as? NSNumber)?.intValue ?? 0, name: name, registryID: id)
            next[id] = ExternalKeyboardDevice(registryID: id, identity: key, name: name, external: external)
        }
        applySnapshot(next)
    }

    /// Quartz field 87 is undocumented. Keep this dependency isolated and accept
    /// ONLY a nonzero ID that matches a currently enumerated keyboard service.
    /// No "most recent keyboard" or single-connected-device guessing fallback.
    static func senderID(_ event: CGEvent) -> UInt64? {
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              let field = CGEventField(rawValue: 87) else { return nil }
        let value = event.getIntegerValueField(field)
        return value > 0 ? UInt64(value) : nil
    }
    func device(for event: CGEvent) -> ExternalKeyboardDevice? {
        Self.senderID(event).flatMap { devices[$0] }
    }
    func isUnique(_ device: ExternalKeyboardDevice) -> Bool {
        devices.values.filter { $0.external && $0.identity == device.identity }.count == 1
    }
    deinit { stop() }
}
