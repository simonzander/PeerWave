const cron = require('node-cron');
const { sequelize } = require('../db/model');
const writeQueue = require('../db/writeQueue');

/**
 * Meeting Cleanup Service
 * Handles cleanup for both instant calls and scheduled meetings
 */
class MeetingCleanupService {
  
  constructor() {
    this.cleanupJob = null;
  }

  /**
   * Start the cleanup cron job (runs every 5 minutes)
   */
  start() {
    // Run every 5 minutes
    this.cleanupJob = cron.schedule('*/5 * * * *', async () => {
      await this.runCleanup();
    });

    console.log('✓ Meeting cleanup service started (runs every 5 minutes)');
  }

  /**
   * Stop the cleanup cron job
   */
  stop() {
    if (this.cleanupJob) {
      this.cleanupJob.stop();
      console.log('✓ Meeting cleanup service stopped');
    }
  }

  /**
   * Run cleanup logic
   */
  async runCleanup() {
    try {
      console.log('[MEETING CLEANUP] Running cleanup...');

      await this.cleanupOrphanedInstantCalls();
      await this.cleanupScheduledMeetings();
      await this.cleanupExternalSessions();

      console.log('[MEETING CLEANUP] Cleanup completed');
    } catch (error) {
      console.error('[MEETING CLEANUP] Error during cleanup:', error);
    }
  }

  /**
   * Cleanup orphaned instant calls (handled by MeetingMemoryStore)
   * This is now a no-op since instant calls are memory-only
   * MeetingMemoryStore.cleanup() handles deletion of ended meetings
   */
  async cleanupOrphanedInstantCalls() {
    // No-op: Instant calls are memory-only and cleaned by MeetingMemoryStore
    // The memory store's cleanup() method runs every 5 minutes automatically
  }

  /**
   * Cleanup scheduled meetings
   * Delete meetings past scheduled end_time + 8 hours
   * Note: Runtime state (participants, status) is in MeetingMemoryStore
   */
  async cleanupScheduledMeetings() {
    try {
      // Find meetings past scheduled_end + 8 hours
      const cleanupTime = new Date(Date.now() - 8 * 60 * 60 * 1000);
      const [oldMeetings] = await sequelize.query(`
        SELECT meeting_id, end_time FROM meetings
        WHERE is_instant_call = 0
        AND end_time < ?
      `, {
        replacements: [cleanupTime]
      });

      if (oldMeetings.length > 0) {
        const oldMeetingIds = oldMeetings.map(m => m.meeting_id);
        console.log(`[MEETING CLEANUP] Deleting ${oldMeetingIds.length} scheduled meetings past end_time + 8h:`, oldMeetingIds);

        for (const meetingId of oldMeetingIds) {
          await writeQueue.enqueue(
            () => sequelize.query('DELETE FROM meetings WHERE meeting_id = ?', {
              replacements: [meetingId]
            }),
            'cleanupOldMeeting'
          );
        }
      }

    } catch (error) {
      console.error('[MEETING CLEANUP] Error cleaning up scheduled meetings:', error);
    }
  }

  /**
   * Cleanup expired external participant sessions
   * Delete sessions where expires_at has passed OR meeting has been deleted
   */
  async cleanupExternalSessions() {
    try {
      const now = new Date();
      const [expiredSessions] = await sequelize.query(`
        SELECT session_id FROM external_participants
        WHERE expires_at < ?
        OR meeting_id NOT IN (SELECT meeting_id FROM meetings)
      `, {
        replacements: [now]
      });

      if (expiredSessions.length > 0) {
        const sessionIds = expiredSessions.map(s => s.session_id);
        console.log(`[MEETING CLEANUP] Deleting ${sessionIds.length} expired external sessions`);

        for (const sessionId of sessionIds) {
          await writeQueue.enqueue(
            () => sequelize.query('DELETE FROM external_participants WHERE session_id = ?', {
              replacements: [sessionId]
            }),
            'cleanupExpiredSession'
          );
        }
      }

    } catch (error) {
      console.error('[MEETING CLEANUP] Error cleaning up external sessions:', error);
    }
  }

  /**
   * Handle WebSocket disconnect for instant call cleanup
   * Now handled by MeetingMemoryStore.removeParticipant() which auto-deletes empty instant calls
   * This method is kept for backward compatibility but does nothing
   * @param {string} user_id - User who disconnected
   */
  async handleParticipantDisconnect(user_id) {
    // No-op: Participant tracking is now in MeetingMemoryStore
    // removeParticipant() automatically deletes instant calls when last participant leaves
  }
}

module.exports = new MeetingCleanupService();
