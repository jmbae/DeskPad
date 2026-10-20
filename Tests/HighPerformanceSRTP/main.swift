import Foundation
func hex(_ s: String) -> Data { let b=Array(s.utf8); return Data(stride(from:0,to:b.count,by:2).map { UInt8(String(bytes:b[$0..<$0+2],encoding:.utf8)!,radix:16)! }) }
func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(),message) }
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let blob=hex(fixture["blob"] as! String), expected=hex(fixture["plain"] as! String)
let packets=(fixture["packets"] as! [String]).map(hex)
let rfc=try HighPerformanceSRTPKeys(masterKeyBlob:hex("f0f04914b513f2763a1b1fa130f10e2998f6f6e43e4309d1e622a0e332b9f1b63b04803de51ee7c96423ab5b78d2"))
check(rfc.encryption == hex("5ba1064e30ec51613cad926c5a28ef731ec7fb397f70a960653caf06554cd8c4"),"RFC6188 AES256 key")
check(rfc.salt == hex("fa31791685ca444a9e07c6c64e93"),"RFC6188 salt")
var receiver=try HighPerformanceSRTPReceiver(masterKeyBlob:blob)
for packet in packets.prefix(5) { let result=try receiver.receive(packet); check(result.payload == expected,"decrypt and wrap/reorder") }
func rejects(_ packet:Data, receiver:inout HighPerformanceSRTPReceiver) { do { _=try receiver.receive(packet); fatalError("accepted invalid/replayed packet") } catch {} }
rejects(packets[4],receiver:&receiver)
rejects(packets[5],receiver:&receiver)
let another=try receiver.receive(packets[6]); check(another.ssrc == 123 && another.payload == expected,"independent SSRC and extension")
var clean=try HighPerformanceSRTPReceiver(masterKeyBlob:blob)
for i in packets[0].indices { var bad=packets[0]; bad[i] ^= 1; rejects(bad,receiver:&clean) }
let untouched=try clean.receive(packets[0]); check(untouched.payload == expected,"tampering did not poison state")
for length in 0..<22 { rejects(Data(repeating:0,count:length),receiver:&clean) }
do { _=try HighPerformanceSRTPReceiver(masterKeyBlob:Data(repeating:0,count:45)); fatalError("invalid key accepted") } catch {}
print("SRTP: RFC6188 KDF and independent OpenSSL payload vectors, wrap/reorder/replay/tamper passed")
check(rfc.authentication == hex("fd9c32d39ed5fbb5a9dc96b30818454d1313dc05"),"RFC6188 auth key")
let control=(fixture["rtcp"] as! [String]).map(hex)
var rtcp=try HighPerformanceSRTCPReceiver(masterKeyBlob:blob)
for data in control.prefix(4) { let plaintext=try rtcp.receive(data); let reports=try HighPerformanceSenderReport.parseCompound(plaintext); check(reports.count == 1 && reports[0].rtpTimestamp == 90000,"RTCP reports") }
for data in [control[3],control[4]] { do { _=try rtcp.receive(data); fatalError("RTCP replay accepted") } catch {} }
var rtcpFresh=try HighPerformanceSRTCPReceiver(masterKeyBlob:blob)
for i in control[0].indices { var bad=control[0]; bad[i] ^= 1; do { _=try rtcpFresh.receive(bad); fatalError("RTCP tamper accepted") } catch {} }
let valid=try rtcpFresh.receive(control[0]); check(valid.count == 28,"RTCP tamper poisoned state")
print("SRTCP: encrypted and authenticated-only SR, reorder, replay and all-byte tampering passed")
