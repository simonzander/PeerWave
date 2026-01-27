const cron = require('node-cron');
const { Op } = require('sequelize');
const logger = require('../utils/logger');

// Track which meetings have already been notified (in-memory)
const notifiedMeetings = new Set();

/**
 * Check for scheduled meetings starting soon and send notifications to offline participants
 */
async function notifyUpcomingMeetings() {
    try {
        const { Meeting, MeetingParticipant, User } = require('../db/model');
        const { sendMeetingNotification } = require('../services/push_notifications');
        const { getDeviceSockets } = require('../server');
        
        // Get meetings starting in the next 5 minutes
        const now = new Date();
        const fiveMinutesFromNow = new Date(now.getTime() + 5 * 60 * 1000);
        
        logger.debug('[MEETING REMINDER] Checking for upcoming meetings', { 
            now: now.toISOString(), 
            window: fiveMinutesFromNow.toISOString() 
        });
        
        // Find scheduled meetings starting soon
        const upcomingMeetings = await Meeting.findAll({
            where: {
                is_instant_call: false,
                start_time: {
                    [Op.gte]: now,
                    [Op.lte]: fiveMinutesFromNow
                }
            },
            include: [{
                model: MeetingParticipant,
                as: 'participants',
                attributes: ['user_id', 'role', 'status']
            }]
        });
        
        if (upcomingMeetings.length === 0) {
            return;
        }
        
        const deviceSockets = getDeviceSockets();
        let totalNotified = 0;
        
        for (const meeting of upcomingMeetings) {
            // Skip if already notified this meeting
            if (notifiedMeetings.has(meeting.uuid)) {
                continue;
            }
            
            try {
                // Get organizer info
                const organizer = await User.findOne({
                    where: { uuid: meeting.created_by },
                    attributes: ['displayName', 'email']
                });
                const organizerName = organizer?.displayName || organizer?.email || 'Someone';
                
                // Check each participant
                let notifiedCount = 0;
                for (const participant of meeting.participants) {
                    // Skip if participant declined
                    if (participant.status === 'declined') {
                        continue;
                    }
                    
                    // Check if user has any online devices
                    const userDevices = Array.from(deviceSockets.keys())
                        .filter(key => key.startsWith(`${participant.user_id}:`));
                    
                    // Only send notification if user has NO connected devices
                    if (userDevices.length === 0) {
                        await sendMeetingNotification(
                            participant.user_id,
                            meeting.title,
                            organizerName,
                            {
                                meetingId: meeting.uuid,
                                roomName: meeting.room_name,
                                startTime: meeting.start_time.toISOString()
                            }
                        ).catch(err => logger.error('[MEETING REMINDER] Error sending notification:', err));
                        notifiedCount++;
                    }
                }
                
                // Mark as notified in memory
                notifiedMeetings.add(meeting.uuid);
                totalNotified += notifiedCount;
                
                if (notifiedCount > 0) {
                    logger.info(`[MEETING REMINDER] Sent notifications for "${meeting.title}" to ${notifiedCount} offline participants`);
                }
            } catch (error) {
                logger.error(`[MEETING REMINDER] Error processing meeting ${meeting.uuid}:`, error);
            }
        }
        
        if (totalNotified > 0) {
            logger.info(`[MEETING REMINDER] Sent ${totalNotified} total notifications for ${upcomingMeetings.length} meetings`);
        }
        
        // Cleanup old entries (meetings that have passed)
        cleanupOldNotifications();
    } catch (error) {
        logger.error('[MEETING REMINDER] Error checking upcoming meetings:', error);
    }
}

/**
 * Remove old meeting IDs from notified set (meetings older than 1 hour)
 */
async function cleanupOldNotifications() {
    try {
        const { Meeting } = require('../db/model');
        const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
        
        // Get all notified meeting IDs that are older than 1 hour
        const oldMeetings = await Meeting.findAll({
            where: {
                uuid: { [Op.in]: Array.from(notifiedMeetings) },
                start_time: { [Op.lt]: oneHourAgo }
            },
            attributes: ['uuid']
        });
        
        // Remove from notified set
        let cleaned = 0;
        for (const meeting of oldMeetings) {
            notifiedMeetings.delete(meeting.uuid);
            cleaned++;
        }
        
        if (cleaned > 0) {
            logger.debug(`[MEETING REMINDER] Cleaned up ${cleaned} old notification entries`);
        }
    } catch (error) {
        logger.error('[MEETING REMINDER] Error cleaning up old notifications:', error);
    }
}

/**
 * Initialize meeting reminder job (runs every minute)
 */
function initMeetingReminderJob() {
    // Run every minute to check for meetings starting soon
    cron.schedule('* * * * *', async () => {
        await notifyUpcomingMeetings();
    });
    
    // Cleanup old entries every 15 minutes
    cron.schedule('*/15 * * * *', async () => {
        await cleanupOldNotifications();
    });
    
    logger.info('[MEETING REMINDER] Meeting reminder job initialized (checks every minute)');
}

module.exports = {
    initMeetingReminderJob,
    notifyUpcomingMeetings
};
