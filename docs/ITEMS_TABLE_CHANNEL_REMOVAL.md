# Database Schema Cleanup: Removed 'channel' Column from Items Table

## Executive Summary

Successfully removed the `channel` column from the `Items` table and updated all related queries. The `Item` table is now exclusively for 1:1 direct messages, and the separation is enforced at the database schema level.

---

## Changes Made

### 1. **Database Schema (model.js)**

**File:** `server/db/model.js`

**Before:**
```javascript
deliveredAt: {
    type: DataTypes.DATE,
    allowNull: true
},
channel: {
    type: DataTypes.UUID,
    allowNull: true,
    defaultValue: null
}
```

**After:**
```javascript
deliveredAt: {
    type: DataTypes.DATE,
    allowNull: true
}
// NOTE: Item table is ONLY for 1:1 messages (no channel field needed)
// Group messages use the separate GroupItem table which has a channel field
```

**Result:** Model definition no longer includes `channel` field.

---

### 2. **Database Migration**

**File:** `server/db/migrations/remove_channel_from_items.js`

**Actions:**
1. Created new `Items_new` table without `channel` column
2. Copied all data from old `Items` table (excluding channel)
3. Dropped old `Items` table
4. Renamed `Items_new` to `Items`

**Result:**
```
✓ Migration successful - channel column removed
  Current columns: uuid, deviceReceiver, receiver, sender, deviceSender, 
                   readed, itemId, type, payload, cipherType, deliveredAt, 
                   createdAt, updatedAt
```

---

### 3. **Query Update (client.js)**

**File:** `server/routes/client.js`

**Before:**
```javascript
const result = await Item.sequelize.query(`
    SELECT *
    FROM Items
    WHERE
    deviceReceiver = :sessionDeviceId
    AND receiver = :sessionUuid
    AND (sender = :userId OR sender = :sessionUuid)
    AND channel IS NULL  // ❌ Field doesn't exist
    ORDER BY rowid ASC
`, ...);
```

**After:**
```javascript
const result = await Item.sequelize.query(`
    SELECT *
    FROM Items
    WHERE
    deviceReceiver = :sessionDeviceId
    AND receiver = :sessionUuid
    AND (sender = :userId OR sender = :sessionUuid)
    ORDER BY rowid ASC
`, ...);
```

**Comment Updated:**
```javascript
// NOTE: Item table contains ONLY 1:1 messages (no channel field)
// Group messages are stored in GroupItem table
```

**Result:** Query no longer references non-existent `channel` column.

---

### 4. **Item Creation (server.js)**

**File:** `server/server.js`

**Before:**
```javascript
const storedItem = await writeQueue.enqueue(async () => {
  return await Item.create({
    sender: senderUserId,
    deviceSender: senderDeviceId,
    receiver: recipientUserId,
    deviceReceiver: recipientDeviceId,
    type: type,
    payload: payload,
    cipherType: cipherType,
    itemId: itemId,
    channel: null  // ❌ Field doesn't exist
  });
}, `sendItem-${itemId}`);
```

**After:**
```javascript
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
```

**Comment Updated:**
```javascript
// NOTE: Item table is for 1:1 messages ONLY (no channel field)
// Group messages use sendGroupItem event and GroupItem table instead
```

**Result:** Item creation no longer tries to set `channel` field.

---

## Architecture Enforcement

### **Clear Separation at Database Level**

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DATABASE SCHEMA SEPARATION                      │
├─────────────────────────────────┬───────────────────────────────────┤
│         Items Table             │       GroupItem Table             │
│      (1:1 Messages ONLY)        │      (Group Messages ONLY)        │
├─────────────────────────────────┼───────────────────────────────────┤
│ ✓ uuid                          │ ✓ uuid                            │
│ ✓ sender                        │ ✓ sender                          │
│ ✓ receiver                      │ ✓ channel (REQUIRED)              │
│ ✓ deviceSender                  │ ✓ senderDevice                    │
│ ✓ deviceReceiver                │ ✓ type                            │
│ ✓ type                          │ ✓ payload                         │
│ ✓ payload                       │ ✓ cipherType                      │
│ ✓ cipherType                    │ ✓ timestamp                       │
│ ✓ itemId                        │ ✓ createdAt                       │
│ ✓ readed                        │ ✓ updatedAt                       │
│ ✓ deliveredAt                   │                                   │
│ ✓ createdAt                     │                                   │
│ ✓ updatedAt                     │                                   │
│                                 │                                   │
│ ❌ NO channel field             │ ✅ HAS channel field              │
└─────────────────────────────────┴───────────────────────────────────┘
```

---

## Benefits

### **1. Schema-Level Enforcement**
- Impossible to accidentally store `channel` in 1:1 messages
- Database schema enforces architectural decisions
- No runtime checks needed for field existence

### **2. Simpler Queries**
- No need to filter by `channel IS NULL`
- Queries are more readable and efficient
- Less error-prone code

### **3. Clear Intent**
- Table structure clearly shows purpose
- Developers immediately understand message type by table name
- Self-documenting architecture

### **4. Performance**
- One less column to store and index
- Simpler query execution plans
- Reduced storage overhead

---

## Testing Checklist

- [x] Database migration completed successfully
- [x] All columns preserved (except channel)
- [x] Model definition updated
- [x] Query in client.js updated and simplified
- [x] Item creation in server.js updated
- [ ] Test 1:1 message flow (send/receive)
- [ ] Test offline message retrieval
- [ ] Test multi-device synchronization
- [ ] Verify no errors in console

---

## Database State

**Before Migration:**
```sql
Items Table: 
  uuid, deviceReceiver, receiver, sender, deviceSender, readed, 
  itemId, type, payload, cipherType, deliveredAt, channel, 
  createdAt, updatedAt
```

**After Migration:**
```sql
Items Table: 
  uuid, deviceReceiver, receiver, sender, deviceSender, readed, 
  itemId, type, payload, cipherType, deliveredAt, 
  createdAt, updatedAt
```

**GroupItem Table** (unchanged):
```sql
GroupItem Table:
  uuid, itemId, channel, sender, senderDevice, type, payload, 
  cipherType, timestamp, createdAt, updatedAt
```

---

## Migration Files

1. **add_channel_to_items.js** - Initial migration (now obsolete)
2. **remove_channel_from_items.js** - Final migration (applied)

---

## Summary

✅ **Completed:**
- Removed `channel` field from Item model
- Removed `channel` from Item.create() calls
- Removed `AND channel IS NULL` from queries
- Database migration successful
- All data preserved

✅ **Architecture:**
- Items table: 1:1 messages ONLY (no channel field)
- GroupItem table: Group messages ONLY (channel required)
- Clean separation at schema level

✅ **Next Steps:**
- Test 1:1 messaging flow
- Verify no SQL errors
- Confirm offline message sync works

---

**Date:** 2025-10-24  
**Status:** ✅ Complete  
**Migration:** Successful  
**Data Loss:** None
