# K7Bridge control protocol v1

The local channel is a pinned-certificate WSS connection. Every JSON object contains:

```json
{
  "v": 1,
  "type": "heartbeat",
  "messageId": "8A1A146B-5BE7-47AB-8AA6-9E59EE075E70",
  "sequence": 42,
  "sentAt": "2026-07-12T12:00:00.000Z",
  "payload": {},
  "auth": "base64-HMAC-SHA256"
}
```

`messageId` is the idempotency key. The receiver retains the latest 256 identifiers.
`sequence` is strictly increasing per connection. A gap triggers `snapshotRequest`;
replayed or decreasing sequences are rejected.

After the unauthenticated one-time `pair` request, client messages authenticate
`type|messageId|sequence|sha256(sorted-json-payload)` with HMAC-SHA256 using the
X25519/HKDF pairing key. The WSS certificate DER SHA-256 is pinned from the QR document.

## Message types

| Type | Direction | Required payload |
|---|---|---|
| `pair` | client → gateway | `clientId`, `clientPublicKey`, `oneTimeCode` |
| `pairResult` | gateway → client | `gatewayId`, `certificateSHA256`, `relayURL` |
| `snapshotRequest` | client → gateway | empty |
| `diagnosticsRequest` | client → gateway | `limit` |
| `diagnosticsPage` | gateway → client | structured recent entries and telephony health |
| `snapshot` | gateway → client | `call`, `device`, `smsCursor` |
| `heartbeat` | both | optional `activeCallId` |
| `incomingCall` | gateway → client | `callId`, `handle`, `displayName` |
| `dial` | client → gateway | `callId`, `handle` |
| `answer`, `reject`, `end` | client → gateway | `callId` |
| `dtmf` | client → gateway | `callId`, `digit` |
| `callUpdate` | gateway → client | `callId`, `state`, optional `reason` |
| `smsList` | client → gateway | optional `cursor`, `limit` (1…100) |
| `smsPage` | gateway → client | `items`, optional `nextCursor` |
| `smsSend` | client → gateway | `smsId`, `handle`, `text` |
| `smsUpdate` | gateway → client | `smsId`, `state`, optional `error` |
| `deviceStatus` | gateway → client | device status fields |
| `error` | both | `code`, `message`, optional `refMessageId` |

Call states are `idle`, `incoming`, `dialing`, `connecting`, `active`, `ended`, and
`failed`. SMS states are `queued`, `sent`, and `failed`.

## Media packet v1

UDP datagrams are encrypted with a per-call ChaCha20-Poly1305 key derived with HKDF.
The authenticated (unencrypted) header is:

```
0               1               2               3
+-------+-------+---------------+-------------------------------+
| ver=1 | flags | sequence u16  | timestampSamples u32          |
+-------+-------+---------------+-------------------------------+
| callIdHash u32                | nonceSuffix u32                |
+-------------------------------+-------------------------------+
| ciphertext (Opus, 16 kHz mono, 20 ms) ... | Poly1305 tag      |
+---------------------------------------------------------------+
```

The 12-byte nonce is `directionPrefix(4) || sequenceEpoch(4) || nonceSuffix(4)`.
Sequence wrap increments the epoch; reuse of a nonce terminates the media session.
