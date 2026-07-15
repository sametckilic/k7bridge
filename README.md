# K7Bridge

## Tek komutla gateway dağıtımı

En güncel commit'in başarılı gateway artifact'ını indirip eski iPhone'a kurmak için:

```powershell
.\scripts\deploy-gateway.ps1
```

Farklı bir cihaz adresi kullanılacaksa `-DeviceHost` parametresi verilebilir. Script mevcut GitHub
kimlik bilgisini yalnız artifact indirmek için bellekte kullanır ve SSH/sudo parolalarını saklamaz.

K7Bridge turns a jailbroken iPhone 7 into a single-SIM GSM gateway for a modern,
non-jailbroken iPhone. The repository contains four independently testable parts:

- `ios-client/`: SwiftUI, CallKit and PushKit client (iOS 18+).
- `gateway/`: rootless palera1n/Theos package for the iPhone 7.
- `relay/`: opaque VoIP-push relay for an always-on Render Web Service.
- `shared/`: versioned wire protocol and test fixtures.

## Audio safety gate

The abandoned AudioUnit/Frida experiment is not shipped. It guessed a render hook and
could crash `mediaserverd`. The current design keeps all media work in `k7bridged`:

- downlink: entitled iOS 15 `ATAudioTap`, verified on the target iPhone at 16 kHz;
- uplink: `AVAudioPlayer`'s runtime-checked telephony-uplink route;
- transport: call-derived ChaCha20-Poly1305 UDP packets, 16 kHz mono PCM, 20 ms.

The daemon fails closed when either private route is absent. A 30-minute physical call
is still required before calling the audio gate production-qualified.

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
| Bidirectional cellular audio bridge | Encrypted PCM implemented; 30-minute device acceptance pending |
| Automatic hotspot activation | Not enabled without a verified iOS 15 selector; manual fallback is required |

## First device run

1. Deploy and test `relay/`, then put its HTTPS URL into the provisioning command.
2. Build/install `gateway/`, provision its TLS identity, and restart the launch daemon.
3. Inspect the daemon log and paste or scan `pairing-url.txt` in the client.
4. Grant microphone access on the new iPhone and verify one two-way call.
5. Run the 30-minute audio, loss, latency and route-change acceptance suite.
6. Replace PCM with Opus only after the verified PCM baseline is stable.
