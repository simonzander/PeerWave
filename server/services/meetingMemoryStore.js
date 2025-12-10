/**
 * MeetingMemoryStore - In-memory storage for meeting runtime state
 * 
 * Stores:
 * - All instant calls (complete object)
 * - Runtime state for scheduled meetings (participants, status, LiveKit room)
 * 
 * Philosophy:
 * - Instant calls: Pure memory, deleted on completion
 * - Scheduled meetings: Hybrid (DB persistent + memory runtime)
 */

class MeetingMemoryStore {
  constructor() {
    // Map<meeting_id, runtimeState>
    this.meetings = new Map();
    
    // Track LiveKit room states
    // Map<meeting_id, { active: boolean, participants: Set<userId> }>
    this.livekitRooms = new Map();
  }

  /**
   * Create or update meeting in memory
   */
  set(meetingId, data) {
    const existing = this.meetings.get(meetingId) || {};
    
    const meeting = {
      ...existing,
      ...data,
      meeting_id: meetingId,
      updated_at_memory: new Date()
    };

    this.meetings.set(meetingId, meeting);
    return meeting;
  }

  /**
   * Get meeting from memory
   */
  get(meetingId) {
    return this.meetings.get(meetingId);
  }

  /**
   * Check if meeting exists in memory
   */
  has(meetingId) {
    return this.meetings.has(meetingId);
  }

  /**
   * Delete meeting from memory
   */
  delete(meetingId) {
    this.livekitRooms.delete(meetingId);
    return this.meetings.delete(meetingId);
  }

  /**
   * Get all meetings in memory
   */
  getAll() {
    return Array.from(this.meetings.values());
  }

  /**
   * Add participant to meeting
   */
  addParticipant(meetingId, participant) {
    const meeting = this.get(meetingId);
    if (!meeting) {
      console.warn(`[Memory] Meeting ${meetingId} not found`);
      return null;
    }

    meeting.participants = meeting.participants || [];
    
    // Remove existing participant entry (if rejoining)
    meeting.participants = meeting.participants.filter(p => 
      !(p.user_id === participant.user_id && p.device_id === participant.device_id)
    );

    // Add new participant entry
    meeting.participants.push({
      user_id: participant.user_id,
      device_id: participant.device_id,
      role: participant.role || 'meeting_member',
      joined_at: new Date(),
      ...participant
    });

    meeting.participant_count = meeting.participants.length;
    this.set(meetingId, meeting);

    console.log(`[Memory] Added participant ${participant.user_id} to meeting ${meetingId}. Total: ${meeting.participant_count}`);
    return meeting;
  }

  /**
   * Remove participant from meeting
   */
  removeParticipant(meetingId, userId, deviceId) {
    const meeting = this.get(meetingId);
    if (!meeting) return null;

    meeting.participants = meeting.participants || [];
    const beforeCount = meeting.participants.length;

    meeting.participants = meeting.participants.filter(p => 
      !(p.user_id === userId && (!deviceId || p.device_id === deviceId))
    );

    meeting.participant_count = meeting.participants.length;
    this.set(meetingId, meeting);

    console.log(`[Memory] Removed participant ${userId} from meeting ${meetingId}. Count: ${beforeCount} → ${meeting.participant_count}`);

    // Return whether meeting is now empty
    return {
      meeting,
      isEmpty: meeting.participant_count === 0
    };
  }

  /**
   * Update LiveKit room state
   */
  setLiveKitRoom(meetingId, active, participants = []) {
    this.livekitRooms.set(meetingId, {
      active,
      participants: new Set(participants),
      updated_at: new Date()
    });

    // Update meeting status
    const meeting = this.get(meetingId);
    if (meeting) {
      meeting.livekit_room_active = active;
      meeting.livekit_participants = Array.from(participants);
      this.set(meetingId, meeting);
    }
  }

  /**
   * Get LiveKit room state
   */
  getLiveKitRoom(meetingId) {
    return this.livekitRooms.get(meetingId);
  }

  /**
   * Calculate meeting status based on runtime state
   */
  calculateStatus(meeting) {
    const now = new Date();
    const startTime = meeting.start_time ? new Date(meeting.start_time) : null;
    const endTime = meeting.end_time ? new Date(meeting.end_time) : null;

    // Instant calls: only 'running' or 'ended'
    if (meeting.is_instant_call) {
      const hasParticipants = (meeting.participant_count || 0) > 0;
      const roomActive = meeting.livekit_room_active || false;
      return (hasParticipants && roomActive) ? 'running' : 'ended';
    }

    // Scheduled meetings
    if (!startTime || !endTime) {
      return 'scheduled';
    }

    // Check if running (LiveKit room active + participants)
    const hasParticipants = (meeting.participant_count || 0) > 0;
    const roomActive = meeting.livekit_room_active || false;
    if (hasParticipants && roomActive) {
      return 'running';
    }

    // Check if ended
    if (now > endTime && !roomActive) {
      return 'ended';
    }

    // Check if starting soon or now
    const msUntilStart = startTime - now;
    const minUntilStart = msUntilStart / (1000 * 60);

    if (now >= startTime && now <= endTime) {
      return 'now'; // Currently scheduled window
    } else if (minUntilStart <= 15 && minUntilStart > 0) {
      return 'starting-soon'; // Within 15 minutes
    }

    return 'scheduled'; // Future meeting
  }

  /**
   * Get meeting with calculated status
   */
  getWithStatus(meetingId) {
    const meeting = this.get(meetingId);
    if (!meeting) return null;

    return {
      ...meeting,
      status: this.calculateStatus(meeting)
    };
  }

  /**
   * Get all meetings with calculated statuses
   */
  getAllWithStatus() {
    return this.getAll().map(meeting => ({
      ...meeting,
      status: this.calculateStatus(meeting)
    }));
  }

  /**
   * Cleanup ended meetings
   * - Instant calls: Delete immediately when empty
   * - Scheduled: Delete 8 hours after end_time
   */
  cleanup() {
    const now = new Date();
    const eightHoursMs = 8 * 60 * 60 * 1000;
    let cleaned = 0;

    for (const [meetingId, meeting] of this.meetings.entries()) {
      const status = this.calculateStatus(meeting);

      // Instant calls: delete if ended (no participants)
      if (meeting.is_instant_call && status === 'ended') {
        this.delete(meetingId);
        cleaned++;
        console.log(`[Memory Cleanup] Deleted instant call: ${meetingId}`);
        continue;
      }

      // Scheduled meetings: delete 8 hours after end_time
      if (!meeting.is_instant_call && meeting.end_time) {
        const endTime = new Date(meeting.end_time);
        const timeSinceEnd = now - endTime;

        if (timeSinceEnd > eightHoursMs && status === 'ended') {
          this.delete(meetingId);
          cleaned++;
          console.log(`[Memory Cleanup] Deleted scheduled meeting: ${meetingId} (${Math.round(timeSinceEnd / 3600000)}h after end)`);
        }
      }
    }

    if (cleaned > 0) {
      console.log(`[Memory Cleanup] Cleaned ${cleaned} meeting(s). Remaining: ${this.meetings.size}`);
    }

    return cleaned;
  }

  /**
   * Get statistics
   */
  getStats() {
    const all = this.getAll();
    const instant = all.filter(m => m.is_instant_call);
    const scheduled = all.filter(m => !m.is_instant_call);
    const running = all.filter(m => this.calculateStatus(m) === 'running');

    return {
      total: all.length,
      instant: instant.length,
      scheduled: scheduled.length,
      running: running.length,
      rooms: this.livekitRooms.size,
      totalParticipants: all.reduce((sum, m) => sum + (m.participant_count || 0), 0)
    };
  }
}

// Singleton instance
const meetingMemoryStore = new MeetingMemoryStore();

// Start cleanup interval (every 5 minutes)
setInterval(() => {
  meetingMemoryStore.cleanup();
}, 5 * 60 * 1000);

module.exports = meetingMemoryStore;
