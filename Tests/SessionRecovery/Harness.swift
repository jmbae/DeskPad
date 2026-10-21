import Foundation
@main struct Harness {
 static func main() {
    var p = SessionRecoveryPolicy(); let generation = p.generation
    precondition(p.failure(recoverable:true,generation:generation) == .stop, "startup failures do not spend established retry budget")
    p.connected()
    for n in 1...3 {
        precondition(p.failure(recoverable:true,generation:generation) == .retry(attempt:n,delay:[1.0,2,4][n-1]))
        p.connected()
    }
    precondition(p.failure(recoverable:true,generation:generation) == .stop)
    var background = SessionRecoveryPolicy(); let bgGeneration = background.generation
    background.connected(); background.background()
    precondition(background.failure(recoverable:true,generation:bgGeneration) == .paused && background.attempts == 0)
    precondition(background.activate() == .retry(attempt:1,delay:1) && background.activate() == nil)
    background.background(); background.pause()
    precondition(background.activate() == .resume && background.attempts == 1)
    background.background(); precondition(background.activate() == nil, "healthy short background must keep same connection")
    precondition(background.failure(recoverable:false,generation:bgGeneration) == .stop && background.attempts == 1)
    background.background(); background.pause(); background.close()
    precondition(background.activate() == nil)
    precondition(background.failure(recoverable:true,generation:bgGeneration) == .stop)
    var cancelled = SessionRecoveryPolicy();cancelled.connected()
    precondition(cancelled.failure(recoverable:true,generation:cancelled.generation,cancelled:true) == .stop && cancelled.attempts == 0)
    precondition(cancelled.failure(recoverable:true,generation:UUID()) == .stop)
    print("Recovery 1/2/4s budget, startup/auth exclusion, deferred background failure, pause/short-return and stale/cancel generation passed")
 }
}
