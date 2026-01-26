/**
 * Push Notification Service
 * 
 * Sends Firebase Cloud Messaging (FCM) push notifications to iOS/Android devices.
 * 
 * Platform support:
 * - iOS/Android: FCM push notifications (only when socket disconnected)
 * - Desktop/Web: No Firebase - use in-app notifications via socket only
 * 
 * Only sends push notifications if:
 * 1. Firebase is configured (credentials provided)
 * 2. The target device is NOT currently connected via socket
 * 3. Device is iOS or Android (only these platforms register FCM tokens)
 * 
 * This prevents duplicate notifications when users are actively using the app.
 */

const { getAdmin, isFirebaseConfigured } = require('./firebase_admin');
const { PushToken, Client } = require('../db/model');
const logger = require('../utils/logger');

/**
 * Check if a specific device is currently connected via socket
 * @param {string} userId - User UUID
 * @param {number} deviceId - Device ID (integer)
 * @returns {boolean} True if device is connected
 */
function isDeviceConnected(userId, deviceId) {
  if (!global.deviceSockets) {
    return false;
  }
  
  const deviceKey = `${userId}:${deviceId}`;
  const socketId = global.deviceSockets.get(deviceKey);
  return !!socketId;
}

/**
 * Get all devices for a user that are NOT currently connected
 * @param {string} userId - User UUID
 * @returns {Promise<Array>} Array of offline device tokens with client info
 */
async function getOfflineDeviceTokens(userId) {
  try {
    const tokens = await PushToken.findAll({
      where: { user_id: userId },
      include: [{
        model: Client,
        as: 'client',
        attributes: ['device_id']
      }],
      attributes: ['client_id', 'fcm_token', 'platform']
    });

    // Filter to only offline devices
    const offlineTokens = tokens.filter(token => {
      if (!token.client) {
        logger.warn(`[PUSH] Client not found for token ${token.client_id}`);
        return false;
      }
      
      const deviceId = token.client.device_id;
      const isConnected = isDeviceConnected(userId, deviceId);
      if (isConnected) {
        logger.debug(`[PUSH] Device ${deviceId} (client ${token.client_id}) is connected, skipping push`);
      }
      return !isConnected;
    });

    return offlineTokens;
  } catch (error) {
    logger.error('[PUSH] Error fetching device tokens:', error);
    return [];
  }
}

/**
 * Send push notification to a user (only to offline devices)
 * @param {string} userId - User UUID
 * @param {string} title - Notification title
 * @param {string} body - Notification body
 * @param {Object} data - Additional data payload
 * @param {Object} options - Platform-specific options
 */
async function sendPushNotification(userId, title, body, data = {}, options = {}) {
  // Check if Firebase is configured
  if (!isFirebaseConfigured()) {
    logger.debug('[PUSH] Firebase not configured, skipping notification');
    return { success: false, reason: 'not_configured' };
  }

  try {
    const admin = getAdmin();
    if (!admin) {
      return { success: false, reason: 'admin_not_available' };
    }

    // Get only offline device tokens
    const offlineTokens = await getOfflineDeviceTokens(userId);

    if (offlineTokens.length === 0) {
      logger.debug(`[PUSH] No offline devices for user ${userId}, skipping notification`);
      return { success: true, reason: 'all_devices_online', sent: 0 };
    }

    logger.info(`[PUSH] Sending to ${offlineTokens.length} offline device(s) for user ${userId}`);

    // Prepare messages for each offline device
    const messages = offlineTokens.map(tokenData => {
      const baseMessage = {
        token: tokenData.fcm_token,
        notification: {
          title,
          body
        },
        data: {
          ...data,
          // Convert all data values to strings (FCM requirement)
          ...Object.fromEntries(
            Object.entries(data).map(([k, v]) => [k, String(v)])
          )
        }
      };

      // Platform-specific configuration
      if (tokenData.platform === 'android') {
        baseMessage.android = {
          priority: 'high',
          notification: {
            sound: 'default',
            channelId: options.channelId || 'messages',
            ...options.android
          }
        };
      } else if (tokenData.platform === 'ios') {
        baseMessage.apns = {
          payload: {
            aps: {
              sound: 'default',
              badge: options.badge || 1,
              ...options.ios
            }
          }
        };
      }

      return baseMessage;
    });

    // Send all messages
    const response = await admin.messaging().sendEach(messages);
    
    logger.info(`[PUSH] Sent to user ${userId}: ${response.successCount} success, ${response.failureCount} failed`);

    // Remove invalid tokens from database
    response.responses.forEach((resp, idx) => {
      if (resp.error) {
        const errorCode = resp.error.code;
        const tokenData = offlineTokens[idx];
        
        if (errorCode === 'messaging/invalid-registration-token' ||
            errorCode === 'messaging/registration-token-not-registered') {
          logger.warn(`[PUSH] Removing invalid token for client ${tokenData.client_id}`);
          PushToken.destroy({
            where: { client_id: tokenData.client_id }
          }).catch(err => logger.error('[PUSH] Error removing invalid token:', err));
        } else {
          logger.warn(`[PUSH] Send error for client ${tokenData.client_id}:`, errorCode);
        }
      }
    });

    return {
      success: true,
      sent: response.successCount,
      failed: response.failureCount
    };

  } catch (error) {
    logger.error('[PUSH] Send error:', error);
    return { success: false, reason: 'error', error: error.message };
  }
}

/**
 * Send message notification
 * @param {number} recipientUserId - Recipient user ID
 * @param {string} senderName - Sender display name
 * @param {string} messagePreview - Message preview text
 * @param {Object} messageData - Message metadata (channelId, senderId, etc.)
 */
async function sendMessageNotification(recipientUserId, senderName, messagePreview, messageData = {}) {
  return sendPushNotification(
    recipientUserId,
    `New message from ${senderName}`,
    messagePreview || 'You have a new message',
    {
      type: 'message',
      channelId: messageData.channelId || '',
      senderId: messageData.senderId || '',
      ...messageData
    },
    { channelId: 'messages' }
  );
}

/**
 * Send meeting notification
 * @param {number} recipientUserId - Recipient user ID
 * @param {string} meetingTitle - Meeting title
 * @param {string} organizerName - Organizer display name
 * @param {Object} meetingData - Meeting metadata (meetingId, startTime, etc.)
 */
async function sendMeetingNotification(recipientUserId, meetingTitle, organizerName, meetingData = {}) {
  return sendPushNotification(
    recipientUserId,
    `Meeting started: ${meetingTitle}`,
    `${organizerName} started a meeting`,
    {
      type: 'meeting',
      meetingId: meetingData.meetingId || '',
      roomName: meetingData.roomName || '',
      ...meetingData
    },
    { channelId: 'meetings' }
  );
}

/**
 * Send instant call notification
 * @param {number} recipientUserId - Recipient user ID
 * @param {string} callerName - Caller display name
 * @param {Object} callData - Call metadata (callId, callType, etc.)
 */
async function sendCallNotification(recipientUserId, callerName, callData = {}) {
  const callType = callData.callType === 'video' ? 'video call' : 'call';
  
  return sendPushNotification(
    recipientUserId,
    `Incoming ${callType}`,
    `${callerName} is calling you`,
    {
      type: 'call',
      callId: callData.callId || '',
      callType: callData.callType || 'audio',
      callerId: callData.callerId || '',
      ...callData
    },
    { 
      channelId: 'calls',
      android: {
        priority: 'max',
        notification: {
          priority: 'max'
        }
      },
      ios: {
        contentAvailable: true
      }
    }
  );
}

module.exports = {
  sendPushNotification,
  sendMessageNotification,
  sendMeetingNotification,
  sendCallNotification,
  isDeviceConnected,
  getOfflineDeviceTokens
};
