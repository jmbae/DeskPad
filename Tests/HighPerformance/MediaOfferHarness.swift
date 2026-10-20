import Foundation
@main struct MediaOfferHarness {
    static func main() throws {
        let first = try AppleHPMediaOffer.make(), second = try AppleHPMediaOffer.make()
        precondition(first.message != second.message)
        let keys = [first.audioKeys.viewerToServer, first.audioKeys.serverToViewer, first.videoKeys.viewerToServer, first.videoKeys.serverToViewer,
                    second.audioKeys.viewerToServer, second.audioKeys.serverToViewer, second.videoKeys.viewerToServer, second.videoKeys.serverToViewer]
        precondition(Set(keys).count == 8 && keys.allSatisfy { $0.count == 46 })
        print(first.message.base64EncodedString())
        print(first.audioSSRC)
        print(first.videoSSRC)
    }
}
