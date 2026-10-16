import Foundation
import SonoFerryCore
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
@main struct SessionRecoveryTests {
    static func main() {
        var state = LDACPendingOpenCleanup()
        // Replay the failing 19:12 probe: an accepted open gets no terminal callback,
        // then its connection guardian reports the actual original ACL disconnect.
        for line in ["CONNECTION_DISCONNECTED handle=0000 connected=0", "CONNECT_DISARMED explicit=1 parentExited=0",
                     "CONNECT_CANCELED callback=1 originalDisconnected=0 retired=1",
                     "CONNECT_CANCELED callback=0 originalDisconnected=1 retired=0",
                     "CONNECT_CANCELED callback=0 originalDisconnected=1 retired=1 extra=1"] {
            state.observeConnector(line)
            check(!state.canRetire(acquiredCID: nil, helperExited: true, connectorExitedCleanly: true), "ambiguous or unrelated cancellation never proves original ACL ended")
        }
        state.observeConnector("CONNECT_CANCELED callback=0 originalDisconnected=1 retired=1")
        check(!state.canRetire(acquiredCID: nil, helperExited: false, connectorExitedCleanly: true), "live helper may still acquire a channel")
        check(!state.canRetire(acquiredCID: nil, helperExited: true, connectorExitedCleanly: false), "guardian must have exited cleanly")
        check(!state.canRetire(acquiredCID: 0x9709, helperExited: true, connectorExitedCleanly: true), "owned CID still requires its channel closure gate")
        check(state.canRetire(acquiredCID: nil, helperExited: true, connectorExitedCleanly: true), "ended original ACL plus exited owners settles unopened acquisition")
        check(!LDACPendingOpenCleanup().canRetire(acquiredCID: nil, helperExited: true, connectorExitedCleanly: true), "proof does not cross sessions")
        check(LDACPriorityControl.State(phase: "cleanup-required", error: "diagnostic", failureCode: "publicationUnavailable").startupFailure == .audioHostUnavailable, "explicit HAL unsent-publication failure is retryable after cleanup")
        for state in [LDACPriorityControl.State(phase: "configuring", error: nil, failureCode: "publicationUnavailable"),
                      .init(phase: "cleanup-required", error: "Target publication was not available before the configuration deadline."),
                      .init(phase: "cleanup-required", error: nil, failureCode: "unknown")] {
            check(state.startupFailure == nil, "phase, unknown code or error text alone never authorizes publication retry")
        }
        print("SESSION_OPEN_RETIREMENT PASS: failed trace, strict original ACL evidence, owner exit barriers, established CID exclusion, session isolation.")
    }
}
