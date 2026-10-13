import Foundation
enum CapsTrial {
    static func monitorReady(_ trace:String,pid:Int?,now:Double)->Bool {
        guard let line=trace.split(separator:"\n").last(where:{$0.contains(" main.pulse ")}) else{return false}
        let values=Dictionary(line.split(separator:" ").compactMap{token -> (String,String)? in
            let parts=token.split(separator:"=",maxSplits:1);guard parts.count==2 else{return nil}
            return (String(parts[0]),String(parts[1]))
        },uniquingKeysWith:{current,_ in current})
        guard let raw=values["mono"],let time=Double(raw),now>=time,now-time<=1_200_000_000,
              pid==nil || values["pid"]==pid.map(String.init) else{return false}
        return ["tap":"true","enabled":"true","cachedAX":"true","mismatchEnabled":"true","mismatchSuspended":"false","mismatchRecovering":"false","mismatchTap":"true","mismatchSwitchTap":"true"].allSatisfy{values[$0.key]==$0.value}
    }

    // Replayed repair keys are excluded by their transaction interval, not by
    // keycode: a later buffered key can legitimately use the same position.
    static func userEvents(_ events:[[String:Any]],trace:String)->[[String:Any]] {
        var ranges:[(Double,Double)]=[],start:Double?
        for line in trace.split(separator:"\n") {
            guard let token=line.split(separator:" ").first(where:{$0.hasPrefix("mono=")}),let nanos=Double(token.dropFirst(5)) else{continue}
            let time=nanos/1_000_000_000
            if line.contains("mismatch.replay_started") {
                if let previous=start{ranges.append((previous,time))};start=time
            }else if line.contains("mismatch.korean_result_verified") || line.contains("mismatch.abort ") || line.contains("mismatch.park ") {
                if let previous=start{ranges.append((previous,time))};start=nil
            }
        }
        if let start{ranges.append((start,Double.greatestFiniteMagnitude))}
        return events.filter{event in
            if event["navigation"] as? Bool == true{return false}
            guard event["replay"] as? Bool == true else{return true}
            let time=event["time"] as? Double ?? 0
            return !ranges.contains{time >= $0.0 && time <= $0.1}
        }
    }
    static func followingRoman(_ keys:[Int],first:Int)->String? {
        guard keys.count==3,keys.first==first else{return nil}
        var result=""
        for key in keys.dropFirst(){
            guard let code=UInt16(exactly:key),let letter=PhysicalLetterKeys.letters[code] else{return nil}
            result+=letter
        }
        return result
    }
    static func followingRoman(_ events:[[String:Any]],first:Int)->String? {
        let keys=events.compactMap{$0["code"] as? Int}
        guard let roman=followingRoman(keys,first:first) else{return nil}
        var result=""
        for (letter,event) in zip(roman,events.dropFirst()) {
            guard let flags=event["modifiers"] as? NSNumber,
                  flags.uintValue & ((1<<17)|(1<<18)|(1<<19)|(1<<20)) == 0 else{return nil}
            result += flags.uintValue & (1<<16) != 0 ? String(letter).uppercased():String(letter)
        }
        return result
    }
}
