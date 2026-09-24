import Foundation

func check(_ ok:Bool,_ name:String){if !ok{FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8));exit(1)}}
func candidate(_ text:String,_ caret:Int,_ baseline:String?=nil,_ code:UInt16=15,_ shift:Bool=false,_ time:Double=0.1)->RecoveryPlan? {
    var d=OnsetDetector()
    d.outsideKey(code:code,shift:shift,time:0,korean:true,plain:true)
    d.entered(time:0.05)
    return d.firstConsonant(time:time,text:text,selection:NSRange(location:caret,length:0),previousText:baseline)
}
check(candidate("ㄱ",1)?.codes.count==1,"single consonant")
check(candidate("앞ㄱ뒤",2,"앞뒤")?.caret==1,"exact surrounding baseline")
check(candidate("앞ㄱ뒤",2)==nil,"unknown existing text excluded")
check(candidate("변ㄱ뒤",2,"앞뒤")==nil,"changed prefix excluded")
check(candidate("ㄱㅏ",2)==nil,"split pair never becomes a repair plan")
check(candidate("가",1)==nil,"composed syllable excluded")
check(candidate("ㄱ",0)==nil,"caret before consonant excluded")
check(candidate("ㄱ",2)==nil,"invalid range excluded")
check(candidate("ㄱ",1,nil,15,false,0.36)==nil,"expired key excluded")
for (code,text):(UInt16,String) in [(15,"ㄲ"),(14,"ㄸ"),(12,"ㅃ"),(17,"ㅆ"),(13,"ㅉ")] {
    check(candidate(text,1,nil,code,true)?.codes.first?.1==true,"double consonant retains Shift")
}
var d=OnsetDetector()
d.outsideKey(code:15,shift:false,time:0,korean:false,plain:true)
check(d.first==nil,"English excluded")
d.outsideKey(code:15,shift:false,time:0,korean:true,plain:false)
check(d.first==nil,"shortcut excluded")
d.outsideKey(code:40,shift:false,time:0,korean:true,plain:true)
check(d.first==nil,"vowel excluded")
print("PASS: single-consonant detector, exact baseline, double consonants, invalid/expired/shortcut/pair input excluded")
