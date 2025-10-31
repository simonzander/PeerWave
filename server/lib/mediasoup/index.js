/**
 * mediasoup Module Index
 * 
 * Exports all mediasoup managers and initialization function
 */

const { getWorkerManager } = require('./WorkerManager');
const { getRoomManager } = require('./RoomManager');
const { getPeerManager } = require('./PeerManager');

/**
 * Initialize mediasoup system
 * Creates worker pool and sets up managers
 * @returns {Promise<Object>} Managers object
 */
async function initializeMediasoup() {
  console.log('[mediasoup] Initializing mediasoup system...');

  try {
    // Initialize worker pool
    const workerManager = getWorkerManager();
    await workerManager.initialize();

    // Get manager instances
    const roomManager = getRoomManager();
    const peerManager = getPeerManager();

    console.log('[mediasoup] ✓ mediasoup system initialized');

    return {
      workerManager,
      roomManager,
      peerManager
    };

  } catch (error) {
    console.error('[mediasoup] ✗ Failed to initialize mediasoup:', error);
    throw error;
  }
}

/**
 * Graceful shutdown of mediasoup system
 */
async function shutdownMediasoup() {
  console.log('[mediasoup] Shutting down mediasoup system...');

  try {
    const roomManager = getRoomManager();
    const workerManager = getWorkerManager();

    // Close all rooms first
    await roomManager.closeAllRooms();

    // Then close all workers
    await workerManager.close();

    console.log('[mediasoup] ✓ mediasoup system shutdown complete');

  } catch (error) {
    console.error('[mediasoup] ✗ Shutdown error:', error);
    throw error;
  }
}

module.exports = {
  initializeMediasoup,
  shutdownMediasoup,
  getWorkerManager,
  getRoomManager,
  getPeerManager
};
