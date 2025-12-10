const { sequelize } = require('../db/model');
const cron = require('node-cron');
const writeQueue = require('../db/writeQueue');

/**
 * PresenceService - Tracks online status with 1-minute heartbeat
 */
class PresenceService {
  
  constructor() {
    this.cleanupJob = null;
    this.heartbeatTimeout = 2 * 60 * 1000; // 2 minutes (2x heartbeat interval)
  }

  /**
   * Start the presence cleanup job (runs every minute)
   */
  start() {
    this.cleanupJob = cron.schedule('* * * * *', async () => {
      await this.cleanupStaleConnections();
    });

    console.log('✓ Presence service started (cleanup every minute)');
  }

  /**
   * Stop the presence cleanup job
   */
  stop() {
    if (this.cleanupJob) {
      this.cleanupJob.stop();
      console.log('✓ Presence service stopped');
    }
  }

  /**
   * Update user heartbeat
   * @param {string} user_id - User UUID
   * @param {string} connection_id - Socket.IO connection ID
   * @returns {Promise<Object>} Updated presence object
   */
  async updateHeartbeat(user_id, connection_id) {
    try {
      // Check if presence exists
      const [existing] = await sequelize.query(`
        SELECT * FROM user_presence WHERE user_id = ?
      `, {
        replacements: [user_id]
      });

      if (existing.length > 0) {
        // Update existing
        await writeQueue.enqueue(
          () => sequelize.query(`
            UPDATE user_presence
            SET status = 'online', last_heartbeat = CURRENT_TIMESTAMP, connection_id = ?, updated_at = CURRENT_TIMESTAMP
            WHERE user_id = ?
          `, {
            replacements: [connection_id, user_id]
          }),
          'updateHeartbeat'
        );
      } else {
        // Insert new
        await writeQueue.enqueue(
          () => sequelize.query(`
            INSERT INTO user_presence (user_id, status, last_heartbeat, connection_id)
            VALUES (?, 'online', CURRENT_TIMESTAMP, ?)
          `, {
            replacements: [user_id, connection_id]
          }),
          'insertPresence'
        );
      }

      const [updated] = await sequelize.query(`
        SELECT * FROM user_presence WHERE user_id = ?
      `, {
        replacements: [user_id]
      });

      return updated[0];
    } catch (error) {
      console.error('Error updating heartbeat:', error);
      throw error;
    }
  }

  /**
   * Mark user as offline
   * @param {string} user_id - User UUID
   * @returns {Promise<void>}
   */
  async markOffline(user_id) {
    try {
      await writeQueue.enqueue(
        () => sequelize.query(`
          UPDATE user_presence
          SET status = 'offline', updated_at = CURRENT_TIMESTAMP
          WHERE user_id = ?
        `, {
          replacements: [user_id]
        }),
        'markOffline'
      );
    } catch (error) {
      console.error('Error marking user offline:', error);
      throw error;
    }
  }

  /**
   * Get presence for specific users
   * @param {string[]} user_ids - Array of user UUIDs
   * @returns {Promise<Array>} Array of presence objects
   */
  async getPresence(user_ids) {
    if (!user_ids || user_ids.length === 0) {
      return [];
    }

    try {
      const placeholders = user_ids.map(() => '?').join(',');
      const [results] = await sequelize.query(`
        SELECT * FROM user_presence WHERE user_id IN (${placeholders})
      `, {
        replacements: user_ids
      });

      // Return all user_ids, defaulting to offline if not found
      return user_ids.map(user_id => {
        const found = results.find(r => r.user_id === user_id);
        return found || {
          user_id,
          status: 'offline',
          last_heartbeat: null,
          connection_id: null
        };
      });
    } catch (error) {
      console.error('Error getting presence:', error);
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
      // Get all channel members
      const [members] = await sequelize.query(`
        SELECT user_id FROM ChannelMembers WHERE channel_id = ?
      `, {
        replacements: [channel_id]
      });

      const userIds = members.map(m => m.user_id);
      return await this.getPresence(userIds);
    } catch (error) {
      console.error('Error getting channel presence:', error);
      throw error;
    }
  }

  /**
   * Cleanup stale connections (last heartbeat > 2 minutes ago)
   * Runs every minute via cron job
   */
  async cleanupStaleConnections() {
    try {
      const cutoffTime = new Date(Date.now() - this.heartbeatTimeout);
      
      const [staleUsers] = await sequelize.query(`
        SELECT user_id FROM user_presence
        WHERE status = 'online'
        AND last_heartbeat < ?
      `, {
        replacements: [cutoffTime]
      });

      if (staleUsers.length > 0) {
        console.log(`[PRESENCE] Marking ${staleUsers.length} users as offline (stale heartbeat)`);
        
        await writeQueue.enqueue(
          () => sequelize.query(`
            UPDATE user_presence
            SET status = 'offline', updated_at = CURRENT_TIMESTAMP
            WHERE last_heartbeat < ?
          `, {
            replacements: [cutoffTime]
          }),
          'cleanupStaleConnections'
        );

        // Return user_ids that were marked offline for Socket.IO broadcast
        return staleUsers.map(u => u.user_id);
      }

      return [];
    } catch (error) {
      console.error('[PRESENCE] Error cleaning up stale connections:', error);
      return [];
    }
  }

  /**
   * Get all online users
   * @returns {Promise<Array>} Array of online user_ids
   */
  async getOnlineUsers() {
    try {
      const [results] = await sequelize.query(`
        SELECT user_id FROM user_presence WHERE status = 'online'
      `);

      return results.map(r => r.user_id);
    } catch (error) {
      console.error('Error getting online users:', error);
      throw error;
    }
  }

  /**
   * Check if user is online
   * @param {string} user_id - User UUID
   * @returns {Promise<boolean>} True if online
   */
  async isOnline(user_id) {
    try {
      const [results] = await sequelize.query(`
        SELECT status FROM user_presence WHERE user_id = ?
      `, {
        replacements: [user_id]
      });

      if (results.length === 0) {
        return false;
      }

      return results[0].status === 'online';
    } catch (error) {
      console.error('Error checking online status:', error);
      return false;
    }
  }
}

module.exports = new PresenceService();
