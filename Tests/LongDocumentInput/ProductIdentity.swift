import Foundation
import Darwin
import CoreGraphics

// LaunchServices registration can disappear while a supervised UI process is
// still alive. Bind the test to its kernel start identity and executable path.
// A PID alone (or NSRunningApplication lookup failure) is insufficient.
struct LongProductIdentity {
    // Read only; PID/AX/post alone cannot prove that fail-open hooks are active.
    static func monitoringState(pid:Int)->[String:Any] {
        var taps=[CGEventTapInformation](repeating:CGEventTapInformation(),count:512),count:UInt32=0
        let status=CGGetEventTapList(UInt32(taps.count),&taps,&count)
        guard status == .success,count<=taps.count else{return ["allExpectedTapsActive":false,"stateAvailable":false]}
        let owned=taps.prefix(Int(count)).filter{$0.tappingProcess==pid},enabled=owned.filter{$0.enabled}
        let hid=enabled.filter{$0.tapPoint == .cghidEventTap}.count
        let session=enabled.filter{$0.tapPoint == .cgSessionEventTap}.count
        let annotated=enabled.filter{$0.tapPoint == .cgAnnotatedSessionEventTap}.count
        let latency:[[String:Any]]=owned.sorted{$0.eventTapID<$1.eventTapID}.map{tap in
            let a=Double(tap.minUsecLatency),b=Double(tap.avgUsecLatency),c=Double(tap.maxUsecLatency)
            let valid=a.isFinite && b.isFinite && c.isFinite && a>=0 && b>=0 && c>=0
            return ["tapID":tap.eventTapID,"point":tap.tapPoint.rawValue,"enabled":tap.enabled,"valid":valid,
                "minimumMicros":valid ? a:-1,"averageMicros":valid ? b:-1,"maximumMicros":valid ? c:-1]
        }
        return ["allExpectedTapsActive":owned.count==6 && enabled.count==6 && hid==2 && session==3 && annotated==1,
            "stateAvailable":true,"pid":pid,"tapCount":owned.count,"enabledCount":enabled.count,
            "enabledHIDCount":hid,"enabledSessionCount":session,"enabledAnnotatedCount":annotated,
            // CGGetEventTapList resets min/max to the average on every call.
            // Other observers can also reset that interval. These snapshots
            // cannot be aligned to one key or used as callback-duration proof.
            "tapLatency":latency,"tapLatencyScope":"OS per-tap snapshots; each CGGetEventTapList call resets min/max to the average; other observers may reset the interval; compare the same tapID; not per-key timing or AX attribution"]
    }
    private struct Identity:Equatable {let path:String,seconds:UInt64,microseconds:UInt64}
    private let pid:pid_t,initial:Identity?
    private static func read(_ pid:pid_t)->Identity? {
        var info=proc_bsdinfo(),buffer=[CChar](repeating:0,count:4096)
        let bytes=MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(bytes))==bytes,
              proc_pidpath(pid,&buffer,UInt32(buffer.count))>0 else{return nil}
        return Identity(path:String(cString:buffer),seconds:info.pbi_start_tvsec,microseconds:info.pbi_start_tvusec)
    }
    init(pid:Int,path:String){
        self.pid=pid_t(pid)
        let actual=Self.read(self.pid)
        // Foundation standardizes /private/tmp to /tmp; proc_pidpath keeps
        // the kernel spelling. Compare both spellings by the same rule,
        // while retaining the raw path and start time for subsequent checks.
        let actualPath=actual.map{URL(fileURLWithPath:$0.path).standardizedFileURL.path}
        initial=actualPath==URL(fileURLWithPath:path).standardizedFileURL.path ? actual:nil
    }
    var alive:Bool {guard let initial else{return false};return Self.read(pid)==initial}
}
