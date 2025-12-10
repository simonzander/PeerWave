const { sequelize } = require('../db/model');
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');
const writeQueue = require('../db/writeQueue');

/**
 * ExternalParticipantService - Manages external guest sessions for meetings
 */
class ExternalParticipantService {
  
  /**
   * Validate invitation token and check time window
   * Valid: ±1 hour from meeting start time
   * @param {string} token - Invitation token
   * @returns {Promise<Object|null>} Meeting object or null if invalid
   */
  async validateInvitationToken(token) {
    try {
      const [meetings] = await sequelize.query(`
        SELECT * FROM meetings
        WHERE invitation_token = ?
        AND allow_external = 1
        AND status != 'cancelled'
      `, {
        replacements: [token]
      });

      if (meetings.length === 0) {
        return null;
      }

      const meeting = meetings[0];
      const now = new Date();
      const startTime = new Date(meeting.start_time);
      
      // Check if within ±1 hour window
      const oneHourBefore = new Date(startTime.getTime() - 60 * 60 * 1000);
      const oneHourAfter = new Date(startTime.getTime() + 60 * 60 * 1000);

      if (now < oneHourBefore || now > oneHourAfter) {
        return { error: 'outside_time_window', meeting };
      }

      return { meeting };
    } catch (error) {
      console.error('Error validating invitation token:', error);
      throw error;
    }
  }

  /**
   * Create external participant session
   * @param {Object} data - Session data
   * @param {string} data.meeting_id - Meeting ID
   * @param {string} data.display_name - Guest display name
   * @param {string} data.identity_key_public - Signal identity key
   * @param {string} data.signed_pre_key - Signal signed pre-key
   * @param {Array} data.pre_keys - Array of Signal pre-keys
   * @returns {Promise<Object>} Created session object
   */
  async createSession(data) {
    const {
      meeting_id,
      display_name,
      identity_key_public,
      signed_pre_key,
      pre_keys
    } = data;

    const session_id = uuidv4().replace(/-/g, '');
    
    // Calculate expiration: min(meeting end + 24h, now + 24h)
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 24 hours from now

    try {
      await writeQueue.enqueue(
        () => sequelize.query(`
          INSERT INTO external_participants (
            session_id, meeting_id, display_name,
            identity_key_public, signed_pre_key, pre_keys,
            admission_status, expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, 'waiting', ?)
        `, {
          replacements: [
            session_id,
            meeting_id,
            display_name,
            identity_key_public,
            signed_pre_key,
            JSON.stringify(pre_keys),
            expiresAt
          ]
        }),
        'createExternalSession'
      );

      return await this.getSession(session_id);
    } catch (error) {
      console.error('Error creating external session:', error);
      throw error;
    }
  }

  /**
   * Get external session by ID
   * @param {string} session_id - Session ID
   * @returns {Promise<Object|null>} Session object or null
   */
  async getSession(session_id) {
    try {
      const [sessions] = await sequelize.query(`
        SELECT * FROM external_participants WHERE session_id = ?
      `, {
        replacements: [session_id]
      });

      if (sessions.length === 0) {
        return null;
      }

      const session = sessions[0];
      // Parse pre_keys JSON
      if (session.pre_keys) {
        session.pre_keys = JSON.parse(session.pre_keys);
      }

      return session;
    } catch (error) {
      console.error('Error getting external session:', error);
      throw error;
    }
  }

  /**
   * Update session admission status
   * @param {string} session_id - Session ID
   * @param {string} status - New status ('admitted' or 'declined')
   * @param {string} by_user_id - User who admitted/declined
   * @returns {Promise<Object>} Updated session object
   */
  async updateAdmissionStatus(session_id, status, by_user_id) {
    const validStatuses = ['waiting', 'admitted', 'declined'];
    
    if (!validStatuses.includes(status)) {
      throw new Error(`Invalid admission status: ${status}`);
    }

    try {
      const timestamp = status === 'admitted' ? 'joined_at = CURRENT_TIMESTAMP,' : '';
      
      await writeQueue.enqueue(
        () => sequelize.query(`
          UPDATE external_participants
          SET admission_status = ?, ${timestamp} admitted_by = ?
          WHERE session_id = ?
        `, {
          replacements: [status, by_user_id, session_id]
        }),
        'updateAdmissionStatus'
      );

      return await this.getSession(session_id);
    } catch (error) {
      console.error('Error updating admission status:', error);
      throw error;
    }
  }

  /**
   * Mark session as left
   * @param {string} session_id - Session ID
   * @returns {Promise<void>}
   */
  async markLeft(session_id) {
    try {
      await writeQueue.enqueue(
        () => sequelize.query(`
          UPDATE external_participants
          SET left_at = CURRENT_TIMESTAMP
          WHERE session_id = ?
        `, {
          replacements: [session_id]
        }),
        'markSessionLeft'
      );
    } catch (error) {
      console.error('Error marking session as left:', error);
      throw error;
    }
  }

  /**
   * Delete external session
   * @param {string} session_id - Session ID
   * @returns {Promise<boolean>} Success status
   */
  async deleteSession(session_id) {
    try {
      await writeQueue.enqueue(
        () => sequelize.query(`
          DELETE FROM external_participants WHERE session_id = ?
        `, {
          replacements: [session_id]
        }),
        'deleteExternalSession'
      );

      return true;
    } catch (error) {
      console.error('Error deleting external session:', error);
      throw error;
    }
  }

  /**
   * Get all external participants for a meeting
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<Array>} Array of external participant sessions
   */
  async getMeetingExternalParticipants(meeting_id) {
    try {
      const [sessions] = await sequelize.query(`
        SELECT * FROM external_participants
        WHERE meeting_id = ?
        AND left_at IS NULL
        ORDER BY created_at ASC
      `, {
        replacements: [meeting_id]
      });

      // Parse pre_keys for each session
      return sessions.map(s => {
        if (s.pre_keys) {
          s.pre_keys = JSON.parse(s.pre_keys);
        }
        return s;
      });
    } catch (error) {
      console.error('Error getting meeting external participants:', error);
      throw error;
    }
  }

  /**
   * Get waiting external participants (pending admission)
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<Array>} Array of waiting sessions
   */
  async getWaitingParticipants(meeting_id) {
    try {
      const [sessions] = await sequelize.query(`
        SELECT session_id, display_name, created_at
        FROM external_participants
        WHERE meeting_id = ?
        AND admission_status = 'waiting'
        AND left_at IS NULL
        ORDER BY created_at ASC
      `, {
        replacements: [meeting_id]
      });

      return sessions;
    } catch (error) {
      console.error('Error getting waiting participants:', error);
      throw error;
    }
  }

  /**
   * Check if session has expired
   * @param {string} session_id - Session ID
   * @returns {Promise<boolean>} True if expired
   */
  async isSessionExpired(session_id) {
    try {
      const [results] = await sequelize.query(`
        SELECT expires_at FROM external_participants WHERE session_id = ?
      `, {
        replacements: [session_id]
      });

      if (results.length === 0) {
        return true; // Session doesn't exist
      }

      const expiresAt = new Date(results[0].expires_at);
      return new Date() > expiresAt;
    } catch (error) {
      console.error('Error checking session expiration:', error);
      return true;
    }
  }

  /**
   * Generate temporary Signal Protocol keys for external user
   * This is a simplified version - in production, use proper libsignal
   * @returns {Object} Generated keys
   */
  generateTemporaryKeys() {
    // Generate identity key pair
    const identityKeyPublic = crypto.randomBytes(32).toString('base64');
    
    // Generate signed pre-key
    const signedPreKey = crypto.randomBytes(32).toString('base64');
    
    // Generate multiple one-time pre-keys
    const preKeys = [];
    for (let i = 0; i < 10; i++) {
      preKeys.push({
        keyId: i,
        publicKey: crypto.randomBytes(32).toString('base64')
      });
    }

    return {
      identityKeyPublic,
      signedPreKey,
      preKeys
    };
  }
}

module.exports = new ExternalParticipantService();
