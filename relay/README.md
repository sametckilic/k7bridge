# Opaque APNs relay

This dependency-free Node service stores one hashed relay secret and APNs token per
gateway. A push request contains only `callId`, `nonce`, and an encrypted envelope.
Caller identity is never accepted as a clear-text field.

Deploy `render.yaml` as a paid always-on Render Blueprint with its persistent disk.
Add the four APNs secrets from `.env.example`. `APNS_PRIVATE_KEY_BASE64` is the base64
encoding of the complete `.p8` file, not its path.

Run tests with Node 20 or newer:

```sh
npm test
```

