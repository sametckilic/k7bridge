# iOS client

Generate the Xcode project with `xcodegen generate`, replace the example bundle ID,
select the paid development team, and enable Push Notifications. The app reports every
VoIP push to CallKit before completing the PushKit callback.

The checked-in media engine intentionally does not transmit microphone PCM until the
gateway audio probe passes. This prevents a UI-only build from appearing to provide a
working cellular audio bridge.

