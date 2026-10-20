# Coding Agent Prompt for Building and Improving DeskPad

Pass the following prompt to a coding agent to build, complete, or improve DeskPad in this repository.

---

## Prompt

You are a senior Swift engineer experienced in native iOS/iPadOS apps, remote-desktop input and rendering, and network protocols. Build and improve DeskPad in this repository as a maintainable, secure, and genuinely usable VNC client for iPhone and iPad. Treat the existing implementation as a real product whose behavior and data must be understood and preserved: do not replace it wholesale or remove working features just to impose a new architecture. Refactor only where the task and evidence justify it. Do not stop at investigation or planning: implement the requested work in the current Xcode project, then run the relevant tests and builds.

### 1. Working principles and repository investigation

1. First inspect the Xcode project’s targets, supported platforms and minimum OS versions, build settings, entitlements, resources, current file organization, and tests. Do not change the existing project identifiers, signing settings, app icon, or target structure without being asked.
2. Review current app behavior and persisted data formats to determine which features must be preserved and what migration is required. Do not assume the current implementation is correct; verify protocol handling, concurrency, memory safety, and error paths.
3. Extend or refactor the app in place while preserving the Xcode project, user-created changes, and existing behavior that is not explicitly being changed. Do not delete or modify unrelated files, build settings, or assets.
4. Use only APIs supported by the project’s existing Swift version and minimum OS. Do not add unnecessary external packages. Resolve real constraints or ambiguities reasonably based on the repository; never report unsupported behavior as successful or hide errors.
5. Build the UI primarily with SwiftUI, using UIKit only at necessary boundaries such as precise remote-screen input and rendering. Define clear actor boundaries for state changes and UI updates, and follow Swift concurrency rules.

### 2. Product goals and existing product baseline

DeskPad is a native SwiftUI VNC client for iPhone and iPad. From first launch through adding a server, connecting, using keyboard/pointer input, and disconnecting, the experience should be natural and predictable. Prioritize the iPad’s larger display and hardware keyboard/trackpad, while ensuring layouts also work on supported iPhone form factors.

Before changing behavior, inventory and preserve the working product surfaces already present in the repository, including:

- Saved VNC connections, connection editing/deletion, recent-connection dates, atomic JSON metadata storage, Keychain credentials, and legacy-data migration.
- RFB version negotiation (including 3.3–3.8 where implemented), None/VNC-password/Apple Diffie–Hellman authentication, framebuffer updates and supported encodings, remote cursor handling, clipboard behavior, connection-state reporting, and retry/disconnect flows. The Apple RSA1 authentication and media offer are part of the experimental Apple-specific path, not a universal VNC capability.
- The UIKit remote-desktop surface embedded in SwiftUI, including viewport transforms, touch/mouse/trackpad input, scroll sensitivity, keyboard events, and Korean/other IME composition.
- The optional Apple-specific high-performance media path in `DeskPad/HighPerformance/` and its session integration. It is protocol-specific and experimental: verify its actual negotiation, authentication, encrypted media transport, playback, lifecycle, and fallback behavior before changing it. Do not silently remove it, present it as universally supported, or infer support from a successful RFB login.
- Existing tests and harnesses under `DeskPadTests/` and `Tests/`, including rendering, remote input, IME, session, storage, and high-performance media coverage.

Use the source and tests as the authority for current behavior; documentation may lag. Distinguish a defect from an intentional limitation, and update directly related documentation when behavior changes.

### 3. Screens and user flows

- **Connection home:** Show saved connections in an easy-to-scan list or card layout. Distinguish server name, address/port, and recent connection status. When there are no saved entries, provide a clear empty state and an action to add a connection.
- **Create/edit connection:** Accept and validate an optional display name, host/IP address, port, optional username, and password. Explain invalid addresses, empty hosts, and out-of-range ports before saving. Use a secure password field and do not accidentally discard an existing password while editing.
- **Connection management:** Allow users to add, edit, and delete entries. Confirm deletions, prevent duplicate submissions, and report save failures. Show connection-attempt status and allow cancellation.
- **Session screen:** Center the remote desktop and clearly distinguish connecting, waiting for the initial screen, connected, disconnected, authentication failure, and protocol error states. Provide the session name, disconnect, fit-to-screen/actual-size, reset-position, and keyboard visibility controls. Session controls must not obscure the screen on smaller displays.
- **Remote screen interaction:** Preserve and verify fit-to-screen and actual-size display, pinch-to-zoom, panning while zoomed, coordinate bounds checking, and large/wide/tall desktop rendering. Handle one-finger pointer movement/click/drag, secondary click, scrolling, and iPad pointer/trackpad input consistently where feasible. Account for gesture conflicts, cursor shape/hotspot, and screen-size changes.
- **Keyboard:** Distinguish hardware keyboard key-down/key-up events, modifiers, function keys, and ordinary text input. Deliver composed Korean and other IME text to the remote only after composition completes, and correctly handle cancellation, deletion, and special-key input during composition. Let users explicitly show and hide the on-screen keyboard.
- Provide accessibility labels, hints, and roles throughout; consider Dynamic Type and light/dark appearances. Respect the app’s existing language and style, and avoid excessive hard-coding of strings in view code.

### 4. App architecture and state model

Separate the UI, connection store, VNC connection lifecycle, RFB encoder/decoder, framebuffer, and remote input into components with clear responsibilities. Do not mix the state of an individual network session with the list of saved connections. Views must not perform protocol parsing or Keychain operations directly.

- Explicitly model at least these connection states: `disconnected`, `connecting`, `handshaking`, `authenticating`, `initializing`, `connected`, and `failed`. Separate user-understandable errors shown in the UI from internal diagnostic details.
- Repeated connect/disconnect/reconnect cycles must not leak a previous socket, task, receive buffer, framebuffer, or input state into a new session. Cancellation and late asynchronous callbacks must not overwrite state belonging to a newer session.
- Keep network work and pixel decoding off the main thread. Publish immutable frame snapshots safely to the UI, avoiding unnecessary full-frame copies and excessive SwiftUI re-rendering.
- Never ignore errors or replace them with arbitrary success-shaped defaults. On failure, present appropriate next steps such as retry, cancel, or correcting credentials.

### 5. VNC/RFB networking and protocol

- Implement TCP transport and the RFB handshake as separate, testable layers. Use a stream buffer/cursor that correctly handles data split across server sends as well as multiple messages received together. Never treat a partial network read as a message boundary.
- Correctly implement the RFB versions the client claims to support, including 3.3–3.8 negotiation where applicable, each version’s security negotiation, server rejection reasons, ServerInit, ClientInit, and server shutdown. Invalid versions, lengths, messages, or security results must end with explicit errors.
- Select only implemented security types, using a clear policy to choose among the types offered by the server. Never send a raw password in the clear. Explain that standard VNC challenge-response is weak and does not encrypt the session; make unauthenticated None security explicit and do not imply it authenticates the server. Do not handle a TLS-dependent type without TLS verification or represent a connection as TLS-secured. Never bypass server certificate validation.
- If VNC Authentication is supported, verify its 16-byte challenge/response, DES key bit order, and 8-byte password limit using known test vectors, and clearly inform users that it is weak authentication. Encryption or authentication failures must never be treated as success.
- Explicitly implement byte order for PixelFormat and message fields. Do not advertise encodings that are not implemented. Preserve and test every encoding currently advertised by the app (including Raw, CopyRect, DesktopSize, ZRLE, and cursor-related encodings where implemented); validate rectangle coordinates, dimensions, and encodings. If an unknown message or encoding breaks stream synchronization, safely terminate the session with an error rather than pretending to recover by discarding arbitrary bytes.
- After a DesktopSize change, safely recreate the framebuffer and request a full-screen update. Clearly define the implementation scope and limitations for incremental framebuffer updates, bell, and clipboard messages. Do not negotiate or present unimplemented features as supported.
- Check for overflow in rectangle-size multiplication and input lengths. Avoid excessive allocations caused by unreasonable screen dimensions, string lengths, or message lengths. Define reasonable limits and report errors explicitly.
- Distinguish and surface network timeouts, peer shutdown, send failures, authentication rejection, unsupported security types, and delays before the first frame. Prevent repeated automatic requests from causing infinite loops or high CPU usage.

### 6. Framebuffer and input handling

- Verify color channels, endianness, and row stride for supported PixelFormats. Check Raw rectangle clipping and CopyRect source/destination bounds; preserve the original region when CopyRect rectangles overlap.
- Validate screen-size limits before allocating. Ensure old buffers and images are released on reallocation, and prevent data races between concurrent decoding and rendering.
- Transform remote pointer coordinates consistently with fit/zoom/pan/rotation or screen-size changes, and keep coordinates within the UInt16 range. Maintain mouse-button masks and scroll press/release pairs correctly. Clear any pressed modifiers/buttons when the session ends.
- Separate special keys from printable/IME text in keysym mapping and preserve modifier press/release pairs. Document actual protocol limitations on Unicode input and never silently drop characters.

### 7. Stored data and credentials

- Persist connection metadata in a format compatible with the existing connection file and write files atomically. Report save, load, delete, and corrupted-data errors to the user; do not arbitrarily overwrite existing entries.
- Never store passwords in JSON, logs, diagnostic messages, screenshots, or thumbnails. Use Keychain and consistently scope items by service/account. Handle empty passwords and Keychain access, update, and delete failures.
- Existing JSON may contain plaintext passwords, so migrate to Keychain in a safe order. Do not remove source password data until Keychain storage succeeds. A failed migration must be retryable without data loss.
- If the current app stores the last connection in `UserDefaults`, migrate it without duplication and remove the original value only after success. Add migration tests.
- If recent-connection information or thumbnails are retained, align their lifecycle with connection data and handle disk-write failures and deletion. Thumbnails must not contain passwords or sensitive input.

### 8. Security and privacy

- Validate abnormal host, port, and server-response input. Prevent memory exhaustion, integer overflow, infinite loops, and UI hangs that could be triggered by a remote server.
- Never log credentials or full RFB payloads. Do not send data to servers the user did not specify or automatically perform remote actions.
- Allow only necessary network security settings. If an ATS exception is essential, minimize its scope and document and verify the reason alongside the build settings.
- Accurately describe security by protocol path. Standard VNC challenge-response is weak and does not encrypt the session; Apple Diffie–Hellman/RSA authentication must not be described as encrypting all RFB traffic. The Apple-specific high-performance media path has its own authentication and SRTP/SRTCP protection; verify and document exactly which traffic it protects. Do not imply that ordinary VNC sessions have TLS or transport encryption when they do not.
- Do not pretend to implement unsupported TLS or authentication types. Do not add certificate-validation bypasses or silently weaken authentication. Keep the existing trusted-network/VPN guidance consistent in the UI and documentation, and explain concrete limitations and safe alternatives.

### 9. Testing requirements

Write unit tests that fit the production code architecture and UI tests for feasible user flows. Do not replace existing tests with meaningless sample tests.

- Port and host validation; connection model encoding/decoding; legacy-data compatibility; password non-disclosure and Keychain migration.
- RFB versions, server security lists, security results, ServerInit, PixelFormat, client-message encoding, server-message decoding, and each advertised encoding including ZRLE/cursor extensions where applicable.
- Safe handling of input split into one-byte chunks or multiple messages at once, truncated messages, malformed fields, extremely large lengths, and unknown messages.
- Raw/CopyRect/ZRLE/cursor/screen-size changes, edge clipping, invalid-size and overflow protection, and known VNC authentication test vectors.
- Connection cancellation, failure, and reconnection; UI feedback for error states; connection creation/editing/deletion; and form validation.
- Existing IME composition, pointer/trackpad, scroll, large-desktop rendering, storage migration, and Apple high-performance media negotiation/transport/playback regressions.
- Design injectable transport and protocol boundaries so deterministic tests do not depend on a real external VNC server, network, or personal credentials.

### 10. Definition of done

Report the work as complete only when all of the following are satisfied:

1. The main SwiftUI screens and connection flow work, existing features remain intact unless explicitly changed, and the UI does not expose unimplemented features as available.
2. Saved connections and existing credential data are preserved, and passwords are not newly stored outside Keychain.
3. Network protocol and framebuffer boundary inputs are explicitly validated, and connection failure, cancellation, and reconnection states remain consistent.
4. Meaningful unit tests and necessary UI tests are added to verify the new behavior.
5. Run the project’s existing tests and build both the app and test targets in Xcode. Fix failures and validate again. If any validation cannot be run, explain why in the results.
6. Briefly report changed files, key design decisions, implemented features/limitations, and test/build results in the final response. Do not stop after providing only a plan or asking for further instructions.

First investigate the project, then begin implementation based on what you find.
