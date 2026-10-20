import Foundation
@main struct Harness {
 static func main() {
  let bytes = AppleHPFeedback.pictureLoss(sender: 0x01020304, media: 0xaabbccdd)
  precondition(bytes == Data([0x81,206,0,2,1,2,3,4,0xaa,0xbb,0xcc,0xdd]))
  print("PASS RTCP PLI framing")
 }
}
