import AppKit
import Carbon

/// Called on the main run loop by the switch coordinator and the input taps.
/// This observer neither owns an event nor reads a focused application.
final class RightCommandLayoutDiagnostics {
    typealias Sources = InputSourceAccess.LayoutSnapshot
    private let trace: InputIncidentTrace
    private let clock: () -> UInt64
    private let textFlags: (CGEventFlags) -> CGEventFlags
    private let secure: () -> Bool
    private let read: () -> Sources
    private var request: (target: String, stamp: CGEventTimestamp, generation: Int32)?
    private var pending: (record: DiagnosticSwitchLayout, source: String, generation: Int32)?
    private var nextID = 0

    init(trace: InputIncidentTrace = .shared,
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         textFlags: @escaping (CGEventFlags) -> CGEventFlags = { $0 },
         secure: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         read: @escaping () -> Sources = InputSourceAccess.layoutSnapshot) {
        self.trace = trace; self.clock = clock; self.secure = secure; self.read = read; self.textFlags = textFlags
    }

    func reset() { request = nil; pending = nil }

    func requested(_ target: String, at stamp: CGEventTimestamp, rightCommand: Bool) {
        let generation = trace.collectionGeneration
        guard generation > 0, !secure() else { reset(); return }
        supersede()
        request = rightCommand ? (target, stamp, generation) : nil
    }

    func confirmed(_ target: String, at stamp: CGEventTimestamp, reading: (UInt64, Sources)? = nil) {
        guard let request, request.target == target, request.stamp == stamp else { return }
        self.request = nil
        guard request.generation == trace.collectionGeneration, !secure() else { return }
        let observed = reading?.0 ?? clock()
        let sample = sample(at: observed, reading: reading)
        guard request.generation == trace.collectionGeneration, !secure() else { return }
        nextID += 1
        let record = DiagnosticSwitchLayout(id: nextID, requestMicros: stamp <= observed ? Int(stamp / 1000) : 0,
            target: Self.kind(target), commit: sample)
        pending = (record, target, request.generation)
        trace.recordSwitchLayout(record, generation: request.generation)
    }

    func sourceChanged(to source: String?) {
        if let pending, let source, source != "unknown", source != pending.source { supersede() }
    }

    private func supersede() {
        guard var old = pending else { return }
        pending = nil
        guard old.generation == trace.collectionGeneration, !secure() else { return }
        old.record.outcome = .superseded
        trace.recordSwitchLayout(old.record, generation: old.generation)
    }

    // The HID tap supplies the original time. The main tap also covers input
    // when the HID monitor is unavailable. Only one qualifying down can claim it.
    func firstKey(_ type: CGEventType, _ event: CGEvent, at stamp: @autoclosure () -> CGEventTimestamp) {
        guard let active = pending, type == .keyDown else { return }
        guard active.generation == trace.collectionGeneration, !secure() else { reset(); return }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        guard tag != SyntheticInputMarker.manualEdit, tag != SourceSwitchBarrier.marker,
              !OnsetInputGate.isRecoveryMarker(tag), !KeyboardStateMirror.isMarker(tag),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),
              textFlags(event.flags).intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty,
              let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)),
              PhysicalLetterKeys.printableCodes.contains(code) || Self.additionalPrintable.contains(code) else { return }
        let observed = clock(), original = stamp()
        guard original == 0 || original / 1000 >= UInt64(active.record.commit.observedMicros) else { return }
        pending = nil
        var record = active.record
        record.firstKey = sample(at: observed, eventTime: original <= observed ? original : 0)
        guard active.generation == trace.collectionGeneration, !secure() else { return }
        record.outcome = .firstKey
        trace.recordSwitchLayout(record, generation: active.generation)
    }

    // ISO/JIS printable positions and the numeric keypad (without Enter/Clear).
    private static let additionalPrintable: Set<UInt16> = [10, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95]

    private func sample(at observed: UInt64, eventTime: UInt64 = 0, reading: (UInt64, Sources)? = nil) -> DiagnosticLayoutSample {
        let began = reading?.0 ?? clock(), values = reading?.1 ?? read()
        return DiagnosticLayoutSample(observedMicros: Int(observed / 1000), readMicros: Int(began / 1000),
            selected: Self.kind(values.selected), layout: Self.kind(values.layout),
            overrideLayout: values.override.map(Self.kind) ?? .none, selectedAfter: Self.kind(values.selectedAfter),
            eventMicros: eventTime > 0 ? Int(eventTime / 1000) : nil)
    }

    private static let categories: [String: DiagnosticLayoutKind] = {
        var values: [String: DiagnosticLayoutKind] = ["unknown": .unavailable, "": .unavailable,
            "com.apple.keylayout.ABC": .abc, "com.apple.keylayout.US": .us]
        let korean: [String: DiagnosticLayoutKind] = [KoreanKeyboardLayout.twoSetID: .twoSet,
            KoreanKeyboardLayout.threeSetID: .threeSet, KoreanKeyboardLayout.threeSet390ID: .threeSet390,
            KoreanKeyboardLayout.gongjinID: .gongjin, KoreanKeyboardLayout.hncID: .hancom]
        for (source, category) in korean {
            values[source] = category
            if let layout = KoreanKeyboardLayout.translationIDs[source] { values[layout] = category }
        }
        return values
    }()

    private static func kind(_ id: String) -> DiagnosticLayoutKind { categories[id] ?? .other }
}
