# Signal Refactoring - Testing Checklist

## ✅ Completed Refactoring

### Phase 1: Service Refactoring
- [x] Split MessagingService into 5 mixins (one_to_one, group, file, receiving, caching)
- [x] Split MeetingService into 2 mixins (key_handler, guest_session)
- [x] Deleted 9 obsolete service files
- [x] Fixed store initialization pattern (managers return themselves, not properties)
- [x] Updated all method signatures to use named parameters
- [x] Fixed EventBus integration (enum-based events)

### Phase 2: Listener Integration
- [x] Updated listeners to use MessagingService instead of deleted files
- [x] Added conditional imports for cross-platform support
- [x] Integrated ListenerRegistry with SignalClient
- [x] Added clientReady emit after listener registration
- [x] Fixed all compilation errors

### Phase 3: Architecture Validation
- [x] No compilation errors in signal/ folder
- [x] Deprecation stub in place for SignalService
- [x] SignalClient properly managed by ServerSettingsService
- [x] Multi-server architecture preserved

## 🧪 Testing Checklist

### Pre-Testing Setup
- [ ] Backup current database and storage
- [ ] Clear app data/cache for clean start
- [ ] Verify server is running and accessible
- [ ] Note: Deprecated SignalService warnings are expected (not errors)

### 1. Authentication & Initialization
#### First Launch
- [ ] App starts without crashes
- [ ] Can navigate to server selection/login
- [ ] WebAuthn login completes successfully
- [ ] Device identity is restored/created
- [ ] Signal client initializes without errors

#### Expected Log Sequence
```
[SIGNAL_CLIENT] ======================================== 
[SIGNAL_CLIENT] Starting initialization for server: <server_url>
[SIGNAL_CLIENT] ✓ KeyManager created
[SIGNAL_CLIENT] ✓ SessionManager created
[SIGNAL_CLIENT] ✓ HealingService created
[SIGNAL_CLIENT] ✓ EncryptionService created
[SIGNAL_CLIENT] ✓ MessagingService created
[SIGNAL_CLIENT] ✓ MeetingService created
[SIGNAL_CLIENT] ✓ OfflineQueueProcessor created
[LISTENER_REGISTRY] Registering all socket listeners...
[MESSAGE_LISTENERS] ✓ Registered 3 listeners
[GROUP_LISTENERS] ✓ Registered 5 listeners
[SESSION_LISTENERS] ✓ Registered 4 listeners
[SYNC_LISTENERS] ✓ Registered 5 listeners
[LISTENER_REGISTRY] ✓ All listeners registered
[LISTENER_REGISTRY] ✓ Sent clientReady to server
[SIGNAL_CLIENT] ✓ Listeners registered & clientReady sent
[SIGNAL_CLIENT] ✓ Initialization complete
```

#### Check for Errors
- [ ] No "store not correct init" errors
- [ ] No "missing required argument" errors
- [ ] No "undefined name" errors
- [ ] No database locking errors

### 2. 1-to-1 Messaging (OneToOneMessagingMixin)
#### Send Messages
- [ ] Send text message to another user
- [ ] Message shows "sending" status
- [ ] Message transitions to "sent" when server confirms
- [ ] Message appears in recipient's chat
- [ ] No encryption errors in console

#### Receive Messages
- [ ] Receive message from another user
- [ ] Message decrypts successfully
- [ ] Message displays correct content
- [ ] Notification appears (if implemented)
- [ ] Unread count updates

#### PreKey Messages
- [ ] First message to new contact uses PreKey message
- [ ] Subsequent messages use Whisper messages
- [ ] Session established successfully
- [ ] No "UntrustedIdentityKeyException" errors

#### Multi-Device Support
- [ ] Send to user with multiple devices
- [ ] All devices receive message
- [ ] Each device decrypts independently
- [ ] No crosstalk between devices

### 3. Group Messaging (GroupMessagingMixin)
#### Send Group Messages
- [ ] Send message to group/channel
- [ ] Sender key is created if missing
- [ ] Message encrypted with sender key
- [ ] All group members receive message
- [ ] Group unread counts update correctly

#### Receive Group Messages
- [ ] Receive group message from another user
- [ ] Sender key distribution received (if first message)
- [ ] Message decrypts with sender key
- [ ] Message displays in group chat
- [ ] Sender name displayed correctly

#### Sender Key Distribution
- [ ] New member added to group
- [ ] Sender key distributed to new member
- [ ] New member can decrypt subsequent messages
- [ ] No "No sender key found" errors

#### Large Groups
- [ ] Send to group with 10+ members
- [ ] All members receive message
- [ ] No timeout errors
- [ ] Performance acceptable

### 4. File Messaging (FileMessagingMixin)
#### Send File (1-to-1)
- [ ] Select and send file to user
- [ ] File encrypts locally
- [ ] File metadata sent via Signal
- [ ] Recipient sees file message
- [ ] File download works for recipient

#### Send File (Group)
- [ ] Send file to group
- [ ] All members see file message
- [ ] Multiple members can download
- [ ] No race conditions

#### File Types
- [ ] Image files work correctly
- [ ] Document files work correctly
- [ ] Large files (>10MB) work
- [ ] File previews display (if implemented)

### 5. Message Receiving (MessageReceivingMixin)
#### Decryption
- [ ] PreKey messages decrypt correctly
- [ ] Whisper messages decrypt correctly
- [ ] SenderKey messages decrypt correctly
- [ ] Duplicate messages detected and skipped

#### Error Handling
- [ ] Decryption failure shows error message
- [ ] Session corruption triggers healing
- [ ] Missing keys request key from server
- [ ] Network errors don't crash app

#### Message Caching (MessageCachingMixin)
- [ ] Messages cached in SQLite
- [ ] Cached messages loaded on app restart
- [ ] Duplicate detection works via cache
- [ ] Recent conversations updated correctly

#### EventBus Integration
- [ ] NewMessage events emitted correctly
- [ ] NewNotification events for activity types
- [ ] UI updates on event emission
- [ ] No duplicate event emissions

### 6. Meeting E2EE (MeetingService)
#### Key Distribution (MeetingKeyHandlerMixin)
- [ ] Create new meeting
- [ ] Meeting sender keys created
- [ ] Keys distributed to participants
- [ ] Participants can decrypt meeting data

#### Guest Sessions (GuestSessionMixin)
- [ ] External guest joins meeting
- [ ] Guest session created
- [ ] Keys distributed to guest
- [ ] Guest can communicate encrypted

#### Meeting Messages
- [ ] Send encrypted meeting chat
- [ ] Video keys distributed
- [ ] Screen share keys work
- [ ] All participants receive keys

### 7. Socket Listeners
#### Connection Events
- [ ] App receives `clientReady` confirmation
- [ ] Pending messages sync after `clientReady`
- [ ] Socket reconnect triggers self-healing
- [ ] No duplicate listener registrations

#### Message Listeners
- [ ] `receiveItem` event handled
- [ ] `groupItem` event handled
- [ ] `receiveSenderKeyDistribution` handled
- [ ] Delivery/read receipts logged (TODO)

#### Session Listeners
- [ ] `signalStatusResponse` updates key status
- [ ] `myPreKeyIdsResponse` syncs PreKeys
- [ ] `sessionInvalidated` clears session
- [ ] `identityKeyChanged` triggers update

#### Sync Listeners
- [ ] `pendingMessagesAvailable` triggers sync
- [ ] `pendingMessagesResponse` processes batch
- [ ] `syncComplete` finishes sync
- [ ] Background sync works correctly

### 8. Offline & Sync
#### Offline Queue
- [ ] Messages queued when offline
- [ ] Queue processes when reconnected
- [ ] Failed items marked appropriately
- [ ] No data loss during offline period

#### Background Sync
- [ ] App closed with pending messages
- [ ] Reopen app
- [ ] Pending messages sync automatically
- [ ] All messages arrive in correct order

### 9. Multi-Server Support
#### Switch Servers
- [ ] Add second server configuration
- [ ] Switch between servers
- [ ] Each server has isolated SignalClient
- [ ] Messages route to correct server
- [ ] No crosstalk between servers

#### Active Server Changes
- [ ] Change active server
- [ ] SocketService routes to new server
- [ ] ApiService routes to new server
- [ ] Listeners receive events from active server

### 10. Self-Healing
#### Key Verification
- [ ] Daily verification runs (check logs after 24h)
- [ ] Manual verification works
- [ ] Missing keys uploaded automatically
- [ ] Corrupted sessions reset

#### Session Recovery
- [ ] Simulate session corruption
- [ ] Healing service detects issue
- [ ] New session established
- [ ] Messages continue to flow

### 11. Performance
#### Startup Time
- [ ] Cold start < 3 seconds
- [ ] Warm start < 1 second
- [ ] Database initialization fast
- [ ] No blocking operations on UI thread

#### Message Throughput
- [ ] Send 100 messages rapidly
- [ ] No UI lag
- [ ] All messages process correctly
- [ ] Memory usage stable

#### Resource Usage
- [ ] CPU usage reasonable
- [ ] Memory doesn't leak
- [ ] Database size grows appropriately
- [ ] Network usage efficient

### 12. Error Scenarios
#### Network Issues
- [ ] Disconnect network during send
- [ ] Message queued for retry
- [ ] Reconnect network
- [ ] Message sends successfully

#### Database Issues
- [ ] Database locked temporarily
- [ ] App doesn't crash
- [ ] Operations retry
- [ ] Data integrity maintained

#### Encryption Issues
- [ ] Missing sender key
- [ ] Key request sent automatically
- [ ] Key received and stored
- [ ] Message decrypts successfully

### 13. Edge Cases
#### Empty States
- [ ] First app launch
- [ ] No messages in chat
- [ ] No groups joined
- [ ] UI displays appropriately

#### Concurrent Operations
- [ ] Send multiple messages simultaneously
- [ ] Join multiple groups at once
- [ ] Receive messages while sending
- [ ] No race conditions

#### Large Data
- [ ] 1000+ messages in chat
- [ ] 50+ groups
- [ ] Large message payload (10KB+)
- [ ] Performance acceptable

## 🐛 Known Issues to Watch For

### Fixed in Refactoring
- ✅ Store initialization (managers return themselves)
- ✅ Named parameters throughout APIs
- ✅ EventBus enum-based events
- ✅ Listener import paths
- ✅ Method signature mismatches

### Still TODO (Not Blocking)
- ⏳ Delivery receipt handling in MessagingService
- ⏳ Read receipt handling in MessagingService
- ⏳ Reaction handling in MessagingService
- ⏳ SyncState UI (removed, needs reimplementation)

### Deprecated (Expected Warnings)
- ⚠️ SignalService usage in 6 UI files (functional but logs warnings)

## 📊 Success Criteria

### Must Pass
- [ ] No compilation errors
- [ ] No runtime crashes
- [ ] Messages send and receive correctly
- [ ] Encryption/decryption works
- [ ] Multi-server isolation maintained
- [ ] Database operations stable

### Should Pass
- [ ] Performance acceptable
- [ ] Error handling graceful
- [ ] UI responsive
- [ ] Resource usage reasonable

### Nice to Have
- [ ] No deprecation warnings (requires migrating UI files)
- [ ] All TODO items implemented
- [ ] Comprehensive error tracking

## 🚀 Post-Testing

### If All Tests Pass
1. Document any issues found
2. Update BUGS.md if needed
3. Consider migrating deprecated SignalService usage
4. Implement TODO items (receipts, reactions)

### If Tests Fail
1. Note exact reproduction steps
2. Check console for error messages
3. Verify store initialization
4. Check listener registration logs
5. Review method signatures
6. Test in isolation (single feature)

## 📝 Testing Log Template

```
Date: 
Tester: 
Build: 
Platform: (Windows/Linux/macOS/Web/Android/iOS)

1. Authentication & Initialization: [ PASS / FAIL ]
   Notes:

2. 1-to-1 Messaging: [ PASS / FAIL ]
   Notes:

3. Group Messaging: [ PASS / FAIL ]
   Notes:

4. File Messaging: [ PASS / FAIL ]
   Notes:

5. Message Receiving: [ PASS / FAIL ]
   Notes:

6. Meeting E2EE: [ PASS / FAIL ]
   Notes:

7. Socket Listeners: [ PASS / FAIL ]
   Notes:

8. Offline & Sync: [ PASS / FAIL ]
   Notes:

9. Multi-Server Support: [ PASS / FAIL ]
   Notes:

10. Self-Healing: [ PASS / FAIL ]
    Notes:

11. Performance: [ PASS / FAIL ]
    Notes:

12. Error Scenarios: [ PASS / FAIL ]
    Notes:

13. Edge Cases: [ PASS / FAIL ]
    Notes:

Overall Result: [ PASS / FAIL ]
Critical Issues:
Non-Critical Issues:
Recommendations:
```
