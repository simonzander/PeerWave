# Device/User Encrypted Storage Migration - Action Plan

## 🎯 Objective

Implement comprehensive per-device/user encryption for all local storage, ensuring that:
1. **PeerWaveFiles** storage is device-scoped with encrypted file keys only
2. **SenderKeys** are device-scoped and encrypted
3. **Messages** (1:1 and group) use application-layer encryption via SQLite
4. Only `peerwave_clientids` remains unencrypted for device identification
5. All other storage uses device-specific names like `peerwaveSignalSignedPreKeys_8ee2b73b082238f3`

---

## 📊 Current State Analysis

### Current Storage Architecture

| Storage | Location | Encryption | Device-Scoped | Notes |
|---------|----------|------------|---------------|-------|
| `peerwave_clientids` | IndexedDB | ❌ No | ❌ Global | Email→ClientID mapping |
| `peerwaveSignal` | IndexedDB | ✅ Yes | ✅ Yes | Identity keys (device-scoped) |
| `peerwavePreKeys_*` | IndexedDB | ✅ Yes | ✅ Yes | PreKeys (device-scoped) |
| `peerwaveSignedPreKeys_*` | IndexedDB | ✅ Yes | ✅ Yes | SignedPreKeys (device-scoped) |
| `peerwaveSenderKeys` | IndexedDB | ✅ Yes | ❌ No | **NEEDS DEVICE SCOPING** |
| `peerwaveSessions` | IndexedDB | ✅ Yes | ✅ Yes | Signal sessions (device-scoped) |
| `PeerWaveFiles` | IndexedDB | ⚠️ Partial | ❌ No | **NEEDS DEVICE SCOPING + KEY ENCRYPTION** |
| `peerwave.db` (SQLite) | IndexedDB | ❌ No | ❌ No | **NEEDS APPLICATION-LAYER ENCRYPTION** |

### Affected Components

#### 1. File Storage (`PeerWaveFiles`)
- **Location**: `client/lib/services/file_transfer/indexeddb_storage.dart`
- **Current State**: 
  - Global database name: `PeerWaveFiles`
  - Stores: `files` (metadata), `chunks` (encrypted data), `fileKeys` (plaintext!)
- **Issues**:
  - ❌ Not device-scoped
  - ❌ File keys stored in plaintext
  - ✅ Chunks are already encrypted (good!)
  - ✅ File metadata is just metadata (ok)

#### 2. Sender Keys
- **Location**: `client/lib/services/sender_key_store.dart`
- **Current State**:
  - Uses `peerwaveSenderKeys` (not device-scoped)
  - Data is encrypted via `DeviceScopedStorageService`
- **Issues**:
  - ❌ Database name not device-scoped
  - ✅ Data is encrypted (good!)

#### 3. SQLite Database (`peerwave.db`)
- **Location**: `client/lib/services/storage/database_helper.dart`
- **Current State**:
  - Global database: `peerwave.db`
  - Stores messages, conversations, Signal protocol data
  - No encryption
- **Issues**:
  - ❌ Not device-scoped
  - ❌ No encryption
  - ⚠️ Contains sensitive message data

#### 4. Client ID Storage
- **Location**: `client/lib/services/clientid_web.dart`
- **Current State**: 
  - Database: `peerwave_clientids`
  - No encryption (by design)
- **Status**: ✅ Correct - should remain global and unencrypted

---

## 🗺️ Migration Strategy

### Phase 1: File Storage Device Scoping ⭐ PRIORITY 1

**Goal**: Make `PeerWaveFiles` device-scoped and encrypt file keys

#### Changes Required:

1. **Database Name Migration**
   - Change from: `PeerWaveFiles`
   - Change to: `PeerWaveFiles_{deviceId}`
   - Example: `PeerWaveFiles_8ee2b73b082238f3`

2. **File Keys Encryption**
   - Current: `fileKeys` store contains plaintext keys
   - New: Encrypt file keys using WebAuthn-derived encryption
   - Store structure:
     ```typescript
     {
       fileId: string,
       encryptedKey: {
         iv: Uint8Array,
         encryptedData: Uint8Array,
         version: 1
       }
     }
     ```

3. **Files Affected**:
   - `client/lib/services/file_transfer/indexeddb_storage.dart`
   - `client/lib/services/file_transfer/storage_interface.dart`

4. **Implementation Steps**:
   - [ ] Add device ID parameter to `IndexedDBStorage` constructor
   - [ ] Update database name generation: `PeerWaveFiles_${deviceId}`
   - [ ] Create `EncryptedFileKeyStore` class for encrypted key operations
   - [ ] Update `saveFileKey()` to encrypt keys before storage
   - [ ] Update `getFileKey()` to decrypt keys after retrieval
   - [ ] Add migration logic to move existing files to device-scoped DB
   - [ ] Test file upload/download with encrypted keys

5. **Migration Logic**:
   ```dart
   // On first login with new system:
   // 1. Check if old PeerWaveFiles exists
   // 2. If yes, migrate to PeerWaveFiles_{deviceId}
   // 3. Encrypt all existing file keys
   // 4. Delete old database after successful migration
   ```

---

### Phase 2: Sender Keys Device Scoping ⭐ PRIORITY 2

**Goal**: Make sender keys device-scoped per device/user

#### Changes Required:

1. **Database Name Migration**
   - Change from: `peerwaveSenderKeys`
   - Change to: `peerwaveSenderKeys_{deviceId}`
   - Example: `peerwaveSenderKeys_8ee2b73b082238f3`

2. **Files Affected**:
   - `client/lib/services/sender_key_store.dart`
   - `client/lib/services/device_scoped_storage_service.dart`

3. **Implementation Steps**:
   - [ ] Update `PermanentSenderKeyStore` to use device-scoped storage
   - [ ] Change `_storeName` to be device-specific
   - [ ] Update all sender key operations to use new store name
   - [ ] Add migration logic for existing sender keys
   - [ ] Test group messaging with device-scoped sender keys
   - [ ] Verify multi-device sender key isolation

4. **Migration Logic**:
   ```dart
   // On first login with new system:
   // 1. Check if old peerwaveSenderKeys exists
   // 2. If yes, migrate to peerwaveSenderKeys_{deviceId}
   // 3. Copy all sender keys with encryption
   // 4. Delete old database after successful migration
   ```

---

### Phase 3: SQLite Application-Layer Encryption ⭐ PRIORITY 3

**Goal**: Add application-layer encryption for SQLite database

#### Approach: Encrypted Column Wrapper

Since we use `sqflite_common_ffi_web` (SQLite in WASM), we can't use SQLite's built-in encryption (SQLCipher). Instead, we'll use **application-layer encryption**:

1. **Selective Encryption Strategy**:
   - Encrypt sensitive columns only (not metadata)
   - Keep indexes on unencrypted search columns
   - Use deterministic encryption for searchable fields (if needed)

2. **Tables to Encrypt**:

   | Table | Columns to Encrypt | Columns to Keep Plain |
   |-------|-------------------|----------------------|
   | `messages` | `message` (content) | `item_id`, `sender`, `timestamp`, `type`, `direction` |
   | `signal_sessions` | `record` | `address` |
   | `signal_identity_keys` | `identity_key` | `address`, `trust_level` |
   | `signal_pre_keys` | `record` | `pre_key_id` |
   | `signal_signed_pre_keys` | `record` | `signed_pre_key_id`, `timestamp` |
   | `sender_keys` | `record` | `sender_key_id` |

3. **Database Naming**:
   - Change from: `peerwave.db`
   - Change to: `peerwave_{deviceId}.db`
   - Example: `peerwave_8ee2b73b082238f3.db`

#### Implementation Steps:

1. **Create Encryption Layer**:
   - [ ] Create `DatabaseEncryptionService` class
   - [ ] Implement `encryptField(plaintext)` → returns `{iv, encryptedData}`
   - [ ] Implement `decryptField(encrypted)` → returns plaintext
   - [ ] Use WebAuthn-derived key from SessionStorage

2. **Update Database Schema**:
   - [ ] Modify table schemas to store encrypted data as BLOB
   - [ ] Add version markers for encryption format
   - [ ] Create indexes only on non-encrypted columns

3. **Update DatabaseHelper**:
   - [ ] Change database name to device-scoped: `peerwave_{deviceId}.db`
   - [ ] Add encryption service injection
   - [ ] Update `_onCreate()` to handle encrypted columns

4. **Update Data Access Layer**:
   - [ ] Wrap all `INSERT` operations with encryption
   - [ ] Wrap all `SELECT` operations with decryption
   - [ ] Update `messages` table operations
   - [ ] Update Signal protocol table operations

5. **Migration Path**:
   ```dart
   // On first login with new system:
   // 1. Check if old peerwave.db exists
   // 2. If yes, create new peerwave_{deviceId}.db
   // 3. Copy all data, encrypting sensitive columns
   // 4. Verify data integrity
   // 5. Delete old database after successful migration
   ```

6. **Files Affected**:
   - `client/lib/services/storage/database_helper.dart`
   - `client/lib/services/storage/database_encryption_service.dart` (new)
   - All files that query the database

---

### Phase 4: Cleanup & Verification ⭐ PRIORITY 4

**Goal**: Ensure all storage follows new pattern

#### Verification Checklist:

- [ ] **Global/Unencrypted Storage** (should only be `peerwave_clientids`):
  - `peerwave_clientids` - ✅ Correct

- [ ] **Device-Scoped Storage** (all should follow `name_{deviceId}` pattern):
  - `peerwaveSignal_{deviceId}` - ✅ Already correct
  - `peerwaveSignalIdentityKeys_{deviceId}` - ✅ Already correct
  - `peerwavePreKeys_{deviceId}` - ✅ Already correct
  - `peerwaveSignedPreKeys_{deviceId}` - ✅ Already correct
  - `peerwaveSenderKeys_{deviceId}` - ⏳ Phase 2
  - `peerwaveSessions_{deviceId}` - ✅ Already correct
  - `peerwaveDecryptedMessages_{deviceId}` - ✅ Already correct
  - `peerwaveSentMessages_{deviceId}` - ✅ Already correct
  - `peerwaveDecryptedGroupItems_{deviceId}` - ✅ Already correct
  - `peerwaveSentGroupItems_{deviceId}` - ✅ Already correct
  - `PeerWaveFiles_{deviceId}` - ⏳ Phase 1
  - `peerwave_{deviceId}.db` - ⏳ Phase 3

#### Cleanup Tasks:

1. **Remove Legacy Databases**:
   - [ ] Add migration flag in device identity storage
   - [ ] After successful migration, delete old databases:
     - Old `PeerWaveFiles`
     - Old `peerwaveSenderKeys`
     - Old `peerwave.db`

2. **Update Documentation**:
   - [ ] Update storage architecture docs
   - [ ] Add encryption key lifecycle diagram
   - [ ] Document migration process
   - [ ] Create developer guide for adding new storage

3. **Add Logging & Monitoring**:
   - [ ] Log all database operations (with privacy in mind)
   - [ ] Add encryption/decryption metrics
   - [ ] Monitor migration success rates
   - [ ] Add error reporting for encryption failures

---

## 🔧 Technical Implementation Details

### Device ID Generation

```dart
// Current implementation in DeviceIdentityService
String deviceId = hash(email + webAuthnCredentialId + clientId);
// Example: "8ee2b73b082238f3"
```

### Encryption Key Management

```dart
// Key derivation from WebAuthn signature
final encryptionKey = await HKDF(
  signature: webAuthnSignature,
  salt: 'peerwave-storage-v1',
  info: deviceId,
);

// Store in SessionStorage (cleared on logout)
sessionStorage['encryption_key_${deviceId}'] = encryptionKey;
```

### Database Naming Convention

```dart
// Pattern: {baseName}_{deviceId}
String getDeviceDatabaseName(String baseName) {
  final deviceId = DeviceIdentityService.instance.deviceId;
  return '${baseName}_$deviceId';
}

// Examples:
// PeerWaveFiles → PeerWaveFiles_8ee2b73b082238f3
// peerwaveSenderKeys → peerwaveSenderKeys_8ee2b73b082238f3
// peerwave.db → peerwave_8ee2b73b082238f3.db
```

### Encryption Envelope Format

```dart
// For IndexedDB storage
{
  "version": 1,
  "iv": Uint8Array(12),  // 96-bit IV for AES-GCM
  "encryptedData": Uint8Array,  // Ciphertext
  "authTag": Uint8Array(16)  // 128-bit authentication tag (included in encryptedData)
}

// For SQLite BLOB storage
// Store as concatenated bytes: [iv(12) | encryptedData | authTag(16)]
```

---

## 🚨 Breaking Changes & Migration

### User Impact:

1. **First Login After Update**:
   - Migration runs automatically
   - May take 5-30 seconds depending on data size
   - User sees progress indicator
   - Old data deleted after successful migration

2. **Multi-Device Sync**:
   - Each device has isolated storage
   - Keys don't sync between devices (by design)
   - Each device must download files independently
   - Sender keys generated per device for groups

3. **Logout Behavior**:
   - Encryption key cleared from SessionStorage
   - Device-scoped data remains encrypted on disk
   - Re-login decrypts data with WebAuthn

### Developer Impact:

1. **New API Pattern**:
   ```dart
   // Old (global)
   final db = await openDatabase('PeerWaveFiles');
   
   // New (device-scoped)
   final db = await DeviceScopedStorageService.instance.openDeviceDatabase('PeerWaveFiles');
   ```

2. **Encrypted Field Access**:
   ```dart
   // Old (plaintext)
   final message = row['message'];
   
   // New (encrypted)
   final encryptedMessage = row['message'];
   final message = await DatabaseEncryptionService.instance.decryptField(encryptedMessage);
   ```

3. **Migration Required For**:
   - All code accessing `PeerWaveFiles`
   - All code accessing sender keys
   - All code querying SQLite database

---

## 📅 Implementation Timeline

### Phase 1: File Storage (Week 1)
- Days 1-2: Implement device-scoped database naming
- Days 3-4: Implement file key encryption
- Days 5-6: Add migration logic
- Day 7: Testing & bug fixes

### Phase 2: Sender Keys (Week 2)
- Days 1-2: Implement device-scoped sender key storage
- Days 3-4: Update group messaging logic
- Days 5-6: Add migration logic
- Day 7: Testing & bug fixes

### Phase 3: SQLite Encryption (Weeks 3-4)
- Days 1-3: Create encryption service
- Days 4-7: Update database schema & queries
- Days 8-10: Implement migration logic
- Days 11-14: Comprehensive testing

### Phase 4: Cleanup & Verification (Week 5)
- Days 1-2: Code cleanup & refactoring
- Days 3-4: Documentation updates
- Day 5: Final testing & verification

**Total Estimated Time**: 5 weeks

---

## ✅ Testing Strategy

### Unit Tests:
- [ ] Device ID generation consistency
- [ ] Encryption/decryption round-trip
- [ ] Database naming convention
- [ ] File key encryption
- [ ] Sender key device isolation
- [ ] SQLite field encryption

### Integration Tests:
- [ ] File upload with encrypted keys
- [ ] File download and decryption
- [ ] Group messaging with device-scoped sender keys
- [ ] Message storage and retrieval with encryption
- [ ] Multi-device scenario testing

### Migration Tests:
- [ ] Old → New file storage migration
- [ ] Old → New sender keys migration
- [ ] Old → New SQLite migration
- [ ] Rollback scenarios
- [ ] Data integrity verification

### Security Tests:
- [ ] Verify encryption keys not in plaintext
- [ ] Verify device isolation (no data leakage)
- [ ] Verify key cleared on logout
- [ ] Verify old databases deleted after migration
- [ ] Penetration testing for IndexedDB access

---

## 🔐 Security Considerations

1. **Key Management**:
   - ✅ Keys derived from WebAuthn signature
   - ✅ Keys stored in SessionStorage (memory only)
   - ✅ Keys cleared on logout
   - ⚠️ Consider key rotation policy

2. **Device Isolation**:
   - ✅ Each device has unique ID
   - ✅ Databases named with device ID
   - ✅ No cross-device data access

3. **Encryption Strength**:
   - ✅ AES-GCM-256 (FIPS 140-2 approved)
   - ✅ 96-bit IV (NIST recommended)
   - ✅ Authentication tag prevents tampering

4. **Migration Security**:
   - ⚠️ Old data vulnerable during migration
   - ✅ Encrypt immediately on migration
   - ✅ Delete old databases after migration
   - ✅ Verify data integrity after migration

---

## 📝 Open Questions & Decisions Needed

### Questions:

1. **File Chunks**: Should we re-encrypt chunks with device-scoped keys, or keep current encryption?
   - **Recommendation**: Keep current chunk encryption (P2P layer), only encrypt file keys at storage layer

2. **Search Functionality**: How to search encrypted message content?
   - **Option A**: Client-side decryption and search (slower, more private)
   - **Option B**: Deterministic encryption for searchable fields (faster, less private)
   - **Recommendation**: Option A for security

3. **Key Rotation**: Should we support key rotation?
   - **Recommendation**: Not in v1, add in future if needed

4. **Legacy Support**: How long to support migration from old format?
   - **Recommendation**: 6 months, then remove migration code

5. **Backup/Export**: How to backup encrypted data?
   - **Option A**: Export encrypted (requires key to restore)
   - **Option B**: Export decrypted (security risk)
   - **Recommendation**: Option A with clear user guidance

### Decisions Needed:

- [ ] **Approve overall approach**: Device-scoped + Application-layer encryption
- [ ] **Approve encryption algorithm**: AES-GCM-256
- [ ] **Approve migration strategy**: Automatic on first login
- [ ] **Approve timeline**: 5 weeks
- [ ] **Approve breaking changes**: Yes, with migration path

---

## 🎯 Success Criteria

### Functional:
- ✅ All file operations work with device-scoped storage
- ✅ All sender key operations work with device-scoped storage
- ✅ All message operations work with encrypted SQLite
- ✅ Migration completes without data loss
- ✅ Multi-device isolation verified

### Security:
- ✅ No plaintext sensitive data in storage
- ✅ Encryption keys not accessible without WebAuthn
- ✅ Device isolation prevents cross-device access
- ✅ Old databases cleaned up after migration

### Performance:
- ✅ Encryption/decryption overhead < 50ms per operation
- ✅ Migration completes in < 30 seconds for typical user
- ✅ No noticeable UI lag during normal operations

### Documentation:
- ✅ Architecture documented
- ✅ API changes documented
- ✅ Migration process documented
- ✅ Security model documented

---

## 🚀 Next Steps

1. **Review this action plan** with team
2. **Approve technical approach** and timeline
3. **Create detailed task breakdown** for Phase 1
4. **Set up development branch**: `feature/device-encrypted-storage`
5. **Begin Phase 1 implementation**: File Storage Device Scoping

---

## 📚 References

- [DEVICE_SCOPED_STORAGE_IMPLEMENTATION.md](./DEVICE_SCOPED_STORAGE_IMPLEMENTATION.md) - Current implementation
- [WEBAUTHN_ENCRYPTION_PHASE1_COMPLETE.md](./WEBAUTHN_ENCRYPTION_PHASE1_COMPLETE.md) - WebAuthn encryption details
- [SQLITE_MIGRATION_GUIDE.md](./SQLITE_MIGRATION_GUIDE.md) - SQLite migration patterns

---

**Status**: ⏳ Awaiting Approval
**Created**: 2025-11-08
**Author**: GitHub Copilot
**Approver**: Development Team
