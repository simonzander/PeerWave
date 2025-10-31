/**
 * RoomManager - Manages mediasoup Routers (Rooms)
 * 
 * Responsibilities:
 * - Create Router per room/channel
 * - Manage Router lifecycle
 * - Enforce E2EE (mandatory, no opt-out)
 * - Handle peer connections per room
 * 
 * Architecture:
 * - 1 Router = 1 WebRTC Channel (Voice/Video room)
 * - Router created on-demand when first user joins
 * - Router closed when last user leaves
 * - E2EE enforced at transport creation (mandatory)
 */

const EventEmitter = require('events');
const { getWorkerManager } = require('./WorkerManager');
const config = require('../../config/mediasoup.config');

class RoomManager extends EventEmitter {
  constructor() {
    super();
    this.rooms = new Map(); // channelId -> Room
  }

  /**
   * Get or create a room (Router) for a channel
   * @param {string} channelId - Channel/Room ID
   * @returns {Promise<Object>} Room object with router
   */
  async getOrCreateRoom(channelId) {
    // Return existing room
    if (this.rooms.has(channelId)) {
      const room = this.rooms.get(channelId);
      console.log(`[RoomManager] Using existing room: ${channelId} (${room.peers.size} peers)`);
      return room;
    }

    // Create new room
    console.log(`[RoomManager] Creating new room: ${channelId}`);
    
    try {
      const workerManager = getWorkerManager();
      const worker = workerManager.getWorker(); // Round-robin worker selection

      // Create mediasoup Router
      const router = await worker.createRouter({
        mediaCodecs: config.router.mediaCodecs
      });

      const room = {
        id: channelId,
        router: router,
        peers: new Map(), // userId -> Peer object
        createdAt: Date.now(),
        e2eeEnabled: config.e2eeEnabled // Always true (mandatory)
      };

      this.rooms.set(channelId, room);
      
      console.log(`[RoomManager] ✓ Room ${channelId} created (Worker: ${worker.workerId}, E2EE: ${room.e2eeEnabled})`);
      this.emit('roomcreated', { channelId, workerId: worker.workerId });

      return room;

    } catch (error) {
      console.error(`[RoomManager] ✗ Failed to create room ${channelId}:`, error);
      throw error;
    }
  }

  /**
   * Get existing room
   * @param {string} channelId - Channel/Room ID
   * @returns {Object|null} Room object or null
   */
  getRoom(channelId) {
    return this.rooms.get(channelId) || null;
  }

  /**
   * Add peer to room
   * @param {string} channelId - Channel/Room ID
   * @param {string} userId - User ID
   * @param {Object} peer - Peer object (from PeerManager)
   */
  addPeer(channelId, userId, peer) {
    const room = this.rooms.get(channelId);
    if (!room) {
      throw new Error(`Room ${channelId} not found`);
    }

    room.peers.set(userId, peer);
    console.log(`[RoomManager] Peer ${userId} added to room ${channelId} (${room.peers.size} peers)`);
    
    this.emit('peerjoined', { channelId, userId, peerCount: room.peers.size });
  }

  /**
   * Remove peer from room
   * @param {string} channelId - Channel/Room ID
   * @param {string} userId - User ID
   */
  async removePeer(channelId, userId) {
    const room = this.rooms.get(channelId);
    if (!room) {
      console.warn(`[RoomManager] Room ${channelId} not found for peer removal`);
      return;
    }

    room.peers.delete(userId);
    console.log(`[RoomManager] Peer ${userId} removed from room ${channelId} (${room.peers.size} peers remaining)`);
    
    this.emit('peerleft', { channelId, userId, peerCount: room.peers.size });

    // Close room if empty
    if (room.peers.size === 0) {
      await this.closeRoom(channelId);
    }
  }

  /**
   * Get all peers in a room
   * @param {string} channelId - Channel/Room ID
   * @returns {Map<string, Object>} Map of userId -> Peer
   */
  getPeers(channelId) {
    const room = this.rooms.get(channelId);
    return room ? room.peers : new Map();
  }

  /**
   * Get peer count in room
   * @param {string} channelId - Channel/Room ID
   * @returns {number}
   */
  getPeerCount(channelId) {
    const room = this.rooms.get(channelId);
    return room ? room.peers.size : 0;
  }

  /**
   * Close a room and cleanup resources
   * @param {string} channelId - Channel/Room ID
   */
  async closeRoom(channelId) {
    const room = this.rooms.get(channelId);
    if (!room) {
      return;
    }

    console.log(`[RoomManager] Closing room: ${channelId}`);

    // Close router (automatically closes all transports)
    room.router.close();

    // Remove room from map
    this.rooms.delete(channelId);

    const lifetime = Date.now() - room.createdAt;
    console.log(`[RoomManager] ✓ Room ${channelId} closed (lifetime: ${Math.round(lifetime / 1000)}s)`);
    
    this.emit('roomclosed', { channelId, lifetime });
  }

  /**
   * Get room statistics
   * @param {string} channelId - Channel/Room ID
   * @returns {Object|null}
   */
  getRoomStats(channelId) {
    const room = this.rooms.get(channelId);
    if (!room) {
      return null;
    }

    return {
      id: room.id,
      peerCount: room.peers.size,
      e2eeEnabled: room.e2eeEnabled,
      createdAt: room.createdAt,
      uptime: Date.now() - room.createdAt
    };
  }

  /**
   * Get all rooms statistics
   * @returns {Object}
   */
  getAllStats() {
    const stats = {
      roomCount: this.rooms.size,
      rooms: []
    };

    for (const [channelId, room] of this.rooms) {
      stats.rooms.push({
        id: channelId,
        peerCount: room.peers.size,
        e2eeEnabled: room.e2eeEnabled,
        uptime: Date.now() - room.createdAt
      });
    }

    return stats;
  }

  /**
   * Check if E2EE is enabled for a room
   * @param {string} channelId - Channel/Room ID
   * @returns {boolean}
   */
  isE2EEEnabled(channelId) {
    const room = this.rooms.get(channelId);
    return room ? room.e2eeEnabled : config.e2eeEnabled; // Always true
  }

  /**
   * Close all rooms (for graceful shutdown)
   */
  async closeAllRooms() {
    console.log(`[RoomManager] Closing all rooms (${this.rooms.size})...`);
    
    const closePromises = [];
    for (const channelId of this.rooms.keys()) {
      closePromises.push(this.closeRoom(channelId));
    }

    await Promise.all(closePromises);
    
    console.log('[RoomManager] ✓ All rooms closed');
    this.emit('allroomsclosed');
  }
}

// Singleton instance
let instance = null;

/**
 * Get RoomManager singleton instance
 * @returns {RoomManager}
 */
function getRoomManager() {
  if (!instance) {
    instance = new RoomManager();
  }
  return instance;
}

module.exports = {
  RoomManager,
  getRoomManager
};
