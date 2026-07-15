# Physical-device audio gate

1. Keep the gateway disconnected from production use and make a test call with a
   consenting second party.
2. Do not attach Frida to `mediaserverd`; two discovery attempts on the target build
   crashed that process. Confirm `k7-audio-tap-check` captures 16 kHz system PCM and
   record the exact iOS build number.
3. Confirm the daemon reports both `ATAudioTap` and `AVAudioPlayer.mixToUplink` as
   available before placing a call.
4. Prove downlink capture, uplink injection, and simultaneous operation for at
   least 1,800 seconds. Hash the exact hook dylib used in the test.
5. Fill `report.template.json`, run `verify_audio_gate.py`, copy the resulting file to
   `/var/mobile/Library/K7Bridge/audio-gate.json`, and keep the signed report.

The shipping package contains no `K7AudioBridge` dylib. Keep it that way unless a future
OS build removes the safer daemon-owned routes and a replacement is independently
verified.
