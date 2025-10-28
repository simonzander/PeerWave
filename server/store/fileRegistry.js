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
    
    // Map: userId -> Set of fileIds (what user is seeding)
    this.userSeeds = new Map();
    
    // Map: fileId -> Set of userIds (who is seeding this file)
    this.fileSeeders = new Map();
    
    // Map: fileId -> Set of userIds (who is downloading this file)
    this.fileLeechers = new Map();
    
    // TTL for file announcements (30 days)
    this.FILE_TTL = 30 * 24 * 60 * 60 * 1000; // 30 days in ms
  }

  /**
   * Announce a file (user has chunks available)
   * 
   * @param {string} userId - User announcing the file
   * @param {object} fileMetadata - File metadata (NO fileName for privacy)
   * @returns {object} Updated file info
   */
  announceFile(userId, fileMetadata) {
    const { fileId, mimeType, fileSize, checksum, chunkCount, availableChunks } = fileMetadata;
    
    // Get or create file entry
    let file = this.files.get(fileId);
    
    if (!file) {
      // New file announcement - save creator
      file = {
        fileId,
        mimeType,
        fileSize,
        checksum,
        chunkCount,
        creator: userId, // Store who created/uploaded this file
        createdAt: Date.now(),
        lastActivity: Date.now(),
        seeders: new Set(),
        leechers: new Set(),
        totalSeeds: 0,
        totalDownloads: 0,
      };
      this.files.set(fileId, file);
      this.fileSeeders.set(fileId, new Set());
      this.fileLeechers.set(fileId, new Set());
    } else {
      // Update existing file
      file.lastActivity = Date.now();
    }
    
    // Add user as seeder
    file.seeders.add(userId);
    this.fileSeeders.get(fileId).add(userId);
    
    // Update user's seed list
    if (!this.userSeeds.has(userId)) {
      this.userSeeds.set(userId, new Set());
    }
    this.userSeeds.get(userId).add(fileId);
    
    // Store available chunks for this seeder
    if (!file.seederChunks) {
      file.seederChunks = new Map();
    }
    file.seederChunks.set(userId, availableChunks || []);
    
    file.totalSeeds++;
    
    return this.getFileInfo(fileId);
  }

  /**
   * Unannounce a file (user no longer seeding)
   * 
   * If user is the creator, completely delete the file from registry
   * Otherwise, just remove user as seeder
   * 
   * @param {string} userId - User unannouncing the file
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  unannounceFile(userId, fileId) {
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
      
      // Remove from all users' seed lists
      for (const [uid, fileSet] of this.userSeeds.entries()) {
        fileSet.delete(fileId);
      }
      
      return true;
    }
    
    // Non-creator: just remove as seeder
    // Remove user as seeder
    file.seeders.delete(userId);
    this.fileSeeders.get(fileId)?.delete(userId);
    
    // Remove from user's seed list
    this.userSeeds.get(userId)?.delete(fileId);
    
    // Remove seeder chunks
    file.seederChunks?.delete(userId);
    
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
   * @param {string} userId - Seeder user ID
   * @param {string} fileId - File ID
   * @param {array} availableChunks - Array of chunk indices
   * @returns {boolean} Success
   */
  updateAvailableChunks(userId, fileId, availableChunks) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    if (!file.seederChunks) {
      file.seederChunks = new Map();
    }
    
    file.seederChunks.set(userId, availableChunks);
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Register a user as downloading a file
   * 
   * @param {string} userId - Leecher user ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  registerLeecher(userId, fileId) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.add(userId);
    this.fileLeechers.get(fileId).add(userId);
    file.totalDownloads++;
    file.lastActivity = Date.now();
    
    return true;
  }

  /**
   * Unregister a user as downloading a file
   * 
   * @param {string} userId - Leecher user ID
   * @param {string} fileId - File ID
   * @returns {boolean} Success
   */
  unregisterLeecher(userId, fileId) {
    const file = this.files.get(fileId);
    if (!file) return false;
    
    file.leechers.delete(userId);
    this.fileLeechers.get(fileId).delete(userId);
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
    
    // Convert seeder chunks Map to object
    const seederChunks = {};
    if (file.seederChunks) {
      for (const [userId, chunks] of file.seederChunks.entries()) {
        seederChunks[userId] = chunks;
      }
    }
    
    return {
      fileId: file.fileId,
      fileName: file.fileName,
      mimeType: file.mimeType,
      fileSize: file.fileSize,
      checksum: file.checksum,
      chunkCount: file.chunkCount,
      createdAt: file.createdAt,
      lastActivity: file.lastActivity,
      seeders: Array.from(file.seeders),
      leechers: Array.from(file.leechers),
      seederCount: file.seeders.size,
      leecherCount: file.leechers.size,
      totalSeeds: file.totalSeeds,
      totalDownloads: file.totalDownloads,
      seederChunks,
    };
  }

  /**
   * Get all files a user is seeding
   * 
   * @param {string} userId - User ID
   * @returns {array} Array of file IDs
   */
  getUserSeeds(userId) {
    const seeds = this.userSeeds.get(userId);
    return seeds ? Array.from(seeds) : [];
  }

  /**
   * Find seeders for a file
   * 
   * @param {string} fileId - File ID
   * @returns {array} Array of user IDs
   */
  getSeeders(fileId) {
    const seeders = this.fileSeeders.get(fileId);
    return seeders ? Array.from(seeders) : [];
  }

  /**
   * Get available chunks from all seeders for a file
   * 
   * @param {string} fileId - File ID
   * @returns {object} Map of userId -> chunks[]
   */
  getAvailableChunks(fileId) {
    const file = this.files.get(fileId);
    if (!file || !file.seederChunks) return {};
    
    const result = {};
    for (const [userId, chunks] of file.seederChunks.entries()) {
      result[userId] = chunks;
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
   * Clean up expired files and inactive users
   * Called periodically by cleanup job
   * 
   * @returns {object} Cleanup stats
   */
  cleanup() {
    const now = Date.now();
    let filesRemoved = 0;
    let usersRemoved = 0;
    
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
    
    // Clean up empty user seed lists
    for (const [userId, seeds] of this.userSeeds.entries()) {
      if (seeds.size === 0) {
        this.userSeeds.delete(userId);
        usersRemoved++;
      }
    }
    
    return {
      filesRemoved,
      usersRemoved,
      totalFiles: this.files.size,
      totalUsers: this.userSeeds.size,
    };
  }

  /**
   * Handle user disconnect - clean up their announcements
   * 
   * @param {string} userId - Disconnected user ID
   */
  handleUserDisconnect(userId) {
    const userFiles = this.getUserSeeds(userId);
    
    for (const fileId of userFiles) {
      this.unannounceFile(userId, fileId);
    }
    
    // Remove from all leecher lists
    for (const [fileId, leechers] of this.fileLeechers.entries()) {
      if (leechers.has(userId)) {
        this.unregisterLeecher(userId, fileId);
      }
    }
    
    this.userSeeds.delete(userId);
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
      totalUsers: this.userSeeds.size,
      totalSeeders,
      totalLeechers,
      totalChunks,
    };
  }
}

// Singleton instance
const fileRegistry = new FileRegistry();

module.exports = fileRegistry;
