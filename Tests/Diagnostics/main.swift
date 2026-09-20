import Foundation

var evaluations = 0
func message() -> String {
    evaluations += 1
    return "diagnostic-test-marker"
}
InputDiagnostics.shared.record(message())
let args = ProcessInfo.processInfo.arguments
if args.contains("--expect-disabled") {
    precondition(evaluations == 0, "Unavailable diagnostic output must leave logging disabled")
} else if let index = args.firstIndex(of: "--diagnose-input"), index + 1 < args.count {
    precondition(evaluations == 1, "Enabled diagnostics must evaluate the message once")
    let contents = try String(contentsOfFile: args[index + 1], encoding: .utf8)
    precondition(contents.contains("diagnostic-test-marker"), "Enabled diagnostics must write the message")
} else {
    precondition(evaluations == 0, "Disabled diagnostics must not evaluate message expressions")
}
print("PASS: diagnostic logging opt-in and lazy message evaluation")
