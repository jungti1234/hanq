import AppKit
import Carbon

// Only this fixture's synthetic text is compared. No arbitrary text or key
// payload is written to its result files, including on a failed comparison.
let longTwoSet = "com.apple.inputmethod.Korean.2SetKorean"
let longABC = "com.apple.keylayout.ABC"
func longSourceID(_ source:TISInputSource)->String {
    guard let p=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else{return ""}
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func longSource()->String { TISCopyCurrentKeyboardInputSource().map{longSourceID($0.takeRetainedValue())} ?? "" }
func longWrite(_ root:URL,_ name:String,_ object:[String:Any]) {
    do { try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(name),options:.atomic) }
    catch { fputs("long-input result write failed\n",stderr); exit(2) }
}
final class LongSourceState {
    let original=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let initiallyEnabled:[String],initiallySelectable:[String]
    var added:[TISInputSource]=[]
    var mayChangeSource:()->Bool=ownedInputSourceChangeAllowed
    var selectSource:(TISInputSource)->OSStatus=ownedSelectInputSource
    var enableSource:(TISInputSource)->OSStatus=ownedEnableInputSource
    var disableSource:(TISInputSource)->OSStatus=ownedDisableInputSource
    var currentSourceID:()->String=longSource
    var currentEnabledIDs:()->[String]={LongSourceState.enabled()}
    private(set) var needsCleanup=false
    static func enabled(_ manageableOnly:Bool=true)->[String] {
        (TISCreateInputSourceList(nil,false)?.takeRetainedValue() as? [TISInputSource] ?? []).filter {
            guard let raw=TISGetInputSourceProperty($0,kTISPropertyInputSourceIsSelectCapable) else{return false}
            guard CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) else{return false}
            if !manageableOnly{return true}
            guard let category=TISGetInputSourceProperty($0,kTISPropertyInputSourceCategory),
                  Unmanaged<CFString>.fromOpaque(category).takeUnretainedValue()==kTISCategoryKeyboardInputSource else{return false}
            guard let value=TISGetInputSourceProperty($0,kTISPropertyInputSourceIsEnableCapable) else{return false}
            return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
        }.map(longSourceID).sorted()
    }
    // OS-managed palette/emoji entries can appear without a persistent enable
    // setting. Record that list separately; never enable/disable those entries.
    init(){initiallyEnabled=Self.enabled();initiallySelectable=Self.enabled(false)}
    func select(_ id:String)->Bool {
        guard mayChangeSource() else{return false}
        guard let source=(TISCreateInputSourceList([kTISPropertyInputSourceID as String:id] as CFDictionary,true)?.takeRetainedValue() as? [TISInputSource])?.first else{return false}
        if !Self.enabled(false).contains(id) {
            guard mayChangeSource() else{return false}
            needsCleanup=true
            if !added.contains(where:{longSourceID($0)==id}){added.append(source)}
            guard enableSource(source)==noErr else{return false}
        }
        guard mayChangeSource() else{return false}
        needsCleanup=true
        let selected=selectSource(source)==noErr
        if selected{needsCleanup=id != original.map(longSourceID) || currentSourceID() != original.map(longSourceID) || !added.isEmpty};return selected
    }
    func restore()->Bool {
        guard needsCleanup else{return true}
        guard mayChangeSource() else{return false}
        let selected=original.map{selectSource($0)==noErr} ?? false
        var remaining:[TISInputSource]=[]
        for source in added {
            if !mayChangeSource() || disableSource(source) != noErr{remaining.append(source)}
        }
        added=remaining
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while (currentSourceID() != original.map(longSourceID) || currentEnabledIDs() != initiallyEnabled),
              ProcessInfo.processInfo.systemUptime<deadline,mayChangeSource() {
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
        let restored=selected && added.isEmpty && currentSourceID()==original.map(longSourceID) && currentEnabledIDs()==initiallyEnabled
        if restored{needsCleanup=false};return restored
    }
}
final class LongField:NSTextView {
    var staleRole=false
    var observedOriginalDowns=0,observedRepairDowns=0,forcedRoman=0,pasteCalls=0
    var lastPasteReceived=0.0,lastPasteHandled=0.0
    var firstOriginalReceived=0.0,lastOriginalReceived=0.0,lastOriginalHandled=0.0,originalHandlingSeconds=0.0
    var receiptCheckpoints:[[String:Double]]=[]
    var originalReceiptTimes:[Double]=[],originalHandledTimes:[Double]=[]
    func resetReceiptTiming(){
        firstOriginalReceived=0;lastOriginalReceived=0;lastOriginalHandled=0;originalHandlingSeconds=0;receiptCheckpoints=[]
        originalReceiptTimes.removeAll(keepingCapacity:true);originalHandledTimes.removeAll(keepingCapacity:true)
        originalReceiptTimes.reserveCapacity(1500);originalHandledTimes.reserveCapacity(1500)
    }
    var forceRoman=false
    var deletionCaret:Int?,deletionSuffixCount=0,deletionEvidence:[String:Any]=[:]
    private func knownEditingState()->String {
        guard let caret=deletionCaret else{return "not_observed"}
        let text=string as NSString,length=text.length-caret-deletionSuffixCount
        guard caret>=0,length>=0,length<=12,caret+length<=text.length else{return "other"}
        // Emit only fixed synthetic-state labels, never an arbitrary substring.
        let value=text.substring(with:NSRange(location:caret,length:length))
        return ["":"empty","ㄱ":"giyuk","가":"ga","간":"gan","감":"gam","ㅁ":"mieum","간ㅁ":"gan_mieum","a":"latin_a"][value] ?? "other"
    }
    override func accessibilityRole()->NSAccessibility.Role? {staleRole ? .button:super.accessibilityRole()}
    override func keyDown(with event:NSEvent) {
        staleRole=false
        let repair=(UInt64(bitPattern:event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)>>32)==0x48414e51
        if repair {observedRepairDowns+=1;forceRoman=false} else {observedOriginalDowns+=1}
        let began=ProcessInfo.processInfo.systemUptime
        if !repair {
            if firstOriginalReceived==0{firstOriginalReceived=began};lastOriginalReceived=began
            if originalReceiptTimes.count<1500{originalReceiptTimes.append(began)}
            if observedOriginalDowns%32==0,receiptCheckpoints.count<16{receiptCheckpoints.append(["count":Double(observedOriginalDowns),"uptime":began])}
        }
        defer {if !repair{
            lastOriginalHandled=ProcessInfo.processInfo.systemUptime;originalHandlingSeconds+=lastOriginalHandled-began
            if originalHandledTimes.count<1500{originalHandledTimes.append(lastOriginalHandled)}
        }}
        if forceRoman,!repair,let letter=[UInt16(2):"d",UInt16(40):"k"][event.keyCode] {
            forcedRoman+=1;insertText(letter,replacementRange:selectedRange());return
        }
        if deletionCaret != nil,event.keyCode==51 {
            deletionEvidence["markedBeforeDelete"]=hasMarkedText();deletionEvidence["beforeDeleteState"]=knownEditingState()
            super.keyDown(with:event)
            deletionEvidence["markedAfterDelete"]=hasMarkedText();deletionEvidence["afterDeleteState"]=knownEditingState();return
        }
        let retype=deletionCaret != nil && event.keyCode==0 && deletionEvidence["beforeDeleteState"] != nil && deletionEvidence["afterRetypeState"]==nil
        super.keyDown(with:event)
        if retype{deletionEvidence["afterRetypeState"]=knownEditingState();deletionEvidence["retypeSourceKorean"]=longSource()==longTwoSet}
    }
    override func paste(_ sender:Any?){pasteCalls+=1;lastPasteReceived=ProcessInfo.processInfo.systemUptime;super.paste(sender);lastPasteHandled=ProcessInfo.processInfo.systemUptime}
}
func longContext(_ count:Int,singleParagraph:Bool=false)->(String,String) {
    // Supplementary scalar and decomposed text exercise UTF-16 offsets.
    let value=("앞🙂e\u{301} "+String(repeating:"한",count:count)+"\n검증 위치: "," 뒤🙂 끝\n"+String(repeating:"뒤",count:300))
    if singleParagraph{return (value.0.replacingOccurrences(of:"\n",with:" "),value.1.replacingOccurrences(of:"\n",with:" "))}
    return value
}
func longField(_ frame:NSRect)->LongField {
    let f=LongField(frame:frame);f.isRichText=false;f.isAutomaticTextReplacementEnabled=false
    f.isAutomaticSpellingCorrectionEnabled=false;f.isAutomaticQuoteSubstitutionEnabled=false
    f.isAutomaticDashSubstitutionEnabled=false
    f.font=NSFont.monospacedSystemFont(ofSize:14,weight:.regular)
    return f
}
func longInstallMenus() {
    let menu=NSMenu(),app=NSMenuItem(),appItems=NSMenu();app.submenu=appItems;menu.addItem(app)
    appItems.addItem(withTitle:"종료",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    let edit=NSMenuItem(title:"편집",action:nil,keyEquivalent:""),items=NSMenu();edit.submenu=items;menu.addItem(edit)
    items.addItem(withTitle:"잘라내기",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
    items.addItem(withTitle:"복사",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
    items.addItem(withTitle:"붙여넣기",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
    items.addItem(withTitle:"전체 선택",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
    NSApp.mainMenu=menu
}
struct LongKey {
    let code:Int
    var shift=false,command=false,rightCommand=false,rightOption=false
    var gap:Double?
    var json:[String:Any] {
        var v:[String:Any]=["code":code,"shift":shift,"command":command,"rightCommand":rightCommand,"rightOption":rightOption]
        if let gap {v["gap"]=gap};return v
    }
}
let longSentence="왼쪽과 오른쪽을 오가며 확인합니다. "
let longSentenceKeys:[LongKey]=[(2,false),(4,false),(37,false),(1,false),(13,true),(4,false),(15,false),(15,false),(4,false),(40,false),(49,false),(2,false),(4,false),(3,false),(46,false),(1,false),(13,true),(4,false),(15,false),(2,false),(46,false),(3,false),(49,false),(2,false),(4,false),(15,false),(40,false),(0,false),(32,false),(49,false),(5,false),(4,false),(40,false),(15,false),(2,false),(37,false),(1,false),(5,false),(40,false),(12,false),(1,false),(37,false),(14,false),(40,false),(47,false),(49,false)].map{LongKey(code:$0.0,shift:$0.1)}
let longGan=[15,40,1].map{LongKey(code:$0)}
let longABCKeys=[0,11,8].map{LongKey(code:$0)}
func longDifference(_ actual:String,_ expected:String)->[String:Any] {
    let a=Array(actual.utf16),e=Array(expected.utf16);var first=0
    while first<min(a.count,e.count),a[first]==e[first]{first+=1}
    var suffix=0
    while suffix<min(a.count,e.count)-first,a[a.count-1-suffix]==e[e.count-1-suffix]{suffix+=1}
    return ["actualUTF16":a.count,"expectedUTF16":e.count,"exact":a==e,
            "commonPrefixUTF16":first,"commonSuffixUTF16":suffix,"actualDifferingUTF16":a.count-first-suffix,"expectedDifferingUTF16":e.count-first-suffix]
}
