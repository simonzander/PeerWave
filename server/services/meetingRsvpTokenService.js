const crypto = require('crypto');
const config = require('../config/config');

const DEFAULT_TTL_DAYS = 30;

function base64urlEncode(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(String(input), 'utf8');
  return buffer
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function base64urlDecodeToString(input) {
  const b64 = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4;
  const padded = pad ? b64 + '='.repeat(4 - pad) : b64;
  return Buffer.from(padded, 'base64').toString('utf8');
}

function hmacSha256(secret, data) {
  return crypto.createHmac('sha256', secret).update(data).digest();
}

function timingSafeEqualString(a, b) {
  const aBuf = Buffer.from(a);
  const bBuf = Buffer.from(b);
  if (aBuf.length !== bBuf.length) return false;
  return crypto.timingSafeEqual(aBuf, bBuf);
}

function getSecret() {
  // Prefer explicit env var, fallback to session secret.
  return process.env.MEETING_RSVP_HMAC_SECRET || config.session?.secret || 'your-secret-key';
}

function createRsvpToken({ meetingId, email, ttlDays = DEFAULT_TTL_DAYS }) {
  if (!meetingId || !email) {
    throw new Error('meetingId and email are required');
  }

  const expiresAtSeconds = Math.floor(Date.now() / 1000) + ttlDays * 24 * 60 * 60;

  const payload = {
    m: String(meetingId),
    e: String(email).toLowerCase(),
    exp: expiresAtSeconds,
  };

  const payloadB64 = base64urlEncode(JSON.stringify(payload));
  const sigB64 = base64urlEncode(hmacSha256(getSecret(), payloadB64));

  return `${payloadB64}.${sigB64}`;
}

function verifyRsvpToken({ token, meetingId, email }) {
  if (!token) return { valid: false, error: 'Missing token' };

  const parts = String(token).split('.');
  if (parts.length !== 2) return { valid: false, error: 'Invalid token format' };

  const [payloadB64, sigB64] = parts;

  let payload;
  try {
    payload = JSON.parse(base64urlDecodeToString(payloadB64));
  } catch {
    return { valid: false, error: 'Invalid token payload' };
  }

  const expectedSigB64 = base64urlEncode(hmacSha256(getSecret(), payloadB64));
  if (!timingSafeEqualString(sigB64, expectedSigB64)) {
    return { valid: false, error: 'Invalid token signature' };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (!payload.exp || typeof payload.exp !== 'number' || payload.exp < nowSeconds) {
    return { valid: false, error: 'Token expired' };
  }

  const normalizedMeetingId = String(meetingId);
  const normalizedEmail = String(email).toLowerCase();

  if (payload.m !== normalizedMeetingId) {
    return { valid: false, error: 'Token meeting mismatch' };
  }

  if (payload.e !== normalizedEmail) {
    return { valid: false, error: 'Token email mismatch' };
  }

  return { valid: true, expiresAtSeconds: payload.exp };
}

module.exports = {
  createRsvpToken,
  verifyRsvpToken,
};
