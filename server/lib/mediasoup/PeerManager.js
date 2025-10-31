/**
 * PeerManager - Manages mediasoup Transports, Producers, Consumers
 * 
 * Responsibilities:
 * - Create WebRTC Transports for each peer (send/recv)
 * - Manage Producers (media sent by peer)
 * - Manage Consumers (media received by peer)
 * - Handle transport events and connectivity
 * - Enforce E2EE at transport level
 * 
 * Architecture:
 * - 1 Peer = 1 User in 1 Room
 * - Each Peer has 2 Transports: sendTransport, recvTransport
 * - Producers: audio/video/screen shared by peer
 * - Consumers: audio/video/screen received from other peers
 */

const EventEmitter = require('events');
const config = require('../../config/mediasoup.config');

class PeerManager extends EventEmitter {
  constructor() {
    super();
    this.peers = new Map(); // peerId -> Peer object
  }

  /**
   * Create a new Peer
   * @param {string} peerId - Unique peer ID (userId-channelId)
   * @param {string} userId - User ID
   * @param {string} channelId - Channel/Room ID
   * @param {mediasoup.Router} router - mediasoup Router
   * @returns {Promise<Object>} Peer object
   */
  async createPeer(peerId, userId, channelId, router) {
    if (this.peers.has(peerId)) {
      console.warn(`[PeerManager] Peer ${peerId} already exists`);
      return this.peers.get(peerId);
    }

    console.log(`[PeerManager] Creating peer: ${peerId}`);

    const peer = {
      id: peerId,
      userId: userId,
      channelId: channelId,
      router: router,
      transports: new Map(), // transportId -> Transport
      producers: new Map(),  // producerId -> Producer
      consumers: new Map(),  // consumerId -> Consumer
      createdAt: Date.now(),
      e2eeEnabled: config.e2eeEnabled // Always true (mandatory)
    };

    this.peers.set(peerId, peer);
    
    console.log(`[PeerManager] ✓ Peer ${peerId} created (E2EE: ${peer.e2eeEnabled})`);
    this.emit('peercreated', { peerId, userId, channelId });

    return peer;
  }

  /**
   * Create WebRTC Transport for peer
   * @param {string} peerId - Peer ID
   * @param {string} direction - 'send' or 'recv'
   * @returns {Promise<Object>} Transport parameters for client
   */
  async createTransport(peerId, direction) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    console.log(`[PeerManager] Creating ${direction} transport for peer ${peerId}`);

    try {
      const transport = await peer.router.createWebRtcTransport({
        listenIps: config.webRtcTransport.listenIps,
        enableUdp: config.webRtcTransport.enableUdp,
        enableTcp: config.webRtcTransport.enableTcp,
        preferUdp: config.webRtcTransport.preferUdp,
        initialAvailableOutgoingBitrate: config.webRtcTransport.initialAvailableOutgoingBitrate,
      });

      // Store transport
      peer.transports.set(transport.id, {
        transport: transport,
        direction: direction
      });

      // Transport event handlers
      transport.on('dtlsstatechange', (dtlsState) => {
        console.log(`[PeerManager] Transport ${transport.id} dtlsState: ${dtlsState}`);
        
        if (dtlsState === 'failed' || dtlsState === 'closed') {
          console.warn(`[PeerManager] Transport ${transport.id} ${dtlsState}`);
          this.emit('transportfailed', { peerId, transportId: transport.id, dtlsState });
        }
      });

      transport.on('close', () => {
        console.log(`[PeerManager] Transport ${transport.id} closed`);
        peer.transports.delete(transport.id);
      });

      // Return transport parameters for client
      const transportParams = {
        id: transport.id,
        iceParameters: transport.iceParameters,
        iceCandidates: transport.iceCandidates,
        dtlsParameters: transport.dtlsParameters,
        e2eeEnabled: peer.e2eeEnabled // Inform client E2EE is mandatory
      };

      console.log(`[PeerManager] ✓ ${direction} transport created: ${transport.id}`);
      this.emit('transportcreated', { peerId, transportId: transport.id, direction });

      return transportParams;

    } catch (error) {
      console.error(`[PeerManager] ✗ Failed to create transport for ${peerId}:`, error);
      throw error;
    }
  }

  /**
   * Connect transport (client sends DTLS parameters)
   * @param {string} peerId - Peer ID
   * @param {string} transportId - Transport ID
   * @param {Object} dtlsParameters - DTLS parameters from client
   */
  async connectTransport(peerId, transportId, dtlsParameters) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    const transportData = peer.transports.get(transportId);
    if (!transportData) {
      throw new Error(`Transport ${transportId} not found for peer ${peerId}`);
    }

    console.log(`[PeerManager] Connecting transport ${transportId} for peer ${peerId}`);

    await transportData.transport.connect({ dtlsParameters });
    
    console.log(`[PeerManager] ✓ Transport ${transportId} connected`);
    this.emit('transportconnected', { peerId, transportId });
  }

  /**
   * Create Producer (peer starts sending media)
   * @param {string} peerId - Peer ID
   * @param {string} transportId - Transport ID
   * @param {Object} rtpParameters - RTP parameters from client
   * @param {string} kind - 'audio' or 'video'
   * @param {string} appData - Application-specific data
   * @returns {Promise<string>} Producer ID
   */
  async createProducer(peerId, transportId, rtpParameters, kind, appData = {}) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    const transportData = peer.transports.get(transportId);
    if (!transportData) {
      throw new Error(`Transport ${transportId} not found`);
    }

    console.log(`[PeerManager] Creating ${kind} producer for peer ${peerId}`);

    try {
      const producer = await transportData.transport.produce({
        kind: kind,
        rtpParameters: rtpParameters,
        appData: { ...appData, peerId, userId: peer.userId }
      });

      // Store producer
      peer.producers.set(producer.id, producer);

      // Producer event handlers
      producer.on('transportclose', () => {
        console.log(`[PeerManager] Producer ${producer.id} transport closed`);
        peer.producers.delete(producer.id);
      });

      producer.on('close', () => {
        console.log(`[PeerManager] Producer ${producer.id} closed`);
        peer.producers.delete(producer.id);
      });

      console.log(`[PeerManager] ✓ ${kind} producer created: ${producer.id}`);
      this.emit('producercreated', { peerId, producerId: producer.id, kind });

      return producer.id;

    } catch (error) {
      console.error(`[PeerManager] ✗ Failed to create producer for ${peerId}:`, error);
      throw error;
    }
  }

  /**
   * Create Consumer (peer receives media from another peer)
   * @param {string} consumerPeerId - Peer who will consume (receiver)
   * @param {string} producerPeerId - Peer who is producing (sender)
   * @param {string} producerId - Producer ID
   * @param {Object} rtpCapabilities - RTP capabilities of consumer
   * @returns {Promise<Object>} Consumer parameters for client
   */
  async createConsumer(consumerPeerId, producerPeerId, producerId, rtpCapabilities) {
    const consumerPeer = this.peers.get(consumerPeerId);
    if (!consumerPeer) {
      throw new Error(`Consumer peer ${consumerPeerId} not found`);
    }

    const producerPeer = this.peers.get(producerPeerId);
    if (!producerPeer) {
      throw new Error(`Producer peer ${producerPeerId} not found`);
    }

    const producer = producerPeer.producers.get(producerId);
    if (!producer) {
      throw new Error(`Producer ${producerId} not found`);
    }

    // Check if router can consume
    if (!consumerPeer.router.canConsume({ producerId, rtpCapabilities })) {
      console.warn(`[PeerManager] Router cannot consume producer ${producerId}`);
      return null;
    }

    console.log(`[PeerManager] Creating consumer: ${consumerPeerId} <- ${producerPeerId} (${producer.kind})`);

    // Get recv transport
    let recvTransport = null;
    for (const [id, data] of consumerPeer.transports) {
      if (data.direction === 'recv') {
        recvTransport = data.transport;
        break;
      }
    }

    if (!recvTransport) {
      throw new Error(`No recv transport found for peer ${consumerPeerId}`);
    }

    try {
      const consumer = await recvTransport.consume({
        producerId: producerId,
        rtpCapabilities: rtpCapabilities,
        paused: true, // Start paused, client will resume
        appData: { 
          peerId: consumerPeerId,
          producerPeerId: producerPeerId,
          userId: consumerPeer.userId
        }
      });

      // Store consumer
      consumerPeer.consumers.set(consumer.id, consumer);

      // Consumer event handlers
      consumer.on('transportclose', () => {
        console.log(`[PeerManager] Consumer ${consumer.id} transport closed`);
        consumerPeer.consumers.delete(consumer.id);
      });

      consumer.on('producerclose', () => {
        console.log(`[PeerManager] Consumer ${consumer.id} producer closed`);
        consumerPeer.consumers.delete(consumer.id);
        this.emit('consumerproducerclosed', { peerId: consumerPeerId, consumerId: consumer.id });
      });

      consumer.on('close', () => {
        console.log(`[PeerManager] Consumer ${consumer.id} closed`);
        consumerPeer.consumers.delete(consumer.id);
      });

      // Return consumer parameters for client
      const consumerParams = {
        id: consumer.id,
        producerId: producerId,
        kind: consumer.kind,
        rtpParameters: consumer.rtpParameters,
        type: consumer.type,
        producerPaused: consumer.producerPaused,
        e2eeEnabled: consumerPeer.e2eeEnabled // Inform client E2EE is mandatory
      };

      console.log(`[PeerManager] ✓ Consumer created: ${consumer.id}`);
      this.emit('consumercreated', { peerId: consumerPeerId, consumerId: consumer.id, producerId });

      return consumerParams;

    } catch (error) {
      console.error(`[PeerManager] ✗ Failed to create consumer:`, error);
      throw error;
    }
  }

  /**
   * Resume consumer (start receiving media)
   * @param {string} peerId - Peer ID
   * @param {string} consumerId - Consumer ID
   */
  async resumeConsumer(peerId, consumerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    const consumer = peer.consumers.get(consumerId);
    if (!consumer) {
      throw new Error(`Consumer ${consumerId} not found`);
    }

    await consumer.resume();
    console.log(`[PeerManager] Consumer ${consumerId} resumed`);
  }

  /**
   * Pause consumer (stop receiving media)
   * @param {string} peerId - Peer ID
   * @param {string} consumerId - Consumer ID
   */
  async pauseConsumer(peerId, consumerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    const consumer = peer.consumers.get(consumerId);
    if (!consumer) {
      throw new Error(`Consumer ${consumerId} not found`);
    }

    await consumer.pause();
    console.log(`[PeerManager] Consumer ${consumerId} paused`);
  }

  /**
   * Close producer (peer stops sending media)
   * @param {string} peerId - Peer ID
   * @param {string} producerId - Producer ID
   */
  async closeProducer(peerId, producerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      throw new Error(`Peer ${peerId} not found`);
    }

    const producer = peer.producers.get(producerId);
    if (!producer) {
      console.warn(`[PeerManager] Producer ${producerId} not found for closure`);
      return;
    }

    producer.close();
    peer.producers.delete(producerId);
    
    console.log(`[PeerManager] Producer ${producerId} closed`);
    this.emit('producerclosed', { peerId, producerId });
  }

  /**
   * Get peer
   * @param {string} peerId - Peer ID
   * @returns {Object|null}
   */
  getPeer(peerId) {
    return this.peers.get(peerId) || null;
  }

  /**
   * Remove peer and cleanup all resources
   * @param {string} peerId - Peer ID
   */
  async removePeer(peerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      console.warn(`[PeerManager] Peer ${peerId} not found for removal`);
      return;
    }

    console.log(`[PeerManager] Removing peer: ${peerId}`);

    // Close all producers
    for (const producer of peer.producers.values()) {
      producer.close();
    }

    // Close all consumers
    for (const consumer of peer.consumers.values()) {
      consumer.close();
    }

    // Close all transports
    for (const { transport } of peer.transports.values()) {
      transport.close();
    }

    // Remove peer from map
    this.peers.delete(peerId);

    const lifetime = Date.now() - peer.createdAt;
    console.log(`[PeerManager] ✓ Peer ${peerId} removed (lifetime: ${Math.round(lifetime / 1000)}s)`);
    
    this.emit('peerremoved', { peerId, lifetime });
  }

  /**
   * Get all producers in a channel (for new peer joining)
   * @param {string} channelId - Channel ID
   * @param {string} excludePeerId - Exclude this peer
   * @returns {Array<Object>} Array of {peerId, producerId, kind}
   */
  getChannelProducers(channelId, excludePeerId = null) {
    const producers = [];

    for (const [peerId, peer] of this.peers) {
      if (peer.channelId !== channelId) continue;
      if (excludePeerId && peerId === excludePeerId) continue;

      for (const [producerId, producer] of peer.producers) {
        producers.push({
          peerId: peerId,
          userId: peer.userId,
          producerId: producerId,
          kind: producer.kind
        });
      }
    }

    return producers;
  }

  /**
   * Get peer statistics
   * @param {string} peerId - Peer ID
   * @returns {Object|null}
   */
  getPeerStats(peerId) {
    const peer = this.peers.get(peerId);
    if (!peer) {
      return null;
    }

    return {
      id: peer.id,
      userId: peer.userId,
      channelId: peer.channelId,
      transportCount: peer.transports.size,
      producerCount: peer.producers.size,
      consumerCount: peer.consumers.size,
      e2eeEnabled: peer.e2eeEnabled,
      uptime: Date.now() - peer.createdAt
    };
  }
}

// Singleton instance
let instance = null;

/**
 * Get PeerManager singleton instance
 * @returns {PeerManager}
 */
function getPeerManager() {
  if (!instance) {
    instance = new PeerManager();
  }
  return instance;
}

module.exports = {
  PeerManager,
  getPeerManager
};
