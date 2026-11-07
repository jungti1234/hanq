import AppKit

// A diagnostic observer, never a recovery witness. It has no AX reader, event
// sender, source selector, gate mutator or callback into the recovery detector.
// Raw snapshots/keys stay in bounded memory; only fixed comparisons leave it.
final class OnsetDiagnosticHistory {
    typealias Evidence = InputIncidentTrace.OnsetObservation
    struct Prior {let snapshot:OnsetSnapshot;let completed:Double}
    private var prior:[Prior]=[]
    private var seed:[Prior]=[]
    private var first:OnsetInputGate.Reservation?
    private var field:AXUIElement?
    private var baseline:Prior?
    private var keys:[(UInt16,Bool)]=[]
    private static var nextEpisode=0 // Main observation thread only.
    private var serial=0,samples=0,coalesced=0
    private var last:Evidence?,lastEmission=0.0
    private var captured=false
    var emit:(Evidence,Bool)->Void = {_,_ in}
    var active:Bool {first != nil}
    var retainedSnapshots:Int {prior.count+seed.count+(baseline == nil ? 0:1)}
    func reset(){prior=[];seed=[];first=nil;field=nil;baseline=nil;keys=[];last=nil;samples=0;coalesced=0;captured=false}
    func remember(_ snapshot:OnsetSnapshot,at time:Double){
        prior.removeAll{time-$0.completed>2 || time<$0.completed}
        guard snapshot.text.utf16.count<=4096,time.isFinite else{return}
        // Keep two observations per field across a key/read race, eight fields.
        let same=prior.indices.filter{CFEqual(prior[$0].snapshot.element,snapshot.element)}
        if same.count>=2{prior.remove(at:same[0])}
        prior.append(Prior(snapshot:snapshot,completed:time))
        if prior.count>16{prior.removeFirst(prior.count-16)}
    }
    func finish(_ reason:Int,at time:Double){
        if var value=last,let first {
            value.phase=3;value.reason=reason;value.samples=samples;value.coalesced=coalesced
            value.firstKeyAgeMicros=Self.age(time-first.time)
            emit(value,false)
        }
        first=nil;field=nil;baseline=nil;seed=[];keys=[];last=nil;samples=0;coalesced=0;captured=false
    }
    func notification(_ reason:Int,at time:Double){
        guard var value=last,let first,time>=first.time,time-first.time<=2 else{return}
        value.phase=2;value.reason=reason;value.firstKeyAgeMicros=Self.age(time-first.time)
        value.samples=samples;value.coalesced=coalesced;emit(value,false)
    }
    // Called only on the main observation path with reads the engine already made.
    // The first pair survives gate rejection for at most two seconds. Subsequent
    // text may match a prefix, but that never proves which operation inserted it.
    func observe(_ snapshot:OnsetSnapshot?,passed:OnsetInputGate.PassedInput?,source:String,at time:Double){
        prior.removeAll{time-$0.completed>2 || time<$0.completed}
        if let first,time<first.time || time-first.time>2{finish(1,at:time)}
        if let first,source != first.sourceID{finish(2,at:time);prior=[]}
        if first==nil,let passed,source==passed.first.sourceID,time>=passed.first.time,time-passed.first.time<=2 {
            first=passed.first;keys=Array(passed.keys.prefix(2));seed=prior
            Self.nextEpisode=Self.nextEpisode>=1_000_000_000 ? 1:Self.nextEpisode+1;serial=Self.nextEpisode
        }
        guard let first else{if let snapshot{remember(snapshot,at:time)};return}
        if let passed,passed.first.time==first.time{keys=Array(passed.keys.prefix(2))}
        if let snapshot {
            if let field,!CFEqual(field,snapshot.element){finish(3,at:time);remember(snapshot,at:time);return}
            if field==nil {
                field=snapshot.element
                baseline=seed.last{CFEqual($0.snapshot.element,snapshot.element) && $0.completed<first.time}
            }
        }
        samples=min(samples+1,1_000_000)
        let baselineState:Int
        if let baseline {baselineState=first.time-baseline.completed<=0.75 ? 2:3}
        else if field==nil{baselineState=0}
        else if seed.contains(where:{CFEqual($0.snapshot.element,field!)}){baselineState=4}
        else{baselineState=1}
        let expected=Self.expected(keys,source:first.sourceID)
        var whole=0,draft=0,insertion=0,selection=0,unicode=0
        if let snapshot,snapshot.text.utf16.count<=4096 {
            whole=Self.relation(snapshot.text,expected)
            selection=Self.selection(snapshot)
            unicode=Self.unicode(snapshot)
            if let before=baseline?.snapshot {
                if InputFocusAccess.literalTextEqual(before.text,snapshot.text){draft=1}
                else if let inserted=Self.inserted(before,after:snapshot){draft=2;insertion=Self.relation(inserted,expected)}
                else{draft=3}
            }
        }
        var value=Evidence(episode:serial,phase:1,reason:0,keys:keys.count,baseline:baselineState,
            history:passed?.first.time==first.time ? 1:2,whole:whole,draft:draft,insertion:insertion,
            selection:selection,unicode:unicode,samples:samples,coalesced:coalesced,
            firstKeyAgeMicros:Self.age(time-first.time),firstEventTimestampMicros:Int(min(first.eventTimestamp/1000,9_000_000_000_000_000)),baselineAgeMicros:baseline.map{Self.age(first.time-$0.completed)})
        let capture = !captured && keys.count==2
        if let last,value.sameState(last),!capture,time-lastEmission<0.25{coalesced=min(coalesced+1,1_000_000)}
        else {
            value.coalesced=coalesced;last=value;lastEmission=time;emit(value,capture)
            if capture{captured=true}
        }
        if let snapshot{remember(snapshot,at:time)}
    }
    private static func age(_ elapsed:Double)->Int {elapsed.isFinite ? Int(max(0,min(elapsed*1_000_000,60_000_000))):0}
    // Deliberately only the stateless two-set mapping. Unsupported layouts are
    // reported as unmeasured, not silently compared using a fallback layout.
    private static func expected(_ keys:[(UInt16,Bool)],source:String)->[String] {
        guard source==KoreanKeyboardLayout.twoSetID,let layout=KoreanKeyboardLayout.load(sourceID:source) else{return []}
        var parts:[String]=[]
        for (code,shift) in keys {
            guard let letter=PhysicalLetterKeys.letters[code],let key=(shift ? letter.uppercased():letter).first,
                  let mapped=layout.keys[key] else{return []}
            parts.append(String(mapped))
        }
        guard let first=parts.first else{return []}
        if parts.count==1{return [first]}
        let split=parts.joined(),composed=JamoComposer.compose(split)
        return [first,split,InputFocusAccess.literalTextEqual(split,composed) ? "":composed]
    }
    private static func relation(_ text:String,_ expected:[String])->Int {
        guard !expected.isEmpty else{return 0}
        // Literal UTF-16 comparison; Swift's canonical String equality could
        // conflate a modern jamo sequence with a precomposed Hangul syllable.
        for i in expected.indices.reversed() where !expected[i].isEmpty && InputFocusAccess.literalTextEqual(text,expected[i]) {return i+1}
        let value=text as NSString
        for i in expected.indices.reversed() {
            let prefix=expected[i] as NSString
            if prefix.length>0,value.length>prefix.length,InputFocusAccess.literalTextEqual(value.substring(to:prefix.length),expected[i]){return i+4}
        }
        return 7
    }
    private static func inserted(_ before:OnsetSnapshot,after:OnsetSnapshot)->String? {
        let original=before.text as NSString,current=after.text as NSString,range=before.selection
        guard range.length==0,range.location>=0,range.location<=original.length,current.length>original.length else{return nil}
        let added=current.length-original.length
        guard InputFocusAccess.literalTextEqual(original.substring(to:range.location),current.substring(to:range.location)),
              InputFocusAccess.literalTextEqual(original.substring(from:range.location),current.substring(from:range.location+added)) else{return nil}
        return current.substring(with:NSRange(location:range.location,length:added))
    }
    private static func selection(_ snapshot:OnsetSnapshot)->Int {
        let range=snapshot.selection,count=snapshot.text.utf16.count
        guard range.location>=0,range.length>=0,range.location<=count,range.length<=count-range.location else{return 5}
        if range.length>0{return 4}
        return range.location==0 ? 1:(range.location==count ? 2:3)
    }
    private static func unicode(_ snapshot:OnsetSnapshot)->Int {
        let range=snapshot.selection
        guard range.length==0,range.location>0,range.location<=snapshot.text.utf16.count else{return 0}
        switch CFStringGetCharacterAtIndex(snapshot.text as CFString,range.location-1) {
        case 0x3130...0x318F:return 1
        case 0x1100...0x115F,0xA960...0xA97F:return 2
        case 0x1160...0x11A7,0xD7B0...0xD7C6:return 3
        case 0x11A8...0x11FF,0xD7CB...0xD7FF:return 4
        case 0xAC00...0xD7A3:return 5
        default:return 6
        }
    }
}
