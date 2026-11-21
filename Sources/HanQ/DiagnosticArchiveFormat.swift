import Foundation

struct DiagnosticApplicationReferences:Codable,Equatable {
    let target:Int,owner:Int
    var packed:UInt64{UInt64(target)<<32 | UInt64(owner)}
    static func ids(_ packed:UInt64)->Set<Int>{Set([Int(packed>>32),Int(packed&0xffffffff)]).subtracting([0])}
    var valid:Bool{target>=0 && owner>=0 && target<=Int(Int32.max) && owner<=Int(Int32.max)}
    static func parse(_ value:Any)->Self? {
        guard let object=value as? [String:Any],Set(object.keys)==Set(["target","owner"]),
              let data=try? JSONSerialization.data(withJSONObject:object),
              let decoded=try? JSONDecoder().decode(Self.self,from:data),decoded.valid else{return nil}
        return decoded
    }
}
struct DiagnosticApplicationRecord:Codable,Equatable {
    let id:Int,pid:Int32
    var name:String?,bundleID:String?,version:String?,build:String?,launchMilliseconds:Int64?
    var shortened=false
    var valid:Bool {
        id>0 && id<=Int(Int32.max) && pid>0 &&
        [name,bundleID].allSatisfy{$0.map{$0.utf8.count<=1024 && $0.unicodeScalars.allSatisfy{!CharacterSet.controlCharacters.contains($0)}} ?? true} &&
        [version,build].allSatisfy{$0.map{$0.utf8.count<=256 && $0.unicodeScalars.allSatisfy{!CharacterSet.controlCharacters.contains($0)}} ?? true} &&
        (launchMilliseconds.map{$0>=0 && $0<=9_000_000_000_000_000} ?? true)
    }
    var memoryCharge:Int{256+[name,bundleID,version,build].compactMap{$0}.reduce(0){$0+$1.utf8.count*2}}
}
struct DiagnosticApplicationSnapshot:Codable {
    var schema=1
    let records:[DiagnosticApplicationRecord],unavailableReferences:[Int]
    var valid:Bool{schema==1 && records.count<=128 && records.allSatisfy(\.valid) && Set(records.map(\.id)).count==records.count && unavailableReferences.count<=131104 && Set(unavailableReferences).count==unavailableReferences.count && unavailableReferences.allSatisfy{$0>0 && $0<=Int(Int32.max)} && Set(records.map(\.id)).isDisjoint(with:unavailableReferences)}
    static func parse(_ value:Any)->Self? {
        guard let object=value as? [String:Any],Set(object.keys)==Set(["schema","records","unavailableReferences"]),
              let rows=object["records"] as? [[String:Any]],rows.count<=128,
              rows.allSatisfy({Set($0.keys).subtracting(["name","bundleID","version","build","launchMilliseconds"])==Set(["id","pid","shortened"]) && $0.values.allSatisfy{!($0 is NSNull)}}),
              let data=try? JSONSerialization.data(withJSONObject:object),
              let decoded=try? JSONDecoder().decode(Self.self,from:data),decoded.valid else{return nil}
        return decoded
    }
}
import Darwin
import CryptoKit
import Compression

// The on-disk version and dictionary are explicit. Keys are diagnostic schema
// names, never user text. Integer values retain their full 64-bit range.
enum DiagnosticPackedError:Error {case invalid,oversized}
final class DiagnosticPackedCodec {
    static let shared=DiagnosticPackedCodec()
    private let lock=NSLock()
    private var names:[String]=[],ids:[String:UInt64]=[:]
    var fields:[String] {lock.lock();defer{lock.unlock()};return names}
    func encode<T:Encodable>(_ value:T)throws->Data {
        lock.lock();defer{lock.unlock()}
        let buffer=DiagnosticPackedBuffer(key:{[self] key in
            if let value=ids[key]{return value}
            guard names.count<4096,key.utf8.count<256 else{throw DiagnosticPackedError.oversized}
            let value=UInt64(names.count);names.append(key);ids[key]=value;return value
        })
        try value.encode(to:DiagnosticPackedEncoder(buffer:buffer))
        if let failure=buffer.failure{throw failure}
        guard buffer.data.count<=65536 else{throw DiagnosticPackedError.oversized}
        return buffer.data
    }
    func decode<T:Decodable>(_ type:T.Type,from data:Data)throws->T {
        let object=try Self.object(data,fields:fields)
        return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed]))
    }
    static func object(_ data:Data,fields:[String])throws->Any {
        guard data.count<=65536,fields.count<=4096 else{throw DiagnosticPackedError.oversized}
        let bytes=[UInt8](data);var offset=0
        func byte()throws->UInt8 {guard offset<bytes.count else{throw DiagnosticPackedError.invalid};defer{offset+=1};return bytes[offset]}
        func unsigned()throws->UInt64 {
            var result:UInt64=0
            for i in 0..<10 {let b=try byte();if i==9,b>1{throw DiagnosticPackedError.invalid};result |= UInt64(b&127) << (i*7);if b<128{return result}}
            throw DiagnosticPackedError.invalid
        }
        func count()throws->Int {
            var n:UInt32=0;for i in 0..<4{n |= UInt32(try byte()) << (i*8)}
            guard n<=UInt32(bytes.count) else{throw DiagnosticPackedError.invalid};return Int(n)
        }
        func value(_ depth:Int)throws->Any {
            guard depth<32 else{throw DiagnosticPackedError.invalid}
            switch try byte() {
            case 0:return NSNull()
            case 1:return false
            case 2:return true
            case 3:return NSNumber(value:try unsigned())
            case 4:return NSNumber(value:Int64(bitPattern:~(try unsigned())))
            case 5:
                var bits:UInt64=0;for i in 0..<8{bits |= UInt64(try byte()) << (i*8)}
                let result=Double(bitPattern:bits);guard result.isFinite else{throw DiagnosticPackedError.invalid};return result
            case 6:
                let n=try unsigned();guard n<=UInt64(bytes.count-offset) else{throw DiagnosticPackedError.invalid}
                defer{offset+=Int(n)};guard let s=String(bytes:bytes[offset..<offset+Int(n)],encoding:.utf8) else{throw DiagnosticPackedError.invalid};return s
            case 7:
                var result:[String:Any]=[:]
                for _ in 0..<(try count()) {
                    let id=try unsigned();guard id<fields.count else{throw DiagnosticPackedError.invalid}
                    let key=fields[Int(id)];guard result[key]==nil else{throw DiagnosticPackedError.invalid}
                    result[key]=try value(depth+1)
                };return result
            case 8:
                var result:[Any]=[];for _ in 0..<(try count()){result.append(try value(depth+1))};return result
            default:throw DiagnosticPackedError.invalid
            }
        }
        let result=try value(0);guard offset==bytes.count else{throw DiagnosticPackedError.invalid};return result
    }
}
private final class DiagnosticPackedBuffer {
    var data=Data()
    var failure:Error?
    let key:(String)throws->UInt64
    init(key:@escaping (String)throws->UInt64){self.key=key;data.reserveCapacity(256)}
    func unsigned(_ value:UInt64){var v=value;while v>=128{data.append(UInt8(v&127)|128);v >>= 7};data.append(UInt8(v))}
    func signed(_ value:Int64){if value>=0{data.append(3);unsigned(UInt64(value))}else{data.append(4);unsigned(~UInt64(bitPattern:value))}}
    func container(_ tag:UInt8)->Int {data.append(tag);let offset=data.count;data.append(contentsOf:[0,0,0,0]);return offset}
    func count(_ offset:Int,_ value:Int){var v=UInt32(value).littleEndian;withUnsafeBytes(of:&v){data.replaceSubrange(offset..<offset+4,with:$0)}}
}
private final class DiagnosticPackedEncoder:Encoder {
    let buffer:DiagnosticPackedBuffer
    var codingPath:[CodingKey]=[]
    var userInfo:[CodingUserInfoKey:Any]=[:]
    init(buffer:DiagnosticPackedBuffer){self.buffer=buffer}
    func container<Key:CodingKey>(keyedBy type:Key.Type)->KeyedEncodingContainer<Key>{
        KeyedEncodingContainer(DiagnosticPackedKeyed<Key>(buffer:buffer,state:DiagnosticPackedCount(buffer,7)))
    }
    func unkeyedContainer()->UnkeyedEncodingContainer{DiagnosticPackedUnkeyed(buffer:buffer,state:DiagnosticPackedCount(buffer,8))}
    func singleValueContainer()->SingleValueEncodingContainer{DiagnosticPackedSingle(buffer:buffer)}
}
private final class DiagnosticPackedCount {
    let offset:Int;var count=0
    init(_ buffer:DiagnosticPackedBuffer,_ tag:UInt8){offset=buffer.container(tag)}
    func add(_ buffer:DiagnosticPackedBuffer){count+=1;buffer.count(offset,count)}
}
private struct DiagnosticPackedKeyed<Key:CodingKey>:KeyedEncodingContainerProtocol {
    let buffer:DiagnosticPackedBuffer,state:DiagnosticPackedCount
    var codingPath:[CodingKey]{[]}
    private func field(_ key:Key)throws{state.add(buffer);buffer.unsigned(try buffer.key(key.stringValue))}
    mutating func encodeNil(forKey key:Key)throws{try field(key);buffer.data.append(0)}
    mutating func encode<T:Encodable>(_ value:T,forKey key:Key)throws{try field(key);try value.encode(to:DiagnosticPackedEncoder(buffer:buffer))}
    mutating func nestedContainer<NestedKey:CodingKey>(keyedBy type:NestedKey.Type,forKey key:Key)->KeyedEncodingContainer<NestedKey>{
        // Synthesized diagnostic Codable types use encode(_:forKey:). A custom
        // nested container still preserves the same schema key.
        do{try field(key)}catch{buffer.failure=error};return DiagnosticPackedEncoder(buffer:buffer).container(keyedBy:type)
    }
    mutating func nestedUnkeyedContainer(forKey key:Key)->UnkeyedEncodingContainer{do{try field(key)}catch{buffer.failure=error};return DiagnosticPackedEncoder(buffer:buffer).unkeyedContainer()}
    mutating func superEncoder()->Encoder{DiagnosticPackedEncoder(buffer:buffer)}
    mutating func superEncoder(forKey key:Key)->Encoder{do{try field(key)}catch{buffer.failure=error};return DiagnosticPackedEncoder(buffer:buffer)}
}
private struct DiagnosticPackedUnkeyed:UnkeyedEncodingContainer {
    let buffer:DiagnosticPackedBuffer,state:DiagnosticPackedCount
    var codingPath:[CodingKey]{[]};var count:Int{state.count}
    mutating func encodeNil()throws{state.add(buffer);buffer.data.append(0)}
    mutating func encode<T:Encodable>(_ value:T)throws{state.add(buffer);try value.encode(to:DiagnosticPackedEncoder(buffer:buffer))}
    mutating func nestedContainer<NestedKey:CodingKey>(keyedBy type:NestedKey.Type)->KeyedEncodingContainer<NestedKey>{state.add(buffer);return DiagnosticPackedEncoder(buffer:buffer).container(keyedBy:type)}
    mutating func nestedUnkeyedContainer()->UnkeyedEncodingContainer{state.add(buffer);return DiagnosticPackedEncoder(buffer:buffer).unkeyedContainer()}
    mutating func superEncoder()->Encoder{state.add(buffer);return DiagnosticPackedEncoder(buffer:buffer)}
}
private struct DiagnosticPackedSingle:SingleValueEncodingContainer {
    let buffer:DiagnosticPackedBuffer
    var codingPath:[CodingKey]{[]}
    mutating func encodeNil()throws{buffer.data.append(0)}
    mutating func encode(_ value:Bool)throws{buffer.data.append(value ? 2:1)}
    mutating func encode(_ value:String)throws{buffer.data.append(6);let b=Data(value.utf8);buffer.unsigned(UInt64(b.count));buffer.data.append(b)}
    mutating func encode(_ value:Double)throws{guard value.isFinite else{throw DiagnosticPackedError.invalid};buffer.data.append(5);var bits=value.bitPattern.littleEndian;withUnsafeBytes(of:&bits){buffer.data.append(contentsOf:$0)}}
    mutating func encode(_ value:Float)throws{try encode(Double(value))}
    mutating func encode(_ value:Int)throws{buffer.signed(Int64(value))}
    mutating func encode(_ value:Int8)throws{buffer.signed(Int64(value))}
    mutating func encode(_ value:Int16)throws{buffer.signed(Int64(value))}
    mutating func encode(_ value:Int32)throws{buffer.signed(Int64(value))}
    mutating func encode(_ value:Int64)throws{buffer.signed(value)}
    mutating func encode(_ value:UInt)throws{buffer.data.append(3);buffer.unsigned(UInt64(value))}
    mutating func encode(_ value:UInt8)throws{buffer.data.append(3);buffer.unsigned(UInt64(value))}
    mutating func encode(_ value:UInt16)throws{buffer.data.append(3);buffer.unsigned(UInt64(value))}
    mutating func encode(_ value:UInt32)throws{buffer.data.append(3);buffer.unsigned(UInt64(value))}
    mutating func encode(_ value:UInt64)throws{buffer.data.append(3);buffer.unsigned(value)}
    mutating func encode<T:Encodable>(_ value:T)throws{try value.encode(to:DiagnosticPackedEncoder(buffer:buffer))}
}

// A typed JSON value avoids treating true and 1 as the same metadata value.
enum DiagnosticJSON:Codable,Equatable {
    case null,bool(Bool),integer(Int64),real(Double),string(String),array([Self]),object([String:Self])
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}
        else if let v=try? c.decode(Bool.self){self = .bool(v)}
        else if let v=try? c.decode(Int64.self){self = .integer(v)}
        else if let v=try? c.decode(Double.self){self = .real(v)}
        else if let v=try? c.decode(String.self){self = .string(v)}
        else if let v=try? c.decode([Self].self){self = .array(v)}
        else{self = .object(try c.decode([String:Self].self))}
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer()
        switch self {
        case .null:try c.encodeNil()
        case .bool(let v):try c.encode(v)
        case .integer(let v):try c.encode(v)
        case .real(let v):try c.encode(v)
        case .string(let v):try c.encode(v)
        case .array(let v):try c.encode(v)
        case .object(let v):try c.encode(v)
        }
    }
    struct Change:Codable {let path:[String];let value:DiagnosticJSON?}
    static func changes(from old:Self,to new:Self,path:[String]=[])->[Change] {
        if case .object(let a)=old,case .object(let b)=new {
            var result=a.keys.filter{b[$0]==nil}.sorted().map{Change(path:path+[$0],value:nil)}
            for key in b.keys.sorted(){if let previous=a[key]{result+=changes(from:previous,to:b[key]!,path:path+[key])}else{result.append(Change(path:path+[key],value:b[key]!))}}
            return result
        }
        return old==new ? []:[Change(path:path,value:new)]
    }
    mutating func apply(_ changes:[Change])throws {
        func setting(_ root:Self,_ path:ArraySlice<String>,_ value:Self?)throws->Self? {
            guard let key=path.first else{return value}
            guard case .object(var fields)=root else{throw DiagnosticPackedError.invalid}
            if path.count==1{fields[key]=value}
            else {guard let child=fields[key] else{throw DiagnosticPackedError.invalid};fields[key]=try setting(child,path.dropFirst(),value)}
            return .object(fields)
        }
        for change in changes{guard change.path.count<=32,let changed=try setting(self,change.path[...],change.value) else{throw DiagnosticPackedError.invalid};self=changed}
    }
}

enum DiagnosticArchiveIO {
    static let chunkBytes = 64 * 1024
    /// Hash/copy bounded chunks while checking both the open file and its name.
    /// A changed, linked or replaced snapshot is never published as reviewed.
    @discardableResult
    static func scan(_ url:URL,maximum:Int,check:()throws->Void = {},
                     consume:(Data)throws->Void = {_ in})throws->(bytes:Int,digest:String) {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{close(fd)}
        let before=try regular(fd,maximum:maximum)
        var hash=SHA256(),total=0,buffer=[UInt8](repeating:0,count:chunkBytes)
        while true {
            try check()
            let count=Darwin.read(fd,&buffer,buffer.count)
            if count<0{if errno==EINTR{continue};throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
            if count==0{break}
            guard count<=maximum-total else{throw DiagnosticPackedError.oversized}
            try autoreleasepool {
                let data=Data(buffer.prefix(count));hash.update(data:data);try consume(data)
            }
            total+=count
        }
        var named=stat()
        guard total==before.st_size,same(before,try regular(fd,maximum:maximum)),
              lstat(url.path,&named)==0,named.st_mode&S_IFMT==S_IFREG,same(before,named) else{throw DiagnosticPackedError.invalid}
        return (total,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    static func copy(_ source:URL,to destination:URL,bytes:Int,digest:String,
                     check:()throws->Void = {})throws {
        let fd=open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        var completed=false
        defer{close(fd);if !completed{_ = unlink(destination.path)}}
        let actual=try scan(source,maximum:bytes,check:check){data in
            try data.withUnsafeBytes{buffer in
                var offset=0
                while offset<buffer.count {
                    try check()
                    let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0{if errno==EINTR{continue};throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
                    guard count>0 else{throw DiagnosticPackedError.invalid};offset+=count
                }
            }
        }
        guard actual.bytes==bytes,actual.digest==digest else{throw DiagnosticPackedError.invalid}
        completed=true
    }
    static func regular(_ fd:Int32,maximum:Int)throws->stat {
        var s=stat();guard fstat(fd,&s)==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        guard s.st_mode&S_IFMT==S_IFREG,s.st_uid==getuid(),s.st_mode&0o7777==0o600,s.st_nlink==1,s.st_size>=0,s.st_size<=maximum else{throw DiagnosticPackedError.invalid}
        return s
    }
    static func same(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    static func read(_ url:URL,maximum:Int)throws->Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{close(fd)};let before=try regular(fd,maximum:maximum)
        guard let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:maximum+1),data.count==before.st_size,
              same(before,try regular(fd,maximum:maximum)) else{throw DiagnosticPackedError.invalid}
        return data
    }
}

enum DiagnosticArchiveReader {
    static let maximumFileBytes=16*1024*1024
    struct FrameRange:Codable {let file:String;var first:Int;var count:Int}
    struct Header:Codable {
        let schema:Int,owner:String,runID:String,incident:Int,phase:Int,trigger:Int
        let milliseconds:Int64,metadataBase:String?,ranges:[FrameRange]
        let frameCount:Int,ownFrameCount:Int,rawBytes:Int,compressed:Bool,digest:String
        var role:Int?=nil // 0/nil capture, 1 metadata-only dependency
    }
    struct Packet:Codable {let sequence:Int,milliseconds:Int,data:Data}
    struct Payload:Codable {let fields:[String],frames:[Packet],changes:[DiagnosticJSON.Change]}
    static func validName(_ name:String)->Bool {name.hasPrefix("shared-") && name.hasSuffix(".hqdiag") && UUID(uuidString:String(name.dropFirst(7).dropLast(7))) != nil}
    static func readHeader(_ url:URL)throws->(Header,stat) {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        defer{close(fd)};let state=try DiagnosticArchiveIO.regular(fd,maximum:maximumFileBytes)
        var prefix=[UInt8](repeating:0,count:12);guard pread(fd,&prefix,12,0)==12,String(bytes:prefix.prefix(8),encoding:.utf8)=="HQSHR001" else{throw DiagnosticPackedError.invalid}
        let length=prefix[8..<12].enumerated().reduce(0){$0+(Int($1.element)<<($1.offset*8))}
        guard length>0,length<=1024*1024,12+length<Int(state.st_size) else{throw DiagnosticPackedError.invalid}
        var bytes=[UInt8](repeating:0,count:length);guard pread(fd,&bytes,length,12)==length else{throw DiagnosticPackedError.invalid}
        let header=try JSONDecoder().decode(Header.self,from:Data(bytes))
        guard header.schema==1,(0...1).contains(header.role ?? 0),header.role != 1 || (header.frameCount==0 && header.ownFrameCount==0),UUID(uuidString:header.owner) != nil,UUID(uuidString:header.runID) != nil,
              header.incident>0,(0...1).contains(header.phase),(1...8).contains(header.trigger),header.milliseconds>=0,
              header.rawBytes>0,header.rawBytes<=maximumFileBytes,header.frameCount>=0,header.frameCount<=65536,
              header.ownFrameCount>=0,header.ownFrameCount<=header.frameCount,
              header.metadataBase.map(validName) ?? true,header.ranges.allSatisfy({validName($0.file) && $0.first>=0 && $0.count>0 && $0.first<=65536-$0.count}),
              header.ranges.reduce(0,{$0+$1.count})==header.frameCount else{throw DiagnosticPackedError.invalid}
        return (header,state)
    }
    struct FileEvidence:Equatable {let bytes:Int,digest:String}
    static func read(_ url:URL,observe:((FileEvidence)->Void)?=nil)throws->(Header,Payload) {
        let (header,state)=try readHeader(url),data=try DiagnosticArchiveIO.read(url,maximum:maximumFileBytes)
        var after=stat();guard lstat(url.path,&after)==0,DiagnosticArchiveIO.same(state,after),data.count==state.st_size else{throw DiagnosticPackedError.invalid}
        let length=data[8..<12].enumerated().reduce(0){$0+(Int($1.element)<<($1.offset*8))},body=Data(data.dropFirst(12+length))
        guard SHA256.hash(data:body).map({String(format:"%02x",$0)}).joined()==header.digest else{throw DiagnosticPackedError.invalid}
        let raw:Data
        if header.compressed {
            var decoded=Data(count:header.rawBytes)
            let count=decoded.withUnsafeMutableBytes{dst in body.withUnsafeBytes{src in compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,dst.count,src.bindMemory(to:UInt8.self).baseAddress!,src.count,nil,COMPRESSION_ZLIB)}}
            guard count==header.rawBytes else{throw DiagnosticPackedError.invalid};raw=decoded
        }else{guard body.count==header.rawBytes else{throw DiagnosticPackedError.invalid};raw=body}
        let payload=try JSONDecoder().decode(Payload.self,from:raw)
        guard payload.frames.count==header.ownFrameCount,payload.fields.count<=4096,Set(payload.fields).count==payload.fields.count else{throw DiagnosticPackedError.invalid}
        observe?(FileEvidence(bytes:data.count,digest:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()))
        return (header,payload)
    }
    struct Selection {
        let name:String,directory:URL,header:Header,payload:Payload,metadata:DiagnosticJSON
        let metadataDependencies:Set<String>
        let metadataEvidence:[String:FileEvidence]
        /// Retain packed sources only; expanded objects live for one visit.
        /// Dependencies come from the same validated pass as the preview.
        func visit(check:()throws->Void = {},observe:(String,FileEvidence)throws->Void = {_,_ in},observePayload:(Header,Payload)->Void = {_,_ in},
                   _ body:([String:Any])throws->Void)throws->Set<String> {
            var dependencies=metadataDependencies,previousName="",previous:Payload?
            for (name,evidence) in metadataEvidence{try observe(name,evidence)}
            for range in header.ranges {
                try check()
                let source:Payload
                if range.file==name{source=payload}
                else if range.file==previousName,let previous{source=previous}
                else {
                    var evidence:FileEvidence?
                    let pair=try read(directory.appendingPathComponent(range.file),observe:{evidence=$0})
                    observePayload(pair.0,pair.1)
                    guard pair.0.owner==header.owner,pair.0.runID==header.runID else{throw DiagnosticPackedError.invalid}
                    try observe(range.file,evidence!)
                    source=pair.1;previousName=range.file;previous=source
                }
                dependencies.insert(range.file)
                guard range.first+range.count<=source.frames.count else{throw DiagnosticPackedError.invalid}
                for (index,p) in source.frames[range.first..<range.first+range.count].enumerated() {
                    if index%256==0{try check()}
                    try autoreleasepool {
                        let object=try DiagnosticPackedCodec.object(p.data,fields:source.fields)
                        guard let frame=object as? [String:Any],frame["sequence"] as? Int==p.sequence,
                              frame["milliseconds"] as? Int==p.milliseconds else{throw DiagnosticPackedError.invalid}
                        try body(frame)
                    }
                }
            }
            return dependencies
        }
    }
    static func selection(_ name:String,in directory:URL,observePayload:(Header,Payload)->Void = {_,_ in})throws->Selection {
        guard validName(name) else{throw DiagnosticPackedError.invalid}
        var visited=Set<String>(),dependencies=Set<String>(),evidence:[String:FileEvidence]=[:]
        func meta(_ name:String)throws->(Header,Payload,DiagnosticJSON) {
            guard visited.count<64,visited.insert(name).inserted else{throw DiagnosticPackedError.invalid}
            let (header,payload)=try read(directory.appendingPathComponent(name),observe:{evidence[name]=$0});dependencies.insert(name)
            observePayload(header,payload)
            var value:DiagnosticJSON = .object([:])
            if let base=header.metadataBase {let prior=try meta(base);guard prior.0.owner==header.owner else{throw DiagnosticPackedError.invalid};value=prior.2}
            try value.apply(payload.changes);return (header,payload,value)
        }
        let (header,payload,metadata)=try meta(name)
        return Selection(name:name,directory:directory,header:header,payload:payload,metadata:metadata,metadataDependencies:dependencies,metadataEvidence:evidence)
    }
    struct Expanded {let header:Header,metadata:DiagnosticJSON,frames:[[String:Any]],dependencies:Set<String>}
    static func expand(_ name:String,in directory:URL,includeFrames:Bool=true)throws->Expanded {
        let selection=try selection(name,in:directory)
        var frames:[[String:Any]]=[]
        let dependencies=includeFrames ? try selection.visit{frames.append($0)}:selection.metadataDependencies
        return Expanded(header:selection.header,metadata:selection.metadata,frames:frames,dependencies:dependencies)
    }
    static func normalized(_ name:String,in directory:URL)throws->Data {
        let result=try expand(name,in:directory)
        guard result.header.role != 1,case .object(let object)=result.metadata else{throw DiagnosticPackedError.invalid}
        var root=try JSONSerialization.jsonObject(with:JSONEncoder().encode(DiagnosticJSON.object(object))) as! [String:Any]
        guard root["runID"] as? String==result.header.runID,root["incident"] as? Int==result.header.incident,root["phase"] as? Int==result.header.phase,root["trigger"] as? Int==result.header.trigger else{throw DiagnosticPackedError.invalid}
        root["frames"]=result.frames
        return try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
    }
}
