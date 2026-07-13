# K7Bridge

K7Bridge turns a jailbroken iPhone 7 into a single-SIM GSM gateway for a modern,
non-jailbroken iPhone. The repository contains four independently testable parts:

- `ios-client/`: SwiftUI, CallKit and PushKit client (iOS 18+).
- `gateway/`: rootless palera1n/Theos package for the iPhone 7.
- `relay/`: opaque VoIP-push relay for an always-on Render Web Service.
- `shared/`: versioned wire protocol and test fixtures.

## Safety gate

The cellular audio bridge is deliberately fail-closed. `AudioBridge` only emits
diagnostics until the scripts under `gateway/probes/` have identified and verified
the actual iOS 15 audio path on the target phone. Do not enable injection by guessing
symbols: a wrong hook can crash `mediaserverd` and interrupt every audio service.

The gate passes only after a 30-minute cellular call proves both downlink capture and
uplink replacement without a process crash. Call control, SMS and status work can be
tested separately, but they do not constitute a completed voice gateway.

## Repository bootstrap

1. Enrol in the Apple Developer Program and create an App ID with Push Notifications
   and Voice over IP background mode.
2. Copy `relay/.env.example` to the Render secret configuration. Never commit the APNs
   `.p8` value.
3. On macOS, install XcodeGen and run `xcodegen generate` in `ios-client/`.
4. Build `gateway/` with Theos for a rootless iOS 15 target (`libsodium-dev` in the
   build environment; `libsodium23` on the phone) and install its `.deb` on
   the palera1n phone.
5. Follow `gateway/probes/README.md` before enabling the audio bridge.

See each component README for deployment and device-test instructions.

## Implemented status

| Area | Status |
|---|---|
| Versioned control protocol, sequence and HMAC authentication | Implemented |
| Opaque APNs relay, persistent registration store and tests | Implemented |
| SwiftUI screens, QR pairing, CallKit and PushKit orchestration | Implemented; macOS CI build pending credentials |
| TLS WebSocket gateway, call state machine and SMS read/send | Implemented; private selectors require device verification |
| Incoming-call observation and encrypted VoIP push request | Implemented; requires paired physical devices |
| Carrier, radio, SIM, battery, thermal and audio-gate status | Implemented; signal bars/hotspot remain conservative when private APIs are unavailable |
| Bidirectional cellular PCM/Opus bridge | Blocked by the mandatory physical-device audio gate |
| Automatic hotspot activation | Not enabled without a verified iOS 15 selector; manual fallback is required |

## First device run

1. Deploy and test `relay/`, then put its HTTPS URL into the provisioning command.
2. Build/install `gateway/`, provision its TLS identity, and restart the launch daemon.
3. Inspect the daemon log and paste or scan `pairing-url.txt` in the client.
4. Verify call control, SMS and status without enabling `K7AudioBridge`.
5. Run the audio probe and satisfy the 30-minute gate before adding the exact hook.
6. Only after the gate passes, enable Opus packet production in both media engines and
   run the loss, latency and route-change acceptance suite.
