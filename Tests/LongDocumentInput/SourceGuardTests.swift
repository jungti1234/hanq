import AppKit
import Carbon

@main enum SourceGuardTests {
    static func main(){
        var checks=0
        func check(_ value:Bool){checks+=1;if !value{fputs("FAIL owned source control guard\n",stderr);exit(1)}}
        for mask in 0..<128 {
            let values=(0..<7).map{mask & (1<<$0) != 0}
            for age in [-1.0,0.0,0.5,1.0,1.01] {
                let allowed=OwnedSourceDecision.allows(receiverAlive:values[0],pathMatches:values[1],bundleMatches:values[2],frontMatches:values[3],focusMatches:values[4],secureOff:values[5],axTrusted:values[6],age:age)
                check(allowed==(mask==127 && age>=0 && age<=1))
            }
        }
        let state=LongSourceState();var owned=false,operations=0
        state.mayChangeSource={owned}
        state.selectSource={_ in operations+=1;return noErr}
        state.enableSource={_ in operations+=1;return noErr}
        state.disableSource={_ in operations+=1;return noErr}
        let original=state.original.map(longSourceID) ?? ""
        state.currentSourceID={original};state.currentEnabledIDs={state.initiallyEnabled}
        let target=original==longABC ? longTwoSet:longABC
        check(!state.select(target));check(operations==0);check(state.restore());check(operations==0)
        owned=true;check(state.select(target));check(state.needsCleanup);let before=operations
        owned=false;check(!state.restore());check(operations==before);check(state.needsCleanup)
        owned=true;check(state.restore());check(operations>before);check(!state.needsCleanup)
        check(!ownedInputSourceLocalFocus());check(ownedInputSourceCommand("select",longABC) != noErr)
        func retry(_ observations:[(Bool,Bool)],expected:Bool,reads:Int,waits:Int){
            var index=0,pauses=0
            let result=OwnedSourceDecision.withFreshAXRetry(probe:{
                let value=observations[index];index+=1;return value
            },pause:{pauses+=1})
            check(result==expected);check(index==reads);check(pauses==waits)
        }
        retry([(true,false)],expected:true,reads:1,waits:0)
        retry([(false,true),(true,false)],expected:true,reads:2,waits:1)
        // An identified foreign owner, denied permission, secure input or stale
        // request is not a transient AX failure and must not be retried.
        retry([(false,false),(true,false)],expected:false,reads:1,waits:0)
        // A new front/focus/permission/secure/age failure overrides the earlier
        // transient error; the second probe cannot borrow the first proof.
        retry([(false,true),(false,false)],expected:false,reads:2,waits:1)
        retry([(false,true),(false,true),(true,false)],expected:false,reads:2,waits:1)
        print("PASS \(checks) ownership, focus/secure/AX/age, lost-focus deferral and explicit cleanup checks; injected mutations only; no OS source changes or keys")
    }
}
