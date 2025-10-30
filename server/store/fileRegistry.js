/**
 * File Registry - In-Memory File Metadata Store
 * 
 * Manages file metadata for P2P file sharing:
 * - Tracks which users are seeding which files
 * - Tracks which users are downloading (leechers)
 * - 30-day TTL for file announcements
 * - Automatic cleanup of expired entries
 */

class FileRegistry {
  constructor() {
    // Map: fileId -> FileMetadata
    this.files = new Map();
    
    // Map: userId:deviceId -> Set of fileIds (what device is seeding)
    this.userSeeds = new Map();
    
    // Map: fileId -> Set of userId:deviceId (who is seeding this file)
    this.fileSeeders = new Map();
    
    // Map: fileId -> Set of userId:deviceId (who is downloading this file)
    this.fileLeechers = new Map();
    
    // TTL for file announcements (30 days)
    this.FILE_TTL = 30 * 24 * 60 * 60 * 1000; // 30 days in ms
  }

  /**
   * Announce a file (device has chunks available)
   * 
   * SECURITY: Only authorized users can announce!
   * - First announcer (uploader) becomes creator and is auto-added to sharedWith
   * - Subsequent announcers must be in sharedWith (have permission)
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {object} fileMetadata - File metadata (NO fileName for privacy)
   * @returns {object} Updated file info or null if denied
   */
  announceFile(userId, deviceId, fileMetadata) {
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks, sharedWith } = fileMetadata;
    const deviceKey = `${userId}:${deviceId}`;
    
    // Get or create file entry
    let file = this.files.get(fileId);
    
    if (!file) {
      // ========================================
      // NEW FILE - First Announcement (Uploader)
      // ========================================
      console.log(`[FILE REGISTRY] NEW FILE: ${fileId.substring(0, 8)} uploaded by ${userId}`);
      
      file = {
        fileId,
        mimeType,
        fileSize,
        checksum, // Canonical checksum set by first announcer
        checksumSetBy: userId, // Track who set the canonical checksum
        checksumSetAt: Date.now(), // Track when checksum was set
        chunkCount,
        creator: userId, // Store who created/uploaded this file
        sharedWith: new Set(sharedWith || [userId]), // Creator can always access + any initial shares
        createdAt: Date.now(),
        lastActivity: Date.now(),
        seeders: new Set(),
        leechers: new Set(),
        totalSeeds: 0,
        totalDownloads: 0,
      };
      
      // Ensure creator is always in sharedWith
      file.sharedWith.add(userId);
      
      this.files.set(fileId, file);
      this.fileSeeders.set(fileId, new Set());
      this.fileLeechers.set(fileId, new Set());
      
      console.log(`[FILE REGISTRY] File ${fileId.substring(0, 8)} created with canonical checksum: ${checksum.substring(0, 16)}...`);
      console.log(`[FILE REGISTRY] Checksum set by ${userId} and shared with: [${Array.from(file.sharedWith).join(', ')}]`);
      
    } else {
      // ========================================
      // EXISTING FILE - Permission Check Required!
      // ========================================
      
      // SECURITY CHECK: User must have permission to announce this file
      if (!this.canAccess(userId, fileId)) {
        console.error(`[SECURITY] ❌ User ${userId} DENIED announce for ${fileId.substring(0, 8)} - NOT in sharedWith!`);
        console.error(`[SECURITY] Authorized users: [${Array.from(file.sharedWith).join(', ')}]`);
        return null; // ❌ REJECT unauthorized announce
      }
      
      console.log(`[FILE REGISTRY] ✓ User ${userId} authorized to announce ${fileId.substring(0, 8)}`);
      
      // User has permission - continue with announce
      
      // Auto-add seeder to sharedWith (if not already there)
      if (!file.sharedWith.has(userId)) {
        file.sharedWith.add(userId);
        console.log(`[FILE REGISTRY] Seeder ${userId} auto-added to sharedWith for ${fileId.substring(0, 8)}`);
      }
      
      // If from creator: Merge with payload sharedWith (add new users)
      if (file.creator === userId && sharedWith && sharedWith.length > 0) {
        sharedWith.forEach(id => {
          if (!file.sharedWith.has(id)) {
            file.sharedWith.add(id);
            console.log(`[FILE REGISTRY] Added ${id} to sharedWith for ${fileId.substring(0, 8)} (from creator)`);
          }
        });
      }
      
      // Checksum verification (prevent malicious data)
      if (file.checksum !== checksum) {
        console.error(`[SECURITY] ❌ Checksum mismatch from ${userId} for ${fileId.substring(0, 8)}`);
        console.error(`[SECURITY] Canonical checksum: ${file.checksum} (set by ${file.checksumSetBy} at ${new Date(file.checksumSetAt).toISOString()})`);
        console.error(`[SECURITY] Received checksum: ${checksum} (from ${userId})`);
        console.error(`[SECURITY] REJECT: File integrity compromised or wrong file announced!`);
        return null; // ❌ REJECT mismatched checksum
      }
      
      console.log(`[FILE REGISTRY] ✓ Checksum verified for ${fileId.substring(0, 8)}: ${checksum.substring(0, 16)}...`);
      
      file.lastActivity = Date.now();
    }
    
    // Add device as seeder
    file.seeders.add(deviceKey);
    this.fileSeeders.get(fileId).add(deviceKey);
    
    // Update device's seed list
    if (!this.userSeeds.has(deviceKey)) {
      this.userSeeds.set(deviceKey, new Set());
    }
    this.userSeeds.get(deviceKey).add(fileId);
    
    // Store available chunks for this seeder
    if (!file.seederChunks) {
      file.seederChunks = new Map();
    }
    file.seederChunks.set(deviceKey, availableChunks || []);
    
    file.totalSeeds++;
    
    return this.getFileInfo(fileId);
  }

  /**
   * Share a file with another user (LÖSUNG 13)
   * 
   * @param {string} fileId - File ID
   * @param {string} creatorId - User sharing the file (must be creator)
   * @param {string} targetUserId - User to share with
   * @returns {boolean} Success
   */
  shareFile(fileId, creatorId, targetUserId) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Add to sharedWith set
    if (!file.sharedWith) {
      file.sharedWith = new Set([file.creator]);
    }
    file.sharedWith.add(targetUserId);
    
    console.log(`[FILE REGISTRY] File ${fileId} shared with ${targetUserId} by ${creatorId}`);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Unshare a file with a user (LÖSUNG 13)
   * 
   * @param {string} fileId - File ID
   * @param {string} creatorId - User unsharing the file (must be creator)
   * @param {string} targetUserId - User to remove access from
   * @returns {boolean} Success
   */
  unshareFile(fileId, creatorId, targetUserId) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Only creator can unshare
    if (file.creator !== creatorId) {
      console.log(`[FILE REGISTRY] User ${creatorId} is not creator of ${fileId}, cannot unshare`);
      return false;
    }
    
    // Cannot unshare from creator
    if (targetUserId === file.creator) {
      console.log(`[FILE REGISTRY] Cannot unshare file from creator`);
      return false;
    }
    
    // Remove from sharedWith set
    if (file.sharedWith) {
      file.sharedWith.delete(targetUserId);
    }
    
    console.log(`[FILE REGISTRY] File ${fileId} unshared from ${targetUserId} by ${creatorId}`);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Check if a user can access a file (LÖSUNG 14)
   * 
   * @param {string} userId - User ID to check
   * @param {string} fileId - File ID
   * @returns {boolean} True if user has access
   */
  canAccess(userId, fileId) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Creator always has access
    if (file.creator === userId) return true;
    
    // Check sharedWith set
    if (file.sharedWith && file.sharedWith.has(userId)) return true;
    
    return false;
  }

  /**
   * Get all users who have access to a file (LÖSUNG 13)
   * 
   * @param {string} fileId - File ID
   * @returns {array} Array of user IDs with access
   */
  getSharedUsers(fileId) {
    const file = this.files.get(fileId);
    if (!file || !file.sharedWith) return [];
    
    return Array.from(file.sharedWith);
  }

  /**
   * Unannounce a file (device no longer seeding)
   * 
   * If user is the creator, completely delete the file from registry
   * Otherwise, just remove device as seeder
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  unannounceFile(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    // Check if user is the creator
    const isCreator = file.creator === userId;
    
    if (isCreator) {
      // Creator wants to delete - remove file completely
      console.log(`[FILE REGISTRY] Creator ${userId} deleting file ${fileId} completely`);
      
      // Remove file from registry
      this.files.delete(fileId);
      this.fileSeeders.delete(fileId);
      this.fileLeechers.delete(fileId);
      
      // Remove from all devices' seed lists
      for (const [devKey, fileSet] of this.userSeeds.entries()) {
        fileSet.delete(fileId);
      }
      
      return true;
    }
    
    // Non-creator: just remove as seeder
    // Remove device as seeder
    file.seeders.delete(deviceKey);
    this.fileSeeders.get(fileId)?.delete(deviceKey);
    
    // Remove from device's seed list
    this.userSeeds.get(deviceKey)?.delete(fileId);
    
    // Remove seeder chunks
    file.seederChunks?.delete(deviceKey);
    
    // Update activity
    file.lastActivity = Date.now();
    
    // If no more seeders, mark for cleanup
    if (file.seeders.size === 0) {
      file.noSeedersTimestamp = Date.now();
    }
    
    return true;
  }

  /**
   * Update available chunks for a seeder
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {string} fileId - File ID
   * @param {array} availableChunks - Array of chunk indices
   * @returns {boolean} Success
   */
  updateAvailableChunks(userId, deviceId, fileId, availableChunks) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    if (!file.seederChunks) {
      file.seederChunks = new Map();
    }
    
    file.seederChunks.set(deviceKey, availableChunks);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Register a device as downloading a file
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  registerLeecher(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.add(deviceKey);
    this.fileLeechers.get(fileId).add(deviceKey);
    file.totalDownloads++;
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Unregister a device as downloading a file
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  unregisterLeecher(userId, deviceId, fileId) {
    const deviceKey = `${userId}:${deviceId}`;
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.delete(deviceKey);
    this.fileLeechers.get(fileId).delete(deviceKey);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Get file information including seeders
   * 
   * @param {string} fileId - File ID
   * @returns {object|null} File info or null
   */
  getFileInfo(fileId) {
    const file = this.files.get(fileId);
    if (!file) return null;
    
    // Convert seeder chunks Map to object (userId:deviceId -> chunks)
    const seederChunks = {};
    if (file.seederChunks) {
      for (const [deviceKey, chunks] of file.seederChunks.entries()) {
        seederChunks[deviceKey] = chunks;
      }
    }
    
    return {
      fileId: file.fileId,
      fileName: file.fileName,
      mimeType: file.mimeType,
      fileSize: file.fileSize,
      checksum: file.checksum, // Canonical checksum
      checksumSetBy: file.checksumSetBy, // Who set the canonical checksum
      checksumSetAt: file.checksumSetAt, // When checksum was set
      chunkCount: file.chunkCount,
      createdAt: file.createdAt,
      lastActivity: file.lastActivity,
      seeders: Array.from(file.seeders), // Array of userId:deviceId strings
      leechers: Array.from(file.leechers), // Array of userId:deviceId strings
      seederCount: file.seeders.size,
      leecherCount: file.leechers.size,
      totalSeeds: file.totalSeeds,
      totalDownloads: file.totalDownloads,
      seederChunks,
      creator: file.creator,
      sharedWith: file.sharedWith ? Array.from(file.sharedWith) : [file.creator],
    };
  }

  /**
   * Get all files a device is seeding
   * 
   * @param {string} userId - User ID
   * @param {string} deviceId - Device ID
   * @returns {array} Array of file IDs
   */
  getUserSeeds(userId, deviceId) {
    const deviceKey = `${userId}:${deviceId}`;
    const seeds = this.userSeeds.get(deviceKey);
    return seeds ? Array.from(seeds) : [];
  }

  /**
   * Find seeders for a file
   * 
   * @param {string} fileId - File ID
   * @returns {array} Array of userId:deviceId strings
   */
  getSeeders(fileId) {
    const seeders = this.fileSeeders.get(fileId);
    return seeders ? Array.from(seeders) : [];
  }

  /**
   * Get available chunks from all seeders for a file
   * 
   * @param {string} fileId - File ID
   * @returns {object} Map of userId:deviceId -> chunks[]
   */
  getAvailableChunks(fileId) {
    const file = this.files.get(fileId);
    if (!file || !file.seederChunks) return {};
    
    const result = {};
    for (const [deviceKey, chunks] of file.seederChunks.entries()) {
      result[deviceKey] = chunks;
    }
    return result;
  }

  /**
   * Search files by name or checksum
   * 
   * @param {string} query - Search query
   * @returns {array} Array of matching files
   */
  searchFiles(query) {
    const results = [];
    const lowerQuery = query.toLowerCase();
    
    for (const file of this.files.values()) {
      // Skip files with no seeders
      if (file.seeders.size === 0) continue;
      
      // Match filename or checksum
      if (
        file.fileName.toLowerCase().includes(lowerQuery) ||
        file.checksum?.toLowerCase().includes(lowerQuery)
      ) {
        results.push(this.getFileInfo(file.fileId));
      }
    }
    
    return results;
  }

  /**
   * Get all active files (with seeders)
   * 
   * @returns {array} Array of file info
   */
  getActiveFiles() {
    const results = [];
    
    for (const file of this.files.values()) {
      if (file.seeders.size > 0) {
        results.push(this.getFileInfo(file.fileId));
      }
    }
    
    return results;
  }

  /**
   * Clean up expired files and inactive devices
   * Called periodically by cleanup job
   * 
   * @returns {object} Cleanup stats
   */
  cleanup() {
    const now = Date.now();
    let filesRemoved = 0;
    let devicesRemoved = 0;
    
    // Remove expired files (30 days old with no seeders)
    for (const [fileId, file] of this.files.entries()) {
      const age = now - file.createdAt;
      const inactiveDuration = now - file.lastActivity;
      
      // Remove if:
      // 1. Older than 30 days AND no seeders
      // 2. No seeders for 7 days
      const shouldRemove = 
        (age > this.FILE_TTL && file.seeders.size === 0) ||
        (file.noSeedersTimestamp && (now - file.noSeedersTimestamp) > 7 * 24 * 60 * 60 * 1000);
      
      if (shouldRemove) {
        this.files.delete(fileId);
        this.fileSeeders.delete(fileId);
        this.fileLeechers.delete(fileId);
        filesRemoved++;
      }
    }
    
    // Clean up empty device seed lists
    for (const [deviceKey, seeds] of this.userSeeds.entries()) {
      if (seeds.size === 0) {
        this.userSeeds.delete(deviceKey);
        devicesRemoved++;
      }
    }
    
    return {
      filesRemoved,
      devicesRemoved,
      totalFiles: this.files.size,
      totalDevices: this.userSeeds.size,
    };
  }

  /**
   * Handle device disconnect - clean up their announcements
   * 
   * @param {string} userId - Disconnected user ID
   * @param {string} deviceId - Disconnected device ID
   */
  handleUserDisconnect(userId, deviceId) {
    const deviceKey = `${userId}:${deviceId}`;
    const userFiles = this.userSeeds.get(deviceKey);
    
    if (userFiles) {
      for (const fileId of userFiles) {
        this.unannounceFile(userId, deviceId, fileId);
      }
    }
    
    // Remove from all leecher lists
    for (const [fileId, leechers] of this.fileLeechers.entries()) {
      if (leechers.has(deviceKey)) {
        this.unregisterLeecher(userId, deviceId, fileId);
      }
    }
    
    this.userSeeds.delete(deviceKey);
  }

  /**
   * Calculate chunk availability quality
   * Returns percentage of available chunks (0-100)
   * 
   * @param {string} fileId - File ID
   * @returns {number} Quality percentage (0-100)
   */
  getChunkQuality(fileId) {
    const file = this.files.get(fileId);
    if (!file) return 0;
    
    // Collect all unique chunks from all seeders
    const availableChunks = new Set();
    
    if (file.seederChunks) {
      for (const chunks of file.seederChunks.values()) {
        chunks.forEach(idx => availableChunks.add(idx));
      }
    }
    
    if (file.chunkCount === 0) return 0;
    
    const quality = (availableChunks.size / file.chunkCount) * 100;
    return Math.round(quality);
  }

  /**
   * Get missing chunk indices
   * 
   * @param {string} fileId - File ID
   * @returns {array} Array of missing chunk indices
   */
  getMissingChunks(fileId) {
    const file = this.files.get(fileId);
    if (!file) return [];
    
    const availableChunks = new Set();
    
    if (file.seederChunks) {
      for (const chunks of file.seederChunks.values()) {
        chunks.forEach(idx => availableChunks.add(idx));
      }
    }
    
    const missing = [];
    for (let i = 0; i < file.chunkCount; i++) {
      if (!availableChunks.has(i)) {
        missing.push(i);
      }
    }
    
    return missing;
  }

  /**
   * Get registry statistics
   * 
   * @returns {object} Stats
   */
  getStats() {
    let totalSeeders = 0;
    let totalLeechers = 0;
    let totalChunks = 0;
    
    for (const file of this.files.values()) {
      totalSeeders += file.seeders.size;
      totalLeechers += file.leechers.size;
      totalChunks += file.chunkCount || 0;
    }
    
    return {
      totalFiles: this.files.size,
      activeFiles: Array.from(this.files.values()).filter(f => f.seeders.size > 0).length,
      totalDevices: this.userSeeds.size,
      totalSeeders,
      totalLeechers,
      totalChunks,
    };
  }
}

// Singleton instance
const fileRegistry = new FileRegistry();

module.exports = fileRegistry;
