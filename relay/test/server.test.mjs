import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { createRelayServer } from "../src/server.mjs";
import { RegistrationStore } from "../src/store.mjs";

const pushes = [];
const store = new RegistrationStore(null);
const server = createRelayServer({
  store,
  allowedBundleId: "com.example.K7Bridge",
  apns: { async sendVoIP(record, payload) { pushes.push({ record, payload }); } }
});
let baseURL;

before(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseURL = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

test("health check", async () => {
  const response = await fetch(`${baseURL}/healthz`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test("registers and sends only opaque push content", async () => {
  const secret = "s".repeat(48);
  const gatewayId = "gateway_0123456789abcdef";
  const registration = await fetch(`${baseURL}/v1/registrations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ gatewayId, relaySecret: secret, deviceToken: "ab".repeat(32), bundleId: "com.example.K7Bridge", environment: "production" })
  });
  assert.equal(registration.status, 201);
  const push = await fetch(`${baseURL}/v1/gateways/${gatewayId}/voip-push`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${secret}` },
    body: JSON.stringify({ callId: "call-1", nonce: "nonce", encryptedEnvelope: "ciphertext" })
  });
  assert.equal(push.status, 202);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].payload.envelope, "ciphertext");
  assert.equal(pushes[0].payload.caller, undefined);
});

test("rejects a wrong secret", async () => {
  const response = await fetch(`${baseURL}/v1/gateways/gateway_0123456789abcdef/voip-push`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${"x".repeat(48)}` },
    body: JSON.stringify({ callId: "call-2", nonce: "n", encryptedEnvelope: "c" })
  });
  assert.equal(response.status, 401);
});

