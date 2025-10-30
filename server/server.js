/**
 * Required modules
 */
const config = require('./config/config');
const LicenseValidator = require('./lib/license-validator');
const express = require("express");
const { randomUUID } = require('crypto');
const http = require("http");
const app = express();
const sanitizeHtml = require('sanitize-html');
const cors = require('cors');
const session = require('express-session');
const sharedSession = require('socket.io-express-session');
const { User, Channel, Thread, Client, SignalSignedPreKey, SignalPreKey, Item, ChannelMembers, SignalSenderKey, GroupItem, GroupItemRead } = require('./db/model');
const path = require('path');
const writeQueue = require('./db/writeQueue');
const { initCleanupJob } = require('./jobs/cleanup');

// Initialize license validator
const licenseValidator = new LicenseValidator();

// Validate license on startup
(async () => {
  console.log('\n🔐 Validating PeerWave License...');
  const license = await licenseValidator.validate();
  
  if (license.valid) {
    console.log('✅ License Valid');
    console.log(`   Customer: ${license.customer}`);
    console.log(`   Type: ${license.type}`);
    console.log(`   Expires: ${license.expires.toISOString().split('T')[0]} (${license.daysRemaining} days)`);
    
    if (license.gracePeriod) {
      console.log(`   ⚠️  Grace Period: ${license.daysRemaining} days remaining`);
    }
    
    if (license.features.maxUsers) {
      console.log(`   Max Users: ${license.features.maxUsers}`);
    }
    
    console.log(`   Grace Period: ${license.gracePeriodDays} days after expiration`);
  } else if (license.error === 'EXPIRED') {
    // License expired and grace period is over - STOP SERVER
    console.error('\n❌ FATAL: License has expired!');
    console.error(`   ${license.message}`);
    console.error(`   Server cannot start with expired license.`);
    console.error(`   Please renew your license or contact support.\n`);
    process.exit(1);
  } else {
    console.log(`⚠️  No valid license found: ${license.message}`);
    console.log(`   Running in non-commercial mode`);
  }
  console.log('');
})();

// Function to validate UUID
function isValidUUID(uuid) {
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[4][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(uuid);
}

// Configure session middleware

const sessionMiddleware = session({
    secret: config.session.secret, // Replace with a strong secret key
    resave: config.session.resave,
    saveUninitialized: config.session.saveUninitialized,
    cookie: config.cookie // Set to true if using HTTPS
});

// Use session middleware in Express
app.use(sessionMiddleware);


  const authRoutes = require('./routes/auth');
  const clientRoutes = require('./routes/client');
  const roleRoutes = require('./routes/roles');
  const groupItemRoutes = require('./routes/groupItems');
  const senderKeyRoutes = require('./routes/senderKeys');

  app.use(clientRoutes);
  app.use('/api', roleRoutes);
  app.use('/api/group-items', groupItemRoutes);
  app.use('/api/sender-keys', senderKeyRoutes);

  // License info endpoint
  app.get('/api/license-info', async (req, res) => {
    const license = await licenseValidator.validate();
    
    if (license.valid) {
      res.json({
        type: license.type,
        showNotice: license.type === 'commercial' ? false : true,
        message: 'Private/Non-Commercial Use',
        customer: license.customer,
        expires: license.expires,
        daysRemaining: license.daysRemaining,
        gracePeriod: license.gracePeriod || false,
        features: license.features
      });
    } else {
      // Fallback to non-commercial
      res.json({
        type: 'non-commercial',
        showNotice: true,
        message: 'Private/Non-Commercial Use',
        features: {}
      });
    }
  });

  //SOCKET.IO
const rooms = {};
const port = config.port || 4000;

const server = http.createServer(app);
const io = require("socket.io")(server);

io.use(sharedSession(sessionMiddleware, { autoSave: true }));

const deviceSockets = new Map(); // Key: userId:deviceId, Value: socket.id

io.sockets.on("error", e => console.log(e));
io.sockets.on("connection", socket => {

  socket.on("authenticate", () => {
    // Here you would normally check the clientid and mail against your database
    try {
      console.log("[SIGNAL SERVER] authenticate event received");
      console.log("[SIGNAL SERVER] Session:", socket.handshake.session);
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        const deviceKey = `${socket.handshake.session.uuid}:${socket.handshake.session.deviceId}`;
        deviceSockets.set(deviceKey, socket.id);
        console.log(`[SIGNAL SERVER] Device registered: ${deviceKey} -> ${socket.id}`);
        console.log(`[SIGNAL SERVER] Total devices online: ${deviceSockets.size}`);
        socket.emit("authenticated", { 
          authenticated: true,
          uuid: socket.handshake.session.uuid,
          deviceId: socket.handshake.session.deviceId
        });
      } else {
        console.log("[SIGNAL SERVER] Authentication failed - missing session data");
        socket.emit("authenticated", { authenticated: false });
      }
    } catch (error) {
      console.error('Error during authentication:', error);
      socket.emit("authenticated", { authenticated: false });
    }
  });

  // SIGNAL HANDLE START

  socket.on("signalIdentity", async (data) => {
    console.log("[SIGNAL SERVER] signalIdentity event received");
    console.log(socket.handshake.session);
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Handle the signal identity - enqueue write operation
        await writeQueue.enqueue(async () => {
          return await Client.update(
            { public_key: data.publicKey, registration_id: data.registrationId },
            { where: { owner: socket.handshake.session.uuid, clientid: socket.handshake.session.clientId } }
          );
        }, 'signalIdentity');
      }
    } catch (error) {
      console.error('Error handling signal identity:', error);
    }
  });

  socket.on("getSignedPreKeys", async () => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Fetch signed pre-keys from the database
        const signedPreKeys = await SignalSignedPreKey.findAll({
          where: { owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId },
          order: [['createdAt', 'DESC']]
        });
        socket.emit("getSignedPreKeysResponse", signedPreKeys);
      }
    } catch (error) {
      console.error('Error fetching signed pre-keys:', error);
      socket.emit("getSignedPreKeysResponse", { error: 'Failed to fetch signed pre-keys' });
    }
  });

  socket.on("removePreKey", async (data) => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        await writeQueue.enqueue(async () => {
          return await SignalPreKey.destroy({
            where: { prekey_id: data.id, owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId }
          });
        }, `removePreKey-${data.id}`);
      }
    } catch (error) {
      console.error('Error removing pre-key:', error);
    }
  });

  socket.on("removeSignedPreKey", async (data) => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.destroy({
            where: { signed_prekey_id: data.id, owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId }
          });
        }, `removeSignedPreKey-${data.id}`);
      }
    } catch (error) {
      console.error('Error removing signed pre-key:', error);
    }
  });

  socket.on("storeSignedPreKey", async (data) => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Create if not exists, otherwise do nothing - enqueue write operation
        await writeQueue.enqueue(async () => {
          return await SignalSignedPreKey.findOrCreate({
            where: {
              signed_prekey_id: data.id,
              owner: socket.handshake.session.uuid,
              client: socket.handshake.session.clientId,
            },
            defaults: {
              signed_prekey_data: data.data,
              signed_prekey_signature: data.signature,
            }
          });
        }, `storeSignedPreKey-${data.id}`);
      }
    } catch (error) {
      console.error('Error storing signed pre-key:', error);
    }
  });

  socket.on("storePreKey", async (data) => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Only store if prekey_data is a 33-byte base64-encoded public key
        let decoded;
        try {
          decoded = Buffer.from(data.data, 'base64');
        } catch (e) {
          console.error('[SIGNAL SERVER] Invalid base64 in prekey_data:', data.data);
          return;
        }
        if (decoded.length !== 33) {
          console.error(`[SIGNAL SERVER] Refusing to store pre-key: prekey_data is ${decoded.length} bytes (expected 33). Possible private key leak or wrong format.`);
          return;
        }
        await writeQueue.enqueue(async () => {
          return await SignalPreKey.findOrCreate({
            where: {
              prekey_id: data.id,
              owner: socket.handshake.session.uuid,
              client: socket.handshake.session.clientId,
            },
            defaults: {
              prekey_data: data.data,
            }
          });
        }, `storePreKey-${data.id}`);
      }
    } catch (error) {
      console.error('Error storing pre-key:', error);
      console.log("[SIGNAL SERVER] storePreKey event received", data);
      console.log(socket.handshake.session);
    }
  });

  // Batch store pre-keys
  socket.on("storePreKeys", async (data) => {
    // ACCEPT BOTH FORMATS:
    // NEW: { preKeys: [ { id, data }, ... ] }
    // OLD: [ { id, data }, ... ] (direct array for backwards compatibility)
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Handle both formats: direct array or wrapped in { preKeys: ... }
        const preKeysArray = Array.isArray(data) ? data : (Array.isArray(data.preKeys) ? data.preKeys : null);
        
        if (preKeysArray) {
          console.log(`[SIGNAL SERVER] Receiving ${preKeysArray.length} PreKeys for batch storage`);
          
          // Enqueue entire batch as a single operation to maintain atomicity
          await writeQueue.enqueue(async () => {
            const results = [];
            for (const preKey of preKeysArray) {
              if (preKey && preKey.id && preKey.data) {
                let decoded;
                try {
                  decoded = Buffer.from(preKey.data, 'base64');
                } catch (e) {
                  console.error('[SIGNAL SERVER] Invalid base64 in batch prekey_data:', preKey.data);
                  continue;
                }
                if (decoded.length !== 33) {
                  console.error(`[SIGNAL SERVER] Refusing to store batch pre-key: prekey_data is ${decoded.length} bytes (expected 33). Possible private key leak or wrong format. id=${preKey.id}`);
                  continue;
                }
                const result = await SignalPreKey.findOrCreate({
                  where: {
                    prekey_id: preKey.id,
                    owner: socket.handshake.session.uuid,
                    client: socket.handshake.session.clientId,
                  },
                  defaults: {
                    prekey_data: preKey.data,
                  }
                });
                results.push(result);
              }
            }
            console.log(`[SIGNAL SERVER] Successfully stored ${results.length} PreKeys`);
            return results;
          }, `storePreKeys-batch-${preKeysArray.length}`);
          
          // CRITICAL: After storage, return ALL PreKey IDs from server for sync verification
          const allServerPreKeys = await SignalPreKey.findAll({
            where: { 
              owner: socket.handshake.session.uuid, 
              client: socket.handshake.session.clientId 
            },
            attributes: ['prekey_id']
          });
          
          const serverPreKeyIds = allServerPreKeys.map(pk => pk.prekey_id);
          console.log(`[SIGNAL SERVER] Sending sync response with ${serverPreKeyIds.length} PreKey IDs`);
          
          // Send back server's PreKey IDs for client to verify sync
          socket.emit("storePreKeysResponse", {
            success: true,
            serverPreKeyIds: serverPreKeyIds,
            count: serverPreKeyIds.length
          });
          
        } else {
          console.error('[SIGNAL SERVER] storePreKeys: Invalid data format - expected array or { preKeys: array }');
          socket.emit("storePreKeysResponse", {
            success: false,
            error: 'Invalid data format'
          });
        }
      }
    } catch (error) {
      console.error('Error storing pre-keys (batch):', error);
      console.log("[SIGNAL SERVER] storePreKeys event received", data);
      console.log(socket.handshake.session);
      socket.emit("storePreKeysResponse", {
        success: false,
        error: error.message
      });
    }
  });

  // Signal status summary for current device
  socket.on("signalStatus", async (_) => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Identity: check if public_key and registration_id are present
        const client = await Client.findOne({
          where: { owner: socket.handshake.session.uuid, clientid: socket.handshake.session.clientId }
        });
        const identityPresent = !!(client && client.public_key && client.registration_id);

        // PreKeys: count
        const preKeysCount = await SignalPreKey.count({
          where: { owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId }
        });

        // SignedPreKey: latest
        const signedPreKey = await SignalSignedPreKey.findOne({
          where: { owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId },
          order: [['createdAt', 'DESC']]
        });
        let signedPreKeyStatus = null;
        if (signedPreKey) {
          signedPreKeyStatus = {
            id: signedPreKey.signed_prekey_id,
            createdAt: signedPreKey.createdAt
          };
        }

        const status = {
          identity: identityPresent,
          preKeys: preKeysCount,
          signedPreKey: signedPreKeyStatus
        };
        socket.emit("signalStatusResponse", status);
      }
      else {
        socket.emit("signalStatusResponse", { error: 'Not authenticated' });
      }
    } catch (error) {
      console.error('Error in signalStatus:', error);
      socket.emit("signalStatusResponse", { error: 'Failed to get signal status' });
    }
  });

  socket.on("getPreKeys", async () => {
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        // Fetch pre-keys from the database
        const preKeys = await SignalPreKey.findAll({
          where: { owner: socket.handshake.session.uuid, client: socket.handshake.session.clientId }
        });
        socket.emit("getPreKeysResponse", preKeys);
      }
    } catch (error) {
      console.error('Error fetching pre-keys:', error);
      socket.emit("getPreKeysResponse", { error: 'Failed to fetch pre-keys' });
    }
  });

  socket.on("sendItem", async (data) => {
    console.log("[SIGNAL SERVER] sendItem event received", data);
    console.log(socket.handshake.session);
    try {
      if(socket.handshake.session.uuid && socket.handshake.session.email && socket.handshake.session.deviceId && socket.handshake.session.clientId && socket.handshake.session.authenticated === true) {
        const recipientUserId = data.recipient;
        const recipientDeviceId = data.recipientDeviceId;
        const senderUserId = socket.handshake.session.uuid;
        const senderDeviceId = socket.handshake.session.deviceId;
        const type = data.type;
        const payload = data.payload;
        const cipherType = parseInt(data.cipherType, 10);
        const itemId = data.itemId;

        // Store ALL 1:1 messages in the database (including PreKey for offline recipients)
        // NOTE: Item table is for 1:1 messages ONLY (no channel field)
        // Group messages use sendGroupItem event and GroupItem table instead
        console.log(`[SIGNAL SERVER] Storing 1:1 message in DB: cipherType=${cipherType}, itemId=${itemId}`);
        const storedItem = await writeQueue.enqueue(async () => {
          return await Item.create({
            sender: senderUserId,
            deviceSender: senderDeviceId,
            receiver: recipientUserId,
            deviceReceiver: recipientDeviceId,
            type: type,
            payload: payload,
            cipherType: cipherType,
            itemId: itemId
          });
        }, `sendItem-${itemId}`);
         console.log(`[SIGNAL SERVER] Message stored successfully in DB`);

        // Send delivery receipt to sender IMMEDIATELY after DB storage
        // (regardless of whether recipient is online)
        const senderSocketId = deviceSockets.get(`${senderUserId}:${senderDeviceId}`);
        if (senderSocketId) {
          io.to(senderSocketId).emit("deliveryReceipt", {
            itemId: itemId,
            recipientUserId: recipientUserId,
            recipientDeviceId: recipientDeviceId,
            deliveredAt: new Date().toISOString()
          });
          console.log(`[SIGNAL SERVER] ✓ Delivery receipt sent to sender ${senderUserId}:${senderDeviceId} (message stored in DB)`);
        }

        // Sende die Nachricht an das spezifische Gerät (recipientDeviceId),
        // für das sie verschlüsselt wurde
        const targetSocketId = deviceSockets.get(`${recipientUserId}:${recipientDeviceId}`);
        const isSelfMessage = (recipientUserId === senderUserId && recipientDeviceId === senderDeviceId);
        
        console.log(`[SIGNAL SERVER] Target device: ${recipientUserId}:${recipientDeviceId}, socketId: ${targetSocketId}`);
        console.log(`[SIGNAL SERVER] Is self-message: ${isSelfMessage}`);
        console.log(`[SIGNAL SERVER] cipherType`, cipherType);
        if (targetSocketId) {
          // Send 1:1 message to target device (NO channel field - direct messages only)
          io.to(targetSocketId).emit("receiveItem", {
            sender: senderUserId,
            senderDeviceId: senderDeviceId,
            recipient: recipientUserId,
            type: type,
            payload: payload,
            cipherType: cipherType,
            itemId: itemId,
            // NOTE: channel is NOT included - receiveItem is for 1:1 messages ONLY
            // Group messages use groupItem event instead
          });
          console.log(`[SIGNAL SERVER] 1:1 message sent to device ${recipientUserId}:${recipientDeviceId}`);
          
          // Update delivery timestamp in database (recipient received the message)
          await writeQueue.enqueue(async () => {
            return await Item.update(
              { deliveredAt: new Date() },
              { where: { uuid: storedItem.uuid } }
            );
          }, `deliveryUpdate-${itemId}`);
        } else {
          console.log(`[SIGNAL SERVER] Target device ${recipientUserId}:${recipientDeviceId} is offline, message stored in DB`);
        }
       } else {
         console.error('[SIGNAL SERVER] ERROR: sendItem blocked - missing session data:');
         console.error(`  uuid: ${!!socket.handshake.session.uuid}`);
         console.error(`  email: ${!!socket.handshake.session.email}`);
         console.error(`  deviceId: ${!!socket.handshake.session.deviceId}`);
         console.error(`  clientId: ${!!socket.handshake.session.clientId}`);
         console.error(`  authenticated: ${socket.handshake.session.authenticated}`);
         console.error('  Please re-authenticate (logout/login or refresh page)');
      }
    } catch (error) {
      console.error('Error sending item:', error);
    }
  });

  // ===== DEPRECATED: OLD GROUP MESSAGE HANDLER =====
  // This handler is kept for backward compatibility but uses the old Item table
  // instead of the new GroupItem table. It should not be used in new code.
  // Use sendGroupItem event instead.
  socket.on("sendGroupMessage", async (data) => {
    console.log("[SIGNAL SERVER] ⚠ WARNING: sendGroupMessage is deprecated, use sendGroupItem instead");
    console.log("[SIGNAL SERVER] Received deprecated sendGroupMessage event", data);
    
    try {
      if(!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[SIGNAL SERVER] ERROR: sendGroupMessage blocked - not authenticated');
        return;
      }

      // Redirect to new sendGroupItem handler
      // Map old data format to new format
      const newData = {
        channelId: data.groupId,
        itemId: data.itemId,
        type: 'message',
        payload: data.ciphertext,
        cipherType: 4,  // Sender Key
        timestamp: data.timestamp
      };

      console.log('[SIGNAL SERVER] Redirecting to sendGroupItem handler with new format');
      // Trigger the new handler
      socket.emit('_internalSendGroupItem', newData);
      
    } catch (error) {
      console.error('[SIGNAL SERVER] Error in deprecated sendGroupMessage:', error);
    }
  });

  // GROUP MESSAGE READ RECEIPT HANDLER
  socket.on("groupMessageRead", async (data) => {
    try {
      if(!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[SIGNAL SERVER] ERROR: groupMessageRead blocked - not authenticated');
        return;
      }

      const { itemId, groupId } = data;
      const readerUserId = socket.handshake.session.uuid;
      const readerDeviceId = socket.handshake.session.deviceId;

      // Update readed flag for this specific device's Item
      const updatedCount = await writeQueue.enqueue(async () => {
        return await Item.update(
          { readed: true },
          { 
            where: { 
              itemId: itemId,
              channel: groupId,
              receiver: readerUserId,
              deviceReceiver: readerDeviceId,
              type: 'groupMessage'
            }
          }
        );
      }, `groupMessageRead-${itemId}-${readerDeviceId}`);

      if (updatedCount[0] > 0) {
        console.log(`[SIGNAL SERVER] Message ${itemId} marked as read by ${readerUserId}:${readerDeviceId}`);

        // Get all Items for this message to calculate read statistics
        const allItems = await Item.findAll({
          where: { 
            itemId: itemId,
            channel: groupId,
            type: 'groupMessage'
          }
        });

        const totalDevices = allItems.length;
        const readDevices = allItems.filter(item => item.readed === true).length;
        const deliveredDevices = allItems.filter(item => item.deliveredAt !== null).length;
        const allRead = readDevices === totalDevices;

        // Send read receipt update to the message sender
        const senderItem = allItems[0]; // All items have the same sender
        if (senderItem) {
          const senderSocketId = deviceSockets.get(`${senderItem.sender}:${senderItem.deviceSender}`);
          if (senderSocketId) {
            io.to(senderSocketId).emit("groupMessageReadReceipt", {
              itemId: itemId,
              groupId: groupId,
              readBy: readerUserId,
              readByDeviceId: readerDeviceId,
              readCount: readDevices,
              deliveredCount: deliveredDevices,
              totalCount: totalDevices,
              allRead: allRead,
              readAt: new Date().toISOString()
            });
            console.log(`[SIGNAL SERVER] Read receipt sent to sender: ${readDevices}/${totalDevices} devices have read`);
          }

          // If all devices have read the message, delete it from server
          if (allRead) {
            const deletedCount = await writeQueue.enqueue(async () => {
              return await Item.destroy({
                where: { 
                  itemId: itemId,
                  channel: groupId,
                  type: 'groupMessage'
                }
              });
            }, `deleteReadGroupMessage-${itemId}`);
            
            console.log(`[SIGNAL SERVER] ✓ Group message ${itemId} read by all ${totalDevices} devices and deleted from server`);
          }
        }
      }
    } catch (error) {
      console.error('[SIGNAL SERVER] Error in groupMessageRead:', error);
    }
  });

  // Store sender key on server (when device creates/distributes sender key)
  socket.on("storeSenderKey", async (data) => {
    try {
      if(!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[SIGNAL SERVER] ERROR: storeSenderKey blocked - not authenticated');
        return;
      }

      const { groupId, senderKey } = data;
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;

      // Find the client record
      const client = await Client.findOne({
        where: {
          owner: userId,
          device_id: deviceId
        }
      });

      if (!client) {
        console.error('[SIGNAL SERVER] ERROR: Client not found for storeSenderKey');
        return;
      }

      // Store or update sender key
      const [stored, created] = await SignalSenderKey.findOrCreate({
        where: {
          channel: groupId,
          client: client.clientid
        },
        defaults: {
          channel: groupId,
          client: client.clientid,
          owner: userId,
          sender_key: senderKey
        }
      });

      if (!created) {
        // Update existing sender key
        await stored.update({ sender_key: senderKey });
      }

      console.log(`[SIGNAL SERVER] Stored sender key for ${userId}:${deviceId} in group ${groupId}`);
      
      // Send confirmation
      socket.emit("senderKeyStored", { groupId, success: true });
    } catch (error) {
      console.error('[SIGNAL SERVER] Error in storeSenderKey:', error);
    }
  });

  // Retrieve sender key from server (when device needs a missing sender key)
  socket.on("getSenderKey", async (data) => {
    try {
      if(!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[SIGNAL SERVER] ERROR: getSenderKey blocked - not authenticated');
        return;
      }

      const { groupId, requestedUserId, requestedDeviceId } = data;

      // Find the client record for the requested sender
      const client = await Client.findOne({
        where: {
          owner: requestedUserId,
          device_id: requestedDeviceId
        }
      });

      if (!client) {
        console.error(`[SIGNAL SERVER] ERROR: Client not found for getSenderKey: ${requestedUserId}:${requestedDeviceId}`);
        socket.emit("senderKeyResponse", { groupId, requestedUserId, requestedDeviceId, senderKey: null });
        return;
      }

      // Retrieve sender key
      const senderKeyRecord = await SignalSenderKey.findOne({
        where: {
          channel: groupId,
          client: client.clientid
        }
      });

      if (senderKeyRecord) {
        console.log(`[SIGNAL SERVER] Retrieved sender key for ${requestedUserId}:${requestedDeviceId} in group ${groupId}`);
        socket.emit("senderKeyResponse", {
          groupId,
          requestedUserId,
          requestedDeviceId,
          senderKey: senderKeyRecord.sender_key,
          success: true
        });
      } else {
        console.log(`[SIGNAL SERVER] Sender key not found for ${requestedUserId}:${requestedDeviceId} in group ${groupId}`);
        socket.emit("senderKeyResponse", {
          groupId,
          requestedUserId,
          requestedDeviceId,
          senderKey: null,
          success: false
        });
      }
    } catch (error) {
      console.error('[SIGNAL SERVER] Error in getSenderKey:', error);
    }
  });

  // SIGNAL HANDLE END
  
  /*socket.on("channels", async(callback) => {
    try {
      const channels = await Channel.findAll({
        include: [
          {
            model: User,
            as: 'Members',
            where: { uuid: socket.handshake.session.uuid },
            through: { attributes: [] }
          },
          {
            model: Thread,
            required: false,
            attributes: [],
          }
        ],
        attributes: {
          include: [
            [Channel.sequelize.fn('MAX', Channel.sequelize.col('Threads.createdAt')), 'latestThread']
          ]
        },
        group: ['Channel.name'],
        order: [[Channel.sequelize.literal('latestThread'), 'DESC']],
        limit: 5
      });
      
      callbackHandler(callback, channels);
    } catch (error) {
      console.error('Error fetching channels:', error);
      callbackHandler(callback, { error: 'Failed to fetch channels' });
    }
  });

  /**
   * Event handler for hosting a room
   * @param {number} slots - Number of available download slots for the host
   * @param {Callback} callback - Callback function to be invoked with the room ID
   */
  socket.on("host", (slots, callback) => {
    const room = randomUUID();
    const seeders = {[socket.id]: {slots: Number(slots), peers: 0, level: 0, score: 100.0}};
    rooms[room] = {host: socket.id, seeders: seeders, stream: false, share: {}, meeting: false, meetingSettings: {}};

    socket.join(room);
    callbackHandler(callback, room);
  });

  /**
   * Event handler for connecting as a client to a room
   * @param {string} room - The ID of the room to connect to
   * @param {string} filename - The name of the file to download
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("client", (room, filename, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined) {
        if (typeof callback === "function") callback({message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seeders = Object.entries(roomData.seeders);

    for (const [seeder, value] of seeders) {
        let fileSeeders;
        if (roomData.share.files[filename]) {
            fileSeeders = roomData.share.files[filename].seeders;
        }
        if (!fileSeeders || !fileSeeders.includes(seeder) || value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("client", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available download slot, please try later", room});
  });

  /**
   * Event handler for watching a room
   * @param {string} room - The ID of the room to watch
   * @param {Callback} callback - Callback function to be invoked with the connection status
   */
  socket.on("watch", (room, callback) => {
    const roomData = rooms[room];
    if (!roomData || roomData.host === undefined || roomData.stream !== true) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }

    socket.join(room);
    const seedersDesc = Object.entries(roomData.seeders).sort((a,b) => a.score > b.score);

    for (const [seeder, value] of seedersDesc) {
        if (value.slots <= value.peers || seeder === socket.id) continue;

        socket.to(seeder).emit("watch", socket.id);
        callbackHandler(callback, {message: "Client connected", room, host: seeder});
        socket.to(roomData.host).emit("currentPeers", Object.keys(roomData.seeders).length);
        return;
    }

    callbackHandler(callback, {message: "no available stream slot, please try later", room});
  });

  socket.on("negotiationneeded", (id) => {
    socket.to(id).emit("negotiationneeded", socket.id);
  });

  /**
   * Event handler for offering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The offer message
   */
  socket.on("offer", (id, message) => {
    socket.to(id).emit("offer", socket.id, message);
  });

  socket.on("offerScreenshare", (id, message) => {
    socket.to(id).emit("offerScreenshare", socket.id, message);
  });

  /**
   * Event handler for answering a WebRTC connection
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The answer message
   */
  socket.on("answer", (id, message) => {
    socket.to(id).emit("answer", socket.id, message);
  });

  socket.on("answerScreenshare", (id, message) => {
    socket.to(id).emit("answerScreenshare", socket.id, message);
  });

  /**
   * Event handler for sending ICE candidate information
   * @param {string} id - The ID of the recipient socket
   * @param {any} message - The ICE candidate message
   */
  socket.on("candidate", (id, message) => {
    socket.to(id).emit("candidate", socket.id, message);
  });

  socket.on("candidateScreenshare", (id, message) => {
    socket.to(id).emit("candidateScreenshare", socket.id, message);
  });

  // ===== P2P FILE SHARING =====
  
  const fileRegistry = require('./store/fileRegistry');
  
  /**
   * Announce a file (user has chunks available for seeding)
   */
  socket.on("announceFile", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[P2P FILE] ERROR: Not authenticated');
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = data;

      console.log(`[P2P FILE] Device ${userId}:${deviceId} announcing file: ${fileId.substring(0, 16)}... (${mimeType}, ${fileSize} bytes)`);
      if (sharedWith) {
        console.log(`[P2P FILE] Shared with: ${sharedWith.join(', ')}`);
      }

      // Register file with userId:deviceId format + sharedWith
      const fileInfo = fileRegistry.announceFile(userId, deviceId, {
        fileId,
        mimeType,
        fileSize,
        checksum,
        chunkCount,
        availableChunks,
        sharedWith
      });

      // ========================================
      // SECURITY: Check if announce was denied
      // ========================================
      if (!fileInfo) {
        console.error(`[SECURITY] ❌ Announce REJECTED for user ${userId} - file ${fileId.substring(0, 16)}`);
        return callback?.({ 
          success: false, 
          error: "Permission denied: You don't have access to this file" 
        });
      }

      // Calculate chunk quality
      const chunkQuality = fileRegistry.getChunkQuality(fileId);

      callback?.({ success: true, fileInfo, chunkQuality });

      // LÖSUNG 12: Notify only authorized users (no broadcast!)
      const sharedUsers = fileRegistry.getSharedUsers(fileId);
      console.log(`[P2P FILE] Notifying ${sharedUsers.length} authorized users about file announcement (quality: ${chunkQuality}%)`);
      
      // Find sockets of authorized users
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => 
          s.handshake.session?.uuid && 
          sharedUsers.includes(s.handshake.session.uuid) &&
          s.id !== socket.id // Don't notify the announcer
        );
      
      // Send targeted notification to each authorized user
      targetSockets.forEach(targetSocket => {
        targetSocket.emit("fileAnnounced", {
          fileId,
          userId,
          deviceId,
          mimeType,
          fileSize,
          seederCount: fileInfo.seederCount,
          chunkQuality
        });
      });

    } catch (error) {
      console.error('[P2P FILE] Error announcing file:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unannounce a file (user no longer seeding)
   */
  socket.on("unannounceFile", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { fileId } = data;

      console.log(`[P2P FILE] Device ${userId}:${deviceId} unannouncing file: ${fileId}`);

      const success = fileRegistry.unannounceFile(userId, deviceId, fileId);
      callback?.({ success });

      // LÖSUNG 12: Notify only authorized users about seeder count change
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (fileInfo) {
        const sharedUsers = fileRegistry.getSharedUsers(fileId);
        
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => 
            s.handshake.session?.uuid && 
            sharedUsers.includes(s.handshake.session.uuid) &&
            s.id !== socket.id
          );
        
        targetSockets.forEach(targetSocket => {
          targetSocket.emit("fileSeederUpdate", {
            fileId,
            seederCount: fileInfo.seederCount
          });
        });
      }

    } catch (error) {
      console.error('[P2P FILE] Error unannouncing file:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Update available chunks for a file
   */
  socket.on("updateAvailableChunks", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { fileId, availableChunks } = data;

      console.log(`[P2P FILE] Device ${userId}:${deviceId} updating chunks for ${fileId.substring(0, 8)}: ${availableChunks.length} chunks`);

      const success = fileRegistry.updateAvailableChunks(userId, deviceId, fileId, availableChunks);
      
      if (!success) {
        return callback?.({ success: false, error: "File not found" });
      }

      callback?.({ success: true });

      // Notify authorized users about chunk update
      const sharedUsers = fileRegistry.getSharedUsers(fileId);
      const fileInfo = fileRegistry.getFileInfo(fileId);
      const chunkQuality = fileRegistry.getChunkQuality(fileId);
      
      if (fileInfo) {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => 
            s.handshake.session?.uuid && 
            sharedUsers.includes(s.handshake.session.uuid) &&
            s.id !== socket.id
          );
        
        targetSockets.forEach(targetSocket => {
          targetSocket.emit("fileSeederUpdate", {
            fileId,
            seederCount: fileInfo.seederCount,
            chunkQuality
          });
        });
        
        console.log(`[P2P FILE] Notified ${targetSockets.length} users about chunk update (quality: ${chunkQuality}%)`);
      }

    } catch (error) {
      console.error('[P2P FILE] Error updating chunks:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Request file information and seeders (LÖSUNG 14: Permission Check)
   */
  socket.on("getFileInfo", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId } = data;
      
      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        console.log(`[P2P FILE] User ${userId} denied access to file ${fileId}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      const fileInfo = fileRegistry.getFileInfo(fileId);

      if (!fileInfo) {
        return callback?.({ success: false, error: "File not found" });
      }

      // Add quality info
      fileInfo.chunkQuality = fileRegistry.getChunkQuality(fileId);
      fileInfo.missingChunks = fileRegistry.getMissingChunks(fileId);

      callback?.({ success: true, fileInfo });

    } catch (error) {
      console.error('[P2P FILE] Error getting file info:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Register as downloading a file (leecher) (LÖSUNG 14: Permission Check)
   */
  socket.on("registerLeecher", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { fileId } = data;

      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        console.log(`[P2P FILE] User ${userId} denied download access to file ${fileId}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      console.log(`[P2P FILE] Device ${userId}:${deviceId} downloading file: ${fileId}`);

      const success = fileRegistry.registerLeecher(userId, deviceId, fileId);
      callback?.({ success });

    } catch (error) {
      console.error('[P2P FILE] Error registering leecher:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unregister as downloading a file
   */
  socket.on("unregisterLeecher", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { fileId } = data;

      const success = fileRegistry.unregisterLeecher(userId, deviceId, fileId);
      callback?.({ success });

    } catch (error) {
      console.error('[P2P FILE] Error unregistering leecher:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Search for files by name or checksum
   */
  socket.on("searchFiles", async (data, callback) => {
    try {
      const { query } = data;
      const results = fileRegistry.searchFiles(query);

      callback?.({ success: true, results });

    } catch (error) {
      console.error('[P2P FILE] Error searching files:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get all active files (with seeders)
   */
  socket.on("getActiveFiles", async (callback) => {
    try {
      const files = fileRegistry.getActiveFiles();
      callback?.({ success: true, files });

    } catch (error) {
      console.error('[P2P FILE] Error getting active files:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get available chunks from seeders (LÖSUNG 14: Permission Check)
   */
  socket.on("getAvailableChunks", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId } = data;
      
      // Check permission
      if (!fileRegistry.canAccess(userId, fileId)) {
        console.log(`[P2P FILE] User ${userId} denied access to chunks for file ${fileId}`);
        return callback?.({ success: false, error: "Access denied" });
      }

      const chunks = fileRegistry.getAvailableChunks(fileId);

      callback?.({ success: true, chunks });

    } catch (error) {
      console.error('[P2P FILE] Error getting available chunks:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  // ===== P2P FILE SHARING - WebRTC SIGNALING RELAY =====
  
  /**
   * Share a file with another user (LÖSUNG 13 API - DEPRECATED)
   * @deprecated Use updateFileShare instead
   */
  socket.on("shareFile", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId, targetUserId } = data;

      if (!fileId || !targetUserId) {
        return callback?.({ success: false, error: "Missing fileId or targetUserId" });
      }

      console.log(`[P2P FILE] User ${userId} sharing file ${fileId} with ${targetUserId}`);

      const success = fileRegistry.shareFile(fileId, userId, targetUserId);
      fileRegistry.shareFile(fileId, userId, userId); // Ensure sharer retains access
      
      if (!success) {
        return callback?.({ success: false, error: "Failed to share file (not creator or file not found)" });
      }

      callback?.({ success: true });

      // Notify target user about new file
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (fileInfo) {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session?.uuid === targetUserId);
        
        targetSockets.forEach(targetSocket => {
          targetSocket.emit("fileSharedWithYou", {
            fileId,
            fromUserId: userId,
            fileInfo
          });
        });
      }

    } catch (error) {
      console.error('[P2P FILE] Error sharing file:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Update file share (add or revoke users) - NEW SECURE VERSION
   * 
   * Permission Model:
   * - Creator can add/revoke anyone
   * - Any seeder can add users (but not revoke)
   * - Must have valid access to the file
   * 
   * Rate Limited: Max 10 operations per minute per user
   * Size Limited: Max 1000 users in sharedWith
   */
  socket.on("updateFileShare", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId, action, userIds } = data;

      // Validation
      if (!fileId || !action || !Array.isArray(userIds) || userIds.length === 0) {
        return callback?.({ success: false, error: "Invalid parameters" });
      }

      if (!['add', 'revoke'].includes(action)) {
        return callback?.({ success: false, error: "Invalid action (must be 'add' or 'revoke')" });
      }

      // Rate limiting (10 operations per minute)
      if (!socket._shareRateLimit) {
        socket._shareRateLimit = { count: 0, resetTime: Date.now() + 60000 };
      }

      const now = Date.now();
      if (now > socket._shareRateLimit.resetTime) {
        socket._shareRateLimit = { count: 0, resetTime: now + 60000 };
      }

      if (socket._shareRateLimit.count >= 10) {
        console.log(`[P2P FILE] Rate limit exceeded for user ${userId}`);
        return callback?.({ success: false, error: "Rate limit: max 10 share operations per minute" });
      }

      socket._shareRateLimit.count++;

      // Get file info
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (!fileInfo) {
        return callback?.({ success: false, error: "File not found" });
      }

      // Permission check
      const isCreator = fileInfo.creator === userId;
      const hasAccess = fileRegistry.canAccess(userId, fileId);
      const isSeeder = fileInfo.seeders.some(s => s.startsWith(`${userId}:`));

      if (!isCreator && !hasAccess && !isSeeder) {
        console.log(`[P2P FILE] User ${userId} has no permission to modify shares for ${fileId}`);
        return callback?.({ success: false, error: "Permission denied" });
      }

      // Action-specific permission checks
      if (action === 'revoke') {
        // Creator can revoke anyone
        if (isCreator) {
          // OK - Creator has full revoke rights
        }
        // Self-revoke: User can remove themselves
        else if (userIds.length === 1 && userIds[0] === userId) {
          console.log(`[P2P FILE] ✓ Self-revoke: User ${userId} removing self from ${fileId.substring(0, 8)}`);
          // OK - Self-revoke allowed
        }
        // Non-creator cannot revoke others
        else {
          console.log(`[P2P FILE] ❌ User ${userId} cannot revoke others from ${fileId.substring(0, 8)} (not creator)`);
          return callback?.({ 
            success: false, 
            error: "Only creator can revoke others. You can only remove yourself." 
          });
        }
      }

      // Size limit check (max 1000 users)
      if (action === 'add') {
        const currentSize = fileInfo.sharedWith.length;
        const newSize = currentSize + userIds.length;
        
        if (newSize > 1000) {
          console.log(`[P2P FILE] Share limit exceeded for ${fileId}: ${newSize} > 1000`);
          return callback?.({ success: false, error: "Maximum 1000 users per file" });
        }
      }

      console.log(`[P2P FILE] User ${userId} ${action}ing ${userIds.length} users for file ${fileId.substring(0, 8)}`);

      // Execute action
      let successCount = 0;
      let failCount = 0;

      for (const targetUserId of userIds) {
        let success = false;
        
        if (action === 'add') {
          success = fileRegistry.shareFile(fileId, userId, targetUserId);
        } else if (action === 'revoke') {
          success = fileRegistry.unshareFile(fileId, userId, targetUserId);
        }

        if (success) {
          successCount++;
        } else {
          failCount++;
        }
      }

      console.log(`[P2P FILE] Share update complete: ${successCount} succeeded, ${failCount} failed`);

      callback?.({ 
        success: true, 
        successCount, 
        failCount,
        totalUsers: fileRegistry.getSharedUsers(fileId).length
      });

      // Notify affected users
      const updatedFileInfo = fileRegistry.getFileInfo(fileId);
      const affectedUserIds = action === 'add' ? userIds : userIds.filter(id => id !== userId);

      affectedUserIds.forEach(targetUserId => {
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session?.uuid === targetUserId);
        
        targetSockets.forEach(targetSocket => {
          if (action === 'add') {
            targetSocket.emit("fileSharedWithYou", {
              fileId,
              fromUserId: userId,
              fileInfo: updatedFileInfo
            });
          } else {
            targetSocket.emit("fileAccessRevoked", {
              fileId,
              byUserId: userId
            });
          }
        });
      });

    } catch (error) {
      console.error('[P2P FILE] Error updating file share:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Unshare a file from a user (LÖSUNG 13 API)
   */
  socket.on("unshareFile", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId, targetUserId } = data;

      if (!fileId || !targetUserId) {
        return callback?.({ success: false, error: "Missing fileId or targetUserId" });
      }

      console.log(`[P2P FILE] User ${userId} unsharing file ${fileId} from ${targetUserId}`);

      const success = fileRegistry.unshareFile(fileId, userId, targetUserId);
      
      if (!success) {
        return callback?.({ success: false, error: "Failed to unshare file (not creator or cannot unshare from creator)" });
      }

      callback?.({ success: true });

      // Notify target user about revoked access
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session?.uuid === targetUserId);
      
      targetSockets.forEach(targetSocket => {
        targetSocket.emit("fileUnsharedFromYou", {
          fileId,
          fromUserId: userId
        });
      });

    } catch (error) {
      console.error('[P2P FILE] Error unsharing file:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Get list of users a file is shared with (LÖSUNG 13 API)
   */
  socket.on("getSharedUsers", async (data, callback) => {
    try {
      if (!socket.handshake.session.uuid) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const { fileId } = data;

      // Only creator can see who file is shared with
      const fileInfo = fileRegistry.getFileInfo(fileId);
      if (!fileInfo || fileInfo.creator !== userId) {
        return callback?.({ success: false, error: "Access denied (not creator)" });
      }

      const sharedUsers = fileRegistry.getSharedUsers(fileId);
      callback?.({ success: true, sharedUsers });

    } catch (error) {
      console.error('[P2P FILE] Error getting shared users:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  // ===== P2P FILE SHARING - WebRTC SIGNALING RELAY =====
  
  /**
   * Relay WebRTC offer from initiator to target peer
   */
  socket.on("file:webrtc-offer", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, offer } = data;
      
      console.log(`[P2P WEBRTC] Relaying offer for file ${fileId} to ${targetUserId}:${targetDeviceId || 'broadcast'}`);
      
      // Route to specific device if deviceId provided (and not empty string)
      if (targetDeviceId && targetDeviceId !== '') {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          io.to(targetSocketId).emit("file:webrtc-offer", {
            fromUserId,
            fromDeviceId,
            fileId,
            offer
          });
          console.log(`[P2P WEBRTC] ✓ Offer relayed to specific device ${targetUserId}:${targetDeviceId}`);
        } else {
          console.warn(`[P2P WEBRTC] ✗ Target device ${targetUserId}:${targetDeviceId} not found online`);
        }
      } else {
        // Broadcast to all devices of the user
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          targetSockets.forEach(targetSocket => {
            targetSocket.emit("file:webrtc-offer", {
              fromUserId,
              fromDeviceId,
              fileId,
              offer
            });
          });
          console.log(`[P2P WEBRTC] ✓ Offer broadcast to ${targetSockets.length} device(s) of user ${targetUserId}`);
        } else {
          console.warn(`[P2P WEBRTC] ✗ Target user ${targetUserId} has no devices online`);
        }
      }
    } catch (error) {
      console.error('[P2P WEBRTC] Error relaying offer:', error);
    }
  });

  /**
   * Relay WebRTC answer from responder to initiator
   */
  socket.on("file:webrtc-answer", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, answer } = data;
      
      console.log(`[P2P WEBRTC] Relaying answer for file ${fileId} to ${targetUserId}:${targetDeviceId}`);
      
      // Route to specific device if deviceId provided
      if (targetDeviceId) {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          io.to(targetSocketId).emit("file:webrtc-answer", {
            fromUserId,
            fromDeviceId,
            fileId,
            answer
          });
          console.log(`[P2P WEBRTC] Answer relayed to ${targetUserId}:${targetDeviceId}`);
        } else {
          console.warn(`[P2P WEBRTC] Target device ${targetUserId}:${targetDeviceId} not found online`);
        }
      } else {
        // Broadcast to all devices (fallback)
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          targetSockets.forEach(targetSocket => {
            targetSocket.emit("file:webrtc-answer", {
              fromUserId,
              fromDeviceId,
              fileId,
              answer
            });
          });
          console.log(`[P2P WEBRTC] Answer broadcast to ${targetSockets.length} devices`);
        } else {
          console.warn(`[P2P WEBRTC] Target user ${targetUserId} not found online`);
        }
      }
    } catch (error) {
      console.error('[P2P WEBRTC] Error relaying answer:', error);
    }
  });

  /**
   * Relay ICE candidate between peers
   */
  socket.on("file:webrtc-ice", (data) => {
    try {
      const { targetUserId, targetDeviceId, fileId, candidate } = data;
      
      console.log(`[P2P WEBRTC] Relaying ICE candidate for file ${fileId} to ${targetUserId}:${targetDeviceId}`);
      
      // Route to specific device if deviceId provided
      if (targetDeviceId) {
        const targetSocketId = deviceSockets.get(`${targetUserId}:${targetDeviceId}`);
        if (targetSocketId) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          io.to(targetSocketId).emit("file:webrtc-ice", {
            fromUserId,
            fromDeviceId,
            fileId,
            candidate
          });
        } else {
          console.warn(`[P2P WEBRTC] Target device ${targetUserId}:${targetDeviceId} not found online`);
        }
      } else {
        // Broadcast to all devices (fallback)
        const targetSockets = Array.from(io.sockets.sockets.values())
          .filter(s => s.handshake.session.uuid === targetUserId);
        
        if (targetSockets.length > 0) {
          const fromUserId = socket.handshake.session.uuid;
          const fromDeviceId = socket.handshake.session.deviceId;
          targetSockets.forEach(targetSocket => {
            targetSocket.emit("file:webrtc-ice", {
              fromUserId,
              fromDeviceId,
              fileId,
              candidate
            });
          });
        } else {
          console.warn(`[P2P WEBRTC] Target user ${targetUserId} not found online`);
        }
      }
    } catch (error) {
      console.error('[P2P WEBRTC] Error relaying ICE candidate:', error);
    }
  });

  /**
   * Relay encryption key request from downloader to seeder
   */
  socket.on("file:key-request", (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[P2P KEY] Key request blocked - not authenticated');
        return;
      }

      const { targetUserId, fileId } = data;
      const requesterId = socket.handshake.session.uuid;
      
      console.log(`[P2P KEY] User ${requesterId} requesting key for file ${fileId} from ${targetUserId}`);
      
      // Find seeder's socket and relay the key request
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          targetSocket.emit("file:key-request", {
            fromUserId: requesterId,
            fileId: fileId
          });
        });
        console.log(`[P2P KEY] Key request relayed to ${targetUserId}`);
      } else {
        console.warn(`[P2P KEY] Seeder ${targetUserId} not found online`);
        // Send error back to requester
        socket.emit("file:key-response", {
          fromUserId: targetUserId,
          fileId: fileId,
          error: "Seeder not online"
        });
      }
    } catch (error) {
      console.error('[P2P KEY] Error relaying key request:', error);
    }
  });

  /**
   * Relay encryption key response from seeder to downloader
   */
  socket.on("file:key-response", (data) => {
    try {
      if (!socket.handshake.session.uuid) {
        console.error('[P2P KEY] Key response blocked - not authenticated');
        return;
      }

      const { targetUserId, fileId, key, error } = data;
      const seederId = socket.handshake.session.uuid;
      
      console.log(`[P2P KEY] User ${seederId} sending key for file ${fileId} to ${targetUserId}`);
      
      // Find requester's socket and relay the key response
      const targetSockets = Array.from(io.sockets.sockets.values())
        .filter(s => s.handshake.session.uuid === targetUserId);
      
      if (targetSockets.length > 0) {
        targetSockets.forEach(targetSocket => {
          targetSocket.emit("file:key-response", {
            fromUserId: seederId,
            fileId: fileId,
            key: key,
            error: error
          });
        });
        console.log(`[P2P KEY] Key response relayed to ${targetUserId}`);
      } else {
        console.warn(`[P2P KEY] Requester ${targetUserId} not found online`);
      }
    } catch (error) {
      console.error('[P2P KEY] Error relaying key response:', error);
    }
  });

  /**
   * Event handler to delete a specific item (1:1 message) for the current user/device as receiver
   * @param {Object} data - Contains itemId to delete
   */
  socket.on("deleteItem", async (data, callback) => {
    try {
      if (
        !socket.handshake.session.uuid ||
        !socket.handshake.session.deviceId ||
        socket.handshake.session.authenticated !== true
      ) {
        return callback?.({ success: false, error: "Not authenticated" });
      }

      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      const { itemId } = data;

      if (!itemId) {
        return callback?.({ success: false, error: "Missing itemId" });
      }

      // Delete item where receiver and deviceReceiver match current session
      const deletedCount = await writeQueue.enqueue(async () => {
        return await Item.destroy({
          where: {
            itemId: itemId,
            receiver: userId,
            deviceReceiver: deviceId
          }
        });
      }, `deleteItem-${itemId}-${userId}-${deviceId}`);

      callback?.({ success: true, deletedCount });
    } catch (error) {
      console.error('[SIGNAL SERVER] Error deleting item:', error);
      callback?.({ success: false, error: error.message });
    }
  });

  /**
   * Event handler for disconnecting from a room
   */
  // ===== NEW GROUP ITEM API (Simplified Architecture) =====
  
  /**
   * Send a group item (message, reaction, file, etc.)
   * Uses GroupItem model - stores encrypted data ONCE for all members
   */
  socket.on("sendGroupItem", async (data) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[GROUP ITEM] ERROR: Not authenticated');
        socket.emit("groupItemError", { error: "Not authenticated" });
        return;
      }

      const { channelId, itemId, type, payload, cipherType, timestamp } = data;
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;

      // Validate required fields
      if (!channelId || !itemId || !payload) {
        console.error('[GROUP ITEM] ERROR: Missing required fields');
        socket.emit("groupItemError", { error: "Missing required fields" });
        return;
      }

      // Check if user is member of channel
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: channelId
        }
      });

      if (!membership) {
        console.error('[GROUP ITEM] ERROR: User not member of channel');
        socket.emit("groupItemError", { error: "Not a member of this channel" });
        return;
      }

      // Check for duplicate itemId
      const existing = await GroupItem.findOne({
        where: { itemId: itemId }
      });

      if (existing) {
        console.log(`[GROUP ITEM] Item ${itemId} already exists, skipping`);
        socket.emit("groupItemDelivered", { itemId: itemId, existing: true });
        return;
      }

      // Create group item (stored ONCE for all members)
      const groupItem = await writeQueue.enqueue(async () => {
        return await GroupItem.create({
          itemId: itemId,
          channel: channelId,
          sender: userId,
          senderDevice: deviceId,
          type: type || 'message',
          payload: payload,
          cipherType: cipherType || 4,
          timestamp: timestamp || new Date()
        });
      }, `createGroupItem-${itemId}`);

      console.log(`[GROUP ITEM] ✓ Created group item ${itemId} in channel ${channelId}`);

      // Get all channel members
      const members = await ChannelMembers.findAll({
        where: { channelId: channelId },
        include: [{
          model: User,
          attributes: ['uuid']
        }]
      });

      // Get all client devices for these members
      const memberUserIds = members.map(m => m.userId);
      const memberClients = await Client.findAll({
        where: {
          owner: { [require('sequelize').Op.in]: memberUserIds }
        }
      });

      // Broadcast to all member devices
      let deliveredCount = 0;
      for (const client of memberClients) {
        const targetSocketId = deviceSockets.get(`${client.owner}:${client.device_id}`);
        if (targetSocketId) {
          io.to(targetSocketId).emit("groupItem", {
            itemId: itemId,
            channel: channelId,
            sender: userId,
            senderDevice: deviceId,
            type: type || 'message',
            payload: payload,
            cipherType: cipherType || 4,
            timestamp: timestamp || new Date().toISOString()
          });
          deliveredCount++;
        }
      }

      console.log(`[GROUP ITEM] ✓ Broadcast to ${deliveredCount} devices`);

      // Confirm delivery to sender
      socket.emit("groupItemDelivered", {
        itemId: itemId,
        deliveredCount: deliveredCount,
        totalDevices: memberClients.length
      });

    } catch (error) {
      console.error('[GROUP ITEM] Error in sendGroupItem:', error);
      socket.emit("groupItemError", { error: "Internal server error" });
    }
  });

  /**
   * Mark a group item as read
   */
  socket.on("markGroupItemRead", async (data) => {
    try {
      if (!socket.handshake.session.uuid || !socket.handshake.session.deviceId || socket.handshake.session.authenticated !== true) {
        console.error('[GROUP ITEM READ] ERROR: Not authenticated');
        return;
      }

      const { itemId } = data;
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;

      if (!itemId) {
        console.error('[GROUP ITEM READ] ERROR: Missing itemId');
        return;
      }

      // Find the group item
      const groupItem = await GroupItem.findOne({
        where: { itemId: itemId }
      });

      if (!groupItem) {
        console.error('[GROUP ITEM READ] ERROR: Item not found');
        return;
      }

      // Check if user is member of channel
      const membership = await ChannelMembers.findOne({
        where: {
          userId: userId,
          channelId: groupItem.channel
        }
      });

      if (!membership) {
        console.error('[GROUP ITEM READ] ERROR: User not member of channel');
        return;
      }

      // Create or update read receipt
      await writeQueue.enqueue(async () => {
        const [receipt, created] = await GroupItemRead.findOrCreate({
          where: {
            itemId: groupItem.uuid,
            userId: userId,
            deviceId: deviceId
          },
          defaults: {
            readAt: new Date()
          }
        });
        return { receipt, created };
      }, `markGroupItemRead-${itemId}-${userId}-${deviceId}`);

      // Count total reads
      const readCount = await GroupItemRead.count({
        where: { itemId: groupItem.uuid }
      });

      // Count total members
      const memberCount = await ChannelMembers.count({
        where: { channelId: groupItem.channel }
      });

      const allRead = readCount >= memberCount;

      console.log(`[GROUP ITEM READ] ✓ Item ${itemId}: ${readCount}/${memberCount} members read`);

      // Notify the sender about read status
      const senderSocketId = deviceSockets.get(`${groupItem.sender}:${groupItem.senderDevice}`);
      if (senderSocketId) {
        io.to(senderSocketId).emit("groupItemReadUpdate", {
          itemId: itemId,
          readBy: userId,
          readByDevice: deviceId,
          readCount: readCount,
          totalMembers: memberCount,
          allRead: allRead
        });
      }

      // If all members have read, delete from server (privacy feature)
      if (allRead) {
        console.log(`[GROUP ITEM READ] ✓ Item ${itemId} read by all members - deleting from server`);
        
        // Delete all read receipts first
        await writeQueue.enqueue(async () => {
          await GroupItemRead.destroy({
            where: { itemId: groupItem.uuid }
          });
        }, `deleteGroupItemReads-${itemId}`);
        
        // Then delete the group item itself
        await writeQueue.enqueue(async () => {
          await groupItem.destroy();
        }, `deleteGroupItem-${itemId}`);
        
        console.log(`[GROUP ITEM READ] ✓ Item ${itemId} and all read receipts deleted`);
      }

    } catch (error) {
      console.error('[GROUP ITEM READ] Error in markGroupItemRead:', error);
    }
  });

  socket.on("disconnect", () => {
    if(socket.handshake.session.uuid && socket.handshake.session.deviceId) {
      const userId = socket.handshake.session.uuid;
      const deviceId = socket.handshake.session.deviceId;
      deviceSockets.delete(`${userId}:${deviceId}`);
      
      // Clean up P2P file sharing announcements (with deviceId)
      const fileRegistry = require('./store/fileRegistry');
      fileRegistry.handleUserDisconnect(userId, deviceId);
    }
    if (!rooms) return;


    Object.keys(rooms).forEach((room) => {
        const roomSeeders = rooms[room].seeders;
        const roomFiles = rooms[room].share && rooms[room].share.files;
        const roomParticipants = rooms[room].participants;

        if (roomParticipants && roomParticipants[socket.id]) {
          delete roomParticipants[socket.id];
          socket.to(room).emit("message", socket.id, "leave", "");
          const hourFuture = new Date(Date.now() + 60 * 60 * 1000).getTime();
          const meetingTime = new Date(rooms[room].meetingSettings.meetingDate).getTime();
          if (Object.keys(roomParticipants).length === 0 && hourFuture < meetingTime) {
            delete rooms[room];
          }
        }

        if (!roomSeeders) return;

        if (roomSeeders[socket.id]) {
            delete roomSeeders[socket.id];
            socket.to(rooms[room].host).emit("currentPeers", Object.keys(roomSeeders).length - 1);
        }

        if (!roomFiles) return;

        Object.keys(roomFiles).forEach((file) => {
            const fileSeeders = roomFiles[file].seeders;
            const socketIndex = fileSeeders.indexOf(socket.id);

            if (socketIndex !== -1) {
                fileSeeders.splice(socketIndex, 1);
                socket.to(rooms[room].host).emit("currentFilePeers", file, Object.keys(fileSeeders).length);
            }

            if (fileSeeders.length === 0) {
                delete roomFiles[file];
            }
        });

        socket.to(room).emit("getFiles", roomFiles);
    });
  });

  /**
   * Event handler for setting the number of download slots for a seeder
   * @param {string} room - The ID of the room
   * @param {number} slots - The number of download slots
   */
  socket.on("setSlots", (room, slots) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0, slots: 0 });

    seeder.slots = Number(slots);
  });

  /**
   * Event handler for setting the number of connected peers for a seeder
   * @param {string} room - The ID of the room
   * @param {number} peers - The number of connected peers
   */
  socket.on("setPeers", (room, peers) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = { peers: 0 });

    seeder.peers += peers;
    if (seeder.peers < 0) seeder.peers = 0;

    if (seeder.level !== undefined && seeder.score !== undefined) {
        let scoreStep = 1 / seeder.slots;
        seeder.score = (100.0 - (seeder.level * 10)) - (scoreStep * seeder.peers);
    }
  });

  /**
   * Event handler for starting or stopping streaming in a room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socket
   */
  socket.on("stream", (room, host) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    const seeder = rooms[room].seeders[socket.id] || (rooms[room].seeders[socket.id] = {});

    if (rooms[room].host === socket.id) {
        rooms[room].stream = true;
        seeder.level = 0;
        seeder.score = 100.0;
    }

    if (host) {
        seeder.level = ((rooms[room].seeders[host] && rooms[room].seeders[host].level) || 0) + 1;
        seeder.score = 100.0 - (seeder.level * 10);
        seeder.peers = 0;
        seeder.slots = 0;
    }
  });

  /**
 * Event handler for offering a file for download in a room
 * @param {string} room - The ID of the room
 * @param {Object} file - The file object containing name and size
 */
  socket.on("offerFile", (room, file) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    const roomFiles = rooms[room].share.files || {};

    if (rooms[room].host === socket.id) {
        roomFiles[file.name] = { size: file.size, seeders: [socket.id] };
    } else if (roomFiles[file.name] &&
        roomFiles[file.name].size === file.size &&
        !roomFiles[file.name].seeders.includes(socket.id)) {
        roomFiles[file.name].seeders.push(socket.id);
    }

    rooms[room].share.files = roomFiles;
    socket.to(room).emit("getFiles", roomFiles);
    socket.to(rooms[room].host).emit("currentFilePeers", file.name, Object.keys(rooms[room].share.files[file.name].seeders).length);
  });

  /**
   * Event handler for getting the shared files in a room
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the shared files
   */
  socket.on("getFiles", (room, callback) => {
    if (!rooms[room] || !rooms[room].share.files) return;

    socket.join(room);
    socket.to(socket.id).emit("getFiles", rooms[room].share.files);

    if (typeof callback === "function") {
        callback(rooms[room].share.files);
    }
  });

  /**
   * Event handler for deleting a file from a room
   * @param {string} filename - The name of the file to delete
   */
  socket.on("deleteFile", (filename) => {
    Object.entries(rooms).forEach(([id, room]) => {
        if (room.host !== socket.id) return;
        if (!room.share.files || !room.share.files[filename]) return;

        delete room.share.files[filename];
        socket.to(id).emit("getFiles", room.share.files);
    });
  });

  /**
   * Event handler for downloading a file from a room
   * @param {string} room - The ID of the room
   * @param {Object} file - The file object to download
   * @param {string} host - The ID of the host socket
   */
  socket.on("downloadFile", (room, file, host) => {
    if (!isValidUUID(room) || !rooms[room]) return;

    socket.to(host).emit("downloadFile", socket.id, file);
  });

  /**
   * Event handler for creating a meeting room
   * @param {string} room - The ID of the room
   * @param {string} host - The ID of the host socketst socket
   * @param {Object} settings - The meeting settings
   */
  socket.on("createMeeting", (room, host, settings) => {
    if (!isValidUUID(room) || !rooms[room]) return;
    rooms[room].meeting = true;
    rooms[room].meetingSettings = settings;
  });

  socket.on("message", (room, type, message) => {
    // Sanitize the message to prevent XSS
    const sanMessage = sanitizeHtml(message, {
      allowedTags: [], // Remove all HTML tags
      allowedAttributes: {} // Remove all attributes
    });
    const sanType = sanitizeHtml(type, {
      allowedTags: [], // Remove all HTML tags
      allowedAttributes: {} // Remove all attributes
    });
    socket.to(room).emit("message", socket.id, sanType, sanMessage);
  });

  /*socket.on("meeting", (room, callback) => {
    if (!rooms[room] && rooms[room].meeting) return;
    const roomData = rooms[room];
    if (!rooms[room] && rooms[room].meeting) {
        callbackHandler(callback, {message: "Room not found", room});
        return;
    }
    socket.join(room);
    const participants = Object.entries(rooms[room].participants);

    for (const [participant, value] of participants) {
        if (participant !== socket.id) continue;

        socket.to(participant).emit("meeting", socket.id);
        callbackHandler(callback, {message: "Client connected", room, participant: participant});
        return;
    }
  });*/
  /**
   * Event handler for getting meeting settings
   * @param {string} room - The ID of the room
   * @param {Callback} callback - Callback function to be invoked with the meeting settings
   */
  socket.on("getMeetingSettings", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const settings = rooms[room].meetingSettings;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, settings });
  });

  socket.on("getParticipants", (room, callback) => {
    if (!rooms[room] || !rooms[room].meeting) {
      callbackHandler(callback, { message: "Meeting not found", room });
      return;
    }
    const participants = rooms[room].participants;
    callbackHandler(callback, { message: "Meeting settings retrieved", room, participants });
  });
  /**
   * Event handler for joining a meeting
   * @param {string} room - The ID of the meeting room
   * @param {string} name - The name of the participant
   */
  socket.on("joinMeeting", (room, name, callback) => {
    if (!rooms[room] || !rooms[room].meeting) return;
    socket.join(room);
    if (!rooms[room].participants) rooms[room].participants = {};
    rooms[room].participants[socket.id] = {name: name, id: socket.id};
    socket.to(room).emit("participantJoined", rooms[room].participants[socket.id]);
    socket.to(room).emit("message", socket.id, "join", "");
    callbackHandler(callback, { message: "meeting joined", participants: rooms[room].participants, id: socket.id });
  });
});
  // SOCKET.IO END

  app.use(cors({
  origin: function(origin, callback) {
      // Allow any localhost port and specifically http://localhost:57044/
      console.log("CORS Origin:", origin);
      if (
        origin === undefined ||
        origin === "http://localhost:3000" ||
        origin === 'http://localhost:55831' ||
        origin === "https://kaylie-physiopathological-kirstie.ngrok-free.dev"
      ) {
        callback(null, origin);
      } else {
        callback(new Error('Not allowed by CORS'));
      }
    },
    credentials: true
  }));

  // Register and signin webpages
  app.use(authRoutes);

// Database error handler middleware (must be after routes)
const dbErrorHandler = require('./middleware/dbErrorHandler');
app.use(dbErrorHandler);

/**
 * Room data object to store information about each room
 * @typedef {Object} RoomData
 * @property {string} host - The ID of the host socket
 * @property {Object} seeders - Object containing information about seeders in the room
 * @property {boolean} stream - Indicates if the room is currently streaming
 * @property {Object} share - Object containing shared files in the room
 */

/**
 * Object to store information about each seeder in a room
 * @typedef {Object} SeederData
 * @property {number} slots - Number of available download slots for the seeder
 * @property {number} peers - Number of connected peers to the seeder
 * @property {number} level - Level of the seeder in the streaming hierarchy
 * @property {number} score - Score of the seeder based on level and number of peers
 */

/**
 * Callback function type
 * @callback Callback
 * @param {any} data - The data to be passed to the callback function
 */



/**
 * Handles the callback function by invoking it with the provided data.
 *
 * @param {Callback} callback - The callback function to be invoked.
 * @param {any} data - The data to be passed to the callback function.
 */
function callbackHandler(callback, data) {
  if (typeof callback === "function") {
    callback(data);
  }
}

//app.use(express.static(__dirname + "/public"));

//app.set("view engine", "pug");



// Serve static files from Flutter web build output
app.use(express.static(path.resolve(__dirname, 'web')));

// For SPA fallback
app.get('*', (req, res) => {
  res.sendFile(path.resolve(__dirname, 'web', 'index.html'));
});

// Initialize cleanup cronjob
initCleanupJob();

server.listen(port, () => console.log(`Server is running on port ${port}`));