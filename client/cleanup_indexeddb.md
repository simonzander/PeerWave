# IndexedDB Cleanup Guide

## Issues Fixed

1. ✅ **Double-hash bug** in `device_scoped_storage_service.dart` - Fixed in `deleteEncrypted()` and `getAllKeys()`
2. ✅ **ClientId localStorage duplication** - Removed from `auth_layout_web.dart` (now only in IndexedDB `peerwave_clientids`)

## Manual Cleanup Required

Since you're starting fresh, you need to **manually delete old IndexedDB databases** from browser DevTools.

### How to Clean Up IndexedDB:

1. **Open Browser DevTools**:
   - Press `F12` or `Ctrl+Shift+I`

2. **Go to Application Tab**:
   - Click "Application" (Chrome) or "Storage" (Firefox)

3. **Expand IndexedDB**:
   - Find "IndexedDB" in the left sidebar

4. **Delete Legacy Databases** (without device hash):
   - `peerwaveSignal`
   - `peerwaveSignalSessions`
   - `peerwaveSenderKeys`
   - `peerwaveSentMessages`
   - `peerwaveDecryptedMessages`
   - `decryptedGroupItems`
   - `sentGroupItems`

5. **Delete Double-Hashed Databases** (pattern: `name_hash1_hash2`):
   - Look for databases with TWO device hashes (e.g., `peerwaveSignalPreKeys_30a8cb5b647e790d_30a8cb5b647e790d`)
   - Right-click each → "Delete database"

6. **Optional - Clean localStorage**:
   - Expand "Local Storage" → Select your domain
   - Delete `clientId` key if it exists

### What to Keep:

✅ **Keep these** (correct format with single hash):
- `peerwave_clientids` - Email → ClientId mapping
- `peerwave_preferences` - User preferences
- `peerwaveSignalPreKeys_[SINGLE_HASH]` - Encrypted PreKeys
- `peerwaveSignalSignedPreKeys_[SINGLE_HASH]` - Encrypted SignedPreKeys
- Any other database with format: `name_[SINGLE_HASH]`

### After Cleanup:

1. Clear browser cache (optional but recommended)
2. Reload the page
3. Login again - fresh databases will be created with correct naming

## What Was Fixed:

### Bug 1: Double-Hashing in device_scoped_storage_service.dart

**Before (BUGGY)**:
```dart
final dbName = getDeviceDatabaseName(baseName); // baseName_hash
final db = await openDeviceDatabase(dbName, ...); // Adds hash AGAIN!
// Result: baseName_hash_hash ❌
```

**After (FIXED)**:
```dart
final db = await openDeviceDatabase(baseName, ...); // Adds hash ONCE
// Result: baseName_hash ✅
```

### Bug 2: ClientId in localStorage

**Before**: ClientId stored in BOTH localStorage AND IndexedDB
**After**: ClientId ONLY in IndexedDB `peerwave_clientids` (email → clientId mapping)

The `webauthnLogin()` function receives clientId as a parameter, so localStorage is unnecessary.
