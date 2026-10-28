import Foundation

// A failed AX activation must not disable recovery for the lifetime of a
// focused application. The caller services this policy only from its idle
// main-run-loop observation, never from a keyboard callback or an edit.
struct OnsetAccessibilityActivation {
    enum Attribute:CaseIterable,Hashable {
        case manual,enhanced
        var name:String {self == .manual ? "AXManualAccessibility":"AXEnhancedUserInterface"}
    }
    enum Result {case enabled,unsupported,retryable}
    private(set) var missingSince:Double?
    private(set) var nextAttemptAt=0.0
    private(set) var attempts=0
    private var unsupported:Set<Attribute>=[]
    mutating func missing(now:Double){
        guard now.isFinite else{return}
        if missingSince == nil{missingSince=now}
    }
    mutating func available(now:Double){
        missingSince=nil;attempts=0
        // Recovery rearms a later failure without allowing rapid focus
        // flapping to bypass the minimum one-second request interval.
        if now.isFinite{nextAttemptAt=min(nextAttemptAt,now+1)}
    }
    func due(now:Double)->Bool {
        now.isFinite && missingSince != nil && now>=nextAttemptAt && unsupported.count<Attribute.allCases.count
    }
    mutating func begin(now:Double)->[Attribute] {
        guard due(now:now) else{return []}
        let delays:[Double]=[1,2,4,8,30]
        nextAttemptAt=now+delays[min(attempts,delays.count-1)]
        attempts=min(attempts+1,delays.count)
        return Attribute.allCases.filter{!unsupported.contains($0)}
    }
    mutating func completed(_ attribute:Attribute,result:Result){
        if case .unsupported=result{unsupported.insert(attribute)}
    }
}
