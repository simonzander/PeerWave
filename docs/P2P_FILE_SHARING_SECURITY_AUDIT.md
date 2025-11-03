# P2P File Sharing - Security Analysis & Use Case Validation

**Date:** October 30, 2025  
**Analysis Type:** Security Audit & Breaking Case Detection

---

## 🔍 Use Case Analysis

### Use Case 1: Bob lädt Datei hoch ✅

**Flow:**
1. Bob calls `fileTransferService.uploadAndAnnounceFile()`
2. File is chunked and stored locally
3. `socketFileClient.announceFile()` sends to server
4. Server: `fileRegistry.announceFile()` creates new file entry
5. **Bob auto-added to `sharedWith` Set**
6. `chunkQuality` calculated (100% if Bob has all chunks)
7. Notification sent to users in `sharedWith` (only Bob initially)

**✅ Security Status:** SECURE
- Bob is automatically added to sharedWith
- Bob is set as `creator`
- No privacy leak (no fileName on server)

---

### Use Case 2: Bob shared Datei zu Alice ✅

**Current Implementation:**
Bob uses `fileTransferService.addUsersToShare()` which:
1. Calls `signalService.sendFileShareUpdate()` (encrypted via Signal Protocol)
2. Alice receives encrypted message with fileId
3. Alice updates her local metadata

**❌ CRITICAL PROBLEM DETECTED:**
```javascript
// server/server.js - shareFile event
socket.on("shareFile", async (data, callback) => {
  const { fileId, targetUserId } = data;
  
  // Only creator can share
  if (!fileRegistry.canAccess(userId, fileId)) { ... }
  
  const file = fileRegistry.getFileInfo(fileId);
  if (file.creator !== userId) {
    return callback?.({ success: false, error: "Only creator can share" });
  }
  
  const success = fileRegistry.shareFile(fileId, userId, targetUserId);
```

**PROBLEM:** Server has no `shareFile` socket event handler that updates the server-side `sharedWith` Set!

The Signal Protocol message is sent, but the server's `fileRegistry` is NOT updated. This means:
- Alice cannot call `getFileInfo()` - server will deny access
- Alice cannot download - `registerLeecher()` will fail with "Access denied"

**❌ BREAKING CASE #1: Alice cannot access file Bob shared with her**

---

### Use Case 3: Alice startet Download der Datei von Bob ❌

**Flow (if Use Case 2 worked):**
1. Alice calls `fileTransferService.downloadFile(fileId)`
2. Alice calls `socketFileClient.getFileInfo(fileId)`
3. **Server checks `canAccess(alice, fileId)` → FAILS because Alice not in sharedWith**
4. Alice gets "Access denied"

**❌ BREAKING CASE #2: Alice cannot download because server sharedWith not updated**

---

### Use Case 4: Alice shared den gestarteten Download in Channel 1 ❌

**Problem:** Alice needs to:
1. Add Channel 1 members to her local `sharedWith`
2. Call `addUsersToShare()` to send Signal Protocol messages
3. **Server needs to update `sharedWith` for the file**

**❌ BREAKING CASE #3: Only file creator can share on server**

```javascript
// fileRegistry.js - shareFile method
shareFile(fileId, creatorId, targetUserId) {
  const file = this.files.get(fileId);
  if (!file) return false;
  
  // No check if creatorId is actually the creator!
  // But server.js DOES check:
  if (file.creator !== userId) { // Only Bob can share
    return callback?.({ success: false, error: "Only creator can share" });
  }
}
```

**Alice cannot share the file even though she has chunks!**

---

### Use Case 5: Frank as Member from Channel 1 starts Download ❌

**Problem Cascade:**
- Use Case 4 failed → Frank not added to server's `sharedWith`
- Frank cannot call `getFileInfo()` → Access denied
- Frank cannot call `registerLeecher()` → Access denied

**❌ BREAKING CASE #4: Frank cannot download because Alice cannot share**

---

### Use Case 6: Bob wents offline in seeding process ✅

**Flow:**
1. Socket disconnect event triggers
2. Server calls `fileRegistry.handleUserDisconnect(bob, deviceId)`
3. Bob removed from seeders list
4. File remains in registry (creator's file)
5. Chunk quality drops to 0% (if Bob was only seeder)
6. Other users get `fileSeederUpdate` event with reduced quality

**✅ Security Status:** SECURE
- File not deleted (Bob is creator)
- Other seeders continue seeding
- Leechers can continue from other sources

---

### Use Case 7: Bob comes online, checks Signal messages, updates metadata ⚠️

**Current Flow:**
1. Bob logs in
2. `fileTransferService.reannounceUploadedFiles()` called
3. Bob re-announces files with current `sharedWith` from local storage
4. Server receives `announceFile` with `sharedWith` array
5. Server merges if Bob is creator

**⚠️ PARTIAL PROBLEM:**
```javascript
// fileRegistry.js
if (file.creator === userId && sharedWith && sharedWith.length > 0) {
  sharedWith.forEach(id => {
    if (!file.sharedWith.has(id)) {
      file.sharedWith.add(id);
      console.log(`[FILE REGISTRY] Added ${id} to sharedWith...`);
    }
  });
}
```

**Problem:** Bob's local `sharedWith` might be outdated if:
- Alice shared the file while Bob was offline (via Signal Protocol)
- Bob doesn't have Alice's share update in his Signal inbox
- Bob re-announces with old `sharedWith` list

**⚠️ INCONSISTENCY RISK: Server sharedWith might not match reality**

---

## 🚨 Critical Security Issues

### 1. Missing Server-Side Share Update Mechanism ⛔

**Issue:** `addUsersToShare()` only sends Signal Protocol message, doesn't update server.

**Impact:**
- Recipients cannot access file on server
- File sharing completely broken
- Share-based access control bypassed

**Fix Required:**
```javascript
// Need new socket event in server.js
socket.on("updateFileShare", async (data, callback) => {
  const { fileId, action, userIds } = data; // action: 'add' | 'revoke'
  const userId = socket.handshake.session.uuid;
  
  const file = fileRegistry.getFileInfo(fileId);
  
  // Check permission: Creator OR current seeder can share
  if (file.creator !== userId && !fileRegistry.canAccess(userId, fileId)) {
    return callback?.({ success: false, error: "No permission" });
  }
  
  if (action === 'add') {
    userIds.forEach(targetId => {
      fileRegistry.shareFile(fileId, userId, targetId);
    });
  } else if (action === 'revoke') {
    userIds.forEach(targetId => {
      fileRegistry.unshareFile(fileId, userId, targetId);
    });
  }
  
  callback?.({ success: true });
});
```

---

### 2. Only Creator Can Share (Too Restrictive) ⛔

**Issue:** `shareFile` socket event checks:
```javascript
if (file.creator !== userId) {
  return callback?.({ success: false, error: "Only creator can share" });
}
```

**Impact:**
- Alice cannot share file she downloaded from Bob
- Collaborative seeding broken
- P2P network growth limited

**Fix Required:**
Change permission model:
- **Creator** can add/revoke any user
- **Any seeder** can add users (but not revoke)
- **Any authorized user** can re-share

**Recommendation:**
```javascript
// More permissive sharing model
const canShare = 
  file.creator === userId || // Creator can always share
  fileRegistry.canAccess(userId, fileId); // Or user has access (is seeding)

if (!canShare) {
  return callback?.({ success: false, error: "No permission" });
}
```

---

### 3. Race Condition: Concurrent Share Updates ⚠️

**Issue:** Multiple users sharing simultaneously:
1. Alice shares to Frank at T0
2. Bob shares to George at T0
3. Both send Signal messages
4. Both call hypothetical `updateFileShare` event
5. Server processes sequentially

**Impact:** Low risk (Set is idempotent)

**Status:** Not critical, but should be documented

---

### 4. Signal Protocol Message Not Synced with Server 🔴

**Issue:** Two-phase update problem:
1. Signal message sent (encrypted, offline-capable)
2. Server update sent (requires online, can fail)

**Scenario:**
- Bob shares with Alice via Signal ✅
- Server update fails (network error) ❌
- Alice receives Signal message ✅
- Alice tries to download → Server denies ❌

**Impact:** Inconsistency between Signal metadata and server state

**Fix Required:**
Implement reliable delivery:
```javascript
// Option 1: Signal message includes server update token
// Alice presents token to server as proof of share

// Option 2: Server polls Signal for share updates
// Server checks Signal GroupItems for file_share_update

// Option 3: Two-phase commit
// 1. Update server first
// 2. Only send Signal message if server succeeds
// 3. If Signal fails, rollback server
```

**Recommended: Option 3 with rollback**

---

### 5. No Verification of Share Updates in Signal ⚠️

**Issue:** Anyone can send a fake `file_share_update` Signal message claiming:
- "Bob shared fileId XYZ with you"
- Recipient trusts it and updates local metadata

**Impact:**
- User thinks they have access
- Server still denies (good!)
- UX confusion

**Fix Required:**
```javascript
// When receiving file_share_update via Signal:
async function handleFileShareUpdate(data) {
  const { fileId, action, senderId } = data;
  
  // VERIFY with server before updating local state
  const verification = await socketFileClient.verifyFileShare({
    fileId,
    sharedBy: senderId
  });
  
  if (!verification.success) {
    console.warn('Invalid share update, ignoring');
    return;
  }
  
  // Only update local metadata if server confirms
  await storage.updateFileMetadata(fileId, { ... });
}
```

---

### 6. sharedWith Can Grow Unbounded 🔴

**Issue:** No limit on `sharedWith` Set size

**Attack Scenario:**
1. Bob creates file
2. Bob shares with 1,000,000 users (spam)
3. Server stores 1M user IDs in Set
4. Memory exhaustion attack

**Impact:** DoS vulnerability

**Fix Required:**
```javascript
// fileRegistry.js
shareFile(fileId, creatorId, targetUserId) {
  const file = this.files.get(fileId);
  if (!file) return false;
  
  // ADD LIMIT CHECK
  const MAX_SHARED_USERS = 1000; // Configurable
  
  if (file.sharedWith.size >= MAX_SHARED_USERS) {
    console.error(`[FILE REGISTRY] Cannot share ${fileId}: max users reached`);
    return false;
  }
  
  file.sharedWith.add(targetUserId);
  return true;
}
```

---

### 7. No Rate Limiting on Share Operations ⚠️

**Issue:** User can spam share/unshare operations

**Attack:**
```javascript
for (let i = 0; i < 10000; i++) {
  socket.emit("shareFile", { fileId, targetUserId: "victim" });
}
```

**Impact:** Server CPU/memory overload

**Fix Required:**
Implement rate limiting:
```javascript
const shareRateLimiter = new Map(); // userId -> { count, resetTime }

socket.on("shareFile", async (data, callback) => {
  const userId = socket.handshake.session.uuid;
  
  // Rate limit: 10 shares per minute
  const limit = shareRateLimiter.get(userId) || { count: 0, resetTime: Date.now() + 60000 };
  
  if (Date.now() > limit.resetTime) {
    limit.count = 0;
    limit.resetTime = Date.now() + 60000;
  }
  
  if (limit.count >= 10) {
    return callback?.({ success: false, error: "Rate limit exceeded" });
  }
  
  limit.count++;
  shareRateLimiter.set(userId, limit);
  
  // ... rest of handler
});
```

---

### 8. Metadata Injection via sharedWith Parameter 🔴

**Issue:** `announceFile` accepts `sharedWith` array from client

**Attack Scenario:**
1. Malicious client sends:
```javascript
announceFile({
  fileId: "malicious",
  sharedWith: ["admin", "user1", "user2", ...] // Claim it's shared
})
```
2. Server trusts client and adds to sharedWith
3. File creator restriction bypassed

**Current Protection:**
```javascript
// fileRegistry.js
if (file.creator === userId && sharedWith && sharedWith.length > 0) {
  // Only creator can set initial sharedWith ✅
}
```

**✅ Status:** PROTECTED (only creator's sharedWith is honored)

**Recommendation:** Add validation:
```javascript
// Validate userIds exist
if (sharedWith && file.creator === userId) {
  const validUsers = await Promise.all(
    sharedWith.map(id => User.findByPk(id))
  );
  
  const existingUserIds = validUsers
    .filter(u => u !== null)
    .map(u => u.uuid);
  
  existingUserIds.forEach(id => file.sharedWith.add(id));
}
```

---

### 9. Creator Can Be Impersonated if Session Hijacked ⚠️

**Issue:** If Bob's session is hijacked:
- Attacker can unshare all users
- Attacker can delete file
- Attacker can add malicious users

**Impact:** Full file control compromise

**Mitigation:**
- Ensure HTTPS only (already in place)
- Short session timeouts
- Multi-device notification for sensitive operations
- Consider adding file PIN/password

---

### 10. No Audit Log for Share Operations ⚠️

**Issue:** No record of who shared with whom

**Impact:**
- Cannot trace abuse
- Cannot debug share issues
- No compliance trail

**Fix Required:**
```javascript
// Add audit logging
const shareAuditLog = [];

function logShareOperation(operation, userId, fileId, targetUserId) {
  shareAuditLog.push({
    timestamp: Date.now(),
    operation, // 'share' | 'unshare'
    userId,
    fileId,
    targetUserId,
    ipAddress: socket.handshake.address
  });
  
  // Persist to database for compliance
  // auditLogService.log({ ... });
}
```

---

## 🛡️ Recommendations Summary

### Critical (Must Fix) 🔴

1. **Implement server-side share update mechanism**
   - Add `updateFileShare` socket event
   - Integrate with `addUsersToShare()` and `revokeUsersFromShare()`

2. **Allow non-creator sharing**
   - Change permission model to allow seeders to share
   - Enable collaborative P2P growth

3. **Sync Signal Protocol with server state**
   - Two-phase commit for share updates
   - Rollback on failure

4. **Add sharedWith size limits**
   - Prevent memory exhaustion
   - Set reasonable maximum (e.g., 1000 users)

### High Priority (Should Fix) 🟠

5. **Add rate limiting for share operations**
   - Prevent spam attacks
   - 10 shares per minute per user

6. **Verify share updates from Signal**
   - Check with server before trusting
   - Prevent fake share messages

7. **Add audit logging**
   - Track all share operations
   - Enable abuse investigation

### Medium Priority (Consider) 🟡

8. **Validate user IDs in sharedWith**
   - Check users exist before adding
   - Prevent invalid entries

9. **Add session security hardening**
   - Multi-device notifications
   - Sensitive operation confirmation

10. **Document race condition handling**
    - Clarify concurrent share behavior
    - Add tests

---

## 🧪 Test Cases to Add

```javascript
describe('P2P File Sharing Security', () => {
  
  test('Bob shares file with Alice, Alice can download', async () => {
    // 1. Bob uploads and announces
    const fileId = await bob.uploadFile(file);
    
    // 2. Bob shares with Alice (should update server!)
    await bob.addUsersToShare(fileId, [alice.id]);
    
    // 3. Alice should be able to get file info
    const fileInfo = await alice.getFileInfo(fileId);
    expect(fileInfo.success).toBe(true);
    
    // 4. Alice should be able to download
    const download = await alice.registerLeecher(fileId);
    expect(download.success).toBe(true);
  });
  
  test('Alice shares Bob\'s file with Frank', async () => {
    // 1. Bob uploads, shares with Alice
    const fileId = await bob.uploadFile(file);
    await bob.addUsersToShare(fileId, [alice.id]);
    
    // 2. Alice downloads and becomes seeder
    await alice.downloadFile(fileId);
    
    // 3. Alice shares with Frank (should work!)
    await alice.addUsersToShare(fileId, [frank.id]);
    
    // 4. Frank should have access
    const fileInfo = await frank.getFileInfo(fileId);
    expect(fileInfo.success).toBe(true);
  });
  
  test('Attacker cannot fake share via Signal', async () => {
    const fileId = await bob.uploadFile(file);
    
    // Attacker sends fake Signal message
    await attacker.sendFakeShareUpdate(fileId, victim.id);
    
    // Victim tries to download
    const result = await victim.getFileInfo(fileId);
    expect(result.success).toBe(false);
    expect(result.error).toBe('Access denied');
  });
  
  test('Cannot share with more than 1000 users', async () => {
    const fileId = await bob.uploadFile(file);
    const users = generateUsers(1001);
    
    const result = await bob.addUsersToShare(fileId, users);
    expect(result.success).toBe(false);
    expect(result.error).toContain('limit');
  });
  
});
```

---

## 📊 Security Score

| Category | Score | Status |
|----------|-------|--------|
| Authentication | 8/10 | ✅ Good (session-based) |
| Authorization | 3/10 | 🔴 Broken (share not working) |
| Data Privacy | 9/10 | ✅ Excellent (no fileName on server) |
| Access Control | 4/10 | 🔴 Critical issues |
| DoS Protection | 5/10 | 🟠 Missing rate limits |
| Audit Trail | 2/10 | 🔴 No logging |
| Input Validation | 7/10 | ✅ Decent |
| **Overall** | **5.4/10** | 🔴 **Not production-ready** |

---

## 🎯 Action Items (Priority Order)

1. ✅ **Implement `updateFileShare` socket event** (2h)
2. ✅ **Change permission model to allow seeder sharing** (1h)
3. ✅ **Integrate server update with `addUsersToShare()`** (2h)
4. ✅ **Add sharedWith size limit (MAX_SHARED_USERS)** (30min)
5. ✅ **Add rate limiting for share operations** (1h)
6. ✅ **Add server-side share verification** (1h)
7. ⚠️ **Write integration tests** (4h)
8. ⚠️ **Add audit logging** (2h)

**Total Estimated Time:** 13.5 hours

---

**Conclusion:** The current implementation has **critical security vulnerabilities** that break the core file sharing functionality. The share mechanism is incomplete and must be fixed before production deployment.
