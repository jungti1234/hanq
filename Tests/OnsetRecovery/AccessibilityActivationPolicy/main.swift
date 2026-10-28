import Foundation
var count=0
func check(_ value:Bool,_ message:String){count+=1;precondition(value,message)}
var policy=OnsetAccessibilityActivation()
check(!policy.due(now:0),"healthy focus does not request activation")
policy.missing(now:0)
check(policy.begin(now:0).count==2,"first failure requests the existing two activation attributes")
for (now,next) in [(1.0,3.0),(3.0,7.0),(7.0,15.0),(15.0,45.0),(45.0,75.0)] {
    check(!policy.due(now:now-0.001),"ordinary 20ms observations do not accelerate retries")
    check(policy.begin(now:now).count==2 && policy.nextAttemptAt==next,"persistent failure uses bounded backoff")
}
policy.available(now:46)
check(!policy.due(now:47),"a successful focus read stops all idle retries")
policy.missing(now:46.1)
check(!policy.due(now:46.99) && policy.begin(now:47).count==2,"a later renderer failure rearms recovery")
for i in 1...99 {
    let time=47+Double(i)/100
    policy.available(now:time);policy.missing(now:time)
    check(!policy.due(now:time),"focus flapping cannot request activation at key/sample frequency")
}
var unsupported=OnsetAccessibilityActivation();unsupported.missing(now:0)
_ = unsupported.begin(now:0);unsupported.completed(.manual,result:.unsupported)
check(unsupported.begin(now:1)==[.enhanced],"unsupported manual attribute does not block the supported alternative")
unsupported.completed(.enhanced,result:.unsupported)
check(!unsupported.due(now:10_000),"unsupported native applications are not written repeatedly")
unsupported.available(now:20);unsupported.missing(now:21)
check(!unsupported.due(now:22),"same-session unsupported knowledge survives a good focus observation")
var transient=OnsetAccessibilityActivation();transient.missing(now:0)
for attribute in transient.begin(now:0){transient.completed(attribute,result:.retryable)}
check(transient.begin(now:1).count==2,"a failed first AX request is retried instead of latched forever")
for attribute in transient.begin(now:3){transient.completed(attribute,result:.enabled)}
check(transient.begin(now:7).count==2,"AX setter success does not prove focus exposure")
check(!transient.due(now:.nan) && transient.begin(now:.infinity).isEmpty,"invalid clocks never issue requests")
transient.available(now:8)
check(!transient.due(now:1_000),"actual focus recovery ends the failure episode")
print("PASS \(count) focus accessibility activation policy checks; no AX, keys, or clipboard access")
