# Gateway package

Build with a rootless Theos toolchain and Procursus `libsodium-dev`; the phone only
needs the `libsodium23` runtime package. Install the resulting
package on the iPhone 7, then run `scripts/provision-device.ps1` from a host with
OpenSSL, SSH and SCP. The daemon refuses to open a listener without its local identity.

`pairing-url.txt` can be pasted into the client. Rendering that string as a QR code is
presentation only; the one-time code and X25519 key agreement provide pairing.

Private selectors are resolved dynamically because they vary by iOS build. Their
presence and behavior must be verified on the exact phone before everyday use.

The package does not install an audio tweak. `k7bridged` listens on UDP 7444, captures
the active cellular downlink with an entitled `ATAudioTap`, and schedules authenticated
client PCM through the runtime-checked telephony uplink route. If either route is
missing, `audioGatePassed` remains false and the media session does not start.
