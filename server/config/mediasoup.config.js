/**
 * mediasoup Configuration
 * SFU Server für End-to-End verschlüsselte Video Conferencing
 * 
 * Wichtig: E2EE ist MANDATORY - Server kann verschlüsselte Frames nicht sehen
 */

const os = require('os');

module.exports = {
  // Worker settings
  worker: {
    rtcMinPort: parseInt(process.env.MEDIASOUP_MIN_PORT || '40000'),
    rtcMaxPort: parseInt(process.env.MEDIASOUP_MAX_PORT || '40099'),
    logLevel: process.env.NODE_ENV === 'production' ? 'warn' : 'debug',
    logTags: [
      'info',
      'ice',
      'dtls',
      'rtp',
      'srtp',
      'rtcp'
      // 'rtx', 'bwe', 'score', 'simulcast', 'svc', 'sctp'  // Weitere Debug Tags
    ]
  },

  // Router settings (Media Codecs)
  router: {
    mediaCodecs: [
      // Audio: Opus (universell unterstützt)
      {
        kind: 'audio',
        mimeType: 'audio/opus',
        clockRate: 48000,
        channels: 2,
        parameters: {
          useinbandfec: 1,  // Forward Error Correction
          usedtx: 1         // Discontinuous Transmission (silence detection)
        }
      },
      
      // Video: VP8 (gut unterstützt, E2EE kompatibel)
      {
        kind: 'video',
        mimeType: 'video/VP8',
        clockRate: 90000,
        parameters: {
          'x-google-start-bitrate': 1000
        }
      },
      
      // Video: VP9 (bessere Compression, E2EE kompatibel)
      {
        kind: 'video',
        mimeType: 'video/VP9',
        clockRate: 90000,
        parameters: {
          'profile-id': 2,
          'x-google-start-bitrate': 1000
        }
      },
      
      // Video: H264 (Hardware-accelerated auf vielen Geräten)
      {
        kind: 'video',
        mimeType: 'video/H264',
        clockRate: 90000,
        parameters: {
          'packetization-mode': 1,
          'profile-level-id': '42e01f',
          'level-asymmetry-allowed': 1,
          'x-google-start-bitrate': 1000
        }
      }
    ]
  },

  // WebRTC Transport settings
  webRtcTransport: {
    listenIps: [
      {
        ip: process.env.MEDIASOUP_LISTEN_IP || '0.0.0.0',
        announcedIp: process.env.MEDIASOUP_ANNOUNCED_IP || '127.0.0.1'
      }
    ],
    
    // Bandwidth settings
    initialAvailableOutgoingBitrate: 1000000, // 1 Mbps
    minimumAvailableOutgoingBitrate: 600000,  // 600 kbps
    maxSctpMessageSize: 262144, // 256 KB
    maxIncomingBitrate: parseInt(process.env.MEDIASOUP_MAX_INCOMING_BITRATE || '1500') * 1000,
    
    // DTLS/SRTP (zusätzlich zu E2EE Frame Encryption)
    enableUdp: true,
    enableTcp: true,
    preferUdp: true,
    preferTcp: false,
    
    // ICE settings
    iceConsentTimeout: 20,
    
    // E2EE Note: Server sieht nur encrypted frames!
    // Kein Transcoding, keine Server-side Processing möglich
  },

  // Number of workers (CPU cores)
  numWorkers: process.env.MEDIASOUP_NUM_WORKERS === 'auto' 
    ? os.cpus().length 
    : parseInt(process.env.MEDIASOUP_NUM_WORKERS || '2'),

  // E2EE Settings
  e2ee: {
    mandatory: true,  // E2EE ist PFLICHT, nicht optional
    algorithm: 'AES-256-GCM',  // Verwendet von Insertable Streams
    keyRotationInterval: 3600000,  // 1 hour in ms
    
    // Browser Support Requirements
    supportedBrowsers: [
      'Chrome >= 86',
      'Edge >= 86',
      'Safari >= 15.4'
      // Firefox: Not yet supported (Stand 2025)
    ]
  }
};
