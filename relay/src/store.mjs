import { createHash, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const hashSecret = (secret) => createHash("sha256").update(secret, "utf8").digest("hex");

export class RegistrationStore {
  constructor(filePath) {
    this.filePath = filePath;
    this.records = new Map();
  }

  async load() {
    if (!this.filePath) return;
    try {
      const parsed = JSON.parse(await readFile(this.filePath, "utf8"));
      for (const record of parsed.records ?? []) this.records.set(record.gatewayId, record);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }

  async register({ gatewayId, relaySecret, deviceToken, bundleId, environment }) {
    const existing = this.records.get(gatewayId);
    const secretHash = hashSecret(relaySecret);
    if (existing && !safeHexEqual(existing.secretHash, secretHash)) {
      const error = new Error("gateway authentication failed");
      error.statusCode = 401;
      throw error;
    }
    const record = {
      gatewayId,
      secretHash,
      deviceToken: deviceToken.toLowerCase(),
      bundleId,
      environment,
      updatedAt: new Date().toISOString()
    };
    this.records.set(gatewayId, record);
    await this.persist();
    return { gatewayId, updatedAt: record.updatedAt };
  }

  authenticate(gatewayId, relaySecret) {
    const record = this.records.get(gatewayId);
    return record && safeHexEqual(record.secretHash, hashSecret(relaySecret)) ? record : null;
  }

  async persist() {
    if (!this.filePath) return;
    await mkdir(dirname(this.filePath), { recursive: true });
    const temporary = `${this.filePath}.tmp`;
    await writeFile(temporary, JSON.stringify({ records: [...this.records.values()] }, null, 2));
    await rename(temporary, this.filePath);
  }
}

function safeHexEqual(left, right) {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

