import { APNSSender } from "./apns.mjs";
import { createRelayServer } from "./server.mjs";
import { RegistrationStore } from "./store.mjs";

const required = ["APNS_TEAM_ID", "APNS_KEY_ID", "APNS_PRIVATE_KEY_BASE64", "ALLOWED_BUNDLE_ID"];
for (const key of required) if (!process.env[key]) throw new Error(`Missing environment variable ${key}`);

const store = new RegistrationStore(process.env.DATA_FILE ?? "./data/registrations.json");
await store.load();
const apns = new APNSSender({
  teamId: process.env.APNS_TEAM_ID,
  keyId: process.env.APNS_KEY_ID,
  privateKey: Buffer.from(process.env.APNS_PRIVATE_KEY_BASE64, "base64").toString("utf8"),
  environment: process.env.APNS_ENVIRONMENT
});
const server = createRelayServer({ store, apns, allowedBundleId: process.env.ALLOWED_BUNDLE_ID });
server.listen(Number(process.env.PORT ?? 8080), "0.0.0.0", () => {
  process.stdout.write(`K7Bridge relay listening on ${process.env.PORT ?? 8080}\n`);
});

