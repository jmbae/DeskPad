# HP session lifetime regression

Run without a remote connection:

```sh
swiftc -swift-version 6 DeskPad/AppleHPSessionLifecycle.swift Tests/HPLifecycle/Harness.swift -o /tmp/deskpad-hp-lifecycle-test
/tmp/deskpad-hp-lifecycle-test
```

Covers startup timeout, presentation cancelling the timeout, terminal-session
reuse rejection, idempotent ordered cancellation, and rejection of display
mutation when no verified restoration implementation exists.

Integration requirements:

- Create a lifecycle for every attempt, call begin before network startup.
- Supply nonblocking cancellation closures; control closure must call
  `NWConnection.forceCancel()` (abortive TCP close), not merely cancel a reader.
- Stop on user disconnect, background, error, peer close, and parent cancellation.
- Call presentationConfirmed only after actual output presentation is established.
  Authentication, received media, enqueued buffers, or pipeline.isPlaying alone
  do not prove a frame was shown or sound was rendered.
- Call validateDisplayPolicy before any 0x1d display configuration or curtain path.
  Current implementation intentionally rejects these operations. A baseline RFB
  size cannot restore the physical screen's mode, identity, scale, or arrangement.

Protocol evidence, investigated read-only:

- Local reference `src/isharescreen/proxy/session.py`,
  `_teardown_negotiation_tcp` and `close`, uses SO_LINGER {1,0} then close
  (TCP RST). Its comments report native-client no-goodbye behavior and a long
  FIN teardown delay. This justifies abortive close, not a claim of restoration.
- `src/isharescreen/proxy/protocol/rfb.py:build_virtual_display` constructs
  0x1d virtual-display creation/resize. It does not provide a documented physical
  display restoration message or a verified count-zero removal operation.
- Existing live prototype altered host display state and did not establish
  restoration after termination. Therefore this change neither sends invented
  rollback packets nor claims the host is restored when local cleanup finishes.

Source reference is AGPL; implementation here is independently authored from
protocol facts, using no copied implementation. No live-host test was performed.
