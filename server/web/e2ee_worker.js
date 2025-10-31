/**
 * Insertable Streams Worker for E2EE Video Conference
 * 
 * This Web Worker handles encryption/decryption of RTP frames
 * using the Insertable Streams API (Chrome 86+, Edge 86+, Safari 15.4+).
 * 
 * Architecture:
 * - Runs in separate thread (doesn't block UI)
 * - Receives frames via TransformStream
 * - Encrypts/decrypts with AES-256-GCM
 * - Returns transformed frames to main thread
 * 
 * Security:
 * - Zero-knowledge: Keys never leave worker
 * - Unique IV per frame
 * - GCM authentication tags
 * 
 * Copyright (c) 2024 Simon Zander
 * Licensed under PolyForm Noncommercial License 1.0.0
 */

// Import crypto polyfill if needed (for older browsers)
// importScripts('crypto-polyfill.js');

/**
 * Encryption state
 */
let sendKey = null;
let peerKeys = new Map();
let ivCounter = 0;

/**
 * Message handler from main thread
 */
self.onmessage = async (event) => {
  const { type, data } = event.data;
  
  try {
    switch (type) {
      case 'setSendKey':
        sendKey = new Uint8Array(data.key);
        ivCounter = 0;
        self.postMessage({ type: 'keySet', success: true });
        break;
        
      case 'addPeerKey':
        peerKeys.set(data.peerId, new Uint8Array(data.key));
        self.postMessage({ type: 'peerKeyAdded', peerId: data.peerId });
        break;
        
      case 'removePeerKey':
        peerKeys.delete(data.peerId);
        self.postMessage({ type: 'peerKeyRemoved', peerId: data.peerId });
        break;
        
      case 'encrypt':
        const encrypted = await encryptFrame(new Uint8Array(data.frame));
        self.postMessage({ 
          type: 'encrypted', 
          frame: encrypted,
          frameId: data.frameId 
        }, [encrypted.buffer]);
        break;
        
      case 'decrypt':
        const decrypted = await decryptFrame(
          new Uint8Array(data.frame),
          data.peerId
        );
        self.postMessage({ 
          type: 'decrypted', 
          frame: decrypted,
          frameId: data.frameId 
        }, [decrypted.buffer]);
        break;
        
      default:
        console.warn('[E2EE Worker] Unknown message type:', type);
    }
  } catch (error) {
    self.postMessage({ 
      type: 'error', 
      error: error.message,
      originalType: type 
    });
  }
};

/**
 * Encrypt frame with AES-256-GCM
 * 
 * @param {Uint8Array} frame - Raw RTP frame
 * @returns {Uint8Array} - [IV (12) + Encrypted Data + Auth Tag (16)]
 */
async function encryptFrame(frame) {
  if (!sendKey) {
    throw new Error('Send key not set');
  }
  
  // Generate unique IV
  const iv = generateIV();
  
  // Import key
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    sendKey,
    { name: 'AES-GCM' },
    false,
    ['encrypt']
  );
  
  // Encrypt
  const encrypted = await crypto.subtle.encrypt(
    {
      name: 'AES-GCM',
      iv: iv,
      tagLength: 128 // 16 bytes
    },
    cryptoKey,
    frame
  );
  
  // Combine: IV + encrypted data (with tag)
  const result = new Uint8Array(12 + encrypted.byteLength);
  result.set(iv, 0);
  result.set(new Uint8Array(encrypted), 12);
  
  return result;
}

/**
 * Decrypt frame with AES-256-GCM
 * 
 * @param {Uint8Array} encryptedFrame - [IV (12) + Encrypted Data + Auth Tag (16)]
 * @param {string} peerId - Peer ID for key lookup
 * @returns {Uint8Array} - Decrypted frame
 */
async function decryptFrame(encryptedFrame, peerId) {
  const peerKey = peerKeys.get(peerId);
  if (!peerKey) {
    throw new Error(`No key for peer: ${peerId}`);
  }
  
  if (encryptedFrame.length < 28) {
    throw new Error('Frame too short (min 28 bytes)');
  }
  
  // Extract IV and ciphertext
  const iv = encryptedFrame.slice(0, 12);
  const ciphertext = encryptedFrame.slice(12);
  
  // Import key
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    peerKey,
    { name: 'AES-GCM' },
    false,
    ['decrypt']
  );
  
  // Decrypt
  const decrypted = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: iv,
      tagLength: 128
    },
    cryptoKey,
    ciphertext
  );
  
  return new Uint8Array(decrypted);
}

/**
 * Generate unique IV (12 bytes)
 * 
 * Format: [timestamp (8 bytes)] [counter (4 bytes)]
 */
function generateIV() {
  const iv = new Uint8Array(12);
  const timestamp = Date.now();
  const counter = ivCounter++;
  
  // Timestamp (big-endian)
  const dataView = new DataView(iv.buffer);
  dataView.setBigUint64(0, BigInt(timestamp), false); // Big-endian
  dataView.setUint32(8, counter, false); // Big-endian
  
  return iv;
}

/**
 * Worker initialization
 */
console.log('[E2EE Worker] Initialized');
self.postMessage({ type: 'ready' });
