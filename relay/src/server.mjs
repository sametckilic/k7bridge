import { createServer } from "node:http";

const jsonHeaders = { "content-type": "application/json", "cache-control": "no-store" };
const gatewayPattern = /^[A-Za-z0-9_-]{16,80}$/;
const tokenPattern = /^[a-fA-F0-9]{64,400}$/;

export function createRelayServer({ store, apns, allowedBundleId }) {
  return createServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/healthz") {
        return send(response, 200, { ok: true });
      }
      if (request.method === "POST" && request.url === "/v1/registrations") {
        const body = await readJSON(request, 8_192);
        requireFields(body, ["gatewayId", "relaySecret", "deviceToken", "bundleId", "environment"]);
        if (!gatewayPattern.test(body.gatewayId) || !tokenPattern.test(body.deviceToken)) badRequest("invalid identifier or device token");
        if (body.bundleId !== allowedBundleId) badRequest("bundleId is not allowed");
        if (!["development", "production"].includes(body.environment)) badRequest("invalid environment");
        validateSecret(body.relaySecret);
        const result = await store.register(body);
        return send(response, 201, result);
      }
      const pushMatch = request.url?.match(/^\/v1\/gateways\/([^/]+)\/voip-push$/);
      if (request.method === "POST" && pushMatch) {
        const gatewayId = decodeURIComponent(pushMatch[1]);
        const secret = bearer(request.headers.authorization);
        const record = store.authenticate(gatewayId, secret);
        if (!record) return send(response, 401, { error: "unauthorized" });
        const body = await readJSON(request, 5_120);
        requireFields(body, ["callId", "nonce", "encryptedEnvelope"]);
        if (String(body.encryptedEnvelope).length > 4096) badRequest("envelope too large");
        await apns.sendVoIP(record, {
          v: 1,
          gatewayId,
          callId: String(body.callId),
          nonce: String(body.nonce),
          envelope: String(body.encryptedEnvelope)
        });
        return send(response, 202, { accepted: true });
      }
      send(response, 404, { error: "not_found" });
    } catch (error) {
      send(response, error.statusCode ?? 500, { error: error.statusCode ? error.message : "internal_error" });
    }
  });
}

function validateSecret(value) {
  if (typeof value !== "string" || value.length < 32 || value.length > 256) badRequest("relaySecret must be 32…256 characters");
}

function bearer(header) {
  const match = /^Bearer (.+)$/i.exec(header ?? "");
  if (!match) {
    const error = new Error("missing bearer token");
    error.statusCode = 401;
    throw error;
  }
  validateSecret(match[1]);
  return match[1];
}

async function readJSON(request, limit) {
  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (Buffer.byteLength(body) > limit) {
      const error = new Error("payload too large");
      error.statusCode = 413;
      throw error;
    }
  }
  try { return JSON.parse(body || "{}"); }
  catch { badRequest("invalid JSON"); }
}

function requireFields(body, fields) {
  for (const field of fields) if (body[field] === undefined || body[field] === "") badRequest(`missing ${field}`);
}

function badRequest(message) {
  const error = new Error(message);
  error.statusCode = 400;
  throw error;
}

function send(response, status, value) {
  if (response.writableEnded) return;
  response.writeHead(status, jsonHeaders);
  response.end(JSON.stringify(value));
}

