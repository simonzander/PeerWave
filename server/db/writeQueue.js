/**
 * Centralized write queue for database operations
 * Ensures only one write operation happens at a time to prevent SQLite locks
 */
class WriteQueue {
  constructor() {
    this.queue = null;
    this.isInitialized = false;
    this.pendingOperations = [];
    
    // Initialize p-queue asynchronously
    this._initQueue();
    
    // Statistics
    this.stats = {
      totalEnqueued: 0,
      totalCompleted: 0,
      totalFailed: 0
    };
  }

  async _initQueue() {
    try {
      const PQueue = (await import('p-queue')).default;
      this.queue = new PQueue({ 
        concurrency: 1,  // Only 1 write at a time
        timeout: 30000,  // 30 second timeout per operation
        throwOnTimeout: true
      });
      this.isInitialized = true;
      console.log('[WriteQueue] Initialized with concurrency: 1');
      
      // Process any pending operations
      while (this.pendingOperations.length > 0) {
        const { operation, name, resolve, reject } = this.pendingOperations.shift();
        this._enqueueOperation(operation, name).then(resolve).catch(reject);
      }
    } catch (error) {
      console.error('[WriteQueue] Failed to initialize:', error);
      throw error;
    }
  }

  async _enqueueOperation(operation, name) {
    this.stats.totalEnqueued++;
    const queueSize = this.queue.size;
    const pending = this.queue.pending;
    
    console.log(`[WRITE QUEUE] Enqueuing operation: ${name} (Queue size: ${queueSize}, Pending: ${pending})`);
    
    try {
      const result = await this.queue.add(async () => {
        console.log(`[WRITE QUEUE] Executing: ${name}`);
        const startTime = Date.now();
        
        try {
          const opResult = await operation();
          const duration = Date.now() - startTime;
          console.log(`[WRITE QUEUE] ✓ Completed: ${name} (${duration}ms)`);
          this.stats.totalCompleted++;
          return opResult;
        } catch (error) {
          const duration = Date.now() - startTime;
          console.error('[WRITE QUEUE] ✗ Failed: %s (%sms)', name, duration, error.message);
          this.stats.totalFailed++;
          throw error;
        }
      });
      
      return result;
    } catch (error) {
      console.error('[WRITE QUEUE] Error enqueuing operation: %s', name, error.message);
      throw error;
    }
  }

  /**
   * Enqueue a database write operation
   * @param {Function} operation - Async function that performs the DB write
   * @param {String} name - Optional name for logging/debugging
   * @returns {Promise} - Result of the operation
   */
  async enqueue(operation, name = 'unnamed') {
    // If queue is not initialized yet, add to pending operations
    if (!this.isInitialized) {
      console.log(`[WRITE QUEUE] Queue not ready yet, adding to pending: ${name}`);
      return new Promise((resolve, reject) => {
        this.pendingOperations.push({ operation, name, resolve, reject });
      });
    }
    
    return this._enqueueOperation(operation, name);
  }

  /**
   * Get current queue statistics
   */
  getStats() {
    if (!this.isInitialized) {
      return {
        ...this.stats,
        queueSize: 0,
        pending: this.pendingOperations.length,
        isPaused: false,
        initialized: false
      };
    }
    
    return {
      ...this.stats,
      queueSize: this.queue.size,
      pending: this.queue.pending,
      isPaused: this.queue.isPaused,
      initialized: true
    };
  }

  /**
   * Pause the queue (for maintenance)
   */
  pause() {
    if (this.queue) {
      this.queue.pause();
      console.log('[WRITE QUEUE] Queue paused');
    }
  }

  /**
   * Resume the queue
   */
  resume() {
    if (this.queue) {
      this.queue.start();
      console.log('[WRITE QUEUE] Queue resumed');
    }
  }

  /**
   * Wait for all pending operations to complete
   */
  async onIdle() {
    if (this.queue) {
      await this.queue.onIdle();
      console.log('[WRITE QUEUE] Queue is now idle');
    }
  }

  /**
   * Clear all pending operations
   */
  clear() {
    if (this.queue) {
      this.queue.clear();
      console.log('[WRITE QUEUE] Queue cleared');
    }
    this.pendingOperations = [];
  }
}

// Export singleton instance
const writeQueue = new WriteQueue();

module.exports = writeQueue;
