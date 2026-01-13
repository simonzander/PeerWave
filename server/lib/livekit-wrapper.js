/**
 * LiveKit SDK Wrapper
 * 
 * Provides a CommonJS-compatible wrapper for the ES module livekit-server-sdk
 * Uses dynamic import() to load the ES module
 */

const logger = require('../utils/logger');

let livekitModule = null;
let loadPromise = null;

/**
 * Load the LiveKit SDK module
 * Returns a promise that resolves when the module is loaded
 */
async function loadLiveKit() {
  if (livekitModule) {
    return livekitModule;
  }
  
  if (loadPromise) {
    return loadPromise;
  }
  
  loadPromise = (async () => {
    try {
      logger.info('[LiveKit Wrapper] Loading livekit-server-sdk...');
      livekitModule = await import('livekit-server-sdk');
      logger.info('[LiveKit Wrapper] livekit-server-sdk loaded successfully');
      return livekitModule;
    } catch (error) {
      logger.error('[LiveKit Wrapper] Failed to load livekit-server-sdk:', error);
      throw error;
    }
  })();
  
  return loadPromise;
}

/**
 * Get AccessToken class
 * Must await this before using
 */
async function getAccessToken() {
  const module = await loadLiveKit();
  return module.AccessToken;
}

/**
 * Get RoomServiceClient class
 * Must await this before using
 */
async function getRoomServiceClient() {
  const module = await loadLiveKit();
  return module.RoomServiceClient;
}

/**
 * Check if LiveKit is loaded
 */
function isLoaded() {
  return livekitModule !== null;
}

module.exports = {
  loadLiveKit,
  getAccessToken,
  getRoomServiceClient,
  isLoaded,
};
