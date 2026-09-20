import Foundation
import Darwin

let mode = CommandLine.arguments.last!
let watchdog = InputSafetyWatchdog(timeout: 0.15, terminate: { _exit(77) })
watchdog.arm()
if mode == "stalled" {
    // Deliberately never run the main run loop: independent timer must exit.
    Thread.sleep(forTimeInterval: 2)
    exit(1)
}
if mode == "healthy" {
    for _ in 0..<10 {
        watchdog.pulse()
        Thread.sleep(forTimeInterval: 0.03)
    }
}
watchdog.disarm()
Thread.sleep(forTimeInterval: 0.3)
print("PASS: watchdog \(mode)")
