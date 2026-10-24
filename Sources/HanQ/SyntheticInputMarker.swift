/// Wire value shared by manual-edit senders and input observers.
/// Keep this distinct from automatic recovery and keyboard-state mirroring.
enum SyntheticInputMarker {
    static let manualEdit: Int64 = 0x454F5448
}
