import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import { APNSSender } from "../src/apns.mjs";

test("creates a cached ES256 provider token", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const sender = new APNSSender({ teamId: "TEAM123456", keyId: "KEY1234567",
    privateKey: privateKey.export({ type: "pkcs8", format: "pem" }), environment: "development" });
  const first = sender.providerToken();
  const second = sender.providerToken();
  assert.equal(first, second);
  assert.equal(first.split(".").length, 3);
  const header = JSON.parse(Buffer.from(first.split(".")[0], "base64url"));
  assert.deepEqual(header, { alg: "ES256", kid: "KEY1234567" });
});
