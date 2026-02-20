const { sequelize, MeetingInvitation } = require('../db/model');
const { v4: uuidv4 } = require('uuid');
const { Op } = require('sequelize');
const writeQueue = require('../db/writeQueue');
const meetingMemoryStore = require('./meetingMemoryStore');
const logger = require('../utils/logger');
const { sanitizeForLog } = require('../utils/logSanitizer');

/**
 * MeetingService - Hybrid Storage (Database + Memory)
 * 
 * Database: Persistent scheduled meetings
 * Memory: All runtime state + instant calls
 * 
 * Key principle:
 * - Scheduled meetings: DB (persistent) + Memory (runtime state)
 * - Instant calls: Memory only (no DB writes)
 */
class MeetingService {
  
  /**
   * Create a new meeting or instant call
   * @param {Object} data - Meeting data
   * @param {string} data.title - Meeting title
   * @param {string} data.created_by - User UUID who created the meeting
   * @param {Date} data.start_time - Start time
   * @param {Date} data.end_time - End time
   * @param {boolean} data.is_instant_call - True for instant calls (memory only), false for scheduled (DB + memory)
   * @param {string} data.description - Optional description
   * @param {Array<string>} data.invited_participants - Array of UUIDs and/or emails (for scheduled meetings)
   * @param {string} data.source_channel_id - Optional channel ID (for instant calls from channels)
   * @param {string} data.source_user_id - Optional user ID (for 1:1 instant calls)
   * @param {boolean} data.allow_external - Allow external participants
   * @param {boolean} data.voice_only - Voice-only mode
   * @param {boolean} data.mute_on_join - Mute participants on join
   * @param {number} data.max_participants - Max participants limit (runtime only)
   * @returns {Promise<Object>} Created meeting object
   */
  async createMeeting(data) {
    const {
      title,
      created_by,
      start_time,
      end_time,
      is_instant_call = false,
      description = null,
      invited_participants = [],
      source_channel_id = null,
      source_user_id = null,
      allow_external = false,
      voice_only = false,
      mute_on_join = false,
      max_participants = null
    } = data;

    const normalizedInvited = Array.isArray(invited_participants)
      ? [...invited_participants]
      : [];

    if (
      is_instant_call &&
      source_user_id &&
      source_user_id !== created_by &&
      !normalizedInvited.includes(source_user_id)
    ) {
      normalizedInvited.push(source_user_id);
    }

    // Generate meeting ID with appropriate prefix
    const prefix = is_instant_call ? 'call_' : 'mtg_';
    const meeting_id = prefix + uuidv4().replace(/-/g, '').substring(0, 12);

    // Generate invitation token if external participants allowed
    const invitation_token = allow_external ? uuidv4().replace(/-/g, '') : null;

    const meeting = {
      meeting_id,
      title,
      description,
      created_by,
      start_time,
      end_time,
      is_instant_call,
      allow_external,
      invitation_token,
      invited_participants: normalizedInvited,
      voice_only,
      mute_on_join,
      // Runtime state
      source_channel_id,
      source_user_id,
      max_participants,
      participants: [],
      participant_count: 0,
      livekit_room_active: false,
      created_at: new Date(),
      updated_at: new Date()
    };

    try {
      if (is_instant_call) {
        // Instant call: Memory only, no DB write
        logger.info('[MEETING] Creating instant call (memory only)');
        logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
        meetingMemoryStore.set(meeting_id, meeting);
        
        // Add creator as participant
        await this.addParticipant(meeting_id, {
          user_id: created_by,
          role: 'meeting_owner'
        });

      } else {
        // Scheduled meeting: Save to DB
        logger.info('[MEETING] Creating scheduled meeting (DB + memory)');
        logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
        
        await writeQueue.enqueue(
          () => sequelize.query(`
            INSERT INTO meetings (
              meeting_id, title, description, created_by, start_time, end_time,
              is_instant_call, allow_external, invitation_token, invited_participants,
              voice_only, mute_on_join
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `, {
            replacements: [
              meeting_id, title, description, created_by, start_time, end_time,
              false, // is_instant_call always false for DB records
              allow_external, invitation_token, JSON.stringify(invited_participants),
              voice_only, mute_on_join
            ]
          }),
          'createMeeting'
        );

        // Also add to memory for runtime state
        meetingMemoryStore.set(meeting_id, meeting);

        // Add creator as participant (memory only)
        await this.addParticipant(meeting_id, {
          user_id: created_by,
          role: 'meeting_owner'
        });
      }

      return this.getMeeting(meeting_id);
    } catch (error) {
      logger.error('[MEETING] Error creating meeting', error);
      throw error;
    }
  }

  /**
   * Get meeting by ID (hybrid: memory first, then DB)
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<Object|null>} Meeting object with runtime state or null
   */
  async getMeeting(meeting_id) {
    try {
      // 1. Check memory first (instant calls + active meetings)
      let meeting = meetingMemoryStore.getWithStatus(meeting_id);
      
      if (meeting) {
        logger.debug('[MEETING] Found in memory:', {
          meetingId: sanitizeForLog(meeting_id),
          type: meeting.is_instant_call ? 'instant' : 'scheduled'
        });
        return meeting;
      }

      // 2. Check database for scheduled meetings
      const [meetings] = await sequelize.query(`
        SELECT * FROM meetings WHERE meeting_id = ?
      `, {
        replacements: [meeting_id]
      });

      if (meetings.length === 0) {
        return null;
      }

      // 3. Load from DB and add to memory with runtime state
      const dbMeeting = meetings[0];
      
      // Parse JSON invited_participants
      if (dbMeeting.invited_participants) {
        try {
          dbMeeting.invited_participants = JSON.parse(dbMeeting.invited_participants);
        } catch (e) {
          dbMeeting.invited_participants = [];
        }
      }
      
      // Fix CURRENT_TIMESTAMP strings (convert to actual dates)
      if (dbMeeting.created_at === 'CURRENT_TIMESTAMP') {
        dbMeeting.created_at = new Date();
      }
      if (dbMeeting.updated_at === 'CURRENT_TIMESTAMP') {
        dbMeeting.updated_at = new Date();
      }

      // Add runtime state
      const meetingWithRuntime = {
        ...dbMeeting,
        participants: [],
        participant_count: 0,
        livekit_room_active: false,
        source_channel_id: null,
        source_user_id: null,
        max_participants: null
      };

      meetingMemoryStore.set(meeting_id, meetingWithRuntime);
      
      logger.info('[MEETING] Loaded from DB into memory');
      logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
      
      return meetingMemoryStore.getWithStatus(meeting_id);

    } catch (error) {
      logger.error('[MEETING] Error getting meeting', error);
      throw error;
    }
  }

  /**
   * Update meeting details (scheduled meetings only)
   * @param {string} meeting_id - Meeting ID
   * @param {Object} updates - Fields to update
   * @returns {Promise<Object>} Updated meeting object
   */
  async updateMeeting(meeting_id, updates) {
    const meeting = await this.getMeeting(meeting_id);
    
    if (!meeting) {
      throw new Error('Meeting not found');
    }

    if (meeting.is_instant_call) {
      throw new Error('Cannot update instant calls');
    }

    const allowedFields = [
      'title', 'description', 'start_time', 'end_time',
      'voice_only', 'mute_on_join', 'allow_external', 'invited_participants'
    ];

    const fields = [];
    const values = [];

    for (const [key, value] of Object.entries(updates)) {
      if (allowedFields.includes(key)) {
        if (key === 'invited_participants') {
          fields.push(`${key} = ?`);
          values.push(JSON.stringify(value));
        } else {
          fields.push(`${key} = ?`);
          values.push(value);
        }
      }
    }

    if (fields.length === 0) {
      throw new Error('No valid fields to update');
    }

    values.push(meeting_id);

    try {
      await writeQueue.enqueue(
        () => sequelize.query(`
          UPDATE meetings SET ${fields.join(', ')} WHERE meeting_id = ?
        `, {
          replacements: values
        }),
        'updateMeeting'
      );

      // Update memory if present
      if (meetingMemoryStore.has(meeting_id)) {
        const memoryMeeting = meetingMemoryStore.get(meeting_id);
        Object.assign(memoryMeeting, updates);
        meetingMemoryStore.set(meeting_id, memoryMeeting);
      }

      return await this.getMeeting(meeting_id);
    } catch (error) {
      logger.error('[MEETING] Error updating meeting', error);
      throw error;
    }
  }

  /**
   * Delete meeting/call
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<boolean>} Success status
   */
  async deleteMeeting(meeting_id) {
    const meeting = await this.getMeeting(meeting_id);
    
    if (!meeting) {
      return true; // Already deleted
    }

    try {
      // Delete from memory first
      meetingMemoryStore.delete(meeting_id);

      // Delete from DB if scheduled meeting
      if (!meeting.is_instant_call) {
        await writeQueue.enqueue(
          () => sequelize.query(`
            DELETE FROM meetings WHERE meeting_id = ?
          `, {
            replacements: [meeting_id]
          }),
          'deleteMeeting'
        );
      }

      return true;
    } catch (error) {
      logger.error('[MEETING] Error deleting meeting', error);
      throw error;
    }
  }

  /**
   * Bulk delete meetings/calls
   * @param {string[]} meeting_ids - Array of meeting IDs
   * @param {string} user_id - User requesting deletion (must be owner or admin)
   * @param {boolean} is_admin - Whether user is admin
   * @returns {Promise<Object>} Deletion results
   */
  async bulkDeleteMeetings(meeting_ids, user_id, is_admin = false) {
    const results = {
      deleted: 0,
      failed: 0,
      errors: []
    };

    for (const meeting_id of meeting_ids) {
      try {
        // Check ownership
        const meeting = await this.getMeeting(meeting_id);
        
        if (!meeting) {
          results.failed++;
          results.errors.push({ meeting_id, reason: 'Meeting not found' });
          continue;
        }

        if (!is_admin && meeting.created_by !== user_id) {
          results.failed++;
          results.errors.push({ meeting_id, reason: 'Not owner' });
          continue;
        }

        await this.deleteMeeting(meeting_id);
        results.deleted++;
      } catch (error) {
        results.failed++;
        results.errors.push({ meeting_id, reason: error.message });
      }
    }

    return results;
  }

  /**
   * List meetings with filters
   * @param {Object} filters - Query filters
   * @param {string} filters.user_id - Filter by user (created or invited)
   * @param {string} filters.status - Filter by status
   * @param {boolean} filters.is_instant_call - Filter by type
   * @param {Date} filters.start_after - Start time after
   * @param {Date} filters.end_before - End time before
   * List meetings with filters (hybrid: memory + DB)
   * @param {Object} filters - Filter options
   * @param {string} filters.user_id - Filter by user (creator or participant)
   * @param {string} filters.status - Filter by status
   * @param {boolean} filters.is_instant_call - Filter by type
   * @param {Date} filters.start_after - Filter by start time after
   * @param {Date} filters.end_before - Filter by end time before
   * @returns {Promise<Array>} List of meetings with runtime state
   */
  async listMeetings(filters = {}) {
    try {
      // 1. Get all meetings from memory (instant calls + active meetings)
      const memoryMeetings = meetingMemoryStore.getAllWithStatus();

      // 2. Get scheduled meetings from DB
      const conditions = [];
      const replacements = [];

      // Filter for scheduled meetings only (instant calls are memory-only)
      conditions.push('is_instant_call = 0');

      if (filters.user_id) {
        conditions.push('created_by = ?');
        replacements.push(filters.user_id);
      }

      if (filters.start_after) {
        conditions.push('start_time > ?');
        replacements.push(filters.start_after);
      }

      if (filters.end_before) {
        conditions.push('end_time < ?');
        replacements.push(filters.end_before);
      }

      const whereClause = 'WHERE ' + conditions.join(' AND ');

      const [dbMeetings] = await sequelize.query(`
        SELECT * FROM meetings ${whereClause} ORDER BY start_time DESC
      `, {
        replacements
      });

      // Parse JSON fields
      dbMeetings.forEach(m => {
        if (m.invited_participants) {
          try {
            m.invited_participants = JSON.parse(m.invited_participants);
          } catch (e) {
            m.invited_participants = [];
          }
        }
        
        // Fix CURRENT_TIMESTAMP strings (convert to actual dates)
        if (m.created_at === 'CURRENT_TIMESTAMP') {
          m.created_at = new Date();
        }
        if (m.updated_at === 'CURRENT_TIMESTAMP') {
          m.updated_at = new Date();
        }
      });

      // 3. Merge: Check if DB meetings are in memory, if not load with runtime state
      const allMeetings = [...memoryMeetings];
      
      for (const dbMeeting of dbMeetings) {
        const inMemory = memoryMeetings.find(m => m.meeting_id === dbMeeting.meeting_id);
        
        if (!inMemory) {
          // Not in memory yet, add runtime state and calculate status
          const withRuntime = {
            ...dbMeeting,
            participants: [],
            participant_count: 0,
            livekit_room_active: false,
            source_channel_id: null,
            source_user_id: null,
            max_participants: null
          };
          
          meetingMemoryStore.set(dbMeeting.meeting_id, withRuntime);
          const withStatus = meetingMemoryStore.getWithStatus(dbMeeting.meeting_id);
          allMeetings.push(withStatus);
        }
      }

      // 4. Apply filters on merged data
      let filtered = allMeetings;

      if (filters.user_id) {
        filtered = filtered.filter(m => {
          // Creator or participant
          const isCreator = m.created_by === filters.user_id;
          const isParticipant = m.participants?.some(p => p.user_id === filters.user_id);
          const isInvited = m.invited_participants?.includes(filters.user_id);
          return isCreator || isParticipant || isInvited;
        });
      }

      if (filters.status) {
        filtered = filtered.filter(m => m.status === filters.status);
      }

      if (filters.is_instant_call !== undefined) {
        filtered = filtered.filter(m => m.is_instant_call === filters.is_instant_call);
      }

      // Sort by start_time descending
      filtered.sort((a, b) => {
        const aTime = a.start_time ? new Date(a.start_time) : new Date(0);
        const bTime = b.start_time ? new Date(b.start_time) : new Date(0);
        return bTime - aTime;
      });

      return filtered;

    } catch (error) {
      logger.error('[MEETING] Error listing meetings', error);
      throw error;
    }
  }

  /**
   * Add participant to meeting (memory only)
   * @param {string} meeting_id - Meeting ID
   * @param {Object} participant - Participant data
   * @param {string} participant.user_id - User UUID
   * @param {number} participant.device_id - Device ID
   * @param {string} participant.role - Role (default: meeting_member)
   * @returns {Promise<Object>} Updated meeting object
   */
  async addParticipant(meeting_id, participant) {
    try {
      const meeting = await meetingMemoryStore.addParticipant(meeting_id, participant);
      if (!meeting) {
        // Meeting not in memory, load it first
        await this.getMeeting(meeting_id);
        return await meetingMemoryStore.addParticipant(meeting_id, participant);
      }
      return meeting;
    } catch (error) {
      logger.error('[MEETING] Error adding participant', error);
      throw error;
    }
  }

  /**
   * Remove participant from meeting (memory only)
   * @param {string} meeting_id - Meeting ID
   * @param {string} user_id - User UUID
   * @param {number} device_id - Device ID (optional)
   * @returns {Promise<Object>} Result with isEmpty flag
   */
  async removeParticipant(meeting_id, user_id, device_id) {
    try {
      const result = meetingMemoryStore.removeParticipant(meeting_id, user_id, device_id);
      
      if (!result) {
        logger.warn('[MEETING] removeParticipant: Meeting not found');
        logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
        return { isEmpty: true };
      }

      // If instant call and now empty, delete immediately
      if (result.isEmpty && result.meeting.is_instant_call) {
        logger.info('[MEETING] Instant call empty, deleting from memory');
        logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
        meetingMemoryStore.delete(meeting_id);
      }

      return result;
    } catch (error) {
      logger.error('[MEETING] Error removing participant', error);
      throw error;
    }
  }

  /**
   * Update LiveKit room state (called by Socket.IO handlers)
   * @param {string} meeting_id - Meeting ID
   * @param {boolean} active - Room active status
   * @param {Array<string>} participants - Array of user IDs in room
   */
  updateLiveKitRoom(meeting_id, active, participants = []) {
    meetingMemoryStore.setLiveKitRoom(meeting_id, active, participants);
  }

  /**
   * Update participant status (memory only)
   * @param {string} meeting_id - Meeting ID
   * @param {string} user_id - User UUID
   * @param {number} device_id - Device ID
   * @param {string} status - New status (e.g., 'invited', 'joined', 'left')
   * @returns {Promise<boolean>} Success
   */
  async updateParticipantStatus(meeting_id, user_id, device_id, status) {
    if (status === undefined && typeof device_id === 'string') {
      status = device_id;
      device_id = undefined;
    }
    try {
      const meeting = meetingMemoryStore.get(meeting_id);
      if (!meeting) {
        logger.warn('[MEETING] updateParticipantStatus: Meeting not found');
        logger.debug('[MEETING] Meeting ID:', { meetingId: sanitizeForLog(meeting_id) });
        return false;
      }

      // Find and update participant
      const participant = meeting.participants?.find(p => 
        p.user_id === user_id && (device_id === undefined || p.device_id === device_id)
      );

      if (participant) {
        participant.status = status;
        if (status === 'joined' && !participant.joined_at) {
          participant.joined_at = new Date().toISOString();
        }
        meetingMemoryStore.set(meeting_id, meeting);
        return true;
      }

      return false;
    } catch (error) {
      logger.error('[MEETING] Error updating participant status', error);
      throw error;
    }
  }

  /**
   * Generate new external invitation link (scheduled meetings only)
   * @param {string} meeting_id - Meeting ID
   * @param {Object} options - Optional settings
   * @param {string} options.label - Optional label for the invitation
   * @param {Date} options.expires_at - Optional expiration date
   * @param {number} options.max_uses - Optional max uses
   * @param {string} options.created_by - User who created the invitation
   * @returns {Promise<Object>} New invitation object with token
   */
  async generateInvitationLink(meeting_id, options = {}) {
    const meeting = await this.getMeeting(meeting_id);
    
    if (!meeting) {
      throw new Error('Meeting not found');
    }

    if (meeting.is_instant_call) {
      throw new Error('Cannot generate invitation link for instant calls');
    }

    const token = uuidv4().replace(/-/g, '');
    const { label, expires_at, max_uses, created_by } = options;

    try {
      // Create invitation in the new table using writeQueue
      const invitation = await writeQueue.enqueue(
        () => MeetingInvitation.create({
          meeting_id,
          token,
          label: label || null,
          created_by: created_by || meeting.created_by,
          expires_at: expires_at || null,
          max_uses: max_uses || null,
          use_count: 0,
          is_active: true
        }),
        'createMeetingInvitation'
      );

      // Ensure allow_external is set on meeting
      await writeQueue.enqueue(
        () => sequelize.query(`
          UPDATE meetings SET allow_external = 1 WHERE meeting_id = ?
        `, {
          replacements: [meeting_id]
        }),
        'enableExternalAccess'
      );

      // Update memory
      const memoryMeeting = meetingMemoryStore.get(meeting_id);
      if (memoryMeeting) {
        memoryMeeting.allow_external = true;
        meetingMemoryStore.set(meeting_id, memoryMeeting);
      }

      logger.info('[MEETING] Generated invitation token');
      logger.debug('[MEETING] Invitation details:', {
        meetingId: sanitizeForLog(meeting_id),
        tokenPreview: token.substring(0, 8) + '...'
      });
      return invitation.toJSON();
    } catch (error) {
      logger.error('[MEETING] Error generating invitation link', error);
      throw error;
    }
  }

  /**
   * Get all invitation tokens for a meeting
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<Array>} Array of invitation objects
   */
  async getInvitationTokens(meeting_id) {
    try {
      // Reads don't need writeQueue
      const invitations = await MeetingInvitation.findAll({
        where: { meeting_id, is_active: true },
        order: [['created_at', 'DESC']]
      });
      return invitations.map(i => i.toJSON());
    } catch (error) {
      logger.error('[MEETING] Error getting invitation tokens', error);
      throw error;
    }
  }

  /**
   * Revoke (deactivate) an invitation token
   * @param {string} token - The invitation token to revoke
   * @returns {Promise<boolean>} Success status
   */
  async revokeInvitationToken(token) {
    try {
      const [updated] = await writeQueue.enqueue(
        () => MeetingInvitation.update(
          { is_active: false },
          { where: { token } }
        ),
        'revokeInvitationToken'
      );
      if (updated > 0) {
        logger.info('[MEETING] Revoked invitation token');
        logger.debug('[MEETING] Token preview:', { token: token.substring(0, 8) + '...' });
      }
      return updated > 0;
    } catch (error) {
      logger.error('[MEETING] Error revoking invitation token', error);
      throw error;
    }
  }

  /**
   * Delete an invitation token permanently
   * @param {string} token - The invitation token to delete
   * @returns {Promise<boolean>} Success status
   */
  async deleteInvitationToken(token) {
    try {
      const deleted = await writeQueue.enqueue(
        () => MeetingInvitation.destroy({ where: { token } }),
        'deleteInvitationToken'
      );
      if (deleted > 0) {
        logger.info('[MEETING] Deleted invitation token');
        logger.debug('[MEETING] Token preview:', { token: token.substring(0, 8) + '...' });
      }
      return deleted > 0;
    } catch (error) {
      logger.error('[MEETING] Error deleting invitation token', error);
      throw error;
    }
  }

  /**
   * Increment use count for an invitation token
   * @param {string} token - The invitation token
   * @returns {Promise<Object|null>} Updated invitation or null if max uses reached
   */
  async incrementInvitationUseCount(token) {
    try {
      const invitation = await MeetingInvitation.findOne({ where: { token } });
      
      if (!invitation) {
        return null;
      }

      // Check if max uses reached
      if (invitation.max_uses !== null && invitation.use_count >= invitation.max_uses) {
        return null;
      }

      invitation.use_count += 1;
      await writeQueue.enqueue(
        () => invitation.save(),
        'incrementInvitationUseCount'
      );

      return invitation.toJSON();
    } catch (error) {
      logger.error('[MEETING] Error incrementing invitation use count', error);
      throw error;
    }
  }

  /**
   * Check if any participant has joined
   * @param {string} meeting_id - Meeting ID
   * @returns {Promise<boolean>} True if at least one participant present
   */
  async hasActiveParticipants(meeting_id) {
    const meeting = meetingMemoryStore.get(meeting_id);
    return meeting ? (meeting.participant_count || 0) > 0 : false;
  }

  /**
   * Get memory store statistics
   */
  getMemoryStats() {
    return meetingMemoryStore.getStats();
  }
}

module.exports = new MeetingService();
