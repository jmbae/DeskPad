import Foundation
import Darwin
final class Received: @unchecked Sendable {
    let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    var values: [Data] = []
    func add(_ data: Data) { lock.lock(); values.append(data); lock.unlock(); signal.signal() }
}
@main struct UDPSocketHarness {
    static func main() async throws {
        let ip = try await AppleHPUDPSocket.resolveIPv4(host: "localhost")
        precondition(ip == "127.0.0.1")
        let server = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { Darwin.close(server) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        precondition(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(result == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server,$0,&length) } }
        let collector = Received()
        let client = try AppleHPUDPSocket(remoteIPv4: ip, port: UInt16(bigEndian: address.sin_port), localPort: 0, receive: { collector.add($0) })
        client.send(Data([1,2,3]))
        var peer = sockaddr_in(), buffer = [UInt8](repeating: 0, count: 16)
        let count = withUnsafeMutablePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server,&buffer,16,0,$0,&length) } }
        precondition(count == 3 && Array(buffer.prefix(3)) == [1,2,3])
        let attacker = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { Darwin.close(attacker) }
        for (fd, payload) in [(attacker, [UInt8(99)]), (server, [UInt8(4),5,6])] {
            _ = payload.withUnsafeBytes { bytes in withUnsafePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd,bytes.baseAddress,bytes.count,0,$0,length)
            } } }
        }
        precondition(collector.signal.wait(timeout: .now()+2) == .success)
        precondition(collector.signal.wait(timeout: .now()+0.05) == .timedOut)
        precondition(collector.values == [Data([4,5,6])])
        client.close(); client.close(); client.send(Data([7]))
        print("PASS: off-main IPv4 DNS, ephemeral local bind, localhost roundtrip, unexpected source-port rejection, idempotent close")
    }
}
