import Foundation
import Security
import Darwin

/// A single bounded local reply. Directory/socket creation can fail, but sending
/// a permission result never creates or writes a result file. Each request has
/// a fresh private directory (nonce); peers must match this executable's signing
/// requirement and the kernel's UID/audit token, not a PID supplied in JSON.
final class PermissionProbeChannel {
    private let listener:Int32
    private var peer:Int32 = -1
    private var peerPID:pid_t=0
    private var bytes=Data()
    private let lock=NSLock()
    private var authentication:Result<Void,OperationalFailure>?
    private static let identitySlot=DispatchSemaphore(value:1)
    private static let identityQueue=DispatchQueue(label:"taek.in.hanq.probe-identity")
    private static func configuredSocket()->Int32 {
        let fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else{return -1}
        var one:Int32=1
        guard fcntl(fd,F_SETFL,O_NONBLOCK)==0,fcntl(fd,F_SETFD,FD_CLOEXEC)==0,
              setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout.size(ofValue:one)))==0 else{let code=errno;close(fd);errno=code;return -1}
        return fd
    }
    private static func address(_ directory:URL)throws->sockaddr_un {
        let path=Array(directory.appendingPathComponent("reply.sock").path.utf8)+[0]
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        guard path.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw OperationalFailure.policy(.transport,1)}
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:path)}
        return address
    }
    init(directory:URL)throws {
        _ = try PrivateProbeDirectory.checkedOpen(directory,prefix:"hanq-permission-").get()
        var address=try Self.address(directory)
        let fd=Self.configuredSocket();guard fd>=0 else{throw OperationalFailure.posix(.transport,errno)}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard result==0,listen(fd,1)==0 else{let code=errno;close(fd);throw OperationalFailure.posix(.transport,code)}
        listener=fd
    }
    deinit{close(listener);if peer>=0{close(peer)}}
    private static func sameCode(_ audit:Data)->Result<Void,OperationalFailure> {
        var own:SecCode?,ownStatic:SecStaticCode?,requirement:SecRequirement?,guest:SecCode?
        let flags=SecCSFlags(rawValue:0)
        func failure(_ code:OSStatus)->Result<Void,OperationalFailure>{.failure(.init(stage:.transport,domain:.osStatus,code:Int(code),underlyingPOSIX:0))}
        var code=SecCodeCopySelf(flags,&own)
        guard code==errSecSuccess,let own else{return failure(code)}
        code=SecCodeCopyStaticCode(own,flags,&ownStatic)
        guard code==errSecSuccess,let ownStatic else{return failure(code)}
        code=SecCodeCopyDesignatedRequirement(ownStatic,flags,&requirement)
        guard code==errSecSuccess,let requirement else{return failure(code)}
        code=SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:audit] as CFDictionary,flags,&guest)
        guard code==errSecSuccess,let guest else{return failure(code)}
        code=SecCodeCheckValidity(guest,flags,requirement)
        return code==errSecSuccess ? .success(()):failure(code)
    }
    func receive()->Result<Data?,OperationalFailure> {
        if peer<0 {
            let fd=accept(listener,nil,nil)
            guard fd>=0 else{let code=errno;return code==EAGAIN || code==EWOULDBLOCK ? .success(nil):.failure(.posix(.transport,code))}
            peer=fd
            var one:Int32=1
            guard fcntl(fd,F_SETFL,O_NONBLOCK)==0,fcntl(fd,F_SETFD,FD_CLOEXEC)==0 else{return .failure(.posix(.transport,errno))}
            guard setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout.size(ofValue:one)))==0 else{return .failure(.posix(.transport,errno))}
            var uid:uid_t=0,gid:gid_t=0,token=audit_token_t(),pid:pid_t=0
            var tokenSize=socklen_t(MemoryLayout.size(ofValue:token)),pidSize=socklen_t(MemoryLayout.size(ofValue:pid))
            guard getpeereid(fd,&uid,&gid)==0,
                  getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&tokenSize)==0,
                  getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&pidSize)==0 else{return .failure(.posix(.transport,errno))}
            guard uid==getuid(),pid>0 else{return .failure(.policy(.transport,2))}
            peerPID=pid
            guard Self.identitySlot.wait(timeout:.now()) == .success else{return .failure(.policy(.transport,3))}
            let data=withUnsafeBytes(of:token){Data($0)}
            Self.identityQueue.async{[weak self] in
                defer{Self.identitySlot.signal()}
                let valid=Self.sameCode(data)
                if let self{self.lock.lock();self.authentication=valid;self.lock.unlock()}
            }
        }
        lock.lock();let valid=authentication;lock.unlock()
        guard let valid else{return .success(nil)}
        if case .failure(let error)=valid{return .failure(error)}
        var buffer=[UInt8](repeating:0,count:8193)
        let count=recv(peer,&buffer,buffer.count,0)
        if count<0 {let code=errno;return [EAGAIN,EWOULDBLOCK,EINTR].contains(code) ? .success(nil):.failure(.posix(.transport,code))}
        guard count>0 else{return .failure(.policy(.transport,5))}
        guard bytes.count+count<=8193 else{return .failure(.policy(.transport,6))}
        bytes.append(contentsOf:buffer.prefix(count))
        guard let end=bytes.firstIndex(of:10) else{return .success(nil)}
        guard end==bytes.count-1 else{return .failure(.policy(.transport,7))}
        let data=Data(bytes.dropLast())
        // Acknowledge even malformed messages so a fixture/helper can exit;
        // acceptance is still subject to decoding/token checks in the monitor.
        var ack:UInt8=1
        _ = Darwin.send(peer,&ack,1,MSG_DONTWAIT)
        if let result=try? JSONDecoder().decode(PermissionProbeResult.self,from:data),result.pid != peerPID{return .failure(.policy(.transport,8))}
        return .success(data)
    }
    static func send(_ data:Data,to directory:URL,timeout:TimeInterval=1)throws {
        _ = try PrivateProbeDirectory.checkedOpen(directory,prefix:"hanq-permission-").get()
        guard data.count<=8192 else{throw OperationalFailure.policy(.probeEncode,1)}
        var address=try address(directory)
        let fd=configuredSocket();guard fd>=0 else{throw OperationalFailure.posix(.transport,errno)}
        defer{close(fd)}
        let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else{throw OperationalFailure.posix(.transport,errno)}
        let payload=data+Data([10]),deadline=ProcessInfo.processInfo.systemUptime+timeout
        var offset=0
        while offset<payload.count {
            let count=payload.withUnsafeBytes{Darwin.send(fd,$0.baseAddress!.advanced(by:offset),$0.count-offset,MSG_DONTWAIT)}
            if count>0{offset+=count;continue}
            let code=errno
            guard count<0,[EAGAIN,EWOULDBLOCK,EINTR].contains(code) else{throw OperationalFailure.posix(.transport,code)}
            guard ProcessInfo.processInfo.systemUptime<deadline else{throw OperationalFailure.posix(.transport,ETIMEDOUT)}
            var event=pollfd(fd:fd,events:Int16(POLLOUT),revents:0);_ = poll(&event,1,10)
        }
        while ProcessInfo.processInfo.systemUptime<deadline {
            var ack:UInt8=0
            let count=recv(fd,&ack,1,MSG_DONTWAIT)
            if count==1,ack==1{return}
            if count==0{throw OperationalFailure.policy(.transport,5)}
            if count<0 {let code=errno;if ![EAGAIN,EWOULDBLOCK,EINTR].contains(code){throw OperationalFailure.posix(.transport,code)}}
            var event=pollfd(fd:fd,events:Int16(POLLIN),revents:0);_ = poll(&event,1,10)
        }
        throw OperationalFailure.posix(.transport,ETIMEDOUT)
    }
}
