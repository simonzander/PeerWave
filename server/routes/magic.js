const express = require('express');
const crypto = require('crypto');
const router = express.Router();

const magicLinks = {}; // { token: { email, expires, deviceId } }

// Generate magic link after WebAuthn login
router.post('/magic/generate', express.json(), (req, res) => {
  const { email, deviceId } = req.body;
  const token = crypto.randomBytes(32).toString('hex');
  magicLinks[token] = {
    email,
    deviceId,
    expires: Date.now() + 15 * 60 * 1000 // 15 min expiry
  };
  res.json({ magicLink: `peerwave://login?token=${token}` });
});

// Verify magic link in native app
router.post('/magic/verify', express.json(), (req, res) => {
  const { token, deviceId } = req.body;
  const entry = magicLinks[token];
  if (!entry || entry.expires < Date.now() || entry.deviceId !== deviceId) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
  // Optionally bind deviceId to user for future logins
  // TODO: Save deviceId for user in DB
  delete magicLinks[token];
  res.json({ status: 'ok', email: entry.email });
});

module.exports = router;
