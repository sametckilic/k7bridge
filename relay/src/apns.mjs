import http2 from "node:http2";
import { createPrivateKey, createSign } from "node:crypto";

const base64url = (value) => Buffer.from(value).toString("base64url");

export class APNSSender {
  constructor({ teamId, keyId, privateKey, environment = "production" }) {
    this.teamId = teamId;
    this.keyId = keyId;
    this.privateKey = createPrivateKey(privateKey);
    this.origin = environment === "development"
      ? "https://api.development.push.apple.com"
      : "https://api.push.apple.com";
    this.cachedToken = null;
  }

  providerToken() {
    const now = Math.floor(Date.now() / 1000);
    if (this.cachedToken && now - this.cachedToken.createdAt < 50 * 60) {
      return this.cachedToken.value;
    }
    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.teamId, iat: now }));
    const unsigned = `${header}.${claims}`;
    const signer = createSign("SHA256");
    signer.update(unsigned);
    signer.end();
    const signature = signer.sign({ key: this.privateKey, dsaEncoding: "ieee-p1363" });
    const value = `${unsigned}.${signature.toString("base64url")}`;
    this.cachedToken = { createdAt: now, value };
    return value;
  }

  async sendVoIP(record, payload) {
    const client = http2.connect(this.origin);
    try {
      return await new Promise((resolve, reject) => {
        const request = client.request({
          ":method": "POST",
          ":path": `/3/device/${record.deviceToken}`,
          authorization: `bearer ${this.providerToken()}`,
          "apns-topic": `${record.bundleId}.voip`,
          "apns-push-type": "voip",
          "apns-priority": "10",
          "apns-expiration": "0"
        });
        let body = "";
        let status = 0;
        request.setEncoding("utf8");
        request.on("response", (headers) => { status = Number(headers[":status"]); });
        request.on("data", (chunk) => { body += chunk; });
        request.on("error", reject);
        request.on("end", () => {
          if (status === 200) resolve({ status });
          else reject(Object.assign(new Error(`APNs rejected request: ${status} ${body}`), { statusCode: 502 }));
        });
        request.end(JSON.stringify(payload));
      });
    } finally {
      client.close();
    }
  }
}

