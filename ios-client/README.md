# iOS client

Generate the Xcode project with `xcodegen generate`, replace the example bundle ID,
select the paid development team, and enable Push Notifications. The app reports every
VoIP push to CallKit before completing the PushKit callback.

During a CallKit audio session the client resamples microphone input to 16 kHz mono,
encrypts each 20 ms packet with a call-derived key, and plays authenticated downlink
PCM. The current local sideload build works while the app is active and during an
active CallKit call. Waking a terminated app for a new incoming call still requires a
VoIP APNs entitlement and therefore an Apple Developer provisioning profile.
