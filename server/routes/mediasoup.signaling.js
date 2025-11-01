/**
 * mediasoup Socket.IO Signaling Routes
 * 
 * Handles WebRTC signaling for video conferencing:
 * - Room/Channel join/leave
 * - Transport creation and connection
 * - Producer/Consumer management
 * - E2EE enforcement (mandatory)
 * 
 * Socket.IO Events:
 * - Client -> Server: requests
 * - Server -> Client: notifications
 */

const { getRoomManager, getPeerManager } = require('../lib/mediasoup');

/**
 * Setup mediasoup signaling routes on Socket.IO
 * @param {Socket} socket - Socket.IO socket instance
 * @param {Object} io - Socket.IO server instance
 */
function setupMediasoupSignaling(socket, io) {
  const roomManager = getRoomManager();
  const peerManager = getPeerManager();

  /**
   * Join a room/channel for video conferencing
   * Client must call this before creating transports
   */
  socket.on('mediasoup:join', async (data, callback) => {
    try {
      const { channelId } = data;
      const userId = socket.data.userId;

      if (!userId || !channelId) {
        return callback({ error: 'Missing userId or channelId' });
      }

      console.log(`[mediasoup] ${userId} joining channel ${channelId}`);

      // Get or create room
      const room = await roomManager.getOrCreateRoom(channelId);

      // Create peer
      const peerId = `${userId}-${channelId}`;
      const peer = await peerManager.createPeer(peerId, userId, channelId, room.router);

      // Add peer to room
      roomManager.addPeer(channelId, userId, peer);

      // Store peerId in socket session
      socket.data.mediasoupPeerId = peerId;
      socket.data.mediasoupChannelId = channelId;

      // Get RTP capabilities for client
      const rtpCapabilities = room.router.rtpCapabilities;

      // Get existing producers in room (for consuming)
      const existingProducers = peerManager.getChannelProducers(channelId, peerId);

      callback({
        success: true,
        peerId: peerId,
        rtpCapabilities: rtpCapabilities,
        e2eeEnabled: room.e2eeEnabled, // Always true
        existingProducers: existingProducers
      });

      // Notify other peers in room
      socket.to(channelId).emit('mediasoup:peer-joined', {
        userId: userId,
        peerId: peerId
      });

      // Join Socket.IO room for notifications
      socket.join(channelId);

    } catch (error) {
      console.error('[mediasoup] Error in join:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Leave room/channel
   */
  socket.on('mediasoup:leave', async (callback) => {
    try {
      const peerId = socket.data.mediasoupPeerId;
      const channelId = socket.data.mediasoupChannelId;
      const userId = socket.data.userId;

      if (!peerId || !channelId) {
        return callback({ success: true }); // Already left or never joined
      }

      console.log(`[mediasoup] ${userId} leaving channel ${channelId}`);

      // Remove peer
      await peerManager.removePeer(peerId);
      await roomManager.removePeer(channelId, userId);

      // Clear socket session
      delete socket.data.mediasoupPeerId;
      delete socket.data.mediasoupChannelId;

      // Leave Socket.IO room
      socket.leave(channelId);

      // Notify other peers
      socket.to(channelId).emit('mediasoup:peer-left', {
        userId: userId,
        peerId: peerId
      });

      callback({ success: true });

    } catch (error) {
      console.error('[mediasoup] Error in leave:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Create WebRTC Transport (send or recv)
   */
  socket.on('mediasoup:create-transport', async (data, callback) => {
    try {
      const { direction } = data; // 'send' or 'recv'
      const peerId = socket.data.mediasoupPeerId;

      if (!peerId) {
        return callback({ error: 'Not joined to room' });
      }

      if (direction !== 'send' && direction !== 'recv') {
        return callback({ error: 'Invalid direction. Must be "send" or "recv"' });
      }

      const transportParams = await peerManager.createTransport(peerId, direction);

      callback({
        success: true,
        transport: transportParams
      });

    } catch (error) {
      console.error('[mediasoup] Error creating transport:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Connect Transport (client sends DTLS parameters)
   */
  socket.on('mediasoup:connect-transport', async (data, callback) => {
    try {
      const { transportId, dtlsParameters } = data;
      const peerId = socket.data.mediasoupPeerId;

      if (!peerId) {
        return callback({ error: 'Not joined to room' });
      }

      await peerManager.connectTransport(peerId, transportId, dtlsParameters);

      callback({ success: true });

    } catch (error) {
      console.error('[mediasoup] Error connecting transport:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Produce (start sending audio/video)
   */
  socket.on('mediasoup:produce', async (data, callback) => {
    try {
      const { transportId, kind, rtpParameters, appData } = data;
      const peerId = socket.data.mediasoupPeerId;
      const channelId = socket.data.mediasoupChannelId;
      const userId = socket.data.userId;

      if (!peerId || !channelId) {
        return callback({ error: 'Not joined to room' });
      }

      const producerId = await peerManager.createProducer(
        peerId,
        transportId,
        rtpParameters,
        kind,
        appData
      );

      callback({
        success: true,
        producerId: producerId
      });

      // Notify other peers about new producer
      socket.to(channelId).emit('mediasoup:new-producer', {
        userId: userId,
        peerId: peerId,
        producerId: producerId,
        kind: kind
      });

    } catch (error) {
      console.error('[mediasoup] Error producing:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Consume (start receiving audio/video from another peer)
   */
  socket.on('mediasoup:consume', async (data, callback) => {
    try {
      const { producerPeerId, producerId, rtpCapabilities } = data;
      const consumerPeerId = socket.data.mediasoupPeerId;

      if (!consumerPeerId) {
        return callback({ error: 'Not joined to room' });
      }

      const consumerParams = await peerManager.createConsumer(
        consumerPeerId,
        producerPeerId,
        producerId,
        rtpCapabilities
      );

      if (!consumerParams) {
        return callback({ error: 'Cannot consume this producer' });
      }

      callback({
        success: true,
        consumer: consumerParams
      });

    } catch (error) {
      console.error('[mediasoup] Error consuming:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Resume Consumer (start receiving media)
   */
  socket.on('mediasoup:resume-consumer', async (data, callback) => {
    try {
      const { consumerId } = data;
      const peerId = socket.data.mediasoupPeerId;

      if (!peerId) {
        return callback({ error: 'Not joined to room' });
      }

      await peerManager.resumeConsumer(peerId, consumerId);

      callback({ success: true });

    } catch (error) {
      console.error('[mediasoup] Error resuming consumer:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Pause Consumer (stop receiving media)
   */
  socket.on('mediasoup:pause-consumer', async (data, callback) => {
    try {
      const { consumerId } = data;
      const peerId = socket.data.mediasoupPeerId;

      if (!peerId) {
        return callback({ error: 'Not joined to room' });
      }

      await peerManager.pauseConsumer(peerId, consumerId);

      callback({ success: true });

    } catch (error) {
      console.error('[mediasoup] Error pausing consumer:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Close Producer (stop sending media)
   */
  socket.on('mediasoup:close-producer', async (data, callback) => {
    try {
      const { producerId } = data;
      const peerId = socket.data.mediasoupPeerId;
      const channelId = socket.data.mediasoupChannelId;

      if (!peerId || !channelId) {
        return callback({ error: 'Not joined to room' });
      }

      await peerManager.closeProducer(peerId, producerId);

      callback({ success: true });

      // Notify other peers
      socket.to(channelId).emit('mediasoup:producer-closed', {
        peerId: peerId,
        producerId: producerId
      });

    } catch (error) {
      console.error('[mediasoup] Error closing producer:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Get Room Stats (for admin/debugging)
   */
  socket.on('mediasoup:get-room-stats', async (data, callback) => {
    try {
      const { channelId } = data;

      const stats = roomManager.getRoomStats(channelId);

      callback({
        success: true,
        stats: stats
      });

    } catch (error) {
      console.error('[mediasoup] Error getting room stats:', error);
      callback({ error: error.message });
    }
  });

  /**
   * Handle disconnect - cleanup peer resources
   */
  socket.on('disconnect', async () => {
    const peerId = socket.data.mediasoupPeerId;
    const channelId = socket.data.mediasoupChannelId;
    const userId = socket.data.userId;

    if (peerId && channelId) {
      console.log(`[mediasoup] ${userId} disconnected, cleaning up peer ${peerId}`);

      try {
        await peerManager.removePeer(peerId);
        await roomManager.removePeer(channelId, userId);

        // Notify other peers
        socket.to(channelId).emit('mediasoup:peer-left', {
          userId: userId,
          peerId: peerId
        });

      } catch (error) {
        console.error('[mediasoup] Error during disconnect cleanup:', error);
      }
    }
  });
}

module.exports = {
  setupMediasoupSignaling
};
