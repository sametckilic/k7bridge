# Physical-device audio gate

1. Keep the gateway disconnected from production use and make a test call with a
   consenting second party.
2. Install Frida on the palera1n phone. Attach `audio-discovery.js` separately to
   `mediaserverd`, `InCallService` (the verified iOS 15.7.5 target), and `CommCenter`;
   store each JSON message and the
   exact iOS build number.
3. Use the trace to create a build-specific hook in a separate branch. The discovery
   script itself is read-only and cannot pass the gate.
4. Prove downlink capture, uplink replacement, and simultaneous operation for at
   least 1,800 seconds. Hash the exact hook dylib used in the test.
5. Fill `report.template.json`, run `verify_audio_gate.py`, copy the resulting file to
   `/var/mobile/Library/K7Bridge/audio-gate.json`, and keep the signed report.

The checked-in `AudioBridge` still contains no guessed hook. Once the report exists,
implement only the symbols and buffer formats proven by that report, then bind startup
to both the OS build and dylib hash stored in the gate.
