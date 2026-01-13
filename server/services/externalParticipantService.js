const { sequelize, ExternalSession, MeetingInvitation } = require('../db/model');
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');
const { sanitizeForLog } = require('../utils/logSanitizer');
const logger = require('../utils/logger');

/**
 * ExternalParticipantService - Manages external guest sessions for meetings
 * 
 * Sessions are stored in-memory using Sequelize's temporaryStorage (SQLite :memory:)
 * This means sessions are cleared on server restart, which is appropriate for
 * temporary guest access.
 * 
 * Invitation tokens are stored persistently in the MeetingInvitation table,
 * with cascade deletion when meetings are deleted.
 */
class ExternalParticipantService {
  
  /**
   * Validate invitation token and check constraints
   * Checks: token exists, is active, not expired, max uses not reached
   * @param {string} token - Invitation token
   * @returns {Promise<Object|null>} Meeting object with invitation info or null if invalid
   */
  async validateInvitationToken(token) {
    try {
      // First check the new MeetingInvitation table
      const invitation = await MeetingInvitation.findOne({
        where: { token, is_active: true }
      });

      if (invitation) {
        // Check expiration
        if (invitation.expires_at && new Date() > new Date(invitation.expires_at)) {
          return { error: 'token_expired', invitation: invitation.toJSON() };
        }

        // Check max uses
        if (invitation.max_uses !== null && invitation.use_count >= invitation.max_uses) {
          return { error: 'max_uses_reached', invitation: invitation.toJSON() };
        }

        // Get meeting details
        const [meetings] = await sequelize.query(`
          SELECT * FROM meetings WHERE meeting_id = ? AND allow_external = 1
        `, {
          replacements: [invitation.meeting_id]
        });

        if (meetings.length === 0) {
          return null;
        }

        return { 
          meeting: meetings[0],
          invitation: invitation.toJSON()
        };
      }

      // Fallback: Check legacy invitation_token on meetings table (for backwards compatibility)
      const [meetings] = await sequelize.query(`
        SELECT * FROM meetings
        WHERE invitation_token = ?
        AND allow_external = 1
      `, {
        replacements: [token]
      });

      if (meetings.length === 0) {
        return null;
      }

      return { meeting: meetings[0] };
    } catch (error) {
      logger.error('[EXTERNAL] Error validating invitation token', error);
      throw error;
    }
  }

  /**
   * Validate that token matches the meeting
   * Used for security on guest endpoints
   * @param {string} token - Invitation token
   * @param {string} meetingId - Meeting ID to validate against
   * @returns {Promise<boolean>} True if valid
   */
  async validateTokenForMeeting(token, meetingId) {
    try {
      const result = await this.validateInvitationToken(token);
      
      if (!result || result.error) {
        return false;
      }
      
      return result.meeting.meeting_id === meetingId;
    } catch (error) {
      logger.error('[EXTERNAL] Error validating token for meeting', error);
      return false;
    }
  }

  /**
   * Check if session is within cooldown period
   * @param {string} session_id - Session ID
   * @returns {Promise<number|null>} Seconds remaining in cooldown, or null if no cooldown
   */
  async checkAdmissionCooldown(session_id) {
    try {
      const session = await ExternalSession.findByPk(session_id, {
        attributes: ['last_admission_request']
      });
      
      if (!session || !session.last_admission_request) {
        return null; // No previous request
      }
      
      const timeSinceLastRequest = Date.now() - new Date(session.last_admission_request).getTime();
      const COOLDOWN_MS = 5000; // 5 seconds
      
      if (timeSinceLastRequest < COOLDOWN_MS) {
        return Math.ceil((COOLDOWN_MS - timeSinceLastRequest) / 1000);
      }
      
      return null; // Cooldown expired
    } catch (error) {
      logger.error('[EXTERNAL] Error checking cooldown', error);
      return null;
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
    
    // Calculate expiration: 24 hours from now
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000);

    try {
      // Ensure signed_pre_key and pre_keys are stored as JSON strings
      const signedPreKeyStr = typeof signed_pre_key === 'string' 
        ? signed_pre_key 
        : JSON.stringify(signed_pre_key);
      const preKeysStr = typeof pre_keys === 'string'
        ? pre_keys
        : JSON.stringify(pre_keys);

      const session = await ExternalSession.create({
        session_id,
        meeting_id,
        display_name,
        identity_key_public,
        signed_pre_key: signedPreKeyStr,
        pre_keys: preKeysStr,
        admitted: null,
        last_admission_request: null,
        expires_at: expiresAt
      });

      logger.info('[EXTERNAL] Created session');
      logger.debug('[EXTERNAL] Session details:', {
        sessionId: sanitizeForLog(session_id),
        meetingId: sanitizeForLog(meeting_id)
      });
      return this._formatSession(session);
    } catch (error) {
      logger.error('[EXTERNAL] Error creating external session', error);
      throw error;
    }
  }

  /**
   * Format session for API response
   */
  _formatSession(session) {
    if (!session) return null;
    
    const data = session.toJSON ? session.toJSON() : session;
    
    // Parse pre_keys if string
    if (typeof data.pre_keys === 'string') {
      try {
        data.pre_keys = JSON.parse(data.pre_keys);
      } catch (e) {
        // Keep as-is if not valid JSON
      }
    }
    
    // Parse signed_pre_key if string
    if (typeof data.signed_pre_key === 'string') {
      try {
        data.signed_pre_key = JSON.parse(data.signed_pre_key);
      } catch (e) {
        // Keep as-is if not valid JSON
      }
    }
    
    return data;
  }

  /**
   * Get external session by ID
   * @param {string} session_id - Session ID
   * @returns {Promise<Object|null>} Session object or null
   */
  async getSession(session_id) {
    try {
      const session = await ExternalSession.findByPk(session_id);
      return this._formatSession(session);
    } catch (error) {
      logger.error('[EXTERNAL] Error getting external session', error);
      throw error;
    }
  }

  /**
   * Update session admission status
   * @param {string} session_id - Session ID
   * @param {boolean|null} admitted - Admission status (null/false/true)
   * @param {string|Date} by_user_or_timestamp - User who admitted/declined OR timestamp for request
   * @returns {Promise<Object>} Updated session object
   */
  async updateAdmissionStatus(session_id, admitted, by_user_or_timestamp) {
    try {
      const updateData = {};
      
      if (admitted === true) {
        // Guest admitted
        updateData.admitted = true;
        updateData.admitted_by = by_user_or_timestamp; // User UUID
        updateData.joined_at = new Date();
      } else if (admitted === false) {
        // Guest requesting admission
        updateData.admitted = false;
        updateData.last_admission_request = by_user_or_timestamp; // Timestamp
      } else {
        // Guest declined (reset to null for retry)
        updateData.admitted = null;
        updateData.admitted_by = by_user_or_timestamp; // User who declined
      }

      await ExternalSession.update(updateData, {
        where: { session_id }
      });

      logger.info('[EXTERNAL] Updated session admission status');
      logger.debug('[EXTERNAL] Update details:', {
        sessionId: sanitizeForLog(session_id),
        admitted
      });
      return await this.getSession(session_id);
    } catch (error) {
      logger.error('[EXTERNAL] Error updating admission status', error);
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
      await ExternalSession.update(
        { left_at: new Date() },
        { where: { session_id } }
      );
      logger.info('[EXTERNAL] Marked session as left');
      logger.debug('[EXTERNAL] Session ID:', { sessionId: sanitizeForLog(session_id) });
    } catch (error) {
      logger.error('[EXTERNAL] Error marking session as left', error);
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
      await ExternalSession.destroy({ where: { session_id } });
      logger.info('[EXTERNAL] Deleted session');
      logger.debug('[EXTERNAL] Session ID:', { sessionId: sanitizeForLog(session_id) });
      return true;
    } catch (error) {
      logger.error('[EXTERNAL] Error deleting external session', error);
      throw error;
    }
  }

  /**
   * Delete all waiting external sessions for a meeting
   * Used to kick duplicate sessions when same invitation is reused
   * @param {string} meeting_id - Meeting ID
   * @param {string} invitation_token - Invitation token (unused, for API compatibility)
   * @returns {Promise<number>} Number of sessions deleted
   */
  async deleteSessionsByToken(meeting_id, invitation_token) {
    try {
      const deleted = await ExternalSession.destroy({
        where: {
          meeting_id,
          left_at: null,
          admitted: null
        }
      });

      if (deleted > 0) {
        logger.info('[EXTERNAL] Deleted duplicate waiting sessions');
        logger.debug('[EXTERNAL] Deletion details:', {
          deletedCount: deleted,
          meetingId: sanitizeForLog(meeting_id)
        });
      }
      return deleted;
    } catch (error) {
      logger.error('[EXTERNAL] Error deleting sessions by token', error);
      return 0; // Don't throw - cleanup shouldn't block registration
    }
  }

  /**
   * Get all external participants for a meeting
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<Array>} Array of external participant sessions
   */
  async getMeetingExternalParticipants(meeting_id) {
    try {
      const sessions = await ExternalSession.findAll({
        where: {
          meeting_id,
          left_at: null
        },
        order: [['createdAt', 'ASC']]
      });

      return sessions.map(s => this._formatSession(s));
    } catch (error) {
      logger.error('[EXTERNAL] Error getting meeting external participants', error);
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
      const sessions = await ExternalSession.findAll({
        where: {
          meeting_id,
          admitted: false,
          left_at: null
        },
        attributes: ['session_id', 'display_name', 'createdAt'],
        order: [['createdAt', 'ASC']]
      });

      return sessions.map(s => s.toJSON());
    } catch (error) {
      logger.error('[EXTERNAL] Error getting waiting participants', error);
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
      const session = await ExternalSession.findByPk(session_id, {
        attributes: ['expires_at']
      });

      if (!session) {
        return true; // Session doesn't exist
      }

      return new Date() > new Date(session.expires_at);
    } catch (error) {
      logger.error('[EXTERNAL] Error checking session expiration', error);
      return true;
    }
  }

  /**
   * Generate temporary Signal Protocol keys for external user
   * This is a simplified version - in production, use proper libsignal
   * @returns {Object} Generated keys
   */
  generateTemporaryKeys() {
    const identityKeyPublic = crypto.randomBytes(32).toString('base64');
    const signedPreKey = crypto.randomBytes(32).toString('base64');
    
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

  /**
   * Consume a one-time pre-key (delete after use)
   * @param {string} session_id - Session ID
   * @param {number} pre_key_id - Pre-key ID to consume
   * @returns {Promise<Object>} Remaining count and keys
   */
  async consumePreKey(session_id, pre_key_id) {
    try {
      const session = await this.getSession(session_id);
      
      if (!session || !session.pre_keys) {
        throw new Error('Session or pre-keys not found');
      }

      const preKeys = Array.isArray(session.pre_keys) 
        ? session.pre_keys 
        : JSON.parse(session.pre_keys);
      const filteredKeys = preKeys.filter(k => k.id !== pre_key_id);

      await ExternalSession.update(
        { pre_keys: JSON.stringify(filteredKeys) },
        { where: { session_id } }
      );

      return {
        remainingCount: filteredKeys.length,
        preKeys: filteredKeys
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error consuming pre-key', error);
      throw error;
    }
  }

  /**
   * Replenish one-time pre-keys
   * @param {string} session_id - Session ID
   * @param {Array} new_pre_keys - Array of new pre-key objects
   * @returns {Promise<Object>} Updated count and keys
   */
  async replenishPreKeys(session_id, new_pre_keys) {
    try {
      const session = await this.getSession(session_id);
      
      if (!session) {
        throw new Error('Session not found');
      }

      const existingKeys = Array.isArray(session.pre_keys) 
        ? session.pre_keys 
        : [];
      const allKeys = [...existingKeys, ...new_pre_keys];

      await ExternalSession.update(
        { pre_keys: JSON.stringify(allKeys) },
        { where: { session_id } }
      );

      return {
        totalCount: allKeys.length,
        preKeys: allKeys
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error replenishing pre-keys', error);
      throw error;
    }
  }

  /**
   * Get remaining pre-key count
   * @param {string} session_id - Session ID
   * @returns {Promise<Object>} Count and keys
   */
  async getRemainingPreKeys(session_id) {
    try {
      const session = await this.getSession(session_id);
      
      if (!session) {
        throw new Error('Session not found');
      }

      const preKeys = Array.isArray(session.pre_keys) 
        ? session.pre_keys 
        : [];

      return {
        count: preKeys.length,
        preKeys: preKeys
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error getting remaining pre-keys', error);
      throw error;
    }
  }

  /**
   * Get external participant's E2EE keys for establishing Signal session
   * @param {string} session_id - Session ID
   * @returns {Promise<Object>} Identity key, signed pre-key, and one available pre-key
   */
  async getKeysForSession(session_id) {
    try {
      const session = await this.getSession(session_id);
      
      if (!session) {
        throw new Error('Session not found');
      }

      const preKeys = Array.isArray(session.pre_keys) 
        ? session.pre_keys 
        : [];
      
      // Get one available pre-key (first one)
      const availablePreKey = preKeys.length > 0 ? preKeys[0] : null;

      return {
        identityKeyPublic: session.identity_key_public,
        signedPreKey: session.signed_pre_key,
        preKey: availablePreKey,
        sessionId: session_id
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error getting keys for session', error);
      throw error;
    }
  }

  /**
   * Update session display name
   * @param {string} session_id - Session ID
   * @param {string} display_name - New display name
   * @returns {Promise<boolean>}
   */
  async updateSessionDisplayName(session_id, display_name) {
    try {
      await ExternalSession.update(
        { display_name },
        { where: { session_id } }
      );
      
      logger.info('[EXTERNAL] Updated display name for session');
      logger.debug('[EXTERNAL] Update details:', {
        sessionId: sanitizeForLog(session_id),
        displayName: display_name
      });
      return true;
    } catch (error) {
      logger.error('[EXTERNAL] Error updating session display name', error);
      throw error;
    }
  }

  /**
   * Clean up expired sessions
   * @returns {Promise<number>} Number of sessions deleted
   */
  async cleanupExpiredSessions() {
    try {
      const { Op } = require('sequelize');
      const deleted = await ExternalSession.destroy({
        where: {
          expires_at: {
            [Op.lt]: new Date()
          }
        }
      });

      if (deleted > 0) {
        logger.info('[EXTERNAL] Cleaned up expired sessions:', { deletedCount: deleted });
      }
      return deleted;
    } catch (error) {
      logger.error('[EXTERNAL] Error cleaning up expired sessions', error);
      return 0;
    }
  }

  /**
   * Rate limiting for keybundle fetches
   * In-memory Map: key -> { count, resetAt }
   * Limit: 3 fetches per minute per participant per guest
   */
  _rateLimitMap = new Map();

  /**
   * Check rate limit for keybundle fetch
   * @param {string} key - Rate limit key (format: "meeting_id:user_id:device_id")
   * @returns {Promise<boolean>} True if allowed, false if rate limited
   */
  async checkKeybundleRateLimit(key) {
    const now = Date.now();
    const limit = 3; // 3 fetches
    const window = 60 * 1000; // 1 minute

    if (!this._rateLimitMap.has(key)) {
      this._rateLimitMap.set(key, { count: 1, resetAt: now + window });
      return true;
    }

    const entry = this._rateLimitMap.get(key);

    // Reset if window expired
    if (now > entry.resetAt) {
      this._rateLimitMap.set(key, { count: 1, resetAt: now + window });
      return true;
    }

    // Check if under limit
    if (entry.count < limit) {
      entry.count++;
      return true;
    }

    // Rate limited
    return false;
  }

  /**
   * Get authenticated participant's Signal Protocol keybundle
   * @param {string} meetingId - Meeting ID
   * @param {string} userId - User UUID
   * @param {string} deviceId - Device ID (clientid)
   * @returns {Promise<Object|null>} Keybundle with identity_key, signed_pre_key, one_time_pre_key
   */
  async getParticipantKeybundle(meetingId, userId, deviceId) {
    try {
      const { Client, SignalSignedPreKey, SignalPreKey } = require('../db/model');

      logger.debug('[EXTERNAL] getParticipantKeybundle called:', {
        userId: sanitizeForLog(userId),
        deviceId: sanitizeForLog(deviceId),
        deviceIdType: typeof deviceId
      });

      // Get identity key from Clients table (using device_id INTEGER, not clientid UUID)
      const client = await Client.findOne({
        where: {
          owner: userId,
          device_id: parseInt(deviceId) // device_id is INTEGER in database
        }
      });

      logger.debug('[EXTERNAL] Client query result:', {
        found: !!client,
        clientId: client ? sanitizeForLog(client.clientid) : null,
        hasKey: client ? !!client.public_key : false
      });

      if (!client || !client.public_key) {
        logger.warn('[EXTERNAL] No client found for participant keybundle');
        logger.debug('[EXTERNAL] Missing client details:', {
          userId: sanitizeForLog(userId),
          deviceId: sanitizeForLog(deviceId)
        });
        return null;
      }

      // Get latest signed pre-key (using client UUID, not device_id)
      const signedPreKey = await SignalSignedPreKey.findOne({
        where: {
          owner: userId,
          client: client.clientid // Use the UUID clientid from found client
        },
        order: [['createdAt', 'DESC']]
      });

      if (!signedPreKey) {
        logger.warn('[EXTERNAL] No signed pre-key found for participant');
        logger.debug('[EXTERNAL] Missing key details:', {
          userId: sanitizeForLog(userId),
          deviceId: sanitizeForLog(deviceId)
        });
        return null;
      }

      // Get one available one-time pre-key (using client UUID, not device_id)
      const preKey = await SignalPreKey.findOne({
        where: {
          owner: userId,
          client: client.clientid // Use the UUID clientid from found client
        },
        order: [['prekey_id', 'ASC']]
      });

      // Delete the consumed pre-key (one-time use)
      if (preKey) {
        await preKey.destroy();
      }

      return {
        identity_key: client.public_key,
        registration_id: client.registration_id,
        signed_pre_key: {
          keyId: signedPreKey.signed_prekey_id,
          publicKey: signedPreKey.signed_prekey_data,
          signature: signedPreKey.signed_prekey_signature
        },
        one_time_pre_key: preKey ? {
          keyId: preKey.prekey_id,
          publicKey: preKey.prekey_data
        } : null
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error getting participant keybundle', error);
      throw error;
    }
  }

  /**
   * Get guest's Signal Protocol keybundle and consume one pre-key
   * @param {string} sessionId - External session ID
   * @returns {Promise<Object|null>} Keybundle with identity_key, signed_pre_key, one_time_pre_key
   */
  async getGuestKeybundle(sessionId) {
    try {
      const session = await this.getSession(sessionId);
      if (!session) {
        return null;
      }

      // Parse pre_keys array
      let preKeys = session.pre_keys;
      if (typeof preKeys === 'string') {
        try {
          preKeys = JSON.parse(preKeys);
        } catch (e) {
          logger.error('[EXTERNAL] Failed to parse guest pre_keys', e);
          return null;
        }
      }

      if (!Array.isArray(preKeys) || preKeys.length === 0) {
        logger.warn('[EXTERNAL] Guest has no available pre-keys');
        return null;
      }

      // Get first available pre-key
      const oneTimePreKey = preKeys[0];

      // Remove consumed pre-key from session
      const remainingKeys = preKeys.slice(1);
      await ExternalSession.update(
        { pre_keys: JSON.stringify(remainingKeys) },
        { where: { session_id: sessionId } }
      );

      logger.info('[EXTERNAL] Consumed guest pre-key');
      logger.debug('[EXTERNAL] Pre-key consumption:', {
        keyId: oneTimePreKey.keyId,
        remainingCount: remainingKeys.length
      });

      // Parse signed_pre_key if needed
      let signedPreKey = session.signed_pre_key;
      if (typeof signedPreKey === 'string') {
        try {
          signedPreKey = JSON.parse(signedPreKey);
        } catch (e) {
          // Keep as-is
        }
      }

      return {
        identity_key: session.identity_key_public,
        signed_pre_key: signedPreKey,
        one_time_pre_key: oneTimePreKey
      };
    } catch (error) {
      logger.error('[EXTERNAL] Error getting guest keybundle', error);
      throw error;
    }
  }
}

module.exports = new ExternalParticipantService();
