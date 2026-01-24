const logger = require('../utils/logger');
const { sanitizeForLog } = require('../utils/logSanitizer');

/**
 * PresenceService - Tracks online/busy/offline status based on socket connections
 * 
 * Pure in-memory tracking - no database persistence or heartbeat timers.
 * 
 * Status Logic:
 * - online: At least one socket connection exists for user
 * - busy: At least one socket connection exists AND user is in a LiveKit room
 * - offline: No socket connections exist for user
 */
class PresenceService {
  
  constructor() {
    // Track socket connections per user: userId -> Set<socketId>
    this.userConnections = new Map();
    
    // Track users in LiveKit rooms: userId -> Set<roomId>
    this.usersInRooms = new Map();
  }

  /**
   * Start the presence service (no-op, kept for compatibility)
   */
  start() {
    logger.info('[PRESENCE] Service started (socket-based tracking)');
  }

  /**
   * Stop the presence service (no-op, kept for compatibility)
   */
  stop() {
    logger.info('[PRESENCE] Service stopped');
  }

  /**
   * Register a socket connection for a user
   * @param {string} user_id - User UUID
   * @param {string} socket_id - Socket.IO connection ID
   * @returns {Promise<string>} User status after connection
   */
  async onSocketConnected(user_id, socket_id) {
    try {
      logger.debug('[PRESENCE] onSocketConnected called:', {
        userId: sanitizeForLog(user_id),
        socketId: socket_id
      });
      
      // Add to in-memory tracking
      if (!this.userConnections.has(user_id)) {
        this.userConnections.set(user_id, new Set());
      }
      this.userConnections.get(user_id).add(socket_id);

      // Determine status
      const status = this._getUserStatus(user_id);
      
      logger.info('[PRESENCE] User connected');
      logger.debug('[PRESENCE] Connection details:', {
        userId: sanitizeForLog(user_id),
        socketId: socket_id,
        status,
        totalConnections: this.userConnections.get(user_id).size
      });
      
      return status;
    } catch (error) {
      logger.error('[PRESENCE] Error on socket connected', error);
      throw error;
    }
  }

  /**
   * Unregister a socket connection for a user
   * @param {string} user_id - User UUID
   * @param {string} socket_id - Socket.IO connection ID
   * @returns {Promise<string>} User status after disconnection
   */
  async onSocketDisconnected(user_id, socket_id) {
    try {
      // Remove from in-memory tracking
      const connections = this.userConnections.get(user_id);
      if (connections) {
        connections.delete(socket_id);
        
        // If no more connections, remove user entirely
        if (connections.size === 0) {
          this.userConnections.delete(user_id);
          
          logger.info('[PRESENCE] User disconnected (all sockets closed), status: offline');
          logger.debug('[PRESENCE] Disconnect details:', { userId: sanitizeForLog(user_id) });
          return 'offline';
        } else {
          // Still has other connections, recalculate status
          const status = this._getUserStatus(user_id);
          
          logger.info('[PRESENCE] User disconnected one socket');
          logger.debug('[PRESENCE] Disconnect details:', {
            userId: sanitizeForLog(user_id),
            remainingSockets: connections.size,
            status
          });
          return status;
        }
      }

      return 'offline';
    } catch (error) {
      logger.error('[PRESENCE] Error on socket disconnected', error);
      throw error;
    }
  }

  /**
   * Mark user as in a LiveKit room (sets status to 'busy')
   * @param {string} user_id - User UUID
   * @param {string} room_id - LiveKit room ID
   * @returns {Promise<string>} Status after joining
   */
  async onUserJoinedRoom(user_id, room_id) {
    try {
      if (!this.usersInRooms.has(user_id)) {
        this.usersInRooms.set(user_id, new Set());
      }
      this.usersInRooms.get(user_id).add(room_id);

      const status = this._getUserStatus(user_id);
      
      logger.info('[PRESENCE] User joined room, status: busy');
      logger.debug('[PRESENCE] Room join details:', {
        userId: sanitizeForLog(user_id),
        roomId: sanitizeForLog(room_id),
        status
      });
      return status;
    } catch (error) {
      logger.error('[PRESENCE] Error on user joined room', error);
      throw error;
    }
  }

  /**
   * Mark user as left a LiveKit room (recalculates status)
   * @param {string} user_id - User UUID
   * @param {string} room_id - LiveKit room ID
   * @returns {Promise<string>} Status after leaving
   */
  async onUserLeftRoom(user_id, room_id) {
    try {
      const rooms = this.usersInRooms.get(user_id);
      if (rooms) {
        rooms.delete(room_id);
        
        if (rooms.size === 0) {
          this.usersInRooms.delete(user_id);
        }
      }

      // Recalculate status
      const status = this._getUserStatus(user_id);

      logger.info('[PRESENCE] User left room');
      logger.debug('[PRESENCE] Room leave details:', {
        userId: sanitizeForLog(user_id),
        roomId: sanitizeForLog(room_id),
        status
      });
      return status;
    } catch (error) {
      logger.error('[PRESENCE] Error on user left room', error);
      throw error;
    }
  }

  /**
   * Calculate user status based on connections and room participation
   * @private
   * @param {string} user_id - User UUID
   * @returns {string} Status: 'online', 'busy', or 'offline'
   */
  _getUserStatus(user_id) {
    const hasConnections = this.userConnections.has(user_id) && this.userConnections.get(user_id).size > 0;
    const inRoom = this.usersInRooms.has(user_id) && this.usersInRooms.get(user_id).size > 0;

    if (!hasConnections) {
      return 'offline';
    }

    if (inRoom) {
      return 'busy';
    }

    return 'online';
  }

  /**
   * DEPRECATED: Legacy method for backward compatibility
   */
  async markOffline(user_id) {
    logger.warn('[PRESENCE] markOffline() is deprecated, use onSocketDisconnected()');
    // No-op: presence is now in-memory only
    return 'offline';
  }

  /**
   * Get presence for specific users (from in-memory tracking)
   * @param {string[]} user_ids - Array of user UUIDs
   * @returns {Promise<Array>} Array of presence objects with {user_id, status}
   */
  async getPresence(user_ids) {
    if (!user_ids || user_ids.length === 0) {
      return [];
    }

    try {
      logger.debug('[PRESENCE] getPresence called:', {
        userCount: user_ids.length
      });

      // Return all user_ids with their in-memory status
      const results = user_ids.map(user_id => {
        const status = this._getUserStatus(user_id);
        logger.debug('[PRESENCE] User status:', {
          userId: sanitizeForLog(user_id),
          status
        });
        return {
          user_id,
          status
        };
      });
      
      return results;
    } catch (error) {
      logger.error('[PRESENCE] Error getting presence', error);
      throw error;
    }
  }

  /**
   * Get presence for all members of a channel
   * @param {string} channel_id - Channel UUID
   * @returns {Promise<Array>} Array of presence objects
   */
  async getChannelPresence(channel_id) {
    try {
      // Need to keep database lookup for channel members, but use in-memory presence
      const { sequelize } = require('../db/model');
      const [members] = await sequelize.query(`
        SELECT user_id FROM ChannelMembers WHERE channel_id = ?
      `, {
        replacements: [channel_id]
      });

      const userIds = members.map(m => m.user_id);
      return await this.getPresence(userIds);
    } catch (error) {
      logger.error('[PRESENCE] Error getting channel presence', error);
      throw error;
    }
  }

  /**
   * Cleanup stale connections - DEPRECATED (no longer needed with socket-based tracking)
   */
  async cleanupStaleConnections() {
    logger.warn('[PRESENCE] cleanupStaleConnections() is deprecated');
    return [];
  }

  /**
   * Get all online users (online or busy) from in-memory tracking
   * @returns {Promise<Array>} Array of online user_ids
   */
  async getOnlineUsers() {
    try {
      // Return all users with active connections
      const onlineUsers = Array.from(this.userConnections.keys());
      
      logger.debug('[PRESENCE] Getting online users:', {
        count: onlineUsers.length
      });
      
      return onlineUsers;
    } catch (error) {
      logger.error('[PRESENCE] Error getting online users', error);
      throw error;
    }
  }

  /**
   * Check if user is online (online or busy) from in-memory tracking
   * @param {string} user_id - User UUID
   * @returns {Promise<boolean>} True if online or busy
   */
  async isOnline(user_id) {
    try {
      const status = this._getUserStatus(user_id);
      const isOnline = status === 'online' || status === 'busy';
      
      logger.debug('[PRESENCE] isOnline check:', {
        userId: sanitizeForLog(user_id),
        status,
        result: isOnline
      });
      
      return isOnline;
    } catch (error) {
      logger.error('[PRESENCE] Error checking online status', error);
      return false;
    }
  }
}

module.exports = new PresenceService();
