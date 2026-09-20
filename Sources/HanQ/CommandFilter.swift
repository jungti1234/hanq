import CoreGraphics

// Device-specific masks from the SDK's IOLLEvent.h; the aggregate Command
// flag alone cannot distinguish both Command keys being held together.
struct CommandFilter {
    static let leftMask: UInt64 = 0x08
    static let rightMask: UInt64 = 0x10
    let keyCode: Int64
    let leftDeviceMask: UInt64
    let rightDeviceMask: UInt64
    let aggregate: CGEventFlags
    init(keyCode: Int64 = 54, left: UInt64 = 0x08, right: UInt64 = 0x10, aggregate: CGEventFlags = .maskCommand) {
        self.keyCode = keyCode; self.leftDeviceMask = left; self.rightDeviceMask = right; self.aggregate = aggregate
    }
    private(set) var consuming = false
    private var rightWasDown = false

    struct Result {
        let consume: Bool
        let flags: CGEventFlags
        let edge: String?
    }

    mutating func process(type: CGEventType, key: Int64, flags: CGEventFlags,
                          acceptNewPress: Bool) -> Result {
        let rightDown = flags.rawValue & rightDeviceMask != 0
        var edge: String?
        var consume = false
        if type == .flagsChanged && key == keyCode {
            let newDown = rightDown && !rightWasDown
            rightWasDown = rightDown
            if newDown && !consuming && acceptNewPress {
                consuming = true
                edge = "right-down"
            } else if !rightDown && consuming {
                consuming = false
                edge = "right-up"
                consume = true
            }
            consume = consume || consuming
        }
        var clean = flags
        if consuming || consume {
            clean = CGEventFlags(rawValue: flags.rawValue & ~rightDeviceMask)
            if flags.rawValue & leftDeviceMask == 0 { clean.remove(aggregate) }
        }
        return Result(consume: consume, flags: clean, edge: edge)
    }
}
