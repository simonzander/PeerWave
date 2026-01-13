const cron = require('node-cron');
const { sequelize } = require('../db/model');
const writeQueue = require('../db/writeQueue');
const logger = require('../utils/logger');

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

    logger.info('[MEETING CLEANUP] Service started (runs every 5 minutes)');
  }

  /**
   * Stop the cleanup cron job
   */
  stop() {
    if (this.cleanupJob) {
      this.cleanupJob.stop();
      logger.info('[MEETING CLEANUP] Service stopped');
    }
  }

  /**
   * Run cleanup logic
   */
  async runCleanup() {
    try {
      logger.info('[MEETING CLEANUP] Running cleanup');

      await this.cleanupOrphanedInstantCalls();
      await this.cleanupScheduledMeetings();
      await this.cleanupExternalSessions();

      logger.info('[MEETING CLEANUP] Cleanup completed');
    } catch (error) {
      logger.error('[MEETING CLEANUP] Error during cleanup', error);
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
        logger.info(`[MEETING CLEANUP] Deleting ${oldMeetingIds.length} scheduled meetings past end_time + 8h`);
        logger.debug('[MEETING CLEANUP] Meeting IDs:', { meetingIds: oldMeetingIds });

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
      logger.error('[MEETING CLEANUP] Error cleaning up scheduled meetings', error);
    }
  }

  /**
   * Cleanup expired external participant sessions
   * NOTE: External sessions are stored in temporary (in-memory) storage, not the main database.
   * They are automatically cleaned up by their TTL and don't need database cleanup.
   * This method is kept for backward compatibility but does nothing.
   */
  async cleanupExternalSessions() {
    // No-op: External sessions are in temporaryStorage (memory-only)
    // They expire automatically and are cleaned up by the temp storage system
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
